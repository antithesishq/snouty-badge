//! Real-time ray tracer for the M2.2 scene (PLAN.md "The M1 scene, exactly",
//! "The M2 scene, exactly" and M2.2 "The scene changes, exactly").
//! Column-major: the ray basis fwd + right*u is built once per column, up*v
//! comes from a comptime row table and the primary ray's 1/length from a
//! per-pixel table. Recursion is resolved at comptime: `trace` is
//! instantiated per (depth, came-from) pair, so there is no runtime recursion
//! and the depth bound (0..2) is structural. The hot instantiations (primary
//! rays and their chrome and water bounces) are inlined; the rest are shared
//! calls.
//!
//! Each column is split into row runs by what a primary ray can hit
//! (plan_columns, before the render loop): the chrome sphere's, the glass
//! sphere's and the Iris logo's per-frame screen spans (.eye segments, each
//! testing only the objects whose span covers it), and outside them sky rows
//! above the shore band (sky only), sky rows in it (shore or sky), water rows
//! that may still reach the shore (shore test first) and the other water rows
//! (hit point and fade from comptime tables, no divide); the water rows whose
//! reflection may meet the logo run a form that tests it. The split is exact
//! or conservative, see sphere_rows, shore_first_row, shore_water_end,
//! water_logo_rows and camera.first_water_row.
const std = @import("std");
const cart = @import("cart-api");
const math = @import("math.zig");
const dither = @import("dither.zig");
const camera = @import("camera.zig");
const scene = @import("scene.zig");
const water = @import("water.zig");
const variant = @import("variant.zig");
const iris = @import("iris.zig");
const Vec3 = math.Vec3;
const splat = math.splat;

const no_hit: f32 = math.inf_f32;
const max_water_t: f32 = 1e5;

/// Benchmark switch: when true the glass, shore and water-shadow shading
/// functions are noinline, so `badge-bench/bench.sh --symbols` attributes
/// their cycles. Ship it off.
const bench_split = false;
const split_call: std.builtin.CallModifier = if (bench_split) .never_inline else .always_inline;

/// Where a ray was spawned; lets the tracer skip tests that cannot succeed.
const From = enum {
    /// Primary ray from the eye inside a span (chrome, glass or logo):
    /// everything, each object only in the rows of its span (EyeFlags).
    eye,
    /// Primary ray outside the spans going up, above the shore band: sky.
    eye_sky,
    /// Primary ray outside the spans going up, in the shore band: shore or
    /// sky.
    eye_env,
    /// Primary ray outside the spans going down, in rows that may pass
    /// z = 14 above the water: shore, else water as eye_water.
    eye_water_shore,
    /// Primary ray outside the spans going down: water, hit from the
    /// comptime tables (PrimaryWater).
    eye_water,
    /// eye_water_shore and eye_water in the rows whose reflection may meet
    /// the logo (water_logo_rows): they spawn water_logo rays.
    eye_water_shore_logo,
    eye_water_logo,
    /// Reflection off the convex chrome sphere: cannot hit it again.
    sphere,
    /// Reflected off or transmitted through the convex glass sphere: cannot
    /// hit it again.
    glass,
    /// Reflection off the water: r.y >= 0.02, cannot hit the water. A
    /// per-frame bound rules out the logo.
    water,
    /// Reflection off the water that may meet the logo (knob 6).
    water_logo,
};

inline fn off_water(from: From) bool {
    return from == .water or from == .water_logo;
}

/// The primary water kinds: hit from the comptime tables.
inline fn eye_water_kind(from: From) bool {
    return switch (from) {
        .eye_water, .eye_water_shore, .eye_water_logo, .eye_water_shore_logo => true,
        else => false,
    };
}

/// The kind of the water reflection a primary water ray spawns.
fn water_child(comptime from: From) From {
    return switch (from) {
        .eye_water, .eye_water_shore => .water,
        else => if (scene.iris_in_water) .water_logo else .water,
    };
}

/// The same row kind with the logo in its water reflections.
fn with_water_logo(comptime from: From) From {
    return switch (from) {
        .eye_water => .eye_water_logo,
        .eye_water_shore => .eye_water_shore_logo,
        else => unreachable,
    };
}

/// Per-frame state shared by every ray.
const Frame = struct {
    ph: water.Phases,
    iris: iris.Frame,
};

/// Tests of the primary rays of an .eye run (a segment of the column inside
/// some span): which objects' spans hold the run, and whether its water
/// reflections may reach the logo (water_logo_rows). Constant per run.
const EyeFlags = packed struct(u8) {
    chrome: bool = false,
    glass: bool = false,
    logo: bool = false,
    water_logo: bool = false,
    _: u4 = 0,
};

/// Water hit of a primary water ray, from water.primary_t/_fade.
const PrimaryWater = struct { p: Vec3, fade: f32 };

/// trace's per-ray extra argument: the flags of an .eye ray, the water hit of
/// a primary water ray, and for a .water_logo ray whether it may reach the
/// logo (false for .eye rays outside water_logo_rows).
fn Extra(comptime from: From) type {
    if (eye_water_kind(from)) return PrimaryWater;
    return switch (from) {
        .eye => EyeFlags,
        .water_logo => bool,
        else => void,
    };
}

/// How hit_sphere forms the discriminant.
const SphereTest = enum {
    /// r^2 - |oc - b d|^2: the same value, but without the cancellation of
    /// two ~|oc|^2 terms, and first-order insensitive to the rounding of b.
    /// For primary rays, whose grazing silhouette hits have ill-conditioned
    /// reflections.
    stable,
    /// b^2 - (|oc|^2 - r^2), for secondary rays off the other sphere.
    standard,
    /// Origin on the water plane (o.y = 0 exactly), so oc = (o.x - cx, -cy,
    /// o.z - cz) and |oc|^2 - r^2 = (o.x - cx)^2 + (o.z - cz)^2 + (cy^2 - r^2).
    on_water,
};

/// Nearest t > 1e-3 of the sphere (centre c, radius r), or no_hit. Assumes
/// |d| = 1 (a = 1 in the quadratic) and an origin outside the sphere.
inline fn hit_sphere(comptime c: Vec3, comptime r: f32, o: Vec3, d: Vec3, comptime mode: SphereTest) f32 {
    const oc = o - c;
    const b = if (mode == .on_water) oc[0] * d[0] + oc[2] * d[2] - c[1] * d[1] else math.dot(oc, d);
    // Outside the sphere and moving away: both roots are negative.
    if (mode != .stable and b >= 0.0) return no_hit;
    const disc = switch (mode) {
        .stable => blk: {
            const q = oc - d * splat(b);
            break :blk r * r - math.dot(q, q);
        },
        .standard => b * b - (math.dot(oc, oc) - r * r),
        .on_water => blk: {
            const k: f32 = comptime c[1] * c[1] - r * r;
            const h2 = oc[0] * oc[0] + oc[2] * oc[2];
            break :blk b * b - (if (k == 0.0) h2 else h2 + k);
        },
    };
    if (disc < 0.0) return no_hit;
    const sq = @sqrt(disc);
    const t0 = -b - sq;
    if (t0 > 1e-3) return t0;
    const t1 = -b + sq;
    if (t1 > 1e-3) return t1;
    return no_hit;
}

