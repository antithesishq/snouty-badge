//! HUD row, stage text (warning, boss HP bar, clear), title card and
//! pause overlay.
const cart = @import("cart-api");
const gfx = @import("gfx");
const draw = @import("draw.zig");
const enemies = @import("enemies.zig");
const world = @import("world.zig");

const max_rewind_icons = 5;
const bomb_slots = 3;
/// Top-left x of the first bomb slot (slots centered at x 68, 76, 84).
const bomb_slot_x: i32 = 64;

/// HUD row: score, bomb slots (filled from the left) and the rewind stock.
/// `rewinds` and `bombs` are main.zig's meta-state.
pub fn draw_hud(rewinds: u32, bombs: u32) void {
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
    for (0..bomb_slots) |k| {
        const x = bomb_slot_x + 8 * @as(i32, @intCast(k));
        draw.draw_sprite(gfx.hud, 8, 8, if (k < bombs) 1 else 2, x, 0, .{});
    }
    const n = @min(rewinds, max_rewind_icons);
    for (0..n) |k| {
        const x: i32 = @as(i32, cart.screen_width) - 8 * @as(i32, @intCast(k + 1));
        draw.draw_sprite(gfx.hud, 8, 8, 0, x, 0, .{});
    }
}

/// Boss HP bar: 2 px at y 8..9, x 8..151.
const bar_x: i32 = 8;
const bar_y: i32 = 8;
const bar_w: u32 = 144;
const bar_h: u32 = 2;
/// Stage text line (the same y as the bug message bar, SPEC.md 10).
const stage_text_y: i32 = 56;
/// WARNING is shown `warning_on` ticks of every `warning_period`.
const warning_period: u32 = 40;
const warning_on: u32 = 20;
/// After a clear: "+500" for this many ticks, then "STAGE n" as long.
const clear_text_ticks: u32 = 60;

/// Over the sprites, under the pause overlay: the flashing WARNING, the
/// boss HP bar, and "+500" then "STAGE n" after a clear.
pub fn draw_stage_text() void {
    const st = &world.w.waves;
    if (st.phase == .warning and st.t % warning_period < warning_on) {
        draw.centered_text("WARNING", stage_text_y, draw.coral);
    }
    if (enemies.boss()) |b| {
        // The bar goes when the death sequence starts.
        if (b.phase != .dying and b.hp > 0) {
            cart.rect(.{ .x = bar_x, .y = bar_y, .width = bar_w, .height = bar_h, .fill_color = draw.anti_black });
            const max = enemies.boss_max_hp();
            const fill: u32 = @min(bar_w, bar_w * @as(u32, b.hp) / @max(max, 1));
            if (fill > 0) {
                cart.rect(.{ .x = bar_x, .y = bar_y, .width = fill, .height = bar_h, .fill_color = draw.coral });
            }
        }
    }
    if (st.clear_tick != 0) {
        const since = world.w.game_tick -% st.clear_tick;
        if (since < clear_text_ticks) {
            draw.centered_text("+500", stage_text_y, draw.anti_white);
        } else if (since < 2 * clear_text_ticks) {
            var buf: [9]u8 = undefined;
            draw.centered_text(stage_label(&buf, @as(u32, st.loop) + 1), stage_text_y, draw.anti_white);
        }
    }
}

/// "STAGE n" into `buf` (n up to 3 digits).
fn stage_label(buf: *[9]u8, n: u32) []const u8 {
    const prefix = "STAGE ";
    @memcpy(buf[0..prefix.len], prefix);
    var digits: [3]u8 = undefined;
    var v = @min(n, 999);
    var len: usize = 0;
    while (true) {
        digits[len] = '0' + @as(u8, @intCast(v % 10));
        len += 1;
        v /= 10;
        if (v == 0) break;
    }
    for (0..len) |k| buf[prefix.len + k] = digits[len - 1 - k];
    return buf[0 .. prefix.len + len];
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
