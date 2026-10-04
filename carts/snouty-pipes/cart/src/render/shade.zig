//! Track A: Phong shading, the pipe palette and 4x4 ordered dither into the
//! cart's RGB565 DisplayColor bits (SPEC.md section 4). Shared by draw.zig
//! and teapot.zig.
//!
//! The look is the screensaver's glossy plastic, but per pixel: saturated
//! base colour times (ambient + key + fill), a tight white highlight from
//! the key light, a softer one from the fill, and a faint colour rim at
//! grazing angles. The lights hang off the camera (key above left behind
//! the viewer, fill low right), so every view of a scene is lit alike;
//! draw.zig calls `set_view` with the scene camera. The 4x4 Bayer dither
//! hides the 5/6-bit steps of the long gradients along the tubes.
const std = @import("std");
const math = @import("../math.zig");
const camera = @import("../camera.zig");

const Vec3 = math.Vec3;

pub const palette_len = 16;

/// Pipe colours, linear-ish display RGB in [0, 1]: saturated hues around
/// the wheel, plus silver and gold. `[3]f32`, never `@Vector`, in tables.
pub const palette = [palette_len][3]f32{
    .{ 1.00, 0.07, 0.05 }, // red
    .{ 1.00, 0.42, 0.02 }, // orange
    .{ 1.00, 0.82, 0.04 }, // yellow
    .{ 0.55, 1.00, 0.05 }, // lime
    .{ 0.04, 0.86, 0.16 }, // green
    .{ 0.00, 0.80, 0.62 }, // teal
    .{ 0.04, 0.82, 1.00 }, // cyan
    .{ 0.14, 0.48, 1.00 }, // sky
    .{ 0.10, 0.18, 1.00 }, // blue
    .{ 0.42, 0.14, 1.00 }, // indigo
    .{ 0.72, 0.10, 1.00 }, // violet
    .{ 1.00, 0.10, 0.82 }, // magenta
    .{ 1.00, 0.36, 0.60 }, // pink
    .{ 0.80, 0.84, 0.90 }, // silver
    .{ 0.96, 0.68, 0.18 }, // gold
    .{ 0.86, 0.38, 0.16 }, // copper
};

// Lighting knobs.
const ambient: f32 = 0.14;
const key_gain: f32 = 0.88;
const fill_gain: f32 = 0.30;
/// Key highlight: strength and Phong exponent (applied as 2^spec_pow2).
const spec_gain: f32 = 0.95;
const spec_pow2 = 4; // exponent 16
/// Broad sheen under the tight highlight (exponent 8).
const sheen_gain: f32 = 0.22;
const fill_spec_gain: f32 = 0.18;
/// Colour rim at grazing angles: gain on (1 - cos)^3.
const rim_gain: f32 = 0.35;

/// Light directions (towards the light) in camera terms: right, up, back
/// towards the viewer.
const key_cam = [3]f32{ -0.50, 0.66, 0.56 };
const fill_cam = [3]f32{ 0.62, -0.45, 0.64 };

/// World-space unit light directions for the current camera. The defaults
/// suit a camera looking down -z with +y up (host tests that never call
/// `set_view`).
var key: Vec3 = from_cam(key_cam, math.vec3(1, 0, 0), math.vec3(0, 1, 0), math.vec3(0, 0, -1));
var fill: Vec3 = from_cam(fill_cam, math.vec3(1, 0, 0), math.vec3(0, 1, 0), math.vec3(0, 0, -1));
var view_fwd: Vec3 = math.vec3(0, 0, -1);

fn from_cam(l: [3]f32, right: Vec3, up: Vec3, fwd: Vec3) Vec3 {
    return math.normalize(right * math.splat(l[0]) + up * math.splat(l[1]) - fwd * math.splat(l[2]));
}

