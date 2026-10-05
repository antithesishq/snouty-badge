//! Status bar (y 104..127, SPEC.md section 4), title card, intermission,
//! victory and pause overlays, the M1 render-time readout. The portrait
//! state lives in portrait.zig (render-only, advanced by `tick`).
const std = @import("std");
const cart = @import("cart-api");
const gfx = @import("gfx");
const state = @import("../state.zig");
const blit = @import("blit.zig");
const portrait = @import("portrait.zig");
const fx = @import("fx.zig");

pub const bar_y: i32 = 104;
pub const bar_h: u32 = 24;
pub const anti_black = cart.DisplayColor.rgb(0x16031B);
pub const anti_white = cart.DisplayColor.rgb(0xFCFBF9);
pub const coral = cart.DisplayColor.rgb(0xF18271);
pub const iris = cart.DisplayColor.rgb(0x8E42DE);
pub const green = cart.DisplayColor.rgb(0x8FD14F);
pub const red = cart.DisplayColor.rgb(0xEE453C);
pub const grey = cart.DisplayColor.rgb(0x958D9D);
pub const steel = cart.DisplayColor.rgb(0x6D6A86);
pub const trough = cart.DisplayColor.rgb(0x29232F);

/// Re-exported so main.zig can drive the rewind face in M4.
pub fn set_rewinding(on: bool) void {
    portrait.rewinding = on;
}

// hud.png cells.
const icon_key0 = 0; // Coral, Iris, Gold = 0, 1, 2
const icon_zapper = 3;
const icon_spray = 4;
const icon_clock = 5;
const icon_rewind = 6;
const icon_debugger = 8; // cell 7 is the heart

// Status bar geometry (x ranges from SPEC.md 4).
const row1_y: i32 = bar_y + 4; // 108: text row
const row2_y: i32 = bar_y + 14; // 118: bars
const mid_y: i32 = bar_y + 8; // 112: single-row items, vertically centred
const hp_bar_x: i32 = 1;
const hp_bar_w: u32 = 30;
const hp_bar_h: u32 = 4;
const ammo_x: i32 = 32;
const face_x: i32 = 64 + (32 - 24) / 2; // 68
const keys_x: i32 = 96;
const meter_x: i32 = 122;
const meter_w: u32 = 36;
const meter_h: u32 = 6;
const max_rewind: u32 = 600;

/// While rewinding: the meter the bar shows (clock text and fill) instead
/// of `s.player.rewind_meter`, so the clock counts down the budget.
pub var meter_override: ?u16 = null;

/// Deathmatch (M9): the shown slot's ammo for an arsenal weapon
/// (`arsenal.ammo`), set by the match frame; the Player holds none.
pub var dm_ammo: ?u8 = null;

/// Once per displayed tick: advances the portrait's render-only state.
pub fn tick(s: *const state.GameState) void {
    portrait.tick(s);
}

