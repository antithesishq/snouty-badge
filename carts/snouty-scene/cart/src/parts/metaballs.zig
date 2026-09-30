//! Part 6, Metaballs (5 bars, 10 s): five blobs on Lissajous paths that
//! merge and split, a sixth one growing in halfway through.
//!
//! Half resolution: an 80x64 index field upscaled 2x through a palette.
//! Each ball adds w * lut[d2] to a pixel, where d2 is the squared distance
//! in half-res pixels and lut[d] ~ 1/(d + eps) (built at init(), shifted so
//! the clamped tail at d2 = 4095 is exactly 0). Ball centres are kept in
//! 1/8 pixel (per frame, from f32), so dx and dy are integers per column
//! and per row: per column one dx*dx per ball, per row a per-frame table of
//! dy*dy per ball, so the inner loop is an add, a shift, a clamp, a table
//! load and a multiply-accumulate. The palette puts the iso contour at
//! index 64 behind a hard bright rim over a smooth dark halo, so the blobs
//! read as solid shiny objects. It cross-fades once from a cool palette to
//! a warm one; on every beat the radii swell 10% and settle over 4 frames.
const std = @import("std");
const cart = @import("cart-api");
const math = @import("../math.zig");
const palette = @import("../palette.zig");
const fx = @import("../fx.zig");

pub const name: []const u8 = "Metaballs";

const w = 80;
const h = 64;

pub const lut_len = 4096;
/// Sub-pixel bits of the ball centres (1/8 px): d2 in 1/64 px^2.
const sub = 3;
/// lut[d] = lut_a / (d + lut_eps) - tail, d in px^2.
const lut_a: u32 = 1 << 18;
const lut_eps: u32 = 4;
/// Field sum to palette index: a ball of radius r (weight r^2 * 16) is at
/// lut_a * 16 >> 16 = 64 on its iso contour.
const index_shift = 16;

var lut: [lut_len]u16 = undefined;
var field: fx.Indices = undefined;
var cool: palette.Palette = undefined;
var warm: palette.Palette = undefined;

/// lut[d] for d in px^2, clamped to the table (the caller clamps d).
pub fn lut_value(d: u32) u16 {
    const tail = lut_a / (lut_len - 1 + lut_eps);
    return @intCast(@min(65535, lut_a / (d + lut_eps) - tail));
}

/// Summed field to palette index.
pub inline fn field_index(sum: u32) u8 {
    return @intCast(@min(255, sum >> index_shift));
}

/// Weight of a ball of radius r half-res pixels: r^2 in 1/16 units.
pub fn weight(r: f32) u32 {
    return @intFromFloat(r * r * 16.0);
}

const Ball = struct {
    cx: f32, // centre and amplitude, half-res pixels
    cy: f32,
    ax: f32,
    ay: f32,
    fx: f32, // turns per frame
    fy: f32,
    px: f32, // phase, turns
    py: f32,
    r: f32,
};

const balls = [_]Ball{
    .{ .cx = 40, .cy = 32, .ax = 30, .ay = 22, .fx = 1.0 / 347.0, .fy = 1.0 / 251.0, .px = 0.00, .py = 0.30, .r = 9.0 },
    .{ .cx = 40, .cy = 32, .ax = 26, .ay = 24, .fx = 1.0 / 263.0, .fy = 1.0 / 411.0, .px = 0.45, .py = 0.10, .r = 8.0 },
    .{ .cx = 40, .cy = 32, .ax = 33, .ay = 18, .fx = 1.0 / 199.0, .fy = 1.0 / 307.0, .px = 0.70, .py = 0.85, .r = 7.0 },
    .{ .cx = 40, .cy = 32, .ax = 20, .ay = 25, .fx = 1.0 / 431.0, .fy = 1.0 / 223.0, .px = 0.20, .py = 0.60, .r = 10.0 },
    .{ .cx = 40, .cy = 32, .ax = 34, .ay = 20, .fx = 1.0 / 293.0, .fy = 1.0 / 181.0, .px = 0.90, .py = 0.45, .r = 6.5 },
    // The sixth ball, growing in from frame 300.
    .{ .cx = 40, .cy = 32, .ax = 16, .ay = 12, .fx = 1.0 / 157.0, .fy = 1.0 / 211.0, .px = 0.35, .py = 0.05, .r = 8.0 },
};
const sixth_from = 300;
const sixth_grow = 45;

/// Palette cross-fade from cool to warm.
const blend_from = 270;
const blend_len = 90;

