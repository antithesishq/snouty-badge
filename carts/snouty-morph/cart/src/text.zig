//! The OS 8x8 font (copied from demosnout) for the HUD and the scroller: thin
//! wrappers over `cart.text` (which draws into `cart.framebuffer`, the frame
//! being rendered), plus hand-rolled integer formatting so `std.fmt` stays
//! out of the cart.
const cart = @import("cart-api");

pub const glyph = 8;

/// `str` at (x, y) in `fg`, over a `bg` box per character when given.
pub fn draw(str: []const u8, x: i32, y: i32, fg: cart.DisplayColor, bg: ?cart.DisplayColor) void {
    cart.text(.{ .str = str, .x = x, .y = y, .text_color = fg, .background_color = bg });
}

/// `str` with a one-pixel dark drop shadow, readable over any effect.
pub fn shadowed(str: []const u8, x: i32, y: i32, fg: cart.DisplayColor, scale: u32) void {
    const s: i32 = @intCast(scale);
    cart.text(.{ .str = str, .x = x + s, .y = y + s, .scale = scale, .text_color = .{ .r = 0, .g = 0, .b = 0 } });
    cart.text(.{ .str = str, .x = x, .y = y, .scale = scale, .text_color = fg });
}

/// `str` at a 7 px character pitch instead of 8 (the font's glyphs leave
/// their eighth column blank, so most letters still do not touch): 22
/// characters fit the 160 px screen. One `cart.text` call per character.
pub fn condensed(str: []const u8, x: i32, y: i32, fg: cart.DisplayColor) void {
    for (str, 0..) |c, i| {
        if (c == ' ') continue;
        cart.text(.{ .str = &.{c}, .x = x + @as(i32, @intCast(i)) * 7, .y = y, .text_color = fg });
    }
}

/// x that centres `str` (one line, 8x8 font at `scale`) on the 160 px screen.
pub fn centre_x(str: []const u8, scale: u32) i32 {
    return @divTrunc(160 - @as(i32, @intCast(str.len * 8 * scale)), 2);
}

/// Right-aligned decimal into `out`, space-padded; digits that do not fit
/// are dropped from the left.
pub fn put_uint(out: []u8, value: u32) void {
    @memset(out, ' ');
    var v = value;
    var i = out.len;
    while (i > 0) {
        i -= 1;
        out[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
        if (v == 0) break;
    }
}

test "put_uint" {
    const std = @import("std");
    var buf: [5]u8 = undefined;
    put_uint(&buf, 42);
    try std.testing.expectEqualStrings("   42", &buf);
    put_uint(&buf, 0);
    try std.testing.expectEqualStrings("    0", &buf);
    put_uint(&buf, 1234567);
    try std.testing.expectEqualStrings("34567", &buf);
    try std.testing.expectEqual(@as(i32, 4), centre_x("ANTITHESIS PRESENTS", 1));
}