pub fn draw_bar(s: *const state.GameState) void {
    const p = &s.player;
    cart.rect(.{ .x = 0, .y = bar_y, .width = 160, .height = bar_h, .fill_color = anti_black });

    // x 0..31: HP "{d}%" over a 30x4 bar.
    var buf: [8]u8 = undefined;
    const hp: i32 = @max(0, p.hp);
    const hp_str = fmt(&buf, "{d}%", .{@min(hp, 999)});
    // Post-death grace (sim.death_grace): HP text and portrait frame blink Iris.
    const grace_on = p.grace > 0 and (p.grace / 6) % 2 == 0;
    text_in(hp_str, 0, 32, row1_y, if (grace_on) iris else anti_white);
    cart.rect(.{ .x = hp_bar_x, .y = row2_y, .width = hp_bar_w, .height = hp_bar_h, .fill_color = trough });
    const fill: u32 = @intCast(@divTrunc(@min(hp, 100) * @as(i32, hp_bar_w), 100));
    const hp_color = if (hp > 60) green else if (hp > 25) coral else red;
    if (fill > 0) cart.rect(.{ .x = hp_bar_x, .y = row2_y, .width = fill, .height = hp_bar_h, .fill_color = hp_color });

    // x 32..63: ammo icon + count (swatter and Garbage Collector: a dash;
    // three digits move left so they clear the portrait frame at x 66).
    switch (p.weapon) {
        .swatter, .gc => text_in("-", ammo_x, 32, mid_y, grey),
        else => {
            const n: u8 = switch (p.weapon) {
                .zapper => p.ammo_zapper,
                .spray => p.ammo_spray,
                .debugger => p.ammo_debugger,
                else => dm_ammo orelse 0,
            };
            const dx: i32 = if (n >= 100) 2 else 0;
            const k = @backingInt(p.weapon);
            if (k >= 4) {
                fx.screen(fx.icons[k - 4], ammo_x + 3 - dx, mid_y);
            } else {
                const icon: u32 = switch (p.weapon) {
                    .zapper => icon_zapper,
                    .spray => icon_spray,
                    else => icon_debugger,
                };
                blit.cell(gfx.hud, 8, 8, icon, ammo_x + 3 - dx, mid_y, .{});
            }
            var abuf: [4]u8 = undefined;
            const a = fmt(&abuf, "{d:>2}", .{n});
            cart.text(.{ .str = a, .x = ammo_x + 13 - 2 * dx, .y = mid_y, .text_color = if (n == 0) red else anti_white });
        },
    }

    // x 64..95: portrait 24x24 in a frame. The bar is only 24 px tall, so
    // the frame is 2 px left and right; top and bottom it is the face's own
    // 1 px transparent border showing the frame colour.
    cart.rect(.{ .x = face_x - 2, .y = bar_y, .width = 28, .height = 24, .fill_color = if (grace_on) iris else steel });
    cart.rect(.{ .x = face_x, .y = bar_y + 1, .width = 24, .height = 22, .fill_color = trough });
    blit.cell(gfx.face, 24, 24, @backingInt(portrait.frame(s)), face_x, bar_y, .{});

    // x 96..119: three key slots, dim when missing.
    for (0..3) |k| {
        const have = (p.keys >> @intCast(k)) & 1 == 1;
        blit.cell(gfx.hud, 8, 8, icon_key0 + @as(u32, @intCast(k)), keys_x + 8 * @as(i32, @intCast(k)), mid_y, .{ .dim = !have });
    }

    // x 120..159: clock glyph and seconds left over the 36x6 meter.
    // (8 + 36 px do not fit side by side in 40, so the glyph sits above.)
    const meter: u32 = @min(meter_override orelse p.rewind_meter, max_rewind);
    const glyph: u32 = if (portrait.rewinding) icon_rewind else icon_clock;
    blit.cell(gfx.hud, 8, 8, glyph, meter_x, row1_y, .{});
    var mbuf: [6]u8 = undefined;
    const secs = fmt(&mbuf, "{d:>2}s", .{(meter + 59) / 60});
    cart.text(.{ .str = secs, .x = meter_x + 12, .y = row1_y, .text_color = iris });
    cart.rect(.{ .x = meter_x, .y = row2_y, .width = meter_w, .height = meter_h, .fill_color = trough });
    const mfill = meter * meter_w / max_rewind;
    if (mfill > 0) cart.rect(.{ .x = meter_x, .y = row2_y, .width = mfill, .height = meter_h, .fill_color = iris });
}

/// Outcome of the last attract-mode demo that ran to the end of its log
/// (main.zig compares `sim.hash_gameplay` against the recorded hash).
pub const DemoResult = enum(u8) { none = 0, ok = 1, desync = 2 };

/// `demo_result`: "DEMO OK" (grey) or "DEMO DESYNC" (Coral) at the top
/// left once a demo has replayed its whole log; nothing for `.none`.
/// The title menu (M7, M8): PLAY (the campaign), DEATHMATCH (two badges
/// on the link cable) and PARTY (up to 16 badges through the laptop's
/// `badge lobby`); Up/Down moves `cursor`. Without link hardware (the
/// simulator) DEATHMATCH is greyed with "NO LINK IN SIMULATOR" under the
/// menu while selected; without the party firmware PARTY is greyed with
/// "NEEDS PARTY FIRMWARE".
pub const TitleMenu = struct { cursor: u8 = 0, link: bool = true, party: bool = true };
pub const title_items = 3;

