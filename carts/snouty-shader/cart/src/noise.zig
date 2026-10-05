//! A 128x128 tileable fbm texture (gradient noise, four octaves), built at
//! start() in f32 (~16k texels, a few ms once), stored as u8 0..255. INK
//! samples it bilinearly through its warp, KALEIDO nearest along the
//! tunnel. `tex[(y << 7) | x]`, both coordinates wrapping at 128.
const std = @import("std");
const math = @import("math.zig");

pub const size = 128;
pub const mask = size - 1;

pub var tex: [size * size]u8 = @splat(0);

fn hash(x: u32, y: u32, o: u32) u32 {
    var h = x *% 0x8da6b343 ^ y *% 0xd8163841 ^ o *% 0xcb1ab31f;
    h ^= h >> 16;
    h *%= 0x7feb352d;
    h ^= h >> 15;
    h *%= 0x846ca68b;
    h ^= h >> 16;
    return h;
}

inline fn fade(t: f32) f32 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

/// Gradient noise of period `period` lattice cells over the texture.
fn gradient_noise(x: f32, y: f32, period: u32, octave: u32) f32 {
    const fx = @floor(x);
    const fy = @floor(y);
    const ix: u32 = @intFromFloat(fx);
    const iy: u32 = @intFromFloat(fy);
    const tx = x - fx;
    const ty = y - fy;
    var corner: [4]f32 = undefined;
    for (0..4) |k| {
        const cx: u32 = @intCast(k & 1);
        const cy: u32 = @intCast(k >> 1);
        const h = hash((ix + cx) % period, (iy + cy) % period, octave);
        const ang = @as(f32, @floatFromInt(h >> 22)) / 1024.0; // turns
        const gx = math.cos_turns(ang);
        const gy = math.sin_turns(ang);
        corner[k] = gx * (tx - @as(f32, @floatFromInt(cx))) + gy * (ty - @as(f32, @floatFromInt(cy)));
    }
    const u = fade(tx);
    const v = fade(ty);
    const a = corner[0] + (corner[1] - corner[0]) * u;
    const b = corner[2] + (corner[3] - corner[2]) * u;
    return a + (b - a) * v;
}

pub fn init() void {
    // Quantise with a generous fixed range first (no 64 KB f32 scratch on
    // a 32 KB stack), then stretch the bytes to the full 0..255.
    var lo: u8 = 255;
    var hi: u8 = 0;
    for (0..size) |y| for (0..size) |x| {
        var v: f32 = 0;
        var amp: f32 = 1;
        var period: u32 = 4;
        for (0..4) |o| {
            const cell = @as(f32, @floatFromInt(size)) / @as(f32, @floatFromInt(period));
            const px = @as(f32, @floatFromInt(x)) / cell;
            const py = @as(f32, @floatFromInt(y)) / cell;
            v += amp * gradient_noise(px, py, period, @intCast(o));
            amp *= 0.5;
            period *= 2;
        }
        const q: u8 = @intFromFloat(math.clampf(128.0 + v * 106.0, 0, 255));
        tex[y * size + x] = q;
        lo = @min(lo, q);
        hi = @max(hi, q);
    };
    const span: u32 = @max(1, @as(u32, hi) - lo);
    for (&tex) |*t| t.* = @intCast((@as(u32, t.*) - lo) * 255 / span);
}

/// Bilinear sample at (u, v) in Q8 texels (wrapping), 0..255.
pub inline fn sample(u: i32, v: i32) i32 {
    const x0: u32 = @as(u32, @bitCast(u >> 8)) & mask;
    const y0: u32 = @as(u32, @bitCast(v >> 8)) & mask;
    const x1 = (x0 + 1) & mask;
    const y1 = (y0 + 1) & mask;
    const fx: i32 = u & 255;
    const fy: i32 = v & 255;
    const a: i32 = tex[(y0 << 7) | x0];
    const b: i32 = tex[(y0 << 7) | x1];
    const c: i32 = tex[(y1 << 7) | x0];
    const d: i32 = tex[(y1 << 7) | x1];
    const top = (a << 8) + (b - a) * fx;
    const bot = (c << 8) + (d - c) * fx;
    return ((top << 8) + (bot - top) * fy) >> 16;
}

/// Nearest texel at integer coordinates (wrapping).
pub inline fn at(x: u32, y: u32) u8 {
    return tex[((y & mask) << 7) | (x & mask)];
}

test "noise: full range, tiles seamlessly, smooth" {
    const t = std.testing;
    math.init_tables();
    init();
    var lo: u8 = 255;
    var hi: u8 = 0;
    for (tex) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    try t.expectEqual(@as(u8, 0), lo);
    try t.expectEqual(@as(u8, 255), hi);
    // Across the wrap the texture changes no more than inside it.
    var max_inside: u32 = 0;
    var max_wrap: u32 = 0;
    for (0..size) |y| {
        for (0..size - 1) |x| max_inside = @max(max_inside, @abs(@as(i32, at(@intCast(x + 1), @intCast(y))) - at(@intCast(x), @intCast(y))));
        max_wrap = @max(max_wrap, @abs(@as(i32, at(0, @intCast(y))) - at(size - 1, @intCast(y))));
    }
    try t.expect(max_wrap <= max_inside);
    try t.expect(max_inside < 40);
    // Bilinear sampling hits the texels at integer positions.
    try t.expectEqual(@as(i32, at(5, 9)), sample(5 << 8, 9 << 8));
    try t.expectEqual(@as(i32, at(127, 0)), sample(-1 << 8, 128 << 8));
}
