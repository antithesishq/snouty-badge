//! New for Snouty GC (M5): the garage between CIRCUIT races (SPEC 9.2).
//! The racer's portrait top left in its livery frame, their car turning
//! on a plinth under it, the slot list on the right (FRONT, REAR,
//! PLATING, CLOCK, TRACTION, BURST, WATCHDOG, then RACE) with each slot's
//! level as pips, and under it the row under the cursor: the item (Left
//! and Right pick a gun on FRONT and REAR), what the next level does and
//! its price (coral when the wallet is short). A buys; the portrait
//! answers every press with a line in the racer's voice
//! (`roster_text.reactions`) for a few seconds. Start (or A on RACE)
//! races the next track; B goes back to the main menu with the Prix kept.
//! Everything 4 px clear of the edges. The career itself is career.zig.
const cart = @import("cart-api");
const world = @import("world.zig");
const racers = @import("racers.zig");
const track = @import("track.zig");
const tuning = @import("tuning.zig");
const career = @import("career.zig");
const roster_text = @import("roster_text.zig");
const sprites = @import("sprites.zig");
const hud = @import("hud.zig");
const input = @import("input.zig");
const sound = @import("sound.zig");
const select = @import("select.zig");

pub const Action = enum { none, race, back };

/// The rows: the seven slots, then RACE.
pub const race_row: u8 = career.slot_count;
const row_count: u8 = career.slot_count + 1;
const labels = [row_count][]const u8{ "FRONT", "REAR", "PLATING", "CLOCK", "TRACTION", "BURST", "WATCHDOG", "RACE" };

pub var cursor: u8 = 0;
/// The gun shown on the FRONT and REAR rows (`Front` / `Rear` number).
var picks: [2]u8 = .{ 0, 0 };
/// The portrait's line and frames left on it.
var talk: roster_text.Reaction = .level;
var talk_frames: u32 = 0;
const talk_show: u32 = 180;
/// Frames on the garage (the turntable).
var frames: u32 = 0;

pub fn enter(c: *const career.Career) void {
    cursor = 0;
    picks = .{ @backingInt(c.front_of(c.racer)), @backingInt(c.rear_of(c.racer)) };
    talk_frames = 0;
    frames = 0;
}

/// The reaction the racer gives to the slot just bought.
fn reaction_for(c: *const career.Career, slot: career.Slot, swapped: bool) roster_text.Reaction {
    return switch (slot) {
        .front, .rear => if (swapped) .swap else .level,
        .plating => if (c.level(c.racer, .plating) >= tuning.plating_ecc) .ecc else .plating,
        .clock => .clock,
        .traction => .traction,
        .burst => .burst,
        .watchdog => .watchdog,
    };
}

fn say(r: roster_text.Reaction) void {
    talk = r;
    talk_frames = talk_show;
}

/// One frame of input.
pub fn update(c: *career.Career) Action {
    frames +%= 1;
    talk_frames -|= 1;
    if (input.pressed(.start)) {
        sound.menu_confirm();
        return .race;
    }
    if (input.pressed(.b)) return .back;
    if (input.pressed(.up)) {
        cursor = if (cursor == 0) row_count - 1 else cursor - 1;
        sound.menu_move();
    }
    if (input.pressed(.down)) {
        cursor = (cursor + 1) % row_count;
        sound.menu_move();
    }
    const step: i32 = @as(i32, @intFromBool(input.pressed(.right))) - @as(i32, @intFromBool(input.pressed(.left)));
    if (step != 0 and cursor < 2) {
        picks[cursor] = @intCast(@mod(@as(i32, picks[cursor]) + step, 4));
        sound.menu_move();
    }
    if (input.pressed(.a)) {
        if (cursor == race_row) {
            sound.menu_confirm();
            return .race;
        }
        const slot: career.Slot = @fromBackingInt(cursor);
        const pick = if (cursor < 2) picks[cursor] else 0;
        const swapped = c.offer(c.racer, slot, pick).kind == .swap;
        switch (c.buy(slot, pick)) {
            .ok => {
                sound.menu_confirm();
                say(reaction_for(c, slot, swapped));
            },
            .poor => {
                sound.menu_move();
                say(.poor);
            },
            .maxed => {
                sound.menu_move();
                say(.maxed);
            },
        }
    }
    return .none;
}

const bg = cart.DisplayColor.rgb(0x100E16);
const panel = cart.DisplayColor.rgb(0x221E2C);
const panel_hi = cart.DisplayColor.rgb(0x4A2440);
const ink = cart.DisplayColor.rgb(0xECE8F0);
const dim = cart.DisplayColor.rgb(0x9692A4);
const rule = cart.DisplayColor.rgb(0x464056);

fn plain(str: []const u8, x: i32, y: i32, color: cart.DisplayColor) void {
    @import("font.zig").draw(str, x, y, .from_color(color), null);
}

fn centered(str: []const u8, y: i32, color: cart.DisplayColor) void {
    plain(str, 80 - @as(i32, @intCast(str.len * 4)), y, color);
}

/// `v` as decimal digits into `buf`, returns them.
fn digits(buf: []u8, v: u32) []const u8 {
    hud.put_uint(buf, v, ' ');
    var i: usize = 0;
    while (i + 1 < buf.len and buf[i] == ' ') i += 1;
    return buf[i..];
}