/// Points the lights for camera `cam`. Cheap when the camera is unchanged.
pub fn set_view(cam: *const camera.Camera) void {
    if (@reduce(.And, cam.fwd == view_fwd)) return;
    view_fwd = cam.fwd;
    key = from_cam(key_cam, cam.right, cam.up, cam.fwd);
    fill = from_cam(fill_cam, cam.right, cam.up, cam.fwd);
}

/// 4x4 Bayer thresholds, (b + 0.5) / 16, indexed [y & 3][x & 3].
const bayer = [16]f32{
    0.5 / 16.0,  8.5 / 16.0,  2.5 / 16.0,  10.5 / 16.0,
    12.5 / 16.0, 4.5 / 16.0,  14.5 / 16.0, 6.5 / 16.0,
    3.5 / 16.0,  11.5 / 16.0, 1.5 / 16.0,  9.5 / 16.0,
    15.5 / 16.0, 7.5 / 16.0,  13.5 / 16.0, 5.5 / 16.0,
};

/// 1/sqrt(x) to ~0.2%: bit-trick guess plus one Newton step, cheaper on
/// the M33 than VSQRT + VDIV. Used for |d| (1 to 1.4), so plenty.
inline fn rsqrt(x: f32) f32 {
    const i: u32 = 0x5f3759df - (@as(u32, @bitCast(x)) >> 1);
    const y: f32 = @bitCast(i);
    return y * (1.5 - 0.5 * x * y * y);
}

/// Lit colour of a surface point: `color` palette index, `n` unit normal,
/// `d` the (not necessarily unit) primary ray direction, (x, y) the pixel
/// for the dither. Returns DisplayColor bits (r low 5, g middle 6, b high 5).
pub inline fn shade(color: u4, n: Vec3, d: Vec3, x: u32, y: u32) u16 {
    const inv_len = rsqrt(math.dot(d, d));
    const dn = math.dot(d, n) * inv_len; // -cos(view angle), <= 0 when facing
    const nk = math.dot(n, key);
    const nf = math.dot(n, fill);
    const lit = ambient + key_gain * @max(0, nk) + fill_gain * @max(0, nf);
    // Phong: reflected view ray dotted with each light, r = v - 2 (v.n) n.
    const rk = @max(0, math.dot(d, key) * inv_len - 2.0 * dn * nk);
    const rf = @max(0, math.dot(d, fill) * inv_len - 2.0 * dn * nf);
    var s8 = rk * rk;
    s8 *= s8;
    s8 *= s8;
    var s = s8;
    inline for (3..spec_pow2) |_| s *= s;
    var f8 = rf * rf;
    f8 *= f8;
    f8 *= f8;
    const white = spec_gain * s + sheen_gain * s8 + fill_spec_gain * f8 * f8;
    const g = math.clamp01(1.0 + dn);
    const rim = rim_gain * g * g * g;
    const base = palette[color];
    const k = lit + rim;
    const th = bayer[(y & 3) * 4 + (x & 3)];
    const r: u16 = @intFromFloat(@min(1.0, base[0] * k + white) * 31.0 + th);
    const gr: u16 = @intFromFloat(@min(1.0, base[1] * k + white) * 63.0 + th);
    const b: u16 = @intFromFloat(@min(1.0, base[2] * k + white) * 31.0 + th);
    return r | (gr << 5) | (b << 11);
}

test "shade stays in range and lights the side facing the key" {
    const d = math.vec3(0, 0, -1);
    for (0..palette_len) |ci| {
        const lit = shade(@intCast(ci), key, d, 0, 0);
        const dark = shade(@intCast(ci), -key, d, 0, 0);
        const lum = struct {
            fn f(c: u16) u32 {
                return (c & 31) + ((c >> 5) & 63) / 2 + (c >> 11);
            }
        }.f;
        try std.testing.expect(lum(lit) > lum(dark));
    }
}

test "set_view keeps lights unit length" {
    const cam = camera.view(3, 0);
    set_view(&cam);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), math.length(key), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), math.length(fill), 1e-4);
    // The key light is on the viewer's side.
    try std.testing.expect(math.dot(key, cam.fwd) < 0);
}
