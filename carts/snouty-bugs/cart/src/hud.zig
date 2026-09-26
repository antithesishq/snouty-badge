//! HUD row, title card and pause overlay.
const cart = @import("cart-api");
const gfx = @import("gfx");
const draw = @import("draw.zig");
const player = @import("player.zig");
const world = @import("world.zig");

const max_life_icons = 3;

pub fn draw_hud() void {
    cart.rect(.{ .x = 0, .y = 0, .width = cart.screen_width, .height = draw.hud_height, .fill_color = draw.anti_black });
    var buf: [6]u8 = undefined;
    var v = world.w.player.score;
    var i: usize = buf.len;
    while (i > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    draw.text(&buf, 0, 0, draw.anti_white);
    const n = @min(player.lives, max_life_icons);
    for (0..n) |k| {
        const x: i32 = @as(i32, cart.screen_width) - 8 * @as(i32, @intCast(k + 1));
        draw.draw_sprite(gfx.hud, 8, 8, 0, x, 0, .{});
    }
}

/// M0 title card over the dimmed, scrolling background.
pub fn draw_title(tick: u32) void {
    // The background layers start at y 8; clear the HUD row too, since
    // no_copy_full_frame leaves a stale frame there otherwise.
    cart.rect(.{ .x = 0, .y = 0, .width = cart.screen_width, .height = draw.hud_height, .fill_color = draw.anti_black });
    draw.darken_checker();
    draw.centered_text("SNOUTY", 40, draw.anti_white);
    draw.centered_text("vs. THE BUGS", 52, draw.coral);
    draw.draw_sprite(gfx.hud, 8, 8, 0, 76, 72, .{});
    if ((tick / 30) % 2 == 0) draw.centered_text("PRESS A", 96, draw.anti_white);
    draw.centered_text("Antithesis", 116, draw.coral);
    draw.draw_sprite(gfx.iris_16, 16, 16, 0, 20, 112, .{});
    draw.draw_sprite(gfx.iris_16, 16, 16, 0, 124, 112, .{});
}

pub fn draw_pause() void {
    draw.darken_checker();
    draw.centered_text("PAUSED", 60, draw.anti_white);
}