pub fn draw(c: *const career.Career, frame: u32) void {
    const r = c.racer;
    const liv = hud.livery(r);
    hud.fill_rect(0, 0, 160, 128, bg);
    // Header: GARAGE and the wallet.
    plain("GARAGE", 4, 2, hud.cyan);
    var wb: [10]u8 = undefined;
    const ws = digits(&wb, c.cycles);
    var wallet: [16]u8 = undefined;
    @memcpy(wallet[0..ws.len], ws);
    @memcpy(wallet[ws.len..][0..4], " CYC");
    plain(wallet[0 .. ws.len + 4], 156 - @as(i32, @intCast((ws.len + 4) * 8)), 2, hud.yellow);
    // The portrait (it bobs while it talks) and the car on its plinth.
    const bob: i32 = if (talk_frames > 0 and (frame / 6) % 2 == 0) 1 else 0;
    hud.fill_rect(3, 11, 50, 50, liv);
    sprites.blit_at(&sprites.portraits[r], 0, 4, 12 - bob, .{});
    select.plinth(28, 80, 17, 4, panel);
    const v = select.turntable[(frames / select.view_frames) % select.turntable.len];
    sprites.blit_cell(&sprites.cars[r], v.cell, 12, 64, 32, 16, .{ .flip = v.flip });
    // The slot list with level pips.
    for (labels, 0..) |label, k| {
        const y: i32 = 12 + @as(i32, @intCast(k)) * 10;
        const sel = k == cursor;
        if (sel) hud.fill_rect(56, y - 1, 100, 10, panel_hi);
        if (k == race_row) {
            plain(label, 60, y, if (sel) hud.coral else hud.cyan);
            plain(">", 100, y, if (sel and (frame / 15) % 2 == 0) hud.coral else hud.cyan);
            continue;
        }
        plain(label, 60, y, if (sel) hud.coral else ink);
        const lv = c.level(r, @fromBackingInt(@intCast(k)));
        var p: u8 = 0;
        while (p < tuning.level_max) : (p += 1) {
            hud.fill_rect(134 + @as(i32, p) * 7, y + 1, 5, 6, if (p < lv) liv else rule);
        }
    }
    hud.fill_rect(4, 91, 152, 1, rule);
    draw_details(c, frame);
    if (talk_frames > 0) {
        const line = roster_text.reactions[r].lines[@backingInt(talk)];
        hud.fill_rect(0, 102, 160, 26, bg);
        const k = roster_text.wrap(line, 19);
        plain(line[0..k], 4, 104, liv);
        if (k < line.len) plain(line[k + 1 ..], 4, 114, liv);
    }
}

/// The row under the cursor: the item (y 94), the next level and its
/// price (y 104), the keys (y 114).
fn draw_details(c: *const career.Career, frame: u32) void {
    const r = c.racer;
    if (cursor == race_row) {
        const t = track.tracks[c.track_index()];
        centered(t.name, 94, hud.cyan);
        var buf: [19]u8 = undefined;
        const lg = t.league.name;
        @memcpy(buf[0..lg.len], lg);
        @memcpy(buf[lg.len..][0..4], " 1/3");
        buf[lg.len + 1] = '1' + c.race;
        buf[lg.len + 3] = '0' + track.tracks_per_league;
        centered(buf[0 .. lg.len + 4], 104, dim);
        centered("A RACE  B MENU", 114, rule);
        return;
    }
    const slot: career.Slot = @fromBackingInt(cursor);
    const pick = if (cursor < 2) picks[cursor] else 0;
    const o = c.offer(r, slot, pick);
    // The item.
    var name_buf: [19]u8 = undefined;
    var name: []const u8 = undefined;
    switch (slot) {
        .front, .rear => {
            const gun = if (slot == .front) roster_text.front_name(@fromBackingInt(pick)) else roster_text.rear_name(@fromBackingInt(pick));
            name = gun;
            const blink = (frame / 20) % 2 == 0;
            plain("<", 4, 94, if (blink) ink else dim);
            plain(">", 148, 94, if (blink) ink else dim);
        },
        else => {
            const n: []const u8 = switch (slot) {
                .plating => "PLATING",
                .clock => "CLOCK",
                .traction => "TRACTION",
                .burst => "BURST BUFFER",
                else => "WATCHDOG",
            };
            @memcpy(name_buf[0..n.len], n);
            @memcpy(name_buf[n.len..][0..3], " L0");
            name_buf[n.len + 2] = '0' + c.level(r, slot);
            name = name_buf[0 .. n.len + 3];
        },
    }
    centered(name, 94, if (o.kind == .swap) hud.orange else ink);
    // What the next level does, and its price.
    const what: []const u8 = switch (o.kind) {
        .maxed => "MAXED",
        .swap => "SWAP IN, L1",
        .level => switch (slot) {
            .front => if (o.level >= 3) "L3 +25% DAMAGE" else "L2 +25% AMMO",
            .rear => if (o.level >= 3) "L3 +25% EFFECT" else "L2 +1 DROP",
            .plating => if (o.level >= tuning.plating_ecc) "+30 ARMOR, ECC" else "+30 ARMOR",
            .clock => "+4% TOP SPEED",
            .traction => "+0.03 GRIP",
            .burst => switch (o.level) {
                1 => "2 BURSTS A LAP",
                2 => "3 BURSTS A LAP",
                else => "4 BURSTS A LAP",
            },
            .watchdog => switch (o.level) {
                1 => "REBOOT IN 1.5S",
                2 => "REBOOT IN 1.0S",
                else => "REBOOT IN 0.7S",
            },
        },
    };
    plain(what, 4, 104, if (o.kind == .maxed) dim else ink);
    if (o.kind != .maxed) {
        var pb: [5]u8 = undefined;
        const ps = digits(&pb, o.price);
        plain(ps, 156 - @as(i32, @intCast(ps.len * 8)), 104, if (o.price > c.cycles) hud.coral else hud.yellow);
    }
    centered("A BUY  START RACE", 114, rule);
}