inline fn hit_chrome(o: Vec3, d: Vec3, comptime mode: SphereTest) f32 {
    return hit_sphere(scene.sphere_centre, 1.0, o, d, mode);
}

/// no_hit without the glass sphere (scene.glass_enabled = false).
inline fn hit_glass(o: Vec3, d: Vec3, comptime mode: SphereTest) f32 {
    if (!scene.glass_enabled) return no_hit;
    return hit_sphere(scene.glass_centre, scene.glass_radius, o, d, mode);
}

/// Shore colour along the ray (o, d), or null if it misses the shore or
/// meets a transparent texel. `on_water`: o.y = 0 exactly. The band test is
/// done without the divide first (d.z > 0 scales it out), so rays that pass
/// above, below or beside the shore cost a few multiplies.
fn shore(o: Vec3, d: Vec3, comptime on_water: bool) ?Vec3 {
    // d.z > 0 as an integer test on the bits (+0 and -0 both fail): no FP
    // compare and status transfer on the path nearly every ray takes.
    if (@as(i32, @bitCast(d[2])) <= 0) return null;
    const dz = scene.shore_z - o[2];
    const yn = if (on_water) d[1] * dz else o[1] * d[2] + d[1] * dz;
    if (!(yn >= 0.0 and yn < scene.shore_height * d[2])) return null;
    const xn = o[0] * d[2] + d[0] * dz;
    if (!(xn > -scene.shore_half_width * d[2] and xn <= scene.shore_half_width * d[2])) return null;
    const ts = dz / d[2];
    const xs = o[0] + d[0] * ts;
    const ys = if (on_water) d[1] * ts else o[1] + d[1] * ts;
    // The clamps catch the band edges, where the divide-free test and the
    // divided coordinates can round to different sides.
    const u = @min(@max((scene.shore_half_width - xs) * scene.shore_texels_per_unit, 0.0), 255.0);
    const v = @min(@max((scene.shore_height - ys) * scene.shore_texels_per_unit, 0.0), @as(f32, @floatFromInt(scene.shore_rows - 1)));
    return scene.shore_texel(@intFromFloat(u), @intFromFloat(v));
}

/// env(d) of the spec: the shore if the ray meets it, else the sky. `any_dir`
/// for directions that may point down (glass_secondary = .env).
inline fn env(o: Vec3, d: Vec3, comptime on_water: bool, comptime any_dir: bool) Vec3 {
    if (@call(split_call, shore, .{ o, d, on_water })) |c| return c;
    return if (any_dir) scene.sky_clamped(d) else scene.sky(d);
}

/// Proposed knob 4's lookup: env() for upward rays; a downward ray sees
/// flat, unshadowed water reflecting env() (no ripples, no spheres).
inline fn env_flat(o: Vec3, d: Vec3) Vec3 {
    if (!(d[1] < 0.0)) return env(o, d, false, false);
    const r = math.vec3(d[0], @max(-d[1], scene.min_reflect_y), d[2]);
    const f = math.schlick(-d[1], scene.water_f0);
    var spec = @max(0.0, math.dot(r, scene.sun_dir));
    inline for (0..6) |_| spec *= spec; // ^64
    const base = comptime scene.water_deep + scene.water_scatter;
    return math.lerp(base, scene.sky(r), f) + scene.water_spec_col * splat(spec);
}

/// Shadow factor of both spheres at water point `p` (y = 0), exactly as
/// the spec: the product of 1 - a * (1 - smoothstep(0.72 rs^2, 1.21 rs^2,
/// q2)) over the spheres the point is sunward-behind. Points outside a
/// sphere's comptime shadow box skip it. Builds shadow_map; the tracer reads
/// the map.
fn water_shadow_exact(px: f32, pz: f32) f32 {
    var sh: f32 = 1.0;
    inline for (scene.casters) |cs| {
        if (px >= cs.x0 and px <= cs.x1 and pz >= cs.z0 and pz <= cs.z1) {
            const oc = math.vec3(cs.c[0] - px, cs.c[1], cs.c[2] - pz);
            const b = math.dot(oc, scene.sun_dir);
            if (b > 0.0) {
                const q2 = math.dot(oc, oc) - b * b;
                const s = scene.smoothstep_k(cs.q2_lo, cs.q2_hi, q2);
                sh *= (1.0 - cs.opacity) + cs.opacity * s;
            }
        }
    }
    return sh;
}

/// The shadow is static (spheres and sun do not move), so it is sampled
/// once, in init(), on a grid of shadow_step over the union of the casters'
/// boxes, and read back bilinearly: one range test outside the boxes, four
/// loads inside, instead of the per-sphere boxes and quadratics. The
/// smoothstep is C1 and at least 4 cells wide, so the bilinear error is
/// below 0.05 in sh (a fraction of a colour unit through water_scatter and
/// the specular); only the b = 0 cut near the spheres' feet blurs by a cell.
/// 77 x 108 u8 = 8 KB of .bss with both casters (less without the glass).
const shadow_step: f32 = 1.0 / 32.0;
const shadow_x0: f32 = casters_bound("x0", false);
const shadow_z0: f32 = casters_bound("z0", false);
const shadow_nx: usize = @as(usize, @intFromFloat(@ceil((casters_bound("x1", true) - shadow_x0) / shadow_step))) + 2;
const shadow_nz: usize = @as(usize, @intFromFloat(@ceil((casters_bound("z1", true) - shadow_z0) / shadow_step))) + 2;
var shadow_map: [shadow_nz][shadow_nx]u8 = undefined;

/// Min (or max) of one box edge over the casters (one or two, see
/// scene.glass_enabled), at comptime.
fn casters_bound(comptime field: []const u8, comptime max: bool) f32 {
    var v: f32 = @field(scene.casters[0], field);
    for (scene.casters[1..]) |cs| v = if (max) @max(v, @field(cs, field)) else @min(v, @field(cs, field));
    return v;
}

var ready = false;

