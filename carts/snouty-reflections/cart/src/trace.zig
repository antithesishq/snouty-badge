//! Real-time ray tracer for the M2 scene (PLAN.md "The M1 scene, exactly"
//! and "The M2 scene, exactly"). Column-major: the ray basis fwd + right*u
//! is built once per column, up*v comes from a comptime row table and the
//! primary ray's 1/length from a comptime per-pixel table. Recursion is
//! resolved at comptime: `trace` is instantiated per (depth, came-from)
//! pair, so there is no runtime recursion and the depth bound (0..2) is
//! structural. The hot instantiations (primary rays and their chrome and
//! water bounces) are inlined; the rest are shared calls.
//!
//! Each column is split into row runs by what a primary ray can hit: the
//! chrome and glass spheres' per-frame screen spans (full test), and outside
//! them sky rows above the shore band (sky only), sky rows in it (shore or
//! sky), water rows that may still reach the shore (shore test first) and
//! the other water rows (hit point and fade from comptime tables, no
//! divide). The split is exact or conservative, see sphere_rows,
//! shore_first_row, shore_water_end and camera.first_water_row.
const std = @import("std");
const cart = @import("cart-api");
const math = @import("math.zig");
const dither = @import("dither.zig");
const camera = @import("camera.zig");
const scene = @import("scene.zig");
const water = @import("water.zig");
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
    /// Primary ray from the eye inside a sphere's screen span: everything.
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
    /// Reflection off the convex chrome sphere: cannot hit it again.
    sphere,
    /// Reflected off or transmitted through the convex glass sphere: cannot
    /// hit it again.
    glass,
    /// Reflection off the water: r.y >= 0.02, cannot hit the water.
    water,
};

/// Per-frame state shared by every ray.
const Frame = struct {
    ph: water.Phases,
};

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

