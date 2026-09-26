//! Text overlays: debug timing readout (M1) and the name strip (M2).
const cart = @import("cart-api");

var buf: [32]u8 = undefined;

/// Top-left render time in microseconds and fps x10.
pub fn draw_debug(render_us: u32, fps_x10: u32) void {
    const s = std.fmt.bufPrint(&buf, "{d}us {d}.{d}", .{ render_us, fps_x10 / 10, fps_x10 % 10 }) catch return;
    cart.rect(.{ .x = 0, .y = 0, .width = @intCast(s.len * 8 + 2), .height = 10, .fill_color = .rgb(0x000000) });
    cart.text(.{ .str = s, .x = 1, .y = 1, .text_color = .rgb(0xffffff) });
}

const std = @import("std");
