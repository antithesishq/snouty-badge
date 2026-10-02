//! The toast: one line of the OS 8x8 font in the top-left corner, with a
//! one-pixel drop shadow so it reads over the starfield, sliding in from
//! the left and out again.
const cart = @import("cart-api");

/// `str` with `left` frames of the toast to go (it counts down to 0):
/// slides in over the first 8 frames and out over the last 8.
pub fn toast(str: []const u8, left: u32) void {
    const total = 90;
    const shown = total - @min(total, left);
    const w: i32 = @intCast(str.len * 8 + 6);
    var x: i32 = 6;
    if (shown < 8) x -= @divTrunc(w * @as(i32, @intCast(8 - shown)), 8);
    if (left < 8) x -= @divTrunc(w * @as(i32, @intCast(8 - left)), 8);
    // Row 8: inside the Tufty's crop (rows 4..123) with a margin.
    cart.text(.{ .str = str, .x = x + 1, .y = 9, .text_color = .rgb(0x000000) });
    cart.text(.{ .str = str, .x = x, .y = 8, .text_color = .rgb(0xfff4c0) });
}
