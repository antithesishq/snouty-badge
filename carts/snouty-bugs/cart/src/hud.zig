//! HUD row, stage text (warning, boss HP bar, clear), title card and
//! pause overlay.
const cart = @import("cart-api");
const gfx = @import("gfx");
const draw = @import("draw.zig");
const enemies = @import("enemies.zig");
const world = @import("world.zig");
const rank = @import("rank.zig");
const waves = @import("waves.zig");

const max_rewind_icons = 5;
/// `hud.png` cell: 12x8 since 2026-09-29 (the 8x8 head read as a rat).
/// Five icons fill x 100..159, right of the fuel bar.
const icon_w: i32 = 12;
/// Status slot x 48..63: the weapon as letter + level (`F3`); rewind.zig
/// patches it and draws `<<` there during a rewind.
pub const status_x: i32 = 48;
pub const status_w: u32 = 16;
/// Fuel bar: 1 px Anti-White frame x 68..99, y 1..6; fill inside it,
/// up to 30x4 at x 69..98, y 2..5.
const fuel_x: i32 = 68;
const fuel_y: i32 = 1;
const fuel_w: u32 = 32;
const fuel_h: u32 = 6;
const fuel_fill_w: u32 = fuel_w - 2;
const fuel_fill_h: u32 = fuel_h - 2;
/// `HARD` in hardcore, in place of the rewind icons.
const hard_x: i32 = 128;
/// Title card ship: the 32x24 level cell centred at y 62..85 (86 when it
/// bobs), the thruster at player.zig's (-6, 8) offset.
const title_ship_x: i32 = 64;
const title_ship_y: i32 = 62;

/// HUD row: score (x 0..47), the status slot (x 48..63, the weapon), the
/// fuel bar (x 68..99) and, on the right, the rewind stock as up to 5
/// right-aligned 12x8 Snouty heads or `HARD` in hardcore. All arguments are
/// main.zig's meta-state; `rewinds` is ignored when `hardcore`.
pub fn draw_hud(rewinds: u32, fuel: u32, fuel_max: u32, fatal_floor: u32, hardcore: bool) void {
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
    draw_weapon();
    draw_fuel(fuel, fuel_max, fatal_floor, hardcore);
    if (hardcore) {
        draw.text("HARD", hard_x, 0, draw.coral);
        return;
    }
    const n = @min(rewinds, max_rewind_icons);
    for (0..n) |k| {
        const x: i32 = @as(i32, cart.screen_width) - icon_w * @as(i32, @intCast(k + 1));
        draw.draw_sprite(gfx.hud, icon_w, 8, 0, x, 0, .{});
    }
}

/// `F3`, `A1`, `B5`: the weapon letter and level in the status slot, in
/// Coral so it reads apart from the score digits ending at x 47.
fn draw_weapon() void {
    const p = &world.w.player;
    const letters = "FAB";
    const slot = [2]u8{ letters[@backingInt(p.weapon)], '0' + @as(u8, @min(p.level, 9)) };
    draw.text(&slot, status_x, 0, draw.coral);
}

