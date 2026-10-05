//! Shared drawing helpers and colours for the Snouty Sense pages.
const std = @import("std");
const cart = @import("cart-api");

pub const bg = cart.DisplayColor.rgb(0x101820);
pub const panel = cart.DisplayColor.rgb(0x202830);
pub const fg = cart.DisplayColor.rgb(0xE0E8F0);
pub const dim = cart.DisplayColor.rgb(0x60707C);
pub const good = cart.DisplayColor.rgb(0x40E070);
pub const warn = cart.DisplayColor.rgb(0xF0C040);
pub const bad = cart.DisplayColor.rgb(0xF05050);
pub const accent = cart.DisplayColor.rgb(0x40C0F0);
pub const black = cart.DisplayColor.rgb(0x000000);
pub const white = cart.DisplayColor.rgb(0xFFFFFF);

pub fn clear() void {
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = 128, .fill_color = bg });
}

pub fn say(col: i32, row: i32, str: []const u8, color: cart.DisplayColor) void {
    cart.text(.{ .str = str, .x = col * 8, .y = row * 8, .text_color = color });
}

pub fn say_px(x: i32, y: i32, str: []const u8, color: cart.DisplayColor) void {
    cart.text(.{ .str = str, .x = x, .y = y, .text_color = color });
}

pub fn trim(s: []const u8, n: usize) []const u8 {
    return s[0..@min(s.len, n)];
}

pub fn fmt(buf: []u8, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, f, args) catch "?";
}

/// False colour by distance: red (near) through orange, yellow, green,
/// blue to purple (2 m and beyond).
pub fn heat(mm: u16) cart.DisplayColor {
    return cart.DisplayColor.rgb(heat_rgb(mm));
}

pub fn heat_rgb(mm: u16) u24 {
    const stops = [_]struct { mm: u32, rgb: u24 }{
        .{ .mm = 0, .rgb = 0xFF2828 },
        .{ .mm = 300, .rgb = 0xFF8C00 },
        .{ .mm = 600, .rgb = 0xFFE600 },
        .{ .mm = 900, .rgb = 0x3CC85A },
        .{ .mm = 1300, .rgb = 0x28A0E6 },
        .{ .mm = 2000, .rgb = 0x5A3CC8 },
    };
    const d: u32 = mm;
    var i: usize = 0;
    while (i + 2 < stops.len and d >= stops[i + 1].mm) i += 1;
    const a = stops[i];
    const b = stops[i + 1];
    const t: u32 = @min(256, (@min(d, b.mm) -| a.mm) * 256 / (b.mm - a.mm));
    return lerp_rgb(a.rgb, b.rgb, t);
}

pub fn lerp_rgb(a: u24, b: u24, t: u32) u24 {
    var out: u24 = 0;
    inline for (.{ 16, 8, 0 }) |s| {
        const ca: u32 = (a >> s) & 0xFF;
        const cb: u32 = (b >> s) & 0xFF;
        const c = (ca * (256 - t) + cb * t) / 256;
        out |= @as(u24, @intCast(c)) << s;
    }
    return out;
}

pub fn ink_on(c: cart.DisplayColor) cart.DisplayColor {
    const lum = @as(u32, c.r) * 2 * 3 + @as(u32, c.g) * 6 + @as(u32, c.b) * 2;
    return if (lum > 330) black else white;
}

/// log2 in 1/16 steps (0 for 0).
pub fn log2_fix(v: u32) u32 {
    if (v == 0) return 0;
    const e: u32 = 31 - @clz(v);
    const frac: u32 = if (e >= 4) (v >> @intCast(e - 4)) & 0xF else (v << @intCast(4 - e)) & 0xF;
    return e * 16 + frac + 1;
}

/// A horizontal progress bar, `permille` of `w` filled.
pub fn bar(x: i32, y: i32, w: u32, h: u32, permille: u32, color: cart.DisplayColor) void {
    cart.rect(.{ .x = x, .y = y, .width = w, .height = h, .stroke_color = dim });
    const fill = @min(permille, 1000) * (w - 2) / 1000;
    if (fill > 0) cart.rect(.{ .x = x + 1, .y = y + 1, .width = fill, .height = h - 2, .fill_color = color });
}