/// Fills shadow_map and camera.inv_len_table; main.start() calls it, and
/// render_frame calls it if nobody has (the emulator bench).
pub fn init() void {
    ready = true;
    camera.init();
    for (&shadow_map, 0..) |*row, j| {
        const pz = shadow_z0 + (@as(f32, @floatFromInt(j)) + 0.5) * shadow_step;
        for (row, 0..) |*m, i| {
            const sh = water_shadow_exact(shadow_x0 + (@as(f32, @floatFromInt(i)) + 0.5) * shadow_step, pz);
            m.* = @intFromFloat(@round(sh * 255.0));
        }
    }
}

/// Shadow factor at water point `p` from shadow_map; exactly 1 outside it.
fn water_shadow(p: Vec3) f32 {
    const fx = (p[0] - shadow_x0) * (1.0 / shadow_step);
    const fz = (p[2] - shadow_z0) * (1.0 / shadow_step);
    const i: u32 = @bitCast(@as(i32, @intFromFloat(@floor(fx))));
    const j: u32 = @bitCast(@as(i32, @intFromFloat(@floor(fz))));
    if (i >= shadow_nx or j >= shadow_nz) return 1.0;
    return @as(f32, @floatFromInt(shadow_map[j][i])) * (1.0 / 255.0);
}

/// Direction from the chrome sphere's centre to the logo's, and the cosine
/// of the cone around it that holds every chrome reflection able to meet the
/// logo's bounding sphere: from a point p on the unit sphere the bounding
/// sphere subtends at most asin(R / (|C - Sc| - 1)), and C - p is within
/// asin(1 / |C - Sc|) of C - Sc; plus 0.01 rad of margin. Comptime, so a
/// chrome reflection pays a dot product and a compare.
const chrome_logo = blk: {
    const dx: f64 = iris.centre[0] - scene.sphere_centre[0];
    const dy: f64 = iris.centre[1] - scene.sphere_centre[1];
    const dz: f64 = iris.centre[2] - scene.sphere_centre[2];
    const dist = @sqrt(dx * dx + dy * dy + dz * dz);
    const ang = std.math.asin(@as(f64, iris.radius) / (dist - 1.0)) + std.math.asin(1.0 / dist) + 0.01;
    break :blk .{
        .dir = math.vec3(@floatCast(dx / dist), @floatCast(dy / dist), @floatCast(dz / dist)),
        .cos = @as(f32, @floatCast(@cos(ang))),
    };
};

/// |r|^2 of a water reflection is at least this: water.normal's one Newton
/// step leaves |n|^2 in [0.996, 1] for gradients up to max_slope, and
/// reflect() about such an n gives |r|^2 = 1 - 4 dot(d, n)^2 (1 - |n|^2).
const water_refl_len2_min: f32 = 0.984;

/// The logo along (o, d), or null. Chrome reflections first pass the
/// comptime cone, water reflections (o.y = 0, unnormalised) the bounding
/// sphere with the length bound: a hit needs b = dot(o - C, d) < 0 (the
/// water is outside the sphere, c > 0) and b^2 >= |d|^2 c. The rest is a
/// call, so the hot loops that inline this keep their registers.
inline fn logo(o: Vec3, d: Vec3, t_near: f32, comptime from: From, fs: *const Frame) ?Vec3 {
    if (from == .sphere and math.dot(d, chrome_logo.dir) < chrome_logo.cos) {
        if (debug_span and debug_hits_logo_sphere(o, d)) debug_logo_miss = true;
        return null;
    }
    if (off_water(from)) {
        const cen = iris.centre;
        const ox = o[0] - cen[0];
        const oz = o[2] - cen[2];
        const b = ox * d[0] + oz * d[2] - cen[1] * d[1];
        if (!(b < 0.0)) return null;
        const c = ox * ox + oz * oz + comptime (cen[1] * cen[1] - iris.radius * iris.radius);
        if (!(b * b >= water_refl_len2_min * c)) return null;
    }
    return @call(logo_call(from), logo_chord, .{ o, d, t_near, from, fs });
}

/// Primary rays inline the whole logo test (-0.5 ms modelled at the worst
/// frame, +2.5 KB); the secondary rays call it, which keeps the variants
/// under the size budget.
fn logo_call(comptime from: From) std.builtin.CallModifier {
    return if (from == .eye) .always_inline else .never_inline;
}

/// The bounding-sphere chord, clipped to t > 1e-3 and to t_near (the nearer
/// sphere hit: a ray from the water beyond the logo can meet the chrome
/// sphere after it), then iris.hit. Water reflections (o.y = 0) arrive
/// unnormalised; they are rejected with the length bound first and
/// renormalised only if they may hit, so the chord is exact.
fn logo_chord(o: Vec3, d_in: Vec3, t_near: f32, comptime from: From, fs: *const Frame) ?Vec3 {
    const cen = iris.centre;
    const oc = if (off_water(from)) math.vec3(o[0] - cen[0], -cen[1], o[2] - cen[2]) else o - cen;
    const c = math.dot(oc, oc) - iris.radius * iris.radius;
    var d = d_in;
    var b = math.dot(oc, d);
    if (off_water(from)) {
        // logo() has done the reject on the unnormalised d.
        d = math.renormalize(d);
        b = math.dot(oc, d);
    }
    const disc = b * b - c;
    if (!(disc >= 0.0)) return null;
    const sq = @sqrt(disc);
    const t_min = @max(-b - sq, 1e-3);
    const t_max = @min(-b + sq, t_near);
    if (!(t_min < t_max)) return null;
    return @call(logo_call(from), iris.hit, .{ oc, d, t_min, t_max, &fs.iris });
}

/// Colour of a ray `d` hitting the water at `p` (y = 0) with ripple fade
/// `fade`. At depth 0 the reflection is traced as `child` (.water when a
/// per-frame bound rules out the logo) with `gate` its runtime extra.
inline fn shade_water(
    p: Vec3,
    d: Vec3,
    fade: f32,
    comptime depth: u32,
    fs: *const Frame,
    comptime child: From,
    gate: Extra(child),
) Vec3 {
    const n = water.normal(p, fade, fs.ph);
    var r = math.reflect(d, n);
    if (r[1] < scene.min_reflect_y) {
        r[1] = scene.min_reflect_y;
        r = math.normalize(r);
    }
    if (debug_span and depth == 0 and (child == .water or !gate) and debug_hits_logo_sphere(p, math.normalize(r)))
        debug_logo_miss = true;
    const refl = if (depth == 0)
        @call(.always_inline, trace, .{ p, r, depth + 1, child, fs, gate })
    else if (depth < 2)
        (if (scene.iris_in_water) trace(p, r, depth + 1, .water_logo, fs, true) else trace(p, r, depth + 1, .water, fs, {}))
    else
        water_env(p, r, fs);
    const f = math.schlick(@max(0.0, -math.dot(d, n)), scene.water_f0);
    var spec = @max(0.0, math.dot(r, scene.sun_dir));
    inline for (0..6) |_| spec *= spec; // ^64
    const shadowed = switch (scene.water_shadows) {
        .all => true,
        .primary_only => depth == 0,
        .off => false,
    };
    if (shadowed) {
        const sh = @call(split_call, water_shadow, .{p});
        const base = scene.water_deep + scene.water_scatter * splat(sh);
        return math.lerp(base, refl, f) + scene.water_spec_col * splat(spec * sh);
    }
    const base = comptime scene.water_deep + scene.water_scatter;
    return math.lerp(base, refl, f) + scene.water_spec_col * splat(spec);
}

