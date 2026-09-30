//! Shared framebuffer effects: the 2x upscale of an 80x64 index field
//! through a palette (the half-resolution escape hatch of SPEC.md section
//! 2), the fade the timeline applies between parts, clears, lines, a
//! vertical gradient and the 8x8 font at 2x.
//!
//! The framebuffer is column-major, `fb[x][y]`, x in 0..159, y in 0..127,
//! with y the fast axis in memory, so every loop here goes down a column.
//! Each column is 256 bytes and the framebuffer is 0x2000-aligned, so a
//! column can be written as 64 u32 words (two pixels each, the lower
//! address in the low half on both thumb and wasm, which are little-endian).
const std = @import("std");
const cart = @import("cart-api");
const palette = @import("palette.zig");

pub const width = 160;
pub const height = 128;

/// Half-resolution index field, column-major like the framebuffer:
/// `indices[x][y]`, x in 0..79, y in 0..63.
pub const Indices = [80][64]u8;

const Column = [height]cart.Pixel;
const Words = [height / 2]u32;

inline fn words(col: *align(4) Column) *Words {
    return @ptrCast(col);
}

/// Each index becomes a 2x2 block of `pal[index]`. Writes every pixel.
pub fn upscale2x(src: *const Indices, pal: *const palette.Palette, fb: cart.FramebufferPtr) void {
    for (src, 0..) |*col, sx| {
        const dst: *align(4) Column = @alignCast(&fb[sx * 2]);
        const w = words(dst);
        for (col, 0..) |idx, sy| {
            const p: u32 = @as(u16, @bitCast(pal[idx]));
            w[sy] = p | (p << 16);
        }
        fb[sx * 2 + 1] = dst.*;
    }
}

/// Scales every pixel's RGB by level / 16: 16 leaves the frame alone, 0
/// makes it black. Works on the RGB565 value (byte-swapped back and forth
/// on wasm), two channels' worth of headroom per field via the classic
/// 0x07E0F81F spread, so it is one multiply per pixel.
pub fn fade(fb: cart.FramebufferPtr, level: u8) void {
    if (level >= 16) return;
    if (level == 0) {
        clear(fb, .from_color(.{ .r = 0, .g = 0, .b = 0 }));
        return;
    }
    const l: u32 = level;
    for (fb) |*col| {
        for (col) |*px| {
            var c: u32 = @as(u16, @bitCast(px.*));
            if (cart.is_wasm) c = @byteSwap(@as(u16, @intCast(c)));
            var x = (c | (c << 16)) & 0x07E0F81F;
            x = ((x * l) >> 4) & 0x07E0F81F;
            var out: u16 = @truncate(x | (x >> 16));
            if (cart.is_wasm) out = @byteSwap(out);
            px.* = @bitCast(out);
        }
    }
}

/// 8x8 Bayer order, 0..63: the order in which 4x4-pixel blocks of an 8x8
/// block tile go black in `dissolve`.
const bayer8 = [8][8]u8{
    .{ 0, 32, 8, 40, 2, 34, 10, 42 },
    .{ 48, 16, 56, 24, 50, 18, 58, 26 },
    .{ 12, 44, 4, 36, 14, 46, 6, 38 },
    .{ 60, 28, 52, 20, 62, 30, 54, 22 },
    .{ 3, 35, 11, 43, 1, 33, 9, 41 },
    .{ 51, 19, 59, 27, 49, 17, 57, 25 },
    .{ 15, 47, 7, 39, 13, 45, 5, 37 },
    .{ 63, 31, 55, 23, 61, 29, 53, 21 },
};

/// Block dissolve to black: the frame is cut into 4x4-pixel blocks and a
/// block stays visible only while its 8x8 Bayer rank is below `level`
/// (64 leaves the frame alone, 0 makes it black), so blocks drop out in an
/// even ordered-dither pattern. Cheaper than `fade`: black blocks are
/// plain stores, visible ones untouched.
pub fn dissolve(fb: cart.FramebufferPtr, level: u8) void {
    if (level >= 64) return;
    const black: cart.Pixel = .from_color(.{ .r = 0, .g = 0, .b = 0 });
    for (fb, 0..) |*col, x| {
        const row = &bayer8[(x >> 2) & 7];
        var by: usize = 0;
        while (by < height / 4) : (by += 1) {
            if (row[by & 7] >= level) @memset(col[by * 4 ..][0..4], black);
        }
    }
}

