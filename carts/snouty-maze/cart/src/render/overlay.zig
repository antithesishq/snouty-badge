//! Text overlays: debug timing readout (M1) and the name strip (M2).
const std = @import("std");
const cart = @import("cart-api");
const camera = @import("../camera.zig");

var buf: [32]u8 = undefined;

/// Top-left: render microseconds and fps on line 1, the camera cell and
/// compass heading on line 2, so a photo of the badge says where it was.
pub fn draw_debug(render_us: u32, fps_x10: u32) void {
    const line1 = std.fmt.bufPrint(buf[0..16], "{d}us {d}.{d}", .{ render_us, fps_x10 / 10, fps_x10 % 10 }) catch return;
    const c = &camera.cam;
    const cx: i32 = @intFromFloat(std.math.clamp(@floor(c.pos[0]), -99.0, 999.0));
    const cz: i32 = @intFromFloat(std.math.clamp(@floor(c.pos[2]), -99.0, 999.0));
    const letter = "NESW"[@backingInt(camera.heading(c.yaw))];
    const line2 = std.fmt.bufPrint(buf[16..], "{d},{d} {c}", .{ cx, cz, letter }) catch return;
    const width = @max(line1.len, line2.len) * 8 + 2;
    cart.rect(.{ .x = 0, .y = 0, .width = @intCast(width), .height = 19, .fill_color = .rgb(0x000000) });
    cart.text(.{ .str = line1, .x = 1, .y = 1, .text_color = .rgb(0xffffff) });
    cart.text(.{ .str = line2, .x = 1, .y = 10, .text_color = .rgb(0xffffff) });
}
