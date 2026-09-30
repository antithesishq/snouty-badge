//! Part 4, Tunnel (5 bars, 10 s): flying down a tunnel lined with Iris
//! marks, the classic lookup-table tunnel.
//!
//! init() fills two byte tables over a 200x168 field, larger than the
//! screen: `ang`, the angle around the tunnel's axis (256 steps per turn),
//! and `dep`, the depth, `depth_k / r` capped at 255 near the centre. The
//! Iris texture (32x32) is repeated 8 times around (u = angle & 31) and
//! every 32 depth units along (v = depth & 31). Each frame the screen is a
//! 160x128 window into the tables whose offset follows a Lissajous path,
//! so the vanishing point sways and the camera seems to drift inside the
//! tunnel; the angle gets a slowly swinging rotation and the depth a
//! forward scroll.
//!
//! Shading and colour: the texture is reduced at init() to texel classes
//! (wall, tile-edge seam, mark), and every frame builds a 256 x 4 palette
//! indexed by depth and class: each ring of tiles along the tunnel has its
//! own mark hue (salmon, amber, teal, orchid, cycling as the rings fly
//! past), everything is fogged towards violet with depth and darkened to
//! black at the far end, which gives the tunnel its depth. On every beat
//! (30 frames) the brightness gets a small decaying push, a flash running
//! down the tunnel. With a per-frame `vof[depth]` (the scrolled texel row)
//! the inner loop is two table loads, the `vof` load, an add and an and for
//! u, the class load, the palette load and one store: no floats and no
//! banding, since brightness is per depth value, not per quantised level.
const cart = @import("cart-api");
const math = @import("../math.zig");
const textures = @import("../gen/textures.zig");
const palette = @import("../palette.zig");

pub const name: []const u8 = "Tunnel";

const width = 160;
const height = 128;
/// Table size: the screen plus the sway range of the window.
pub const lw = 200;
pub const lh = 168;
const sway_x = (lw - width) / 2; // 20
const sway_y = (lh - height) / 2; // 20

/// Depth = depth_k / r (r in pixels). At r = 55 a texel is about square.
pub const depth_k: f32 = 2200.0;

const tex_n: u32 = 32 * 32;

var ang: [lw][lh]u8 = undefined;
var dep: [lw][lh]u8 = undefined;
/// Texel classes of the Iris texture, [v * 32 + u]: 0 wall, 1 seam (tile
/// edge), 2 mark.
var cls: [tex_n]u8 = undefined;
/// Brightness (0..256) and fog (0..256, towards `fog_rgb`) per depth.
var bright: [256]u16 = undefined;
var fog: [256]u16 = undefined;

/// Mark colour per ring of tiles along the tunnel, cycling.
const ring_rgb = [4]u32{ 0xff9a84, 0xffd060, 0x60f0d8, 0xe088ff };
const wall_rgb: u32 = 0x1c0a3c;
const seam_rgb: u32 = 0x5a36b0;
const fog_rgb: u32 = 0x8a1ad8;

/// Angle of (x, y) in 1/256 turns, 0..255. f32 at init() only.
pub fn angle256(x: f32, y: f32) u8 {
    const ax = @abs(x);
    const ay = @abs(y);
    if (ax == 0 and ay == 0) return 0;
    // atan(z) for z in [0, 1], in turns: good to about 0.001 turn.
    const swap = ay > ax;
    const z = if (swap) ax / ay else ay / ax;
    var a = z * (0.125 + (1.0 - z) * (0.03895 + 0.01055 * z)); // turns, 0..1/8
    if (swap) a = 0.25 - a;
    if (x < 0) a = 0.5 - a;
    if (y < 0) a = 1.0 - a;
    const v: i32 = @intFromFloat(a * 256.0 + 0.5);
    return @truncate(@as(u32, @bitCast(v)));
}

/// Depth byte for a radius in pixels: depth_k / r, capped at 255.
pub fn depth_of(r: f32) u8 {
    if (r * 255.0 <= depth_k) return 255;
    return @intFromFloat(depth_k / r);
}