pub fn draw_title(tick_n: u32, sound_on: bool, demo_result: DemoResult, menu: TitleMenu) void {
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = 128, .fill_color = anti_black });
    switch (demo_result) {
        .none => {},
        .ok => cart.text(.{ .str = "DEMO OK", .x = 2, .y = 2, .text_color = grey }),
        .desync => cart.text(.{ .str = "DEMO DESYNC", .x = 2, .y = 2, .text_color = coral }),
    }
    blit.cell(gfx.title, 128, 40, 0, 16, 14, .{});
    centered("powered by", 57, iris);
    centered("deterministic replay", 66, iris);
    const blink = (tick_n / 30) % 2 == 0;
    const items = [title_items][]const u8{ "PLAY", "DEATHMATCH", "PARTY" };
    const ok = [title_items]bool{ true, menu.link, menu.party };
    for (items, 0..) |item, i| {
        const y: i32 = 76 + 9 * @as(i32, @intCast(i));
        const on = menu.cursor == i;
        const color = if (!ok[i]) steel else if (on) anti_white else grey;
        centered(item, y, color);
        if (on and blink) {
            const x: i32 = 80 - @as(i32, @intCast(item.len * 4)) - 12;
            cart.text(.{ .str = ">", .x = x, .y = y, .text_color = coral });
        }
    }
    if (menu.cursor < title_items and !ok[menu.cursor]) {
        centered(if (menu.cursor == 1) "NO LINK IN SIMULATOR" else "NEEDS PARTY FIRMWARE", 104, grey);
    } else {
        centered(if (sound_on) "SELECT: SOUND ON" else "SELECT: SOUND OFF", 104, grey);
    }
    centered("B: E1M1  START: TEST", 116, grey);
}

/// Deathmatch (M7): frags in the bar's right block (x 96..159) instead of
/// the keys and the rewind meter: "YOU n" over "THEM n".
pub fn draw_frags(me: i16, them: i16) void {
    cart.rect(.{ .x = 96, .y = bar_y, .width = 64, .height = bar_h, .fill_color = anti_black });
    var buf: [8]u8 = undefined;
    cart.text(.{ .str = "YOU", .x = 98, .y = bar_y + 3, .text_color = green });
    cart.text(.{ .str = "THEM", .x = 98, .y = bar_y + 13, .text_color = coral });
    text_right(signed(&buf, me), 158, bar_y + 3, anti_white);
    text_right(signed(&buf, them), 158, bar_y + 13, anti_white);
}

/// `v` as decimal, a minus sign only when negative (std.fmt's width
/// formats put a plus on signed values).
pub fn signed(buf: []u8, v: i32) []const u8 {
    const mag: u32 = @abs(v);
    return if (v < 0) fmt(buf, "-{d}", .{mag}) else fmt(buf, "{d}", .{mag});
}

/// `str` with its last pixel column at `x1`.
pub fn text_right(str: []const u8, x1: i32, y: i32, color: cart.DisplayColor) void {
    const x: i32 = x1 + 1 - @as(i32, @intCast(str.len * 8));
    cart.text(.{ .str = str, .x = x, .y = y, .text_color = color });
}

/// Death freeze (SPEC.md 9.1): the view is drawn red underneath; this is
/// the prompt plus the rewind available. `meter_ticks` is the budget the
/// lead passes; it is floored to the 3 s once-per-death reserve here too.
pub fn draw_dead(meter_ticks: u16) void {
    cart.rect(.{ .x = 20, .y = 40, .width = 120, .height = 28, .fill_color = anti_black });
    centered("HOLD B TO REWIND", 46, coral);
    const m: u32 = @max(meter_ticks, reserve_ticks);
    var buf: [16]u8 = undefined;
    centered(fmt(&buf, "{d}s OF REWIND", .{(m + 59) / 60}), 57, iris);
}

/// SPEC.md 9.1: dying always leaves at least 3 s of rewind.
const reserve_ticks: u32 = 180;

/// While rewinding: "<<" at the top left of the view.
pub fn draw_rewind_marker() void {
    cart.text(.{ .str = "<<", .x = 0, .y = 0, .text_color = iris, .background_color = anti_black });
}