/// A depth-2 water reflection: env(), with the logo in front (knob 6).
inline fn water_env(p: Vec3, r: Vec3, fs: *const Frame) Vec3 {
    if (scene.iris_in_water) {
        if (logo(p, r, no_hit, .water_logo, fs)) |c| return c;
    }
    return env(p, r, true, false);
}

/// The runtime extra of a water_child that is always allowed to test.
fn gate_true(comptime from: From) Extra(water_child(from)) {
    if (comptime water_child(from) == .water) return {};
    return true;
}

/// Colour of a ray `d` hitting the chrome sphere at `p`.
inline fn shade_chrome(p: Vec3, d: Vec3, comptime depth: u32, fs: *const Frame) Vec3 {
    const n = p - scene.sphere_centre; // radius 1
    if (depth == 0) {
        return scene.sphere_tint * @call(.always_inline, trace, .{ p, math.reflect(d, n), depth + 1, .sphere, fs, {} });
    } else if (depth < 2) {
        return scene.sphere_tint * trace(p, math.reflect(d, n), depth + 1, .sphere, fs, {});
    } else {
        const lambert = 0.25 + 0.75 * @max(0.0, math.dot(n, scene.sun_dir));
        return scene.sphere_lit_col * splat(lambert);
    }
}

const eta_in: f32 = 1.0 / scene.glass_ior;
const inv_glass_r: f32 = 1.0 / scene.glass_radius;
/// The glass's two child rays are calls: inlining both measured -0.75 ms at
/// frame 558 for +14 KB of .text.
const glass_child_call: std.builtin.CallModifier = .auto;

/// Colour of a ray `d` hitting the glass sphere from outside at `p`, depth
/// < 2 (depth 2 is the constant glass_far). The spec's exit construction in
/// closed form: with cos_t = sqrt(k) the cosine inside, the chord is t1 =
/// 2 rg cos_t, so q - G = rg (n + 2 cos_t d1), c2 = cos_t and the exit
/// refraction's k2 = c^2. Same vectors, one sqrt instead of two and no
/// exit-point dot products.
fn shade_glass(p: Vec3, d: Vec3, comptime depth: u32, fs: *const Frame) Vec3 {
    const n = (p - scene.glass_centre) * splat(inv_glass_r);
    // c > 0 for a hit from outside; the clamp keeps grazing rounding from
    // pushing F above 1 (colours stay non-negative).
    const c = @max(0.0, -math.dot(d, n));
    const f = math.schlick(c, scene.glass_f0);
    const r = d + n * splat(2.0 * c);
    const k = 1.0 - eta_in * eta_in * (1.0 - c * c); // >= 1 - eta^2 > 0
    const cos_t = @sqrt(k);
    const d1 = d * splat(eta_in) + n * splat(eta_in * c - cos_t);
    const o2, const d2 = switch (scene.glass_mode) {
        .real => blk: {
            const q = p + d1 * splat(2.0 * scene.glass_radius * cos_t);
            const n2 = n + d1 * splat(2.0 * cos_t);
            break :blk .{ q, d1 * splat(scene.glass_ior) - n2 * splat(scene.glass_ior * cos_t - c) };
        },
        .fake => .{ p, math.renormalize(d1) },
    };
    const refl, const trans = if (depth == 1 and scene.glass_secondary == .env)
        .{ env(p, r, false, true), env(o2, d2, false, true) }
    else if (depth == 0 and scene.glass_primary == .env)
        .{ env_flat(p, r), env_flat(o2, d2) }
    else
        .{
            @call(glass_child_call, trace, .{ p, r, depth + 1, .glass, fs, {} }),
            @call(glass_child_call, trace, .{ o2, d2, depth + 1, .glass, fs, {} }),
        };
    return refl * splat(f) + scene.glass_tint * trans * splat(1.0 - f);
}

fn trace(
    o: Vec3,
    d: Vec3,
    comptime depth: u32,
    comptime from: From,
    fs: *const Frame,
    pw: Extra(from),
) Vec3 {
    switch (from) {
        .eye_sky => return scene.sky(d),
        .eye_env => return env(o, d, false, false),
        .eye_water, .eye_water_logo => return shade_water(pw.p, d, pw.fade, depth, fs, water_child(from), gate_true(from)),
        .eye_water_shore, .eye_water_shore_logo => {
            if (@call(split_call, shore, .{ o, d, false })) |c| return c;
            return shade_water(pw.p, d, pw.fade, depth, fs, water_child(from), gate_true(from));
        },
        else => {},
    }

    // Nearest sphere first: both lie above the water and nearer than the
    // shore along every ray (PLAN.md "The M2 scene, exactly").
    const mode: SphereTest = switch (from) {
        .eye => .stable,
        .water, .water_logo => .on_water,
        else => .standard,
    };
    // .eye rows test only the objects whose span holds the row.
    const chrome_ok = switch (from) {
        .sphere => false,
        .eye => pw.chrome,
        else => true,
    };
    const glass_ok = switch (from) {
        .glass => false,
        .eye => pw.glass,
        else => true,
    };
    const tc = if (chrome_ok) hit_chrome(o, d, mode) else no_hit;
    const tg = if (glass_ok) hit_glass(o, d, mode) else no_hit;

    // The logo lies above the water and in front of the shore, so only a
    // sphere can be nearer; its chord ends at the nearer sphere hit.
    const logo_ok = switch (from) {
        .eye => pw.logo,
        .sphere => scene.iris_in_chrome,
        .water_logo => pw,
        else => false,
    };
    if (logo_ok) {
        if (logo(o, d, @min(tc, tg), from, fs)) |c| return c;
    }

    if (tc < tg) return shade_chrome(o + d * splat(tc), d, depth, fs);
    if (tg != no_hit) {
        if (depth == 2) return scene.glass_far;
        return @call(split_call, shade_glass, .{ o + d * splat(tg), d, depth, fs });
    }

    if (@call(split_call, shore, .{ o, d, off_water(from) })) |c| return c;

    if (!off_water(from) and d[1] < 0.0) {
        // tw = -o.y / d.y and g = 1 / (1 + fade_k * tw) = d.y / k with
        // k = d.y - fade_k * o.y, both from one reciprocal of d.y * k.
        // |d| = 1, so tw is the distance from the ray origin. o.y >= 0 and
        // d.y < 0, so k has no cancellation. tw is clamped so the ripple
        // phases stay inside sin_turns' range; past 1e5 the fade is below
        // 4e-8 and the normal is flat to f32 anyway.
        const k = d[1] - water.fade_k * o[1];
        const inv = 1.0 / (d[1] * k);
        const tw = @min(-o[1] * k * inv, max_water_t);
        // On the plane by construction; y = 0 exactly simplifies the sphere
        // tests of the reflected ray.
        const p = math.vec3(o[0] + d[0] * tw, 0.0, o[2] + d[2] * tw);
        const g = d[1] * d[1] * inv;
        const child = comptime water_child(from);
        const gate: Extra(child) = if (comptime child == .water) {} else if (from == .eye) pw.water_logo else true;
        return shade_water(p, d, g * g, depth, fs, child, gate);
    }

    return scene.sky(d);
}

