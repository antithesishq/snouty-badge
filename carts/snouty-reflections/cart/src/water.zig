//! Ripple normal for the water plane y = 0 (PLAN.md table of three waves).
//! Only the gradient of the height field is used; the plane stays flat.
const std = @import("std");
const math = @import("math.zig");
const camera = @import("camera.zig");
const variant = @import("variant.zig");
const scene = @import("scene.zig");
const Vec3 = math.Vec3;

const Wave = struct { a: f32, kx: f32, kz: f32, w: f32 };

pub const waves = [3]Wave{
    .{ .a = 0.020, .kx = 0.90, .kz = 0.35, .w = 0.55 },
    .{ .a = 0.012, .kx = -0.45, .kz = 0.80, .w = 0.80 },
    .{ .a = 0.006, .kx = 1.70, .kz = -1.20, .w = 1.30 },
};

/// A_i * k_i * 2pi, folded at comptime.
const gx: [3]f32 = blk: {
    var g: [3]f32 = undefined;
    for (waves, 0..) |wv, i| g[i] = wv.a * wv.kx * (2.0 * std.math.pi);
    break :blk g;
};
const gz: [3]f32 = blk: {
    var g: [3]f32 = undefined;
    for (waves, 0..) |wv, i| g[i] = wv.a * wv.kz * (2.0 * std.math.pi);
    break :blk g;
};

/// Upper bound on the ripple gradient |(dh/dx, dh/dz)| before the fade.
/// The gradient is sum_i g_i c_i with fixed vectors g_i = A_i k_i 2 pi and
/// c_i in [-1, 1]; its norm is convex in c, so the maximum is at a vertex of
/// the cube: the largest |sum_i +-g_i| (0.220, against 0.269 for sum |g_i|).
/// normal() tilts the normal by atan(fade * |gradient|).
pub const max_slope: f32 = blk: {
    var best: f64 = 0.0;
    for (0..8) |m| {
        var x: f64 = 0.0;
        var z: f64 = 0.0;
        for (0..3) |i| {
            const sgn: f64 = if ((m >> i) & 1 == 1) -1.0 else 1.0;
            x += sgn * gx[i];
            z += sgn * gz[i];
        }
        best = @max(best, @sqrt(x * x + z * z));
    }
    break :blk @floatCast(best);
};

/// The waves' gradient bound per preset: the ripple scale times max_slope.
pub const preset_max_slope: [scene.preset_count]f32 = blk: {
    var t: [scene.preset_count]f32 = undefined;
    for (0..scene.preset_count) |i| t[i] = max_slope * scene.ripple_scale[i];
    break :blk t;
};

/// A_i k_i 2 pi times the preset's ripple scale, per preset: the sunset
/// values are gx and gz bit for bit ((A * 1) k 2 pi).
pub const Gains = struct { gx: [3]f32, gz: [3]f32 };
pub const preset_gains: [scene.preset_count]Gains = blk: {
    var t: [scene.preset_count]Gains = undefined;
    for (0..scene.preset_count) |p| {
        for (waves, 0..) |wv, i| {
            const a = wv.a * scene.ripple_scale[p];
            t[p].gx[i] = a * wv.kx * (2.0 * std.math.pi);
            t[p].gz[i] = a * wv.kz * (2.0 * std.math.pi);
        }
    }
    break :blk t;
};

comptime {
    for (0..3) |i| {
        if (preset_gains[0].gx[i] != gx[i] or preset_gains[0].gz[i] != gz[i]) @compileError("sunset gains differ from M2.2");
    }
}

/// Distance fade of the ripples: g * g with g = 1 / (1 + fade_k * dist)
/// (M2; the square cuts the horizon moire).
pub const fade_k = 0.05;

