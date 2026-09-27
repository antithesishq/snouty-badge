//! Real-time ray tracer for the M1 scene (PLAN.md "The M1 scene, exactly").
//! Column-major: the ray basis fwd + right*u is built once per column, up*v
//! comes from a comptime row table and the primary ray's 1/length from a
//! comptime per-pixel table. Recursion is resolved at comptime: `trace` is
//! an inline function instantiated per (depth, came-from) pair, so there is
//! no runtime recursion and the depth bound (0..2) is structural.
//!
//! Each column is split into row runs by what a primary ray can hit: the
//! sphere's per-frame screen span (sphere test), sky rows above it (sky
//! only) and water rows below it (hit point and fade from comptime tables,
//! no divide). The split is exact, see sphere_rows and camera.first_water_row.
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

/// Where a ray was spawned; lets the tracer skip tests that cannot succeed.
const From = enum {
    /// Primary ray from the eye inside the sphere's screen span.
    eye,
    /// Primary ray outside the span going up (row < first_water_row): sky.
    eye_sky,
    /// Primary ray outside the span going down: water, hit from the
    /// comptime tables (PrimaryWater).
    eye_water,
    /// Reflection off the convex sphere: cannot hit the sphere again.
    sphere,
    /// Reflection off the water: r.y >= 0.02, cannot hit the water.
    water,
};

/// Per-frame state shared by every ray.
const Frame = struct {
    ph: water.Phases,
};

/// How hit_sphere forms the discriminant.
const SphereTest = enum {
    /// 1 - |oc - b d|^2: the same value, but without the cancellation of two
    /// ~|oc|^2 terms, and first-order insensitive to the rounding of b. For
    /// primary rays, whose grazing silhouette hits have ill-conditioned
    /// reflections.
    stable,
    /// Origin on the water plane (o.y = 0 exactly), so oc = (o.x, -1, o.z)
    /// and |oc|^2 - 1 = o.x^2 + o.z^2.
    on_water,
};

/// Nearest t > 1e-3 of the unit sphere at scene.sphere_centre, or no_hit.
/// Assumes |d| = 1 (a = 1 in the quadratic).
inline fn hit_sphere(o: Vec3, d: Vec3, comptime mode: SphereTest) f32 {
    comptime if (scene.sphere_centre[0] != 0.0 or scene.sphere_centre[1] != 1.0 or
        scene.sphere_centre[2] != 0.0) @compileError("on_water assumes the centre (0, 1, 0)");
    const oc = o - scene.sphere_centre;
    const b = if (mode == .on_water) o[0] * d[0] + o[2] * d[2] - d[1] else math.dot(oc, d);
    const disc = switch (mode) {
        .stable => blk: {
            const q = oc - d * splat(b);
            break :blk 1.0 - math.dot(q, q);
        },
        .on_water => b * b - (o[0] * o[0] + o[2] * o[2]),
    };
    if (disc < 0.0) return no_hit;
    const sq = @sqrt(disc);
    const t0 = -b - sq;
    if (t0 > 1e-3) return t0;
    const t1 = -b + sq;
    if (t1 > 1e-3) return t1;
    return no_hit;
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
    const refl = if (depth < 2)
        trace(p, r, depth + 1, .water, fs, {})
    else
        scene.sky(r);
    const f = math.schlick(@max(0.0, -math.dot(d, n)), scene.water_f0);
    var spec = @max(0.0, math.dot(r, scene.sun_dir));
    inline for (0..6) |_| spec *= spec; // ^64
    return math.lerp(scene.water_deep, refl, f) + scene.water_spec_col * splat(spec);
}

/// Water hit of an .eye_water primary ray, from water.primary_t/_fade.
const PrimaryWater = struct { p: Vec3, fade: f32 };

