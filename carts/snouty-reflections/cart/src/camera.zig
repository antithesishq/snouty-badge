//! Orbiting camera and the screen-to-ray mapping (PLAN.md "Screen to ray",
//! "Camera"). Built once per frame; the tracer adds right*u per column and
//! up*v per row from the comptime tables below.
const std = @import("std");
const math = @import("math.zig");
const variant = @import("variant.zig");
const Vec3 = math.Vec3;
const vec3 = math.vec3;
const splat = math.splat;

pub const width = 160;
pub const height = 128;

/// tan(30 deg): horizontal FOV 60 degrees.
pub const tan_h: f32 = 0.57735;

pub const orbit_radius: f32 = 4.5;
/// Eye height (PLAN.md M3 "Camera height"): the orbit's default and the free
/// camera's range.
pub const default_height: f32 = 1.6;
pub const min_height: f32 = 1.0;
pub const max_height: f32 = 3.0;
pub const orbit_height: f32 = default_height;
/// Seconds per revolution, at every frame rate (PLAN.md M2.1).
pub const orbit_seconds = 30;
/// Frames per revolution: 600 at 20 fps, 450 at 15, 900 at 30.
pub const orbit_frames = orbit_seconds * variant.fps;
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
/// correctly rounded). u(159 - x) = -u(x) and v(127 - y) = -v(y) exactly
/// (both tables are symmetric in f32), so the image only stores the top-left
/// quarter (80 x 64 f32 = 20 KB of .text; M2.2 mirrored it in y for the
/// logo's code size) and init() unfolds it in y into inv_len_table in .bss,
/// indexed with `half_column(x)`: the same values, no per-ray index fold.
const inv_len_quarter: [width / 2][height / 2]f32 = blk: {
    @setEvalBranchQuota(200000);
    var t: [width / 2][height / 2]f32 = undefined;
    for (0..width / 2) |x| {
        const u: f64 = u_table[x];
        for (0..height / 2) |y| {
            const v: f64 = v_table[y];
            t[x][y] = @floatCast(1.0 / @sqrt(1.0 + u * u + v * v));
        }
    }
    break :blk t;
};

/// 80 x 128 f32 (40 KB of .bss), filled by init().
pub var inv_len_table: [width / 2][height]f32 = undefined;

pub fn init() void {
    for (&inv_len_table, &inv_len_quarter) |*col, *q| {
        for (q, 0..) |v, y| {
            col[y] = v;
            col[height - 1 - y] = v;
        }
    }
}

comptime {
    for (0..height / 2) |y| {
        if (v_table[height - 1 - y] != -v_table[y]) @compileError("v_table is not symmetric");
    }
}

pub inline fn half_column(x: usize) usize {
    return if (x < width / 2) x else width - 1 - x;
}

pub const Camera = struct {
    eye: Vec3,
    fwd: Vec3,
    right: Vec3,
    up: Vec3,
};

/// (sin, cos) of theta = i / orbit_frames turns for every orbit frame, rounded once
/// from f64. The runtime sine table's interpolation error (~5e-6) is fine
/// for ripples but not for the camera: it tilts every primary ray by ~1e-6
/// rad, and grazing silhouette rays (sphere, then water at ~70 units) turn
/// that into visible colour changes. 8 bytes per frame (4.8 KB at 20 fps).
pub const orbit_sincos: [orbit_frames][2]f32 = blk: {
    @setEvalBranchQuota(40 * orbit_frames);
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

/// The height-dependent part of the basis: eye height, basis_h, basis_y and
/// the first row whose primary rays go down.
pub const Basis = struct {
    height: f32,
    h: f32,
    y: f32,
    first_water_row: usize,
};

/// The M2.2 values, folded in f64 at comptime (the legacy identity).
pub const default_basis: Basis = .{
    .height = default_height,
    .h = basis_h,
    .y = basis_y,
    .first_water_row = first_water_row,
};

/// The basis at eye height `height`: default_basis at default_height, else
/// the same closed form in f32 (PLAN.md M3: the height basis is the one
/// per-frame f32-rounded value the reference mirrors).
pub fn basis_at(eye_height: f32) Basis {
    if (eye_height == default_height) return default_basis;
    const dy = target[1] - eye_height;
    const inv_l = 1.0 / @sqrt(orbit_radius * orbit_radius + dy * dy);
    const bh = orbit_radius * inv_l;
    const by = dy * inv_l;
    // basis_h > 0, so the ray's y is decreasing in the row: one switch.
    var first: usize = height;
    var y: usize = height;
    while (y > 0) {
        y -= 1;
        if (!(by + bh * v_table[y] < 0.0)) break;
        first = y;
    }
    return .{ .height = eye_height, .h = bh, .y = by, .first_water_row = first };
}

/// The camera at orbit index `orbit` (theta = orbit / orbit_frames turns).
pub fn at(orbit: u32, b: *const Basis) Camera {
    const sc = orbit_sincos[orbit % orbit_frames];
    const s = sc[0];
    const c = sc[1];
    return .{
        .eye = vec3(orbit_radius * s, b.height, orbit_radius * c),
        .fwd = vec3(-s * b.h, b.y, -c * b.h),
        .right = vec3(c, 0.0, -s),
        .up = vec3(s * b.y, b.h, c * b.y),
    };
}