/// Screen footprint of a sphere for primary rays, per frame. In camera
/// coordinates the sphere centre is c = (cx, cy, cz) relative to the eye and
/// the (unnormalised) primary ray is w = (u, v, 1). The ray line passes
/// within radius r of the centre iff (w.c)^2 >= (|c|^2 - r^2) |w|^2, which
/// for a fixed column u is a quadratic in v with a negative leading
/// coefficient when the eye is outside the sphere's cylinder along `up`
/// (true for both spheres on the whole orbit; sphere_rows falls back to the
/// whole column otherwise), so the hit rows of each column form one interval
/// between its roots. The span uses span_r2 * r^2 and pads a row each side,
/// so it is conservative against f32 rounding; rows outside it skip the
/// sphere tests.
const SphereSpan = struct {
    cx: f32,
    cy: f32,
    cz: f32,
    k: f32,
    a: f32,
    /// 1 / a, per frame.
    inv_a: f32,
};

const span_r2: f32 = 1.05;
/// Rows per unit of v: y = 63.5 - v * rows_per_v (camera.v_table inverted).
const rows_per_v: f32 = 80.0 / camera.tan_h;

fn sphere_span_at(cam: camera.Camera, centre: Vec3, r: f32) SphereSpan {
    const e2c = centre - cam.eye;
    const cy = math.dot(e2c, cam.up);
    const k = math.dot(e2c, e2c) - span_r2 * r * r;
    return .{
        .cx = math.dot(e2c, cam.right),
        .cy = cy,
        .cz = math.dot(e2c, cam.fwd),
        .k = k,
        .a = cy * cy - k,
        .inv_a = 1.0 / (cy * cy - k),
    };
}

const Rows = struct { lo: usize, hi: usize };

/// Rows [lo, hi) of column u that may hit the sphere (lo == hi if none).
inline fn sphere_rows(sp: SphereSpan, u: f32) Rows {
    if (!(sp.a < 0.0)) return .{ .lo = 0, .hi = camera.height };
    // (m + v cy)^2 - k (u^2 + v^2 + 1) >= 0 with m = u cx + cz:
    // a v^2 + 2 b v + q >= 0, a = cy^2 - k < 0.
    const m = u * sp.cx + sp.cz;
    const b = sp.cy * m;
    const q = m * m - sp.k * (u * u + 1.0);
    const disc = b * b - sp.a * q;
    if (!(disc >= 0.0)) return .{ .lo = 0, .hi = 0 };
    const sq = @sqrt(disc);
    const inv_a = sp.inv_a;
    // a < 0: (-b + sq) / a is the smaller root, (-b - sq) / a the larger.
    const v_min = (-b + sq) * inv_a;
    const v_max = (-b - sq) * inv_a;
    // Larger v is higher on screen (smaller y).
    const y_top = @floor(63.5 - v_max * rows_per_v) - 1.0;
    const y_bot = @ceil(63.5 - v_min * rows_per_v) + 2.0;
    const lo: usize = @intFromFloat(@min(@max(y_top, 0.0), camera.height));
    const hi: usize = @intFromFloat(@min(@max(y_bot, 0.0), camera.height));
    return .{ .lo = lo, .hi = @max(lo, hi) };
}

/// Primary water rows whose reflection may meet the logo, per column. A
/// primary ray E + t d hits the water at p; the ripple normal there is
/// tilted by at most theta = atan(fade * max_slope), so the reflected ray r
/// is within 2 theta of the flat mirror direction r0 (reflection about n is
/// 2-Lipschitz in n), plus 0.02 rad where the r.y >= 0.02 clamp lifts a
/// near-horizon ray and 0.008 for the unnormalised n: alpha. If r meets the
/// bounding sphere (C, R), then r0 is within asin(R / L) + alpha of C - p,
/// L = |C - p|, and mirroring in y = 0 (r0 -> d, C -> C' = (Cx, -Cy, Cz)),
/// d is within that angle of C' - p. Then:
///  - p lies before the point of the line nearest C' (t < tau): otherwise
///    the angle is >= 90 degrees, which needs asin(R / L) + alpha >= 90
///    degrees, and no water point qualifies (it would lie within 0.44 of
///    below C, over 7.9 from every eye position, where alpha < 0.32);
///  - the line's distance delta to C' is at most L sin(asin(R / L) +
///    alpha) <= R + s L, s = sin(2 theta) + slack >= sin(alpha) (sin(a + b)
///    <= sin a + sin b), and L^2 = delta^2 + (tau - t)^2 with 0 < tau - t <=
///    D' - t (D' = |C' - E| >= tau), so delta <= R + s sqrt(delta^2 +
///    (D' - t)^2), which solves to delta <= rho = (R + s sqrt(R^2 + (1 -
///    s^2) A^2)) / (1 - s^2), A = D' - t.
/// The line bound is a projected sphere around C' (sphere_span_at). Its
/// radius shrinks with t, so the water rows are cut into bands by the
/// comptime distance primary_t (at most the true distance t, so fade(t) and
/// D' - t at the band's nearest row bound the band); a band whose nearest
/// distance is at least D' is empty (t < tau <= D'). The column's range is
/// the hull of the bands' spans, each clipped to its band.
const WaterLogoBand = struct { lo: usize, hi: usize, t: f32, s: f32, inv_1ms2: f32 };

/// Band edges in primary_t, far to near.
const water_logo_band_t = [_]f32{ 16.0, 11.0, 7.5, 5.0 };
const water_logo_slack: f32 = 0.035;
const water_logo_nb = water_logo_band_t.len + 1;

