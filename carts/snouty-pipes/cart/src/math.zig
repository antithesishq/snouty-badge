//! Shared float math (copied from snouty-maze). Everything is f32; the M33 FPU handles
//! add/mul in one cycle and div/sqrt in ~14. Never use f64 here (soft-float).
const std = @import("std");

pub const Vec3 = @Vector(3, f32);

pub inline fn vec3(x: f32, y: f32, z: f32) Vec3 {
    return .{ x, y, z };
}

pub inline fn splat(s: f32) Vec3 {
    return @splat(s);
}

pub inline fn dot(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}

pub inline fn length(a: Vec3) f32 {
    return @sqrt(dot(a, a));
}

/// Exact normalise: one hardware sqrt and one divide.
pub inline fn normalize(a: Vec3) Vec3 {
    return a * splat(1.0 / @sqrt(dot(a, a)));
}

/// One Newton step from an initial guess; good when `a` is already close to
/// unit length (perturbed normals). No sqrt, no divide.
pub inline fn renormalize(a: Vec3) Vec3 {
    return a * splat(1.5 - 0.5 * dot(a, a));
}

pub inline fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

/// Reflect incident direction `d` about unit normal `n`.
pub inline fn reflect(d: Vec3, n: Vec3) Vec3 {
    return d - n * splat(2.0 * dot(d, n));
}

pub inline fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
    return a + (b - a) * splat(t);
}

pub inline fn clamp01(x: f32) f32 {
    return @min(1.0, @max(0.0, x));
}

pub inline fn saturate(v: Vec3) Vec3 {
    return @min(splat(1.0), @max(splat(0.0), v));
}

pub inline fn smoothstep(e0: f32, e1: f32, x: f32) f32 {
    const t = clamp01((x - e0) / (e1 - e0));
    return t * t * (3.0 - 2.0 * t);
}

/// Schlick's Fresnel approximation. `cos_theta` is the cosine between the
/// view direction and the normal, `f0` the reflectance at normal incidence.
pub inline fn schlick(cos_theta: f32, f0: f32) f32 {
    const m = clamp01(1.0 - cos_theta);
    const m2 = m * m;
    return f0 + (1.0 - f0) * m2 * m2 * m;
}

// ---------------------------------------------------------------------------
// Sine table. Angles are in "turns" (1.0 = 360 degrees) so wrapping is a
// fract, not a modulo by pi.

pub const sin_table_len = 1024;
pub const sin_table: [sin_table_len]f32 = blk: {
    @setEvalBranchQuota(20000);
    var t: [sin_table_len]f32 = undefined;
    for (0..sin_table_len) |i| {
        const a: f64 = @as(f64, @floatFromInt(i)) * (2.0 * std.math.pi / @as(f64, sin_table_len));
        t[i] = @floatCast(@sin(a));
    }
    break :blk t;
};

/// sin(turns * 2*pi) with linear interpolation. Valid for any finite input.
pub inline fn sin_turns(turns: f32) f32 {
    const f = (turns - @floor(turns)) * @as(f32, sin_table_len);
    const i: u32 = @intFromFloat(f);
    const frac = f - @as(f32, @floatFromInt(i));
    const a = sin_table[i & (sin_table_len - 1)];
    const b = sin_table[(i + 1) & (sin_table_len - 1)];
    return a + (b - a) * frac;
}

pub inline fn cos_turns(turns: f32) f32 {
    return sin_turns(turns + 0.25);
}

test "sin table" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sin_turns(0.0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sin_turns(0.25), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), sin_turns(0.75), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cos_turns(3.0), 1e-4);
}

/// Fractional part, x - floor(x), in [0, 1). Keeps turn-valued phases small
/// so f32 precision does not degrade as time grows.
pub inline fn fract(x: f32) f32 {
    return x - @floor(x);
}

pub const inf_f32: f32 = std.math.inf(f32);

// ---------------------------------------------------------------------------
// Angles and rotation. Angles are u16, 65,536 per turn, so wrapping is free.

pub const Angle = u16;

/// Degrees to Angle, for constants: `deg(90)`.
pub inline fn deg(comptime d: comptime_float) Angle {
    return @intFromFloat(@mod(d, 360.0) / 360.0 * 65536.0);
}

pub inline fn sin_angle(a: Angle) f32 {
    return sin_turns(@as(f32, @floatFromInt(a)) * (1.0 / 65536.0));
}

pub inline fn cos_angle(a: Angle) f32 {
    return cos_turns(@as(f32, @floatFromInt(a)) * (1.0 / 65536.0));
}

/// Row-major 3x3 matrix; `apply(v)` = rows dotted with v.
pub const Mat3 = struct {
    r: [3]Vec3,

    pub const identity: Mat3 = .{ .r = .{ vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1) } };

    pub inline fn apply(m: Mat3, v: Vec3) Vec3 {
        return .{ dot(m.r[0], v), dot(m.r[1], v), dot(m.r[2], v) };
    }

    pub fn mul(a: Mat3, b: Mat3) Mat3 {
        const c0 = vec3(b.r[0][0], b.r[1][0], b.r[2][0]);
        const c1 = vec3(b.r[0][1], b.r[1][1], b.r[2][1]);
        const c2 = vec3(b.r[0][2], b.r[1][2], b.r[2][2]);
        var out: Mat3 = undefined;
        for (0..3) |i| out.r[i] = vec3(dot(a.r[i], c0), dot(a.r[i], c1), dot(a.r[i], c2));
        return out;
    }
};

/// smoothstep on [0, 1].
pub inline fn smoothstep01(t: f32) f32 {
    const x = clamp01(t);
    return x * x * (3.0 - 2.0 * x);
}

pub inline fn lerp1(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

test "angles" {
    try std.testing.expectEqual(@as(Angle, 16384), deg(90));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sin_angle(deg(90)), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), cos_angle(deg(180)), 1e-4);
    const v = Mat3.identity.apply(vec3(1, 2, 3));
    try std.testing.expectEqual(@as(f32, 2), v[1]);
}
