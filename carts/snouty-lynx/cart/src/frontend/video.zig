//! Lynx frame -> badge framebuffer (SPEC.md section 6). The 160x102
//! picture goes 1:1 to badge rows 0..101 (`top`); rows 102..127 are the
//! status strip main.zig draws. Each Lynx byte is two pixels, the left one
//! in the high nibble; the nibble is a palette index into a 16-entry
//! `Pixel` cache of the 12-bit palette (GREEN, BLUERED), rebuilt when the
//! palette registers change.
//!
//! A 256-entry byte -> pixel pair table (SPEC.md 6; 1 KB) gives both pixels
//! of a byte in one load. The framebuffer is column-major
//! (`[160][128]Pixel`): two Lynx rows at a time make each column's pair of
//! pixels one word store.
const cart = @import("cart-api");
const core = @import("core");

const fb_h = cart.screen_height;
const fb_w = cart.screen_width;
const lynx_w = core.screen_w;
const lynx_h = core.screen_h;

/// First badge row of the picture (SPEC.md 6: 0, or 13 when centred).
pub const top = 0;
/// First row of the status strip, and its height (26 rows).
pub const strip_y = top + lynx_h;
pub const strip_h = fb_h - strip_y;

comptime {
    if (lynx_w != fb_w) @compileError("horizontal mapping is 1:1");
    if (strip_y + strip_h != fb_h) @compileError("strip below the picture");
}

var green_seen: [16]u8 = @splat(0xFF);
var bluered_seen: [16]u8 = @splat(0xFF);
var pixels: [16]cart.Pixel = @splat(.{ .bits = 0 });
/// Palette cache rebuilds since boot (a `debug_*` export).
pub var palette_rebuilds: u32 = 0;

/// Lynx 12-bit colour (green nibble, blue/red byte) to a DisplayColor.
pub fn lynx_color(green: u8, bluered: u8) cart.DisplayColor {
    const r: u32 = bluered & 0xF;
    const g: u32 = green & 0xF;
    const b: u32 = bluered >> 4;
    return .rgb((r * 17) << 16 | (g * 17) << 8 | b * 17);
}

fn palette_changed(f: core.Frame) bool {
    var diff: u8 = 0;
    for (f.green, f.bluered, &green_seen, &bluered_seen) |g, br, gs, bs| diff |= (g ^ gs) | (br ^ bs);
    return diff != 0;
}

/// Lynx byte -> its two pixels (left in the low half), rebuilt with the
/// palette cache (SPEC.md 6's byte -> pixel pair table).
var pairs: [256]u32 = @splat(0);

/// Draw one Lynx frame into rows `top`..`top + 101`. The framebuffer is
/// column-major, so two Lynx rows are converted together: the pixels of
/// rows y and y + 1 in one column are adjacent, one 32-bit store.
pub fn show(f: core.Frame) void {
    if (palette_changed(f)) {
        for (&pixels, f.green, f.bluered) |*px, g, br| px.* = .from_color(lynx_color(g, br));
        for (&pairs, 0..) |*p, b| p.* = @as(u32, pixels[b >> 4].bits) | @as(u32, pixels[b & 0xF].bits) << 16;
        green_seen = f.green.*;
        bluered_seen = f.bluered.*;
        palette_rebuilds +%= 1;
    }
    comptime {
        if (top % 2 != 0 or lynx_h % 2 != 0 or fb_h % 2 != 0) @compileError("row pairs");
    }
    const fb: [*]u32 = @ptrCast(@alignCast(cart.framebuffer));
    var y: usize = 0;
    while (y < lynx_h) : (y += 2) {
        const src0 = f.pixels[y * (lynx_w / 2) ..][0 .. lynx_w / 2];
        const src1 = f.pixels[(y + 1) * (lynx_w / 2) ..][0 .. lynx_w / 2];
        var dst = fb + (top + y) / 2;
        for (src0, src1) |b0, b1| {
            const p0 = pairs[b0];
            const p1 = pairs[b1];
            dst[0] = (p0 & 0xFFFF) | (p1 << 16);
            dst[fb_h / 2] = (p0 >> 16) | (p1 & 0xFFFF_0000);
            dst += fb_h;
        }
    }
}

/// Fill the whole screen with one colour.
pub fn blank(c: cart.DisplayColor) void {
    const px: u16 = cart.Pixel.from_color(c).bits;
    const fb: *[fb_w * fb_h / 2]u32 = @ptrCast(cart.framebuffer);
    @memset(fb, @as(u32, px) << 16 | px);
}

/// Fill rows y0..y0+h with one colour.
pub fn fill_rows(y0: usize, h: usize, c: cart.DisplayColor) void {
    const px = cart.Pixel.from_color(c);
    for (cart.framebuffer) |*column| @memset(column[y0..][0..h], px);
}