/// Primary rays that go down (rows >= camera.first_water_row) hit the water
/// at a distance that does not depend on the frame: the eye height is fixed
/// and the ray's y component depends only on the row. So the hit is
/// p = eye + w * primary_t[row] for the unnormalised ray w = fwd + right*u +
/// up*v, and the fade is a per-pixel constant; both folded at comptime in
/// f64. primary_fade is indexed [camera.half_column(x)][y - first_water_row]
/// (80 x 86 f32, 27.5 KB).
pub const primary_t: [camera.water_rows]f32 = blk: {
    var t: [camera.water_rows]f32 = undefined;
    for (0..camera.water_rows) |i| {
        const v: f64 = camera.v_table[camera.first_water_row + i];
        t[i] = @floatCast(-@as(f64, camera.orbit_height) / (camera.basis_y64 + camera.basis_h64 * v));
    }
    break :blk t;
};
pub const primary_fade: [camera.width / 2][camera.water_rows]f32 = blk: {
    @setEvalBranchQuota(200000);
    var t: [camera.width / 2][camera.water_rows]f32 = undefined;
    for (0..camera.width / 2) |x| {
        const u: f64 = camera.u_table[x];
        for (0..camera.water_rows) |i| {
            const v: f64 = camera.v_table[camera.first_water_row + i];
            const dist = -@as(f64, camera.orbit_height) / (camera.basis_y64 + camera.basis_h64 * v) *
                @sqrt(1.0 + u * u + v * v);
            if (dist > 1e5) @compileError("primary water hit beyond sin_turns range");
            const g = 1.0 / (1.0 + fade_k * dist);
            t[x][i] = @floatCast(g * g);
        }
    }
    break :blk t;
};

/// primary_t and primary_fade for the frame's eye height, indexed by the row
/// itself (rows above first_water_row unused): build_tables() copies
/// primary_t at default_height (the tracer reads the comptime primary_fade
/// there, bit for bit M2.2) and recomputes both in f32 at any other height,
/// only when the height changes. 128 f32 + 80 x 128 f32 (40.5 KB of .bss;
/// at max_height every row goes down).
pub var primary_t_rt: [camera.height]f32 = undefined;
pub var primary_fade_rt: [camera.width / 2][camera.height]f32 = undefined;
/// The comptime primary_fade at default_height only with motion off (the
/// M2.2 identity); the shipped build computes every height at runtime and
/// leaves the 27.5 KB table out.
pub const fade_comptime = !scene.motion;

/// Height the tables hold; NaN until the first build.
var tables_height: f32 = std.math.nan(f32);

/// Hit distances beyond this are clamped (the fade there is ~1e-6 and the
/// ripple phases must stay inside sin_turns' range).
const max_primary_t: f32 = 2e4;

/// Makes primary_t_rt and primary_fade_rt hold basis `b`'s tables. Returns
/// true if it rebuilt them.
pub fn build_tables(b: *const camera.Basis) bool {
    if (b.height == tables_height) return false;
    tables_height = b.height;
    const fwr = b.first_water_row;
    if (b.height == camera.default_height) {
        @memcpy(primary_t_rt[fwr..], &primary_t);
        // The tracer reads primary_fade itself at this height.
        if (fade_comptime) return true;
    } else for (fwr..camera.height) |y| {
        const wy = b.y + b.h * camera.v_table[y];
        primary_t_rt[y] = @min(-b.height / wy, max_primary_t);
    }
    // t = -height / w.y for the unnormalised ray w, w.y = basis_y + basis_h v;
    // dist = t |w| = t / inv_len; g = 1 / (1 + fade_k dist) = inv_len /
    // (inv_len + fade_k t): one divide per entry.
    for (&primary_fade_rt, 0..) |*col, hc| {
        for (fwr..camera.height) |y| {
            const il = camera.inv_len(hc, y);
            const g = il / (il + fade_k * primary_t_rt[y]);
            col[y] = g * g;
        }
    }
    return true;
}

/// Per-frame phase offsets (fract(w_i * t) + 1/4) * 1024, in sine-table
/// steps: the quarter turn turns the table sine into the cosine the gradient
/// needs, and the power-of-two scale (folded into k too) saves the per-wave
/// multiply in the lookup without changing a bit of the result.
pub const Phases = [3]f32;
const steps: f32 = math.sin_table_len;

/// Circular ripples around the spheres (PLAN.md M3 "Rings", knob rings):
/// h = A sin_turns(k d - w s) (1 - d / R)^2 for d < R, d the horizontal
/// distance from the sphere's (x, z); not scaled by the preset's ripple
/// amplitude. Its gradient is added to the waves' before the fade.
pub const ring_a: f32 = 0.006;
pub const ring_k: f32 = 1.0 / 0.6;
pub const ring_w: f32 = 1.3;
pub const ring_r: f32 = 3.0;
/// Upper bound on one ring's gradient: A (2 pi k + 2 / R).
pub const ring_max_slope: f32 = ring_a * (2.0 * std.math.pi * ring_k + 2.0 / ring_r);

