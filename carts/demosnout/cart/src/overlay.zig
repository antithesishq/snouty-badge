//! Timing overlay (from snouty-reflections), compiled in with
//! -Ddebug_overlay=true and toggled with B: render microseconds, the part
//! index and the frame within the part, e.g. " 8123us P 1 F  42".
//! Integers are formatted by hand to keep std.fmt out of the cart.
const cart = @import("cart-api");
const text = @import("text.zig");

pub fn draw(render_us: u32, part: u8, frame: u32) void {
    var buf: [18]u8 = "      us P   F    ".*;
    text.put_uint(buf[0..6], @min(render_us, 999_999));
    text.put_uint(buf[10..12], part);
    text.put_uint(buf[14..18], @min(frame, 9999));
    text.draw(&buf, 0, 0, .{ .r = 31, .g = 63, .b = 31 }, .{ .r = 0, .g = 0, .b = 0 });
}
