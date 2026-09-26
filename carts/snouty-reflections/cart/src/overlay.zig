//! Debug overlay drawn over the finished frame when built with
//! -Ddebug_overlay=true: render microseconds, the fps that render time
//! would allow (1e6 / render_us, capped at 999), and the dither mode
//! letter (B = bayer_temporal, N = none), e.g. "12345us  81fps B".
//! Text uses the OS 8x8 font with a dark background so it reads over any
//! scene. Integers are formatted by hand to keep std.fmt out of the cart.
const cart = @import("cart-api");
const dither = @import("dither.zig");

const fg: cart.DisplayColor = .{ .r = 31, .g = 63, .b = 31 };
const bg: cart.DisplayColor = .{ .r = 0, .g = 0, .b = 0 };

pub fn draw(render_us: u32, frame: u32) void {
    _ = frame;
    // "uuuuuus fffps M": 6-digit microseconds, 3-digit fps, mode letter.
    var buf: [17]u8 = "      us    fps  ".*;
    put_uint(buf[0..6], @min(render_us, 999_999));
    const fps: u32 = if (render_us == 0) 999 else @min(1_000_000 / render_us, 999);
    put_uint(buf[9..12], fps);
    buf[16] = if (dither.mode == .none) 'N' else 'B';
    cart.text(.{
        .str = &buf,
        .x = 0,
        .y = 0,
        .text_color = fg,
        .background_color = bg,
    });
}

/// Right-aligned decimal into `out`, space-padded. `v` must fit.
fn put_uint(out: []u8, value: u32) void {
    var v = value;
    var i = out.len;
    while (i > 0) {
        i -= 1;
        out[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
        if (v == 0) break;
    }
}