/// The ripples of a frame: the wave phases and the preset's gains, and the
/// rings: their count (the first n of rx/rz) and phase.
pub const Frame = struct {
    ph: Phases,
    gx: [3]f32,
    gz: [3]f32,
    n_rings: u32 = 0,
    rx: [3]f32 = undefined,
    rz: [3]f32 = undefined,
    /// fract(w s) * 1024: the ring phase k d - w s in table steps is
    /// k * 1024 * d - ring_ph.
    ring_ph: f32 = 0.0,
};

/// Scene time `t` in frames at variant.fps.
pub fn frame_at(t: u32, preset: scene.Preset) Frame {
    // s = t / fps seconds. The f32 product is exact enough for any
    // frame below 2^24; fract keeps the runtime phase argument small.
    const s = @as(f32, @floatFromInt(t)) * (1.0 / @as(comptime_float, variant.fps));
    var wf: Frame = undefined;
    inline for (waves, 0..) |wv, i| wf.ph[i] = (math.fract(wv.w * s) + 0.25) * steps;
    const g = &preset_gains[@backingInt(preset)];
    wf.gx = g.gx;
    wf.gz = g.gz;
    wf.n_rings = 0;
    wf.ring_ph = math.fract(ring_w * s) * steps;
    return wf;
}

/// Adds a ring around (x, z) to the frame (at most three).
pub fn add_ring(wf: *Frame, x: f32, z: f32) void {
    wf.rx[wf.n_rings] = x;
    wf.rz[wf.n_rings] = z;
    wf.n_rings += 1;
}

/// The rings' gradient at water point p, added to (dx, dz). Outside a
/// ring's 2R square it costs two compares; inside its disc one sqrt, one
/// divide and two table lookups. dh/dd = A q (2 pi k cos(phi) q - (2 / R)
/// sin(phi)), q = 1 - d / R, times (p - c) / d; zero at d = 0.
inline fn add_rings(p: Vec3, wf: *const Frame, dx: *f32, dz: *f32) void {
    const two_pi_k: f32 = 2.0 * std.math.pi * ring_k;
    const two_over_r: f32 = 2.0 / ring_r;
    var i: u32 = 0;
    while (i < wf.n_rings) : (i += 1) {
        const ex = p[0] - wf.rx[i];
        const ez = p[2] - wf.rz[i];
        if (!(@abs(ex) < ring_r and @abs(ez) < ring_r)) continue;
        const d2 = ex * ex + ez * ez;
        if (!(d2 < ring_r * ring_r and d2 > 1e-12)) continue;
        const inv = 1.0 / @sqrt(d2);
        const d = d2 * inv;
        const ph = (ring_k * steps) * d - wf.ring_ph;
        const sn = math.sin_steps(ph);
        const cs = math.sin_steps(ph + 0.25 * steps);
        const q = 1.0 - d * (1.0 / ring_r);
        const coef = ring_a * q * (two_pi_k * cs * q - two_over_r * sn) * inv;
        dx.* += coef * ex;
        dz.* += coef * ez;
    }
}

/// Perturbed unit normal at water point `p`. `fade` is g * g, g = 1 / (1 +
/// fade_k * dist) for the distance from the ray origin; the tracer derives g
/// from the same reciprocal as the hit distance.
/// `p` must satisfy |p.x|, |p.z| < 2e5 (sin_turns range); the tracer clamps
/// the hit distance to guarantee it.
pub inline fn normal(p: Vec3, fade: f32, wf: *const Frame) Vec3 {
    var dx: f32 = 0.0;
    var dz: f32 = 0.0;
    inline for (waves, 0..) |wv, i| {
        // cos(k.p + w t): ph carries the quarter turn; all in table steps.
        const c = math.sin_steps((wv.kx * steps) * p[0] + (wv.kz * steps) * p[2] + wf.ph[i]);
        dx += wf.gx[i] * c;
        dz += wf.gz[i] * c;
    }
    if (scene.any_rings) add_rings(p, wf, &dx, &dz);
    // math.renormalize of (nx, 1, nz), with its 1.5 - 0.5 * (nx^2 + 1 + nz^2)
    // written as 1 - 0.5 * (nx^2 + nz^2).
    const nx = -fade * dx;
    const nz = -fade * dz;
    const sc = 1.0 - 0.5 * (nx * nx + nz * nz);
    return math.vec3(nx * sc, sc, nz * sc);
}
