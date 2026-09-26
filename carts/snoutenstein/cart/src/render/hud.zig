//! Status bar (y 104..127), title card, overlays. M0: title + debug bar.
const cart = @import("cart-api");
const state = @import("../state.zig");
const fixed = @import("../fixed.zig");

pub const bar_y: i32 = 104;
pub const anti_black = cart.DisplayColor.rgb(0x16031B);
pub const anti_white = cart.DisplayColor.rgb(0xFCFBF9);
pub const coral = cart.DisplayColor.rgb(0xF18271);
pub const iris = cart.DisplayColor.rgb(0x8E42DE);

pub fn draw_title(tick: u32) void {
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = 128, .fill_color = anti_black });
    cart.text(.{ .str = "SNOUTENSTEIN 3D", .x = 20, .y = 40, .text_color = coral });
    cart.text(.{ .str = "powered by", .x = 40, .y = 60, .text_color = iris });
    cart.text(.{ .str = "deterministic replay", .x = 0, .y = 70, .text_color = iris });
    if ((tick / 30) % 2 == 0) {
        cart.text(.{ .str = "PRESS A", .x = 52, .y = 100, .text_color = anti_white });
    }
}

/// Debug status bar for M1: position, angle and render microseconds.
pub fn draw_debug_bar(s: *const state.GameState, render_us: u32) void {
    cart.rect(.{ .x = 0, .y = bar_y, .width = 160, .height = 24, .fill_color = anti_black });
    var buf: [40]u8 = undefined;
    const px = fixed.to_int(s.player.x);
    const py = fixed.to_int(s.player.y);
    const deg: u32 = @as(u32, s.player.angle) * 360 / 65536;
    const line1 = fmt(&buf, "X{d:>2} Y{d:>2} A{d:>3}", .{ px, py, deg });
    cart.text(.{ .str = line1, .x = 2, .y = bar_y + 4, .text_color = anti_white });
    var buf2: [40]u8 = undefined;
    const line2 = fmt(&buf2, "RENDER {d:>5}us", .{render_us});
    cart.text(.{ .str = line2, .x = 2, .y = bar_y + 14, .text_color = coral });
}

fn fmt(buf: []u8, comptime f: []const u8, args: anytype) []const u8 {
    const std = @import("std");
    return std.fmt.bufPrint(buf, f, args) catch "?";
}