inline fn trace(
    o: Vec3,
    d: Vec3,
    comptime depth: u32,
    comptime from: From,
    fs: *const Frame,
    pw: if (from == .eye_water) PrimaryWater else void,
) Vec3 {
    if (from == .eye_sky) return scene.sky(d);
    if (from == .eye_water) return shade_water(pw.p, d, pw.fade, depth, fs);

    const sphere_possible = from != .sphere;
    const ts = if (sphere_possible) hit_sphere(o, d, if (from == .water) .on_water else .stable) else no_hit;

    if (from != .water and d[1] < 0.0) {
        // tw = -o.y / d.y and fade = 1 / (1 + 0.06 * tw) = d.y / k with
        // k = d.y - 0.06 * o.y, both from one reciprocal of d.y * k. |d| = 1,
        // so tw is the distance from the ray origin. o.y >= 0 and d.y < 0,
        // so k has no cancellation. tw is clamped so the ripple phases stay
        // inside sin_turns' range; past 1e5 the fade is below 2e-4 and the
        // normal is flat to f32 anyway.
        const k = d[1] - water.fade_k * o[1];
        const inv = 1.0 / (d[1] * k);
        const tw = @min(-o[1] * k * inv, max_water_t);
        if (!sphere_possible or tw < ts) {
            // On the plane by construction; y = 0 exactly simplifies the
            // sphere test of the reflected ray.
            const p = math.vec3(o[0] + d[0] * tw, 0.0, o[2] + d[2] * tw);
            return shade_water(p, d, d[1] * d[1] * inv, depth, fs);
        }
    }

    if (ts != no_hit) {
        const p = o + d * splat(ts);
        const n = p - scene.sphere_centre; // radius 1
        if (depth < 2) {
            return scene.sphere_tint * trace(p, math.reflect(d, n), depth + 1, .sphere, fs, {});
        } else {
            const lambert = 0.25 + 0.75 * @max(0.0, math.dot(n, scene.sun_dir));
            return scene.sphere_lit_col * splat(lambert);
        }
    }

    return scene.sky(d);
}

/// Screen footprint of the sphere for primary rays, per frame. In camera
/// coordinates the sphere centre is c = (cx, cy, cz) relative to the eye and
/// the (unnormalised) primary ray is w = (u, v, 1). The ray line passes
/// within radius r of the centre iff (w.c)^2 >= (|c|^2 - r^2) |w|^2, which
/// for a fixed column u is a quadratic in v with a negative leading
/// coefficient (the eye is outside the sphere's vertical cylinder), so the
/// hit rows of each column form one interval between its roots. The span
/// uses r^2 = span_r2 > 1 and pads a row each side, so it is conservative
/// against f32 rounding; rows outside it skip the sphere test.
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

fn sphere_span_at(cam: camera.Camera) SphereSpan {
    const e2c = scene.sphere_centre - cam.eye;
    const cy = math.dot(e2c, cam.up);
    const k = math.dot(e2c, e2c) - span_r2;
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

/// Verification switch: paint magenta every primary ray outside the span that
/// would have hit the sphere. With it on, all 600 orbit frames rendered with
/// zero magenta pixels (tools/preview.mjs --frames 600 --every 1).
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
        const pw = if (from == .eye_water) blk: {
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
        if (debug_span and from != .eye and hit_sphere(cam.eye, d, .stable) != no_hit)
            column[y] = cart.Pixel.from_color(.{ .r = 31, .g = 0, .b = 31 });
    }
}

/// Rows [y0, y1) outside the sphere span: sky above first_water_row, water
/// below.
inline fn render_clear_rows(
    column: *[camera.height]cart.Pixel,
    x: usize,
    base: Vec3,
    inv_len: *const [camera.height]f32,
    cam: *const camera.Camera,
    fs: *const Frame,
    y0: usize,
    y1: usize,
) void {
    const split = camera.first_water_row;
    render_rows(column, x, base, inv_len, cam, fs, y0, @max(y0, @min(y1, split)), .eye_sky);
    render_rows(column, x, base, inv_len, cam, fs, @min(y1, @max(y0, split)), y1, .eye_water);
}

/// Not inlined into update(): keeps the caller's register state out of the
/// hot loop's allocation.
pub noinline fn render_frame(frame: u32) void {
    const cam = camera.at_frame(frame);
    const fs = Frame{ .ph = water.phases_at_frame(frame) };
    const sp = sphere_span_at(cam);
    const fb = cart.framebuffer;
    for (fb, 0..) |*column, x| {
        const u = camera.u_table[x];
        const base = cam.fwd + cam.right * splat(u);
        const inv_len = &camera.inv_len_table[camera.half_column(x)];
        const rows = sphere_rows(sp, u);
        render_clear_rows(column, x, base, inv_len, &cam, &fs, 0, rows.lo);
        render_rows(column, x, base, inv_len, &cam, &fs, rows.lo, rows.hi, .eye);
        render_clear_rows(column, x, base, inv_len, &cam, &fs, rows.hi, camera.height);
    }
}