/// Fills the whole frame with one pixel.
pub fn clear(fb: cart.FramebufferPtr, px: cart.Pixel) void {
    for (fb) |*col| @memset(col, px);
}

/// One full-width row of one pixel.
pub fn hline(fb: cart.FramebufferPtr, y: u8, px: cart.Pixel) void {
    if (y >= height) return;
    for (fb) |*col| col[y] = px;
}

/// Fills every column with the same vertical gradient from `top` to
/// `bottom` (0x00RRGGBB). Writes every pixel.
pub fn vgradient(fb: cart.FramebufferPtr, top: u32, bottom: u32) void {
    var column: Column = undefined;
    for (&column, 0..) |*px, y| {
        px.* = palette.pixel(palette.mix_rgb(top, bottom, @intCast((y * 256) / (height - 1))));
    }
    for (fb) |*col| col.* = column;
}

/// The OS 8x8 font at 2x (16 px per character), drawn with `cart.text`'s
/// own `scale` option into `cart.framebuffer`, the frame being rendered
/// (main passes that same buffer to the parts as `fb`). Clipped to the
/// screen; transparent background. Deterministic on wasm and thumb (the
/// same Zig code draws the same font bitmap on both).
pub fn text2x(str: []const u8, x: i32, y: i32, color: cart.DisplayColor) void {
    cart.text(.{ .str = str, .x = x, .y = y, .scale = 2, .text_color = color });
}

/// Width in pixels of `str` in the 8x8 font at `scale` (single line).
pub fn text_width(str: []const u8, scale: u32) i32 {
    return @intCast(str.len * 8 * scale);
}

test "fade at 16, 8 and 0" {
    var fb: cart.Framebuffer align(cart.framebuffer_alignment) = undefined;
    const white: cart.Pixel = .from_color(.{ .r = 31, .g = 63, .b = 31 });
    const mixed: cart.Pixel = .from_color(.{ .r = 20, .g = 40, .b = 10 });
    clear(&fb, white);
    fb[3][5] = mixed;
    fade(&fb, 16);
    try std.testing.expectEqual(white, fb[0][0]);
    try std.testing.expectEqual(mixed, fb[3][5]);
    fade(&fb, 8);
    try std.testing.expectEqual(cart.DisplayColor{ .r = 15, .g = 31, .b = 15 }, fb[0][0].to_color());
    try std.testing.expectEqual(cart.DisplayColor{ .r = 10, .g = 20, .b = 5 }, fb[3][5].to_color());
    fade(&fb, 0);
    for (fb) |col| for (col) |px| try std.testing.expectEqual(cart.DisplayColor{ .r = 0, .g = 0, .b = 0 }, px.to_color());
}

test "dissolve at 64, 32 and 0" {
    var fb: cart.Framebuffer align(cart.framebuffer_alignment) = undefined;
    const white: cart.Pixel = .from_color(.{ .r = 31, .g = 63, .b = 31 });
    const black: cart.Pixel = .from_color(.{ .r = 0, .g = 0, .b = 0 });
    clear(&fb, white);
    dissolve(&fb, 64);
    for (fb) |col| for (col) |px| try std.testing.expectEqual(white, px);
    dissolve(&fb, 32);
    var lit: u32 = 0;
    for (fb) |col| for (col) |px| {
        if (px == white) lit += 1;
    };
    try std.testing.expectEqual(@as(u32, width * height / 2), lit);
    dissolve(&fb, 0);
    for (fb) |col| for (col) |px| try std.testing.expectEqual(black, px);
    // Every rank appears once in the order.
    var seen: [64]bool = @splat(false);
    for (bayer8) |r| for (r) |v| {
        seen[v] = true;
    };
    for (seen) |s| try std.testing.expect(s);
}

test "upscale2x doubles every index" {
    var fb: cart.Framebuffer align(cart.framebuffer_alignment) = undefined;
    var src: Indices = undefined;
    for (&src, 0..) |*col, x| for (col, 0..) |*v, y| {
        v.* = @truncate(x * 3 + y);
    };
    var pal: palette.Palette = undefined;
    for (&pal, 0..) |*e, i| e.* = .from_color(.{ .r = @truncate(i), .g = @truncate(i >> 2), .b = 7 });
    upscale2x(&src, &pal, &fb);
    for (0..width) |x| for (0..height) |y| {
        try std.testing.expectEqual(pal[src[x / 2][y / 2]], fb[x][y]);
    };
}