/// While the attract demo drives: "DEMO" centred at the top of the view
/// (x 64..95, y 0), on for 40 of every 60 ticks. Stays clear of the `<<`
/// marker (x < 16) and the render readout (x >= 104).
pub fn draw_demo_marker(tick_n: u32) void {
    if (tick_n % 60 >= 40) return;
    cart.text(.{ .str = "DEMO", .x = 64, .y = 0, .text_color = anti_white, .background_color = anti_black });
}

pub fn draw_intermission(s: *const state.GameState, level_name: []const u8, total_enemies: u32, ticks: u32) void {
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = 128, .fill_color = anti_black });
    centered("LEVEL CLEAR", 16, coral);
    centered(level_name[0..@min(level_name.len, 20)], 30, anti_white);
    var kbuf: [20]u8 = undefined;
    centered(fmt(&kbuf, "KILLS {d}/{d}", .{ s.kills, total_enemies }), 56, anti_white);
    stats_time(s, 70);
    press_a(ticks);
}

pub fn draw_victory(s: *const state.GameState, ticks: u32) void {
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = 128, .fill_color = anti_black });
    centered("ALL BUGS FIXED", 16, coral);
    blit.cell(gfx.face, 24, 24, @backingInt(portrait.Frame.grin), 68, 28, .{});
    var kbuf: [20]u8 = undefined;
    centered(fmt(&kbuf, "KILLS {d}", .{s.kills}), 56, anti_white);
    stats_time(s, 70);
    press_a(ticks);
}

/// Pause screen: "PAUSED" and the in-game controls (SPEC.md 3) on a dark
/// panel over the frozen view (x 4..155, y 8..95, clear of the HUD bar).
/// Keys in Coral at x 12, actions at x 100 (at most 6 characters).
pub fn draw_pause() void {
    cart.rect(.{ .x = 4, .y = 8, .width = 152, .height = 88, .fill_color = anti_black, .stroke_color = grey });
    centered("PAUSED", 13, anti_white);
    for (pause_help, 0..) |row, i| {
        const y: i32 = 27 + 10 * @as(i32, @intCast(i));
        cart.text(.{ .str = row[0], .x = 12, .y = y, .text_color = coral });
        cart.text(.{ .str = row[1], .x = 100, .y = y, .text_color = anti_white });
    }
}

/// Key, action. Doors have no button: walking into one opens it.
const pause_help = [_][2][]const u8{
    .{ "UP/DOWN", "WALK" },
    .{ "LEFT/RIGHT", "TURN" },
    .{ "A", "FIRE" },
    .{ "SELECT", "WEAPON" },
    .{ "HOLD B", "REWIND" },
    .{ "BUMP DOOR", "OPENS" },
    .{ "START", "RESUME" },
};

/// M1 gate readout: render microseconds, top right of the view
/// (right-aligned, last column x 159) so it never covers the rewind marker.
pub fn draw_render_us(us: u32) void {
    var buf: [12]u8 = undefined;
    const str = fmt(&buf, "{d}us", .{us});
    const x: i32 = @as(i32, cart.screen_width) - @as(i32, @intCast(str.len * cart.font_width));
    cart.text(.{ .str = str, .x = x, .y = 0, .text_color = coral, .background_color = anti_black });
}

fn stats_time(s: *const state.GameState, y: i32) void {
    const secs = s.tick / 60;
    var buf: [20]u8 = undefined;
    centered(fmt(&buf, "TIME {d:0>2}:{d:0>2}", .{ @min(secs / 60, 99), secs % 60 }), y, anti_white);
}

fn press_a(ticks: u32) void {
    if (ticks >= 60 and (ticks / 30) % 2 == 0) centered("PRESS A", 100, anti_white);
}

pub fn centered(str: []const u8, y: i32, color: cart.DisplayColor) void {
    text_in(str, 0, 160, y, color);
}

/// `str` centred in the span x0..x0+w.
pub fn text_in(str: []const u8, x0: i32, w: i32, y: i32, color: cart.DisplayColor) void {
    const tw: i32 = @intCast(str.len * 8);
    cart.text(.{ .str = str, .x = x0 + @divTrunc(w - tw, 2), .y = y, .text_color = color });
}

pub fn fmt(buf: []u8, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, f, args) catch "?";
}
