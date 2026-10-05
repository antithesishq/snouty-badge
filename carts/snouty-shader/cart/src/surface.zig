//! The half-resolution render target and its 2x upscale (SPEC.md section 2).
//!
//! Every program writes an 80x64 `Surface`, column-major like the
//! framebuffer (`s[x][y]`), each pixel an RGB565 colour in "spread" form:
//! `(c | c << 16) & 0x07E0F81F`, which leaves five or more spare bits above
//! each channel, so two to four pixels add (and a pixel scales by up to 32)
//! with one integer operation for all three channels. `upscale` writes the
//! 160x128 framebuffer: even output pixels are the source pixels, odd ones
//! the average of their two (or four) neighbours, i.e. a bilinear 2x
//! upscale, smooth instead of blocky, for about 1 ms.
//!
//! The RGB565 layout is the cart API's `DisplayColor` (r in bits 0..4, g in
//! 5..10, b in 11..15); `pixel_bits` byte-swaps for the wasm simulator the
//! way `cart.Pixel.from_color` does. No cart API here (host-tested).
const std = @import("std");
const builtin = @import("builtin");

pub const w = 80;
pub const h = 64;
pub const Surface = [w][h]u32;

pub const mask: u32 = 0x07E0F81F;

const is_wasm = builtin.cpu.arch.isWasm();

/// 0..255 channels to the cart API's RGB565 bits.
pub inline fn rgb565(r: u32, g: u32, b: u32) u16 {
    return @intCast((r >> 3) | ((g >> 2) << 5) | ((b >> 3) << 11));
}

pub inline fn spread(c: u16) u32 {
    const v: u32 = c;
    return (v | (v << 16)) & mask;
}

pub inline fn unspread(v: u32) u16 {
    return @truncate((v & mask) | ((v & mask) >> 16));
}

/// 0..255 channels straight to the spread form.
pub inline fn spread_rgb(r: u32, g: u32, b: u32) u32 {
    return spread(rgb565(r, g, b));
}

/// Scale a spread colour by f/32 (f 0..32).
pub inline fn scale(v: u32, f: u32) u32 {
    return ((v * f) >> 5) & mask;
}

/// Framebuffer bits of an RGB565 colour (byte-swapped on wasm).
pub inline fn pixel_bits(c: u16) u16 {
    return if (is_wasm) @byteSwap(c) else c;
}

/// The framebuffer as raw columns of 64 words (two pixels each, the upper
/// pixel in the low half: little-endian on thumb and wasm).
pub const Words = [160][64]u32;

/// Bilinear 2x upscale of `src` into `dst` (every pixel written).
pub fn upscale(src: *const Surface, dst: *Words) void {
    for (0..w) |x| {
        const nx = if (x + 1 < w) x + 1 else x;
        const s0 = &src[x];
        const s1 = &src[nx];
        const d0 = &dst[2 * x];
        const d1 = &dst[2 * x + 1];
        var a = s0[0];
        var c = s1[0];
        for (0..h) |y| {
            const ny = if (y + 1 < h) y + 1 else y;
            const b = s0[ny];
            const d = s1[ny];
            const p01 = ((a + b) >> 1) & mask;
            const p10 = ((a + c) >> 1) & mask;
            const p11 = ((a + b + c + d) >> 2) & mask;
            d0[y] = @as(u32, pixel_bits(unspread(a))) | (@as(u32, pixel_bits(unspread(p01))) << 16);
            d1[y] = @as(u32, pixel_bits(unspread(p10))) | (@as(u32, pixel_bits(unspread(p11))) << 16);
            a = b;
            c = d;
        }
    }
}

test "surface: spread round trip and averaging" {
    const t = std.testing;
    const white = rgb565(255, 255, 255);
    try t.expectEqual(@as(u16, 0xffff), white);
    try t.expectEqual(white, unspread(spread(white)));
    const red = spread_rgb(255, 0, 0);
    const blue = spread_rgb(0, 0, 255);
    // Averages never bleed between channels.
    const mid = unspread(((red + blue) >> 1) & mask);
    try t.expectEqual(rgb565(127, 0, 127), mid);
    const four = unspread(((spread(white) * 4) >> 2) & mask);
    try t.expectEqual(white, four);
    // Half of white: 15 of 31 red and blue, 31 of 63 green.
    try t.expectEqual(@as(u16, 15 | (31 << 5) | (15 << 11)), unspread(scale(spread(white), 16)));
}

test "surface: upscale keeps source pixels and interpolates between" {
    const t = std.testing;
    var src: Surface = undefined;
    for (0..w) |x| for (0..h) |y| {
        src[x][y] = spread_rgb(@intCast(x * 3), @intCast(y * 4), 0);
    };
    var dst: Words = undefined;
    upscale(&src, &dst);
    // Even pixels are the source pixels.
    try t.expectEqual(@as(u32, unspread(src[10][20])), dst[20][20] & 0xffff);
    // The odd column between source columns 10 and 11 is their average.
    const between = unspread(((src[10][20] + src[11][20]) >> 1) & mask);
    try t.expectEqual(@as(u32, between), dst[21][20] & 0xffff);
    // The last column repeats its source.
    try t.expectEqual(@as(u32, unspread(src[79][5])), dst[159][5] & 0xffff);
}