/// The fuel bar: frame, then a fill of `fuel * 30 / fuel_max` px (rounded
/// down, at least 1 while there is any fuel), red in hardcore below the
/// fatal floor.
fn draw_fuel(fuel: u32, fuel_max: u32, fatal_floor: u32, hardcore: bool) void {
    cart.rect(.{ .x = fuel_x, .y = fuel_y, .width = fuel_w, .height = fuel_h, .stroke_color = draw.anti_white });
    if (fuel == 0) return;
    const f = @min(fuel, fuel_max);
    const w: u32 = @max(1, f * fuel_fill_w / @max(fuel_max, 1));
    const color = if (hardcore and fuel < fatal_floor) draw.red else draw.coral;
    cart.rect(.{ .x = fuel_x + 1, .y = fuel_y + 1, .width = w, .height = fuel_fill_h, .fill_color = color });
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
/// After a clear: "+500" (or "ESCAPED") for this many ticks.
const clear_text_ticks: u32 = 60;
/// The stage pop: `LOOP n` (from the second loop), `STAGE n`, the name.
const pop_loop_y: i32 = 40;
const pop_stage_y: i32 = 52;
const pop_name_y: i32 = 62;

/// Over the sprites, under the pause overlay: the `STAGE n` pop at the
/// start of a stage, the flashing WARNING, the boss HP bar, and "+500"
/// (or "ESCAPED") after the boss.
pub fn draw_stage_text() void {
    const st = &world.w.waves;
    if (st.phase == .waves and st.t < waves.stage_pop) {
        var buf: [9]u8 = undefined;
        if (st.loop > 0 and st.stage == 0) {
            draw.centered_text(number_label(&buf, "LOOP ", @as(u32, st.loop) + 1), pop_loop_y, draw.coral);
        }
        draw.centered_text(number_label(&buf, "STAGE ", @as(u32, st.stage) + 1), pop_stage_y, draw.anti_white);
        draw.centered_text(waves.stage_names[@min(st.stage, waves.stage_count - 1)], pop_name_y, draw.coral);
    }
    if (st.phase == .warning and st.t % warning_period < warning_on) {
        draw.centered_text("WARNING", stage_text_y, draw.coral);
    }
    if (enemies.boss()) |b| {
        // The bar goes when the death sequence starts.
        if (b.phase != .dying and b.hp > 0) {
            cart.rect(.{ .x = bar_x, .y = bar_y, .width = bar_w, .height = bar_h, .fill_color = draw.anti_black });
            const max = enemies.boss_max_hp_of(b.*);
            const fill: u32 = @min(bar_w, bar_w * @as(u32, b.hp) / @max(max, 1));
            if (fill > 0) {
                cart.rect(.{ .x = bar_x, .y = bar_y, .width = fill, .height = bar_h, .fill_color = draw.coral });
            }
        }
    }
    if (st.phase == .cleared and world.w.game_tick -% st.clear_tick < clear_text_ticks) {
        draw.centered_text(if (st.escaped) "ESCAPED" else "+500", stage_text_y, draw.anti_white);
    }
}

/// `prefix` and `n` (up to 3 digits) into `buf`.
fn number_label(buf: *[9]u8, comptime prefix: []const u8, n: u32) []const u8 {
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

/// Title card over the dimmed, scrolling background: "SNOUTY" / "BUGHUNT",
/// the ship (level pose, thruster looping, bobbing 1 px) where the head icon
/// used to be, then "A PLAY" (normal game) and "B HARDCORE" (Coral) blinking
/// together where M0 had "PRESS A".
pub fn draw_title(tick: u32) void {
    // The background layers start at y 8; clear the HUD row too, since
    // no_copy_full_frame leaves a stale frame there otherwise.
    cart.rect(.{ .x = 0, .y = 0, .width = cart.screen_width, .height = draw.hud_height, .fill_color = draw.anti_black });
    draw.darken_checker();
    draw.centered_text("SNOUTY", 40, draw.anti_white);
    draw.centered_text("BUGHUNT", 52, draw.coral);
    const ship_y: i32 = title_ship_y + @as(i32, @intCast((tick / 40) % 2));
    draw.draw_sprite(gfx.thruster, 8, 8, (tick / 3) % 4, title_ship_x - 6, ship_y + 8, .{});
    draw.draw_sprite(gfx.ship, 32, 24, 0, title_ship_x, ship_y, .{});
    if ((tick / 30) % 2 == 0) {
        draw.centered_text("A PLAY", 92, draw.anti_white);
        draw.centered_text("B HARDCORE", 104, draw.coral);
    }
    draw.centered_text("Antithesis", 116, draw.coral);
    draw.draw_sprite(gfx.iris_16, 16, 16, 0, 20, 112, .{});
    draw.draw_sprite(gfx.iris_16, 16, 16, 0, 124, 112, .{});
}

/// Pause overlay: the frozen scene dimmed, then "PAUSED", the in-game
/// controls and `RANK nnn` (PLAN.md M7, for testers) on a dark panel
/// (x 12..147, y 34..107). Keys in Coral at x 20, actions at x 92 (at most
/// 6 characters).
pub fn draw_pause() void {
    draw.darken_checker();
    cart.rect(.{ .x = 12, .y = 34, .width = 136, .height = 74, .fill_color = draw.anti_black, .stroke_color = draw.star_dim });
    draw.centered_text("PAUSED", 38, draw.anti_white);
    for (pause_help, 0..) |row, i| {
        const y: i32 = 50 + 10 * @as(i32, @intCast(i));
        draw.text(row[0], 20, y, draw.coral);
        draw.text(row[1], 92, y, draw.anti_white);
    }
    draw.centered_text("REWIND USES FUEL", 89, draw.star_dim);
    var buf: [9]u8 = undefined;
    draw.centered_text(rank_label(&buf, rank.value()), 98, draw.anti_white);
}

/// "RANK nnn" into `buf`: three digits, four for the maximum 1000.
fn rank_label(buf: *[9]u8, value: u32) []const u8 {
    const prefix = "RANK ";
    @memcpy(buf[0..prefix.len], prefix);
    const digits: usize = if (value >= 1000) 4 else 3;
    var v = @min(value, 9999);
    var k = digits;
    while (k > 0) {
        k -= 1;
        buf[prefix.len + k] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    return buf[0 .. prefix.len + digits];
}

/// Key, action (main.zig's playing state and player.zig).
const pause_help = [_][2][]const u8{
    .{ "JOYSTICK", "FLY" },
    .{ "HOLD A", "FIRE" },
    .{ "HOLD B", "REWIND" },
    .{ "START", "RESUME" },
};