/// Bands nearest first (largest radius first): rows, the distance of the
/// band's nearest row, s there and 1 / (1 - s^2).
const water_logo_bands: [water_logo_nb]WaterLogoBand = blk: {
    var bands: [water_logo_nb]WaterLogoBand = undefined;
    const fwr = camera.first_water_row;
    var hi: usize = camera.height;
    for (0..water_logo_nb) |b| {
        // Rows [lo, hi) with primary_t below the next edge (nearer rows
        // are lower on screen, so primary_t falls as y grows).
        var lo = hi;
        if (b + 1 < water_logo_nb) {
            const edge = water_logo_band_t[water_logo_nb - 2 - b];
            while (lo > fwr and water.primary_t[lo - 1 - fwr] < edge) lo -= 1;
        } else lo = fwr;
        const t = water.primary_t[hi - 1 - fwr];
        const g = 1.0 / (1.0 + water.fade_k * t);
        // sin(2 atan x) = 2 x / (1 + x^2), x = max_slope fade.
        const x = water.max_slope * g * g;
        const s = 2.0 * x / (1.0 + x * x) + water_logo_slack;
        bands[b] = .{ .lo = lo, .hi = hi, .t = t, .s = s, .inv_1ms2 = 1.0 / (1.0 - s * s) };
        hi = lo;
    }
    break :blk bands;
};

const C_mirror = math.vec3(iris.centre[0], -iris.centre[1], iris.centre[2]);

/// Per-frame spans of the active bands (a prefix: nearer bands first).
const WaterLogo = struct { sp: [water_logo_nb]SphereSpan, n: usize };

fn water_logo_at(cam: camera.Camera) WaterLogo {
    var wl: WaterLogo = .{ .sp = undefined, .n = 0 };
    if (!scene.iris_in_water) return wl;
    const e2c = C_mirror - cam.eye;
    const dd = @sqrt(math.dot(e2c, e2c));
    const r = iris.radius;
    inline for (water_logo_bands) |band| {
        const a = dd - band.t;
        if (!(a > 0.0)) return wl;
        // 1% on the radius covers the rounding of the bound itself.
        const s = band.s;
        const rho = 1.01 * (r + s * @sqrt(r * r + (1.0 - s * s) * a * a)) * band.inv_1ms2;
        const sp = sphere_span_at(cam, C_mirror, rho);
        // Wholly behind the eye's plane: no ray passes within rho ahead of
        // the eye (tau > 0), nor within the smaller radii of the next bands.
        if (sp.cz < -span_r2 * rho) return wl;
        wl.sp[wl.n] = sp;
        wl.n += 1;
    }
    return wl;
}

/// Hull of the active bands' rows in column u. The spans are nested (the
/// radius shrinks band by band), so an empty first span ends the column.
inline fn water_logo_rows(wl: *const WaterLogo, u: f32) Rows {
    if (wl.n == 0) return .{ .lo = 0, .hi = 0 };
    // Only rays with t < tau, so tau = dot(C' - E, d) > 0: rows with
    // m + v cy > 0 (sphere_rows' terms), one side of a row threshold,
    // padded by a row.
    const sp = &wl.sp[0];
    const m = u * sp.cx + sp.cz;
    var lo: usize = camera.height;
    var hi: usize = 0;
    var f_lo: usize = 0;
    var f_hi: usize = camera.height;
    if (sp.cy == 0.0) {
        if (!(m > 0.0)) return .{ .lo = 0, .hi = 0 };
    } else {
        const y = 63.5 + m / sp.cy * rows_per_v;
        if (sp.cy > 0.0) {
            f_hi = @intFromFloat(@min(@max(@ceil(y) + 1.0, 0.0), camera.height));
        } else {
            f_lo = @intFromFloat(@min(@max(@floor(y) - 1.0, 0.0), camera.height));
        }
    }
    for (0..wl.n) |b| {
        const r = sphere_rows(wl.sp[b], u);
        if (r.lo == r.hi) break;
        const band = water_logo_bands[b];
        const c = clip(band.lo, band.hi, r.lo, r.hi);
        if (c.lo != c.hi) {
            lo = @min(lo, c.lo);
            hi = @max(hi, c.hi);
        }
    }
    lo = @max(lo, f_lo);
    hi = @min(hi, f_hi);
    if (lo >= hi) return .{ .lo = 0, .hi = 0 };
    return .{ .lo = lo, .hi = hi };
}

/// Per-frame line of the shore's top edge. A primary ray w = base + up*v
/// with w.z > 0 meets z = 14 below y = H (scene.shore_height) iff f(v) = (H - eye.y) w.z -
/// (14 - eye.z) w.y > 0, linear in v: f = f0(column) + f1 v with f1 < 0 on
/// the whole orbit (up is nearly +y), so the shore rows of a column are the
/// rows below one threshold.
///
/// Likewise the ray is above y = 0 at z = 14 iff g(v) = eye.y w.z +
/// (14 - eye.z) w.y > 0, g = g0(column) + g1 v with g1 > 0, so the water
/// rows that may reach the shore before the water are the rows above a
/// second threshold.
const ShoreEdge = struct { hy: f32, ey: f32, dz: f32, f1: f32, g1: f32, up_z: f32 };

fn shore_edge_at(cam: camera.Camera) ShoreEdge {
    const hy = scene.shore_height - cam.eye[1];
    const dz = scene.shore_z - cam.eye[2];
    return .{
        .hy = hy,
        .ey = cam.eye[1],
        .dz = dz,
        .f1 = hy * cam.up[2] - dz * cam.up[1],
        .g1 = cam.eye[1] * cam.up[2] + dz * cam.up[1],
        .up_z = cam.up[2],
    };
}

/// w.z <= 0 (with margin) at both ends of rows [lo, hi): w.z is linear in
/// v, so no ray of the run faces the shore.
inline fn faces_away(se: ShoreEdge, base: Vec3, lo: usize, hi: usize) bool {
    const wz_top = base[2] + se.up_z * camera.v_table[lo];
    const wz_bot = base[2] + se.up_z * camera.v_table[hi - 1];
    return wz_top < -1e-5 and wz_bot < -1e-5;
}

/// End of the water rows of the column that may meet the shore: rows
/// [first_water_row, result) run the shore test. Padded by a row.
inline fn shore_water_end(se: ShoreEdge, base: Vec3) usize {
    const fwr = camera.first_water_row;
    if (!(se.g1 > 0.0)) return camera.height;
    const g0 = se.ey * base[2] + se.dz * base[1];
    // g > 0 iff v > -g0 / g1 iff y < 63.5 + g0 / g1 * rows_per_v.
    const y = @ceil(63.5 + g0 / se.g1 * rows_per_v) + 1.0;
    const hi: usize = @intFromFloat(@min(@max(y, @as(f32, @floatFromInt(fwr))), camera.height));
    if (hi == fwr or faces_away(se, base, fwr, hi)) return fwr;
    return hi;
}