pub fn init() void {
    for (&ang, &dep, 0..) |*ac, *dc, x| {
        const fx_: f32 = @as(f32, @floatFromInt(x)) - lw / 2 + 0.5;
        for (ac, dc, 0..) |*a, *d, y| {
            const fy: f32 = @as(f32, @floatFromInt(y)) - lh / 2 + 0.5;
            a.* = angle256(fx_, fy);
            d.* = depth_of(@sqrt(fx_ * fx_ + fy * fy));
        }
    }
    // Brightness by depth: full near the viewer, black from depth ~185;
    // fog grows with depth.
    for (&bright, &fog, 0..) |*b, *f, d| {
        const z: f32 = @as(f32, @floatFromInt(d)) / 185.0; // 0 near .. 1 far
        const lin = @max(0.0, 1.0 - z);
        b.* = @intFromFloat(@min(256.0, lin * lin * 300.0));
        f.* = @intFromFloat(@min(256.0, z * 200.0));
    }
    for (&cls, 0..) |*c, i| {
        const v = i >> 5;
        const u = i & 31;
        c.* = if (textures.iris[v][u] != 0) 2 else if (u == 0 or v == 0) 1 else 0;
    }
}

pub fn enter() void {}

pub fn render(t: u32, fb: cart.FramebufferPtr) void {
    // Window offset on a Lissajous path, 0..40 in x and y.
    const ox: u32 = @intCast(sway_x + ((sway_x * math.isin(t * 3)) >> 15));
    const oy: u32 = @intCast(sway_y + ((sway_y * math.isin(t * 5 + 200)) >> 15));
    // Rotation: a slow drift plus a swing, in 1/256 turns.
    const rot: u32 = @bitCast((@as(i32, @intCast(t)) >> 1) + ((40 * math.isin(t * 2)) >> 15));
    const scroll: u32 = t * 3;
    // Beat flash: +48 brightness at the beat, decaying over 12 frames.
    const ph = t % 30;
    const flash: u32 = if (ph < 12) (12 - ph) * 4 else 0;

    // Per depth: the texel row (scrolled v) and the colours of the three
    // texel classes (ring hue, fog, brightness, beat flash).
    var vof: [256]u16 = undefined;
    var pal: [256 * 4]cart.Pixel = undefined;
    for (0..256) |d| {
        const dv: u32 = @as(u32, @intCast(d)) + scroll;
        vof[d] = @intCast((dv & 31) << 5);
        const b: u32 = @min(256, @as(u32, bright[d]) + flash);
        const f: u32 = fog[d];
        const mark = ring_rgb[(dv >> 5) & 3];
        inline for (.{ wall_rgb, seam_rgb, mark }, 0..) |base, c| {
            const fogged = palette.mix_rgb(base, fog_rgb, f);
            pal[d * 4 + c] = palette.pixel(palette.mix_rgb(0, fogged, b));
        }
    }

    for (fb, 0..) |*col, x| {
        const ac: *const [height]u8 = ang[x + ox][oy..][0..height];
        const dc: *const [height]u8 = dep[x + ox][oy..][0..height];
        for (col, ac, dc) |*px, a, d| {
            px.* = pal[(@as(u32, d) << 2) | cls[vof[d] + ((a +% rot) & 31)]];
        }
    }
}

test "angle256 quadrants and depth cap" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u8, 0), angle256(10, 0));
    try std.testing.expectEqual(@as(u8, 64), angle256(0, 10));
    try std.testing.expectEqual(@as(u8, 128), angle256(-10, 0));
    try std.testing.expectEqual(@as(u8, 192), angle256(0, -10));
    try std.testing.expectEqual(@as(u8, 32), angle256(7, 7));
    try std.testing.expectEqual(@as(u8, 160), angle256(-7, -7));
    try std.testing.expectEqual(@as(u8, 255), depth_of(0.5));
    try std.testing.expectEqual(@as(u8, 55), depth_of(40));
    try std.testing.expectEqual(@as(u8, 22), depth_of(100));
}
