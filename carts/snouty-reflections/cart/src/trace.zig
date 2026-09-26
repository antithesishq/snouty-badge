//! Real-time ray tracer for the M1 scene (PLAN.md "The M1 scene, exactly").
//! Column-major: the ray basis fwd + right*u is built once per column and
//! up*v comes from a comptime row table. Recursion is resolved at comptime:
//! `trace` is instantiated per (depth, came-from) pair, so there is no
//! runtime recursion and the depth bound (0..2) is structural.
const cart = @import("cart-api");
const math = @import("math.zig");
const dither = @import("dither.zig");
const camera = @import("camera.zig");
const scene = @import("scene.zig");
const water = @import("water.zig");
const Vec3 = math.Vec3;
const splat = math.splat;

const no_hit: f32 = math.inf_f32;

/// Where a ray was spawned; lets the tracer skip tests that cannot succeed.
const From = enum {
    /// Primary ray from the eye.
    eye,
    /// Reflection off the convex sphere: cannot hit the sphere again.
    sphere,
    /// Reflection off the water: r.y >= 0.02, cannot hit the water.
    water,
};

/// Per-frame state shared by every ray.
const Frame = struct {
    ph: water.Phases,
};

/// Nearest t > 1e-3 of the unit sphere at scene.sphere_centre, or no_hit.
/// Assumes |d| = 1 (a = 1 in the quadratic).
inline fn hit_sphere(o: Vec3, d: Vec3) f32 {
    const oc = o - scene.sphere_centre;
    const b = math.dot(oc, d);
    const c = math.dot(oc, oc) - 1.0;
    const disc = b * b - c;
    if (disc < 0.0) return no_hit;
    const sq = @sqrt(disc);
    const t0 = -b - sq;
    if (t0 > 1e-3) return t0;
    const t1 = -b + sq;
    if (t1 > 1e-3) return t1;
    return no_hit;
}

fn trace(o: Vec3, d: Vec3, comptime depth: u32, comptime from: From, fs: *const Frame) Vec3 {
    const ts = if (from == .sphere) no_hit else hit_sphere(o, d);

    if (from != .water and d[1] < 0.0) {
        const tw = -o[1] / d[1];
        if (tw < ts) {
            const p = o + d * splat(tw);
            // |d| = 1, so tw is the distance from the ray origin (the eye
            // for primary rays).
            const n = water.normal(p, tw, fs.ph);
            var r = math.reflect(d, n);
            if (r[1] < scene.min_reflect_y) {
                r[1] = scene.min_reflect_y;
                r = math.normalize(r);
            }
            const refl = if (depth < 2)
                trace(p, r, depth + 1, .water, fs)
            else
                scene.sky(r);
            const f = math.schlick(@max(0.0, -math.dot(d, n)), scene.water_f0);
            var spec = @max(0.0, math.dot(r, scene.sun_dir));
            inline for (0..6) |_| spec *= spec; // ^64
            return math.lerp(scene.water_deep, refl, f) + scene.sun_col * splat(0.5 * spec);
        }
    }

    if (ts != no_hit) {
        const p = o + d * splat(ts);
        const n = p - scene.sphere_centre; // radius 1
        if (depth < 2) {
            return scene.sphere_tint * trace(p, math.reflect(d, n), depth + 1, .sphere, fs);
        } else {
            const lambert = 0.25 + 0.75 * @max(0.0, math.dot(n, scene.sun_dir));
            return scene.sphere_tint * scene.sun_col * splat(lambert);
        }
    }

    return scene.sky(d);
}

pub fn render_frame(frame: u32) void {
    const cam = camera.at_frame(frame);
    const fs = Frame{ .ph = water.phases_at_frame(frame) };
    const fb = cart.framebuffer;
    for (fb, 0..) |*column, x| {
        const base = cam.fwd + cam.right * splat(camera.u_table[x]);
        for (column, 0..) |*px, y| {
            const d = math.normalize(base + cam.up * splat(camera.v_table[y]));
            const c = @call(.always_inline, trace, .{ cam.eye, d, 0, .eye, &fs });
            px.* = dither.quantise(@intCast(x), @intCast(y), math.saturate(c));
        }
    }
}