/// First sky row of the column (ray basis `base`) that may meet the shore,
/// in [0, first_water_row]; rows above it see only sky. Padded by a row and
/// conservative in the w.z > 0 test.
inline fn shore_first_row(se: ShoreEdge, base: Vec3) usize {
    const fwr = camera.first_water_row;
    if (!(se.f1 < 0.0)) return 0;
    const f0 = se.hy * base[2] - se.dz * base[1];
    const v_thr = -f0 / se.f1;
    const y = @floor(63.5 - v_thr * rows_per_v) - 1.0;
    const lo: usize = @intFromFloat(@min(@max(y, 0.0), @as(f32, @floatFromInt(fwr))));
    if (lo == fwr or faces_away(se, base, lo, fwr)) return fwr;
    return lo;
}

/// Verification switch: paint magenta every primary ray that would have hit
/// a sphere or the logo's bounding sphere without testing it (outside the
/// spans, or in the .eye rows outside that object's span), cyan every eye_sky
/// or eye_water ray that would have hit the shore, and yellow every primary
/// water ray outside water_logo_rows whose reflection meets the logo's
/// bounding sphere, and every pixel with a chrome reflection that the cone
/// rejected but that meets it. With it on, a whole orbit rendered with zero
/// magenta, cyan and yellow pixels in cut20, full20 and half30 (M2.2,
/// tools/preview.mjs --every 1; a halved water-logo radius stays clean, a
/// fifth of it paints the reflection yellow).
const debug_span = false;
/// Set by shade_water and logo() under debug_span (single-threaded).
var debug_logo_miss = false;

/// The logo's bounding sphere along (o, d), unit d, t > 1e-3 (debug only).
fn debug_hits_logo_sphere(o: Vec3, d: Vec3) bool {
    const oc = o - iris.centre;
    const b = math.dot(oc, d);
    const disc = b * b - (math.dot(oc, oc) - iris.radius * iris.radius);
    return disc >= 0.0 and -b + @sqrt(disc) > 1e-3;
}

/// Pixels per ray along each axis (variant.zig): 1, or 2 for a ray per even
/// (x, y) written to its 2x2 block.
const scale = variant.render_scale;
/// The `scale` framebuffer columns a column of rays writes.
const Columns = *[scale][camera.height]cart.Pixel;

/// A row run stored in a byte pair.
const Run8 = struct {
    lo: u8,
    hi: u8,

    inline fn of(r: Rows) Run8 {
        return .{ .lo = @intCast(r.lo), .hi = @intCast(r.hi) };
    }
};

/// A run of .eye rows with its tests.
const EyeSeg = struct { lo: u8, hi: u8, flags: EyeFlags };
/// The chrome, glass and logo spans and the water-logo rows have at most 8
/// ends between them, so at most 7 segments.
const max_eye_segs = 7;

/// Every bound of a column, computed for all columns before the render loop
/// (plan_columns) so the loop keeps none of the per-frame span parameters in
/// registers: the union of the spans cut into .eye segments with constant
/// tests, the water rows whose reflection may meet the logo, and the shore
/// rows.
const ColumnRows = struct {
    segs: [max_eye_segs]EyeSeg,
    n_segs: u8,
    water_logo: Run8,
    shore_lo: u8,
    shore_hi: u8,
};
var column_rows: [camera.width]ColumnRows = undefined;

inline fn in_rows(r: Rows, y: usize) bool {
    return y >= r.lo and y < r.hi;
}

/// The .eye segments of a column: the union of the object spans, cut at every
/// span end and at the water-logo rows' ends, each segment with the tests
/// whose spans (or rows) cover it. Adjacent segments with equal tests merge.
fn eye_segments(cr: *ColumnRows, chrome: Rows, glass: Rows, logo_r: Rows, water_logo: Rows) void {
    var ends: [8]usize = undefined;
    var n: usize = 0;
    for ([4]Rows{ chrome, glass, logo_r, water_logo }) |r| {
        if (r.lo == r.hi) continue;
        for ([2]usize{ r.lo, r.hi }) |e| {
            var i = n;
            while (i > 0 and ends[i - 1] > e) : (i -= 1) ends[i] = ends[i - 1];
            ends[i] = e;
            n += 1;
        }
    }
    var ns: usize = 0;
    var i: usize = 0;
    while (i + 1 < n) : (i += 1) {
        const a = ends[i];
        const b = ends[i + 1];
        if (a == b) continue;
        const flags = EyeFlags{
            .chrome = in_rows(chrome, a),
            .glass = in_rows(glass, a),
            .logo = in_rows(logo_r, a),
            .water_logo = in_rows(water_logo, a),
        };
        if (!(flags.chrome or flags.glass or flags.logo)) continue;
        if (ns > 0 and cr.segs[ns - 1].hi == a and cr.segs[ns - 1].flags == flags) {
            cr.segs[ns - 1].hi = @intCast(b);
        } else {
            cr.segs[ns] = .{ .lo = @intCast(a), .hi = @intCast(b), .flags = flags };
            ns += 1;
        }
    }
    cr.n_segs = @intCast(ns);
}

/// Primary rays of rows [y0, y1) of column x (with scale 2: the even rows,
/// so a block takes the row kind of its even row; runs partition the column,
/// so each even row is in exactly one).
inline fn render_rows(
    columns: Columns,
    x: usize,
    base: Vec3,
    inv_len: *const [camera.height]f32,
    cam: *const camera.Camera,
    fs: *const Frame,
    y0: usize,
    y1: usize,
    comptime from: From,
    flags: EyeFlags,
) void {
    const fade_col = &water.primary_fade[camera.half_column(x)];
    var y = if (scale == 1) y0 else (y0 + 1) & ~@as(usize, 1);
    while (y < y1) : (y += scale) {
        const w = base + cam.up * splat(camera.v_table[y]);
        const d = w * splat(inv_len[y]);
        const pw: Extra(from) = if (comptime eye_water_kind(from)) blk: {
            const i = y - camera.first_water_row;
            const t = water.primary_t[i];
            break :blk .{
                .p = math.vec3(cam.eye[0] + w[0] * t, 0.0, cam.eye[2] + w[2] * t),
                .fade = fade_col[i],
            };
        } else if (from == .eye) flags else {};
        if (debug_span) debug_logo_miss = false;
        const c = @call(.always_inline, trace, .{ cam.eye, d, 0, from, fs, pw });
        // Every shaded colour is a non-negative combination of non-negative
        // constants, so saturate reduces to the upper clamp.
        const cs = @min(splat(1.0), c);
        // Each pixel of the block takes its own full-resolution dither
        // threshold, so the Bayer pattern stays at full resolution.
        inline for (0..scale) |i| {
            inline for (0..scale) |j| {
                columns[i][y + j] = dither.quantise(@intCast(x + i), @intCast(y + j), cs);
            }
        }
        if (debug_span) {
            const no_chrome = if (from == .eye) !pw.chrome else true;
            const no_glass = if (from == .eye) !pw.glass else true;
            const no_logo = if (from == .eye) !pw.logo else true;
            if ((no_chrome and hit_chrome(cam.eye, d, .stable) != no_hit) or
                (no_glass and hit_glass(cam.eye, d, .stable) != no_hit) or
                (no_logo and debug_hits_logo_sphere(cam.eye, d)))
                columns[0][y] = cart.Pixel.from_color(.{ .r = 31, .g = 0, .b = 31 });
            if ((from == .eye_sky or from == .eye_water or from == .eye_water_logo) and shore(cam.eye, d, false) != null)
                columns[0][y] = cart.Pixel.from_color(.{ .r = 0, .g = 63, .b = 31 });
            if (debug_logo_miss)
                columns[0][y] = cart.Pixel.from_color(.{ .r = 31, .g = 63, .b = 0 });
        }
    }
}