pub fn init() void {
    for (&lut, 0..) |*v, d| v.* = lut_value(@intCast(d));
    cool = palette.gradient(&.{
        .{ .pos = 0, .rgb = 0x000000 },
        .{ .pos = 24, .rgb = 0x00030f },
        .{ .pos = 44, .rgb = 0x000c3a },
        .{ .pos = 54, .rgb = 0x06268a },
        .{ .pos = 60, .rgb = 0x2a78f0 },
        .{ .pos = 65, .rgb = 0xd8ffff },
        .{ .pos = 71, .rgb = 0x70d8ff },
        .{ .pos = 79, .rgb = 0x1c5cc0 },
        .{ .pos = 150, .rgb = 0x2c84e8 },
        .{ .pos = 215, .rgb = 0x70c8ff },
        .{ .pos = 245, .rgb = 0xd0f4ff },
        .{ .pos = 255, .rgb = 0xffffff },
    });
    warm = palette.gradient(&.{
        .{ .pos = 0, .rgb = 0x000000 },
        .{ .pos = 24, .rgb = 0x0c0006 },
        .{ .pos = 44, .rgb = 0x34041c },
        .{ .pos = 54, .rgb = 0x8a1410 },
        .{ .pos = 60, .rgb = 0xf06018 },
        .{ .pos = 65, .rgb = 0xfff4c8 },
        .{ .pos = 71, .rgb = 0xffc050 },
        .{ .pos = 79, .rgb = 0xb83c10 },
        .{ .pos = 150, .rgb = 0xe06c20 },
        .{ .pos = 215, .rgb = 0xffb050 },
        .{ .pos = 245, .rgb = 0xfff0b0 },
        .{ .pos = 255, .rgb = 0xffffff },
    });
}

pub fn enter() void {}

/// Radius factor for the beat: +10% on the beat frame, settling over 4.
pub fn beat_swell(t: u32) f32 {
    const k = t % 30;
    return if (k < 4) 1.0 + 0.1 * @as(f32, @floatFromInt(4 - k)) / 4.0 else 1.0;
}

pub fn render(t: u32, fb: cart.FramebufferPtr) void {
    const n_max = balls.len;
    var bx: [n_max]i32 = undefined; // centres in 1/8 px
    var wt: [n_max]u32 = undefined;
    var dy2: [n_max][h]u32 = undefined;
    const tf: f32 = @floatFromInt(t);
    const swell = beat_swell(t);
    var n: usize = 0;
    for (balls, 0..) |b, i| {
        var r = b.r * swell;
        if (i == 5) {
            if (t < sixth_from) continue;
            const g = @min(1.0, @as(f32, @floatFromInt(t - sixth_from)) / sixth_grow);
            r *= math.smoothstep(0.0, 1.0, g);
        }
        const x = b.cx + b.ax * math.sin_turns(math.fract(tf * b.fx + b.px));
        const y = b.cy + b.ay * math.sin_turns(math.fract(tf * b.fy + b.py));
        bx[n] = @intFromFloat(@round(x * (1 << sub)));
        const by: i32 = @intFromFloat(@round(y * (1 << sub)));
        wt[n] = weight(r);
        for (&dy2[n], 0..) |*v, yy| {
            const dy: i32 = @as(i32, @intCast(yy << sub)) + (1 << (sub - 1)) - by;
            v.* = @intCast(dy * dy);
        }
        n += 1;
    }

    const lim: u32 = (lut_len - 1) << (2 * sub);
    for (&field, 0..) |*col, x| {
        var acc: [h]u32 = @splat(0);
        for (0..n) |b| {
            const dx: i32 = @as(i32, @intCast(x << sub)) + (1 << (sub - 1)) - bx[b];
            const dx2: u32 = @intCast(dx * dx);
            if (dx2 >= lim) continue;
            const wb = wt[b];
            const dyb = &dy2[b];
            for (&acc, dyb) |*a, d| {
                const dd = @min(dx2 + d, lim) >> (2 * sub);
                a.* += @as(u32, lut[dd]) * wb;
            }
        }
        for (col, acc) |*v, a| v.* = field_index(a);
    }

    if (t < blend_from) {
        fx.upscale2x(&field, &cool, fb);
    } else if (t >= blend_from + blend_len) {
        fx.upscale2x(&field, &warm, fb);
    } else {
        const f: f32 = @as(f32, @floatFromInt(t - blend_from)) / blend_len;
        const k: u8 = @intFromFloat(math.smoothstep(0.0, 1.0, f) * 255.0);
        const pal = palette.lerp(&cool, &warm, k);
        fx.upscale2x(&field, &pal, fb);
    }
}

test "metaballs: lut is monotonic, zero at the tail, iso at index 64" {
    try std.testing.expectEqual(@as(u16, lut_a / lut_eps - lut_a / (lut_len - 1 + lut_eps)), lut_value(0));
    try std.testing.expectEqual(@as(u16, 0), lut_value(lut_len - 1));
    var prev: u16 = lut_value(0);
    for (1..lut_len) |d| {
        const v = lut_value(@intCast(d));
        try std.testing.expect(v <= prev);
        prev = v;
    }
    // One ball of radius 10 (d2 = 100 - eps on its contour) sits at 64.
    const r2: u32 = 100;
    const on = field_index(@as(u32, lut_value(r2 - lut_eps)) * weight(10.0));
    try std.testing.expect(on >= 59 and on <= 64); // the tail shift pulls it in a little
    // Six balls at their centres, swollen, do not overflow u32.
    const worst: u64 = 6 * @as(u64, 65535) * weight(12.0 * 1.1);
    try std.testing.expect(worst < std.math.maxInt(u32));
    try std.testing.expectEqual(@as(u8, 255), field_index(std.math.maxInt(u32)));
}

test "metaballs: beat swell" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), beat_swell(0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), beat_swell(60), 1e-6);
    try std.testing.expect(beat_swell(3) > 1.0 and beat_swell(3) < beat_swell(2));
    try std.testing.expectEqual(@as(f32, 1.0), beat_swell(4));
    try std.testing.expectEqual(@as(f32, 1.0), beat_swell(29));
}
