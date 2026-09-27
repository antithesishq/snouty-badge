//! Orbiting camera and the screen-to-ray mapping (PLAN.md "Screen to ray",
//! "Camera"). Built once per frame; the tracer adds right*u per column and
//! up*v per row from the comptime tables below.
const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;
const vec3 = math.vec3;
const splat = math.splat;

pub const width = 160;
pub const height = 128;

/// tan(30 deg): horizontal FOV 60 degrees.
pub const tan_h: f32 = 0.57735;

pub const orbit_radius: f32 = 4.5;
pub const orbit_height: f32 = 1.6;
/// Frames per revolution (30 s at 20 fps).
pub const orbit_frames = 600;
pub const target = vec3(0.0, 0.9, 0.0);

/// u(x) = (x + 0.5 - 80) / 80 * tan_h, one per column.
pub const u_table: [width]f32 = blk: {
    var t: [width]f32 = undefined;
    for (0..width) |x| {
        const fx: f32 = @floatFromInt(x);
        t[x] = (fx + 0.5 - 80.0) / 80.0 * tan_h;
    }
    break :blk t;
};

/// v(y) = -(y + 0.5 - 64) / 80 * tan_h, one per row.
pub const v_table: [height]f32 = blk: {
    var t: [height]f32 = undefined;
    for (0..height) |y| {
        const fy: f32 = @floatFromInt(y);
        t[y] = -(fy + 0.5 - 64.0) / 80.0 * tan_h;
    }
    break :blk t;
};

/// 1 / |fwd + right*u + up*v| = 1 / sqrt(1 + u^2 + v^2) for an orthonormal
/// basis, so it depends only on the pixel and is folded at comptime (in f64,
/// correctly rounded). u(159 - x) = -u(x), so only the left half is stored:
/// index with `half_column(x)`. 80 x 128 f32 = 40 KB.
pub const inv_len_table: [width / 2][height]f32 = blk: {
    @setEvalBranchQuota(200000);
    var t: [width / 2][height]f32 = undefined;
    for (0..width / 2) |x| {
        const u: f64 = u_table[x];
        for (0..height) |y| {
            const v: f64 = v_table[y];
            t[x][y] = @floatCast(1.0 / @sqrt(1.0 + u * u + v * v));
        }
    }
    break :blk t;
};

pub inline fn half_column(x: usize) usize {
    return if (x < width / 2) x else width - 1 - x;
}

pub const Camera = struct {
    eye: Vec3,
    fwd: Vec3,
    right: Vec3,
    up: Vec3,
};

/// (sin, cos) of theta = i / 600 turns for every orbit frame, rounded once
/// from f64. The runtime sine table's interpolation error (~5e-6) is fine
/// for ripples but not for the camera: it tilts every primary ray by ~1e-6
/// rad, and grazing silhouette rays (sphere, then water at ~70 units) turn
/// that into visible colour changes. 4.8 KB.
const orbit_sincos: [orbit_frames][2]f32 = blk: {
    @setEvalBranchQuota(20000);
    var t: [orbit_frames][2]f32 = undefined;
    for (0..orbit_frames) |i| {
        const a: f64 = @as(f64, @floatFromInt(i)) * (2.0 * std.math.pi / @as(f64, orbit_frames));
        t[i] = .{ @floatCast(@sin(a)), @floatCast(@cos(a)) };
    }
    break :blk t;
};

/// The spec's basis in closed form. With eye = (R sin, h, R cos) and the
/// target on the y axis, target - eye = (-R sin, ty - h, -R cos), so
///   fwd   = (-sin * basis_h, basis_y, -cos * basis_h)   basis_h = R / L, basis_y = (ty - h) / L
///   right = normalize(cross(fwd, +y)) = (cos, 0, -sin)
///   up    = cross(right, fwd) = (sin * basis_y, basis_h, cos * basis_y)
/// with L = |target - eye|; basis_h and basis_y are folded at comptime in f64, so each
/// basis component is one f32 rounding away from the exact value.
const basis_len: f64 = @sqrt(@as(f64, orbit_radius) * orbit_radius +
    (@as(f64, target[1]) - orbit_height) * (@as(f64, target[1]) - orbit_height));
pub const basis_h64: f64 = @as(f64, orbit_radius) / basis_len;
pub const basis_y64: f64 = (@as(f64, target[1]) - orbit_height) / basis_len;
const basis_h: f32 = @floatCast(basis_h64);
const basis_y: f32 = @floatCast(basis_y64);

/// fwd.y and up.y do not depend on the frame and right.y = 0, so the y
/// component of every primary ray, and with it whether the ray goes down to
/// the water, depends only on the row: rows >= first_water_row go down.
/// Evaluated in f32 exactly as the tracer does (base.y = fwd.y), so the
/// split is exact, and asserted to be one clean switch.
pub const first_water_row: usize = blk: {
    var first: usize = height;
    for (0..height) |y| {
        const dy: f32 = basis_y + basis_h * v_table[y];
        if (dy < 0.0) {
            if (first == height) first = y;
        } else if (first != height) @compileError("primary ray y is not monotonic in the row");
    }
    break :blk first;
};
pub const water_rows = height - first_water_row;

comptime {
    if (target[0] != 0.0 or target[2] != 0.0) @compileError("closed-form basis needs the target on the y axis");
}

pub fn at_frame(frame: u32) Camera {
    // theta = frame / 600 turns.
    const sc = orbit_sincos[frame % orbit_frames];
    const s = sc[0];
    const c = sc[1];
    return .{
        .eye = vec3(orbit_radius * s, orbit_height, orbit_radius * c),
        .fwd = vec3(-s * basis_h, basis_y, -c * basis_h),
        .right = vec3(c, 0.0, -s),
        .up = vec3(s * basis_y, basis_h, c * basis_y),
    };
}