inline fn hit_glass(o: Vec3, d: Vec3, comptime mode: SphereTest) f32 {
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
    const v = @min(@max((scene.shore_height - ys) * scene.shore_texels_per_unit, 0.0), 31.0);
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
/// 77 x 108 f32 = 33 KB of .bss.
const shadow_step: f32 = 1.0 / 32.0;
const shadow_x0: f32 = @min(scene.casters[0].x0, scene.casters[1].x0);
const shadow_z0: f32 = @min(scene.casters[0].z0, scene.casters[1].z0);
const shadow_nx: usize = @as(usize, @intFromFloat(@ceil((@max(scene.casters[0].x1, scene.casters[1].x1) - shadow_x0) / shadow_step))) + 2;
const shadow_nz: usize = @as(usize, @intFromFloat(@ceil((@max(scene.casters[0].z1, scene.casters[1].z1) - shadow_z0) / shadow_step))) + 2;
var shadow_map: [shadow_nz][shadow_nx]u8 = undefined;

/// Fills shadow_map; call once before the first render_frame.
pub fn init() void {
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

/// Colour of a ray `d` hitting the water at `p` (y = 0) with ripple fade
/// `fade`.
inline fn shade_water(p: Vec3, d: Vec3, fade: f32, comptime depth: u32, fs: *const Frame) Vec3 {
    const n = water.normal(p, fade, fs.ph);
    var r = math.reflect(d, n);
    if (r[1] < scene.min_reflect_y) {
        r[1] = scene.min_reflect_y;
        r = math.normalize(r);
    }
    const refl = if (depth == 0)
        @call(.always_inline, trace, .{ p, r, depth + 1, .water, fs, {} })
    else if (depth < 2)
        trace(p, r, depth + 1, .water, fs, {})
    else
        env(p, r, true, false);
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

/// Water hit of an .eye_water primary ray, from water.primary_t/_fade.
const PrimaryWater = struct { p: Vec3, fade: f32 };

fn trace(
    o: Vec3,
    d: Vec3,
    comptime depth: u32,
    comptime from: From,
    fs: *const Frame,
    pw: if (from == .eye_water or from == .eye_water_shore) PrimaryWater else void,
) Vec3 {
    switch (from) {
        .eye_sky => return scene.sky(d),
        .eye_env => return env(o, d, false, false),
        .eye_water => return shade_water(pw.p, d, pw.fade, depth, fs),
        .eye_water_shore => {
            if (@call(split_call, shore, .{ o, d, false })) |c| return c;
            return shade_water(pw.p, d, pw.fade, depth, fs);
        },
        else => {},
    }

    // Nearest sphere first: both lie above the water and nearer than the
    // shore along every ray (PLAN.md "The M2 scene, exactly").
    const mode: SphereTest = switch (from) {
        .eye => .stable,
        .water => .on_water,
        else => .standard,
    };
    const tc = if (from != .sphere) hit_chrome(o, d, mode) else no_hit;
    const tg = if (from != .glass) hit_glass(o, d, mode) else no_hit;
    if (tc < tg) return shade_chrome(o + d * splat(tc), d, depth, fs);
    if (tg != no_hit) {
        if (depth == 2) return scene.glass_far;
        return @call(split_call, shade_glass, .{ o + d * splat(tg), d, depth, fs });
    }

    if (@call(split_call, shore, .{ o, d, from == .water })) |c| return c;

    if (from != .water and d[1] < 0.0) {
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
        return shade_water(p, d, g * g, depth, fs);
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
};

const span_r2: f32 = 1.05;
/// Rows per unit of v: y = 63.5 - v * rows_per_v (camera.v_table inverted).
const rows_per_v: f32 = 80.0 / camera.tan_h;

fn sphere_span_at(cam: camera.Camera, comptime centre: Vec3, comptime r: f32) SphereSpan {
    const e2c = centre - cam.eye;
    const cy = math.dot(e2c, cam.up);
    const k = math.dot(e2c, e2c) - span_r2 * r * r;
    return .{
        .cx = math.dot(e2c, cam.right),
        .cy = cy,
        .cz = math.dot(e2c, cam.fwd),
        .k = k,
        .a = cy * cy - k,
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
    const inv_a = 1.0 / sp.a;
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

/// Up to two disjoint, sorted row runs: the union of the two sphere spans.
const Spans = struct { r: [2]Rows, n: usize };

inline fn span_union(a: Rows, b: Rows) Spans {
    if (a.lo == a.hi) return .{ .r = .{ b, b }, .n = @intFromBool(b.lo != b.hi) };
    if (b.lo == b.hi) return .{ .r = .{ a, a }, .n = 1 };
    const first = if (a.lo <= b.lo) a else b;
    const second = if (a.lo <= b.lo) b else a;
    if (second.lo <= first.hi) {
        const m = Rows{ .lo = first.lo, .hi = @max(first.hi, second.hi) };
        return .{ .r = .{ m, m }, .n = 1 };
    }
    return .{ .r = .{ first, second }, .n = 2 };
}

/// Per-frame line of the shore's top edge. A primary ray w = base + up*v
/// with w.z > 0 meets z = 14 below y = 4 iff f(v) = (4 - eye.y) w.z -
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

/// Verification switch: paint magenta every primary ray outside the spans
/// that would have hit a sphere, and cyan every eye_sky or eye_water ray
/// that would have hit the shore. With it on, all 600 orbit frames rendered with zero
/// magenta and cyan pixels (tools/preview.mjs --frames 600 --every 1).
const debug_span = false;

inline fn render_rows(
    column: *[camera.height]cart.Pixel,
    x: usize,
    base: Vec3,
    inv_len: *const [camera.height]f32,
    cam: *const camera.Camera,
    fs: *const Frame,
    y0: usize,
    y1: usize,
    comptime from: From,
) void {
    const fade_col = &water.primary_fade[camera.half_column(x)];
    for (y0..y1) |y| {
        const w = base + cam.up * splat(camera.v_table[y]);
        const d = w * splat(inv_len[y]);
        const pw = if (from == .eye_water or from == .eye_water_shore) blk: {
            const i = y - camera.first_water_row;
            const t = water.primary_t[i];
            break :blk PrimaryWater{
                .p = math.vec3(cam.eye[0] + w[0] * t, 0.0, cam.eye[2] + w[2] * t),
                .fade = fade_col[i],
            };
        } else {};
        const c = @call(.always_inline, trace, .{ cam.eye, d, 0, from, fs, pw });
        // Every shaded colour is a non-negative combination of non-negative
        // constants, so saturate reduces to the upper clamp.
        column[y] = dither.quantise(@intCast(x), @intCast(y), @min(splat(1.0), c));
        if (debug_span and from != .eye and
            (hit_chrome(cam.eye, d, .stable) != no_hit or hit_glass(cam.eye, d, .stable) != no_hit))
            column[y] = cart.Pixel.from_color(.{ .r = 31, .g = 0, .b = 31 });
        if (debug_span and (from == .eye_sky or from == .eye_water) and shore(cam.eye, d, false) != null)
            column[y] = cart.Pixel.from_color(.{ .r = 0, .g = 63, .b = 31 });
    }
}

/// [lo, hi) clipped to [y0, y1], never inverted.
inline fn clip(y0: usize, y1: usize, lo: usize, hi: usize) Rows {
    const a = @min(@max(lo, y0), y1);
    return .{ .lo = a, .hi = @max(a, @min(hi, y1)) };
}

/// Rows [y0, y1) outside the sphere spans: sky above shore_lo, shore or sky
/// down to first_water_row, shore or water down to shore_hi, water below.
inline fn render_clear_rows(
    column: *[camera.height]cart.Pixel,
    x: usize,
    base: Vec3,
    inv_len: *const [camera.height]f32,
    cam: *const camera.Camera,
    fs: *const Frame,
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
    render_rows(column, x, base, inv_len, cam, fs, s.lo, s.hi, .eye_sky);
    render_rows(column, x, base, inv_len, cam, fs, e.lo, e.hi, .eye_env);
    render_rows(column, x, base, inv_len, cam, fs, ws.lo, ws.hi, .eye_water_shore);
    render_rows(column, x, base, inv_len, cam, fs, wr.lo, wr.hi, .eye_water);
}

/// Not inlined into update(): keeps the caller's register state out of the
/// hot loop's allocation.
pub noinline fn render_frame(frame: u32) void {
    const cam = camera.at_frame(frame);
    const fs = Frame{ .ph = water.phases_at_frame(frame) };
    const sp_chrome = sphere_span_at(cam, scene.sphere_centre, 1.0);
    const sp_glass = sphere_span_at(cam, scene.glass_centre, scene.glass_radius);
    const se = shore_edge_at(cam);
    const fb = cart.framebuffer;
    for (fb, 0..) |*column, x| {
        const u = camera.u_table[x];
        const base = cam.fwd + cam.right * splat(u);
        const inv_len = &camera.inv_len_table[camera.half_column(x)];
        const shore_lo = shore_first_row(se, base);
        const shore_hi = shore_water_end(se, base);
        const spans = span_union(sphere_rows(sp_chrome, u), sphere_rows(sp_glass, u));
        // Clear rows before each span, the span, and the clear rest; one
        // call site each keeps a single inlined copy of every row kind.
        var y: usize = 0;
        for (0..spans.n + 1) |i| {
            const end = if (i < spans.n) spans.r[i].lo else camera.height;
            render_clear_rows(column, x, base, inv_len, &cam, &fs, y, end, shore_lo, shore_hi);
            if (i == spans.n) break;
            render_rows(column, x, base, inv_len, &cam, &fs, spans.r[i].lo, spans.r[i].hi, .eye);
            y = spans.r[i].hi;
        }
    }
}