/// [lo, hi) clipped to [y0, y1], never inverted.
inline fn clip(y0: usize, y1: usize, lo: usize, hi: usize) Rows {
    const a = @min(@max(lo, y0), y1);
    return .{ .lo = a, .hi = @max(a, @min(hi, y1)) };
}

/// Water rows [y0, y1) of one kind, split at cr.water_logo: the rows inside
/// run the kind's logo form, the (up to two) runs outside the plain one; one
/// call site each keeps a single inlined copy of both.
inline fn render_water_rows(
    columns: Columns,
    x: usize,
    base: Vec3,
    inv_len: *const [camera.height]f32,
    cam: *const camera.Camera,
    fs: *const Frame,
    cr: *const ColumnRows,
    y0: usize,
    y1: usize,
    comptime from: From,
) void {
    if (!scene.iris_in_water) return render_rows(columns, x, base, inv_len, cam, fs, y0, y1, from, .{});
    const in = clip(y0, y1, cr.water_logo.lo, cr.water_logo.hi);
    const outside = [2]Rows{ .{ .lo = y0, .hi = in.lo }, .{ .lo = in.hi, .hi = y1 } };
    for (outside) |r| render_rows(columns, x, base, inv_len, cam, fs, r.lo, r.hi, from, .{});
    render_rows(columns, x, base, inv_len, cam, fs, in.lo, in.hi, with_water_logo(from), .{});
}

/// Rows [y0, y1) outside the spans: sky above shore_lo, shore or sky down to
/// first_water_row, shore or water down to shore_hi, water below.
inline fn render_clear_rows(
    columns: Columns,
    x: usize,
    base: Vec3,
    inv_len: *const [camera.height]f32,
    cam: *const camera.Camera,
    fs: *const Frame,
    cr: *const ColumnRows,
    y0: usize,
    y1: usize,
    shore_lo: usize,
    shore_hi: usize,
) void {
    const fwr = camera.first_water_row;
    const s = clip(y0, y1, 0, shore_lo);
    const e = clip(y0, y1, shore_lo, fwr);
    const ws = clip(y0, y1, fwr, shore_hi);
    const wr = clip(y0, y1, shore_hi, camera.height);
    render_rows(columns, x, base, inv_len, cam, fs, s.lo, s.hi, .eye_sky, .{});
    render_rows(columns, x, base, inv_len, cam, fs, e.lo, e.hi, .eye_env, .{});
    render_water_rows(columns, x, base, inv_len, cam, fs, cr, ws.lo, ws.hi, .eye_water_shore);
    render_water_rows(columns, x, base, inv_len, cam, fs, cr, wr.lo, wr.hi, .eye_water);
}

/// Fills column_rows for the frame. Not inlined: its registers stay out of
/// the render loop.
noinline fn plan_columns(cam: *const camera.Camera) void {
    const sp_chrome = sphere_span_at(cam.*, scene.sphere_centre, 1.0);
    const sp_glass = if (scene.glass_enabled) sphere_span_at(cam.*, scene.glass_centre, scene.glass_radius) else {};
    const sp_logo = sphere_span_at(cam.*, iris.centre, iris.radius);
    // sphere_rows takes whole lines, so a bounding sphere behind the eye
    // would show on the opposite side of the screen: skip it when it lies
    // wholly behind the eye's plane (every primary ray has w.fwd = 1 > 0).
    const logo_ahead = sp_logo.cz > -span_r2 * iris.radius;
    const wl = water_logo_at(cam.*);
    const se = shore_edge_at(cam.*);
    const none = Rows{ .lo = 0, .hi = 0 };
    var x: usize = 0;
    while (x < camera.width) : (x += scale) {
        const u = camera.u_table[x];
        const base = cam.fwd + cam.right * splat(u);
        const chrome = sphere_rows(sp_chrome, u);
        const glass = if (scene.glass_enabled) sphere_rows(sp_glass, u) else none;
        const logo_r = if (logo_ahead) sphere_rows(sp_logo, u) else none;
        const water_logo = water_logo_rows(&wl, u);
        const cr = &column_rows[x];
        cr.water_logo = .of(water_logo);
        cr.shore_lo = @intCast(shore_first_row(se, base));
        cr.shore_hi = @intCast(shore_water_end(se, base));
        eye_segments(cr, chrome, glass, logo_r, water_logo);
    }
}

/// Not inlined into update(): keeps the caller's register state out of the
/// hot loop's allocation.
pub noinline fn render_frame(frame: u32) void {
    if (!ready) init();
    const cam = camera.at_frame(frame);
    const fs = Frame{ .ph = water.phases_at_frame(frame), .iris = iris.at_frame(frame) };
    plan_columns(&cam);
    const fb = cart.framebuffer;
    var x: usize = 0;
    while (x < camera.width) : (x += scale) {
        const columns: Columns = fb[x..][0..scale];
        const base = cam.fwd + cam.right * splat(camera.u_table[x]);
        const inv_len = &camera.inv_len_table[camera.half_column(x)];
        const cr = &column_rows[x];
        // Clear rows before each .eye segment, the segment, and the clear
        // rest; one call site each keeps a single inlined copy of every row
        // kind.
        var y: usize = 0;
        const n: usize = cr.n_segs;
        for (0..n + 1) |i| {
            const end: usize = if (i < n) cr.segs[i].lo else camera.height;
            render_clear_rows(columns, x, base, inv_len, &cam, &fs, cr, y, end, cr.shore_lo, cr.shore_hi);
            if (i == n) break;
            const seg = cr.segs[i];
            render_rows(columns, x, base, inv_len, &cam, &fs, seg.lo, seg.hi, .eye, seg.flags);
            y = seg.hi;
        }
    }
}
