//! New for Snouty GC (M6 Track B): BATTLE's words and option rows, kept
//! apart from the screens (battle_ui.zig, hud.zig, results.zig,
//! link_ui.zig, which need the cart API) so the host tests
//! (battle_ui_test.zig) can hold them: every line fits its panel, the
//! LIVES / TIME / CREWS rows cycle SPEC 8.3's values (TIME NONE never with
//! INF lives), the clock and the standings lines read right, and the LINK
//! lobby's rows and rule changes (LINK RACE / LINK GC / LINK BATTLE) behave.
//! Pure: no cart API, no World writes.
const std = @import("std");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const net = @import("net.zig");
const track = @import("track.zig");

// --- The single-player setup screen (battle_ui.zig) ---------------------------------

/// The setup screen's rows, top to bottom; A on any row (or Start) starts
/// the round, Left / Right change the row's value.
pub const Row = enum(u8) { arena, lives, time, crews, fight };
pub const row_count = 5;

/// The line about the row under the cursor (the setup's hint bar, at most
/// 18 characters like the main menu's).
pub fn hint(r: Row) []const u8 {
    return switch (r) {
        .arena => "RAMPS AND A PIT",
        .lives => "WRECKS BEFORE OUT",
        .time => "ROUND LENGTH",
        .crews => "AI HUNTERS",
        .fight => "NO APPEAL",
    };
}
pub const title = "BATTLE";
pub const footer = "A FIGHT  B BACK";
/// The INF lives' TIME row when NONE is skipped.
pub const time_inf_note = "INF: TIME NEEDED";

/// The options a setup holds (main.zig keeps them between rounds).
pub const Options = struct {
    arena: u8 = 0,
    lives: u8 = 3,
    minutes: u8 = 3,
    /// AI cars (single player 5..1).
    crews: u8 = 5,
};

/// Single-player CREWS (SPEC 8.3: every slot filled by default).
pub const crew_steps_solo = [_]u8{ 5, 4, 3, 2, 1 };
/// LINK's CREWS (SPEC 7.1).
pub const crew_steps_link = [_]u8{ 4, 2, 0 };

fn index_of(opts: []const u8, v: u8) usize {
    for (opts, 0..) |o, i| {
        if (o == v) return i;
    }
    return 0;
}

fn cycle(opts: []const u8, v: u8, step: i32) u8 {
    const n: i32 = @intCast(opts.len);
    const k: i32 = @intCast(index_of(opts, v));
    return opts[@intCast(@mod(k + step, n))];
}

/// The next LIVES value (1, 3, 5, 9, INF = 0), wrapping.
pub fn next_lives(v: u8, step: i32) u8 {
    return cycle(&tuning.battle_lives_opts, v, step);
}

/// The next TIME value (2, 3, 5, NONE = 0), wrapping; NONE is skipped with
/// INF lives (SPEC 8.3: a round must end).
pub fn next_minutes(v: u8, step: i32, lives: u8) u8 {
    var m = cycle(&tuning.battle_minutes_opts, v, step);
    if (lives == 0 and m == 0) m = cycle(&tuning.battle_minutes_opts, m, step);
    return m;
}

/// After LIVES changed: INF with TIME NONE becomes the default 3 minutes
/// (the sim reads it so anyway).
pub fn fix_minutes(lives: u8, minutes: u8) u8 {
    return if (lives == 0 and minutes == 0) 3 else minutes;
}

pub fn next_crews(steps: []const u8, v: u8, step: i32) u8 {
    return cycle(steps, v, step);
}

/// Left / Right on a setup row (`n_arenas`: arenas to cycle).
pub fn change(o: *Options, r: Row, step: i32, n_arenas: usize) void {
    switch (r) {
        .arena => {
            const n: i32 = @intCast(@max(1, n_arenas));
            o.arena = @intCast(@mod(@as(i32, o.arena) + step, n));
        },
        .lives => {
            o.lives = next_lives(o.lives, step);
            o.minutes = fix_minutes(o.lives, o.minutes);
        },
        .time => o.minutes = next_minutes(o.minutes, step, o.lives),
        .crews => o.crews = next_crews(&crew_steps_solo, o.crews, step),
        .fight => {},
    }
}

/// Writes `v` (0..99) at `out`, returns the digits used.
pub fn put(out: []u8, v: u32) usize {
    const n = @min(v, 99);
    if (n >= 10) {
        out[0] = '0' + @as(u8, @intCast(n / 10));
        out[1] = '0' + @as(u8, @intCast(n % 10));
        return 2;
    }
    out[0] = '0' + @as(u8, @intCast(n));
    return 1;
}

fn join(buf: []u8, parts: []const []const u8) []const u8 {
    var n: usize = 0;
    for (parts) |p| {
        @memcpy(buf[n..][0..p.len], p);
        n += p.len;
    }
    return buf[0..n];
}

/// `LIVES: 3`, `LIVES: INF`.
pub fn lives_label(buf: *[16]u8, lives: u8) []const u8 {
    if (lives == 0) return join(buf, &.{"LIVES: INF"});
    var d: [2]u8 = undefined;
    return join(buf, &.{ "LIVES: ", d[0..put(&d, lives)] });
}

/// `TIME: 3 MIN`, `TIME: NONE`.
pub fn time_label(buf: *[16]u8, minutes: u8) []const u8 {
    if (minutes == 0) return join(buf, &.{"TIME: NONE"});
    var d: [2]u8 = undefined;
    return join(buf, &.{ "TIME: ", d[0..put(&d, minutes)], " MIN" });
}

/// `CREWS: 5 AI`.
pub fn crews_label(buf: *[16]u8, crews: u8) []const u8 {
    var d: [2]u8 = undefined;
    return join(buf, &.{ "CREWS: ", d[0..put(&d, crews)], " AI" });
}

/// The rules in one line for the link select and the KILL -9 card:
/// `3 LIVES, 3 MIN`, `INF LIVES, 5 MIN`, `1 LIFE, NO LIMIT` (at most 18).
pub fn rules_line(buf: *[24]u8, lives: u8, minutes: u8) []const u8 {
    var d: [2]u8 = undefined;
    var e: [2]u8 = undefined;
    const l: []const u8 = if (lives == 0) "INF" else d[0..put(&d, lives)];
    const lw: []const u8 = if (lives == 1) " LIFE, " else " LIVES, ";
    const m = if (lives == 0 and minutes == 0) 3 else minutes;
    if (m == 0) return join(buf, &.{ l, lw, "NO LIMIT" });
    return join(buf, &.{ l, lw, e[0..put(&e, m)], " MIN" });
}

// --- The KILL -9 card (SPEC 8.3) ----------------------------------------------------

pub const card_title = "KILL -9";
pub const card_prompt = "$ kill -9 -1";
pub const card_line1 = "no cleanup handler";
pub const card_line2 = "no appeal";

/// The card shows over the countdown's first `card_steps` steps (READY and
/// 3; `tuning.countdown_step` ticks each): render only, so a LINK BATTLE's
/// lockstep never waits on it.
pub const card_steps = 2;

/// Is the card up at countdown ticks left `cd` (World.countdown)?
pub fn card_up(cd: u16) bool {
    return cd > (4 - card_steps) * tuning.countdown_step;
}

// --- The HUD (hud.zig) --------------------------------------------------------------

/// The round clock `M:SS` from ticks (rounded up, so 0:00 shows only at
/// the end).
pub fn clock(buf: *[5]u8, ticks: u32) []const u8 {
    const s = (ticks + 59) / 60;
    const m = @min(s / 60, 99);
    var n: usize = put(buf, m);
    buf[n] = ':';
    n += 1;
    buf[n] = '0' + @as(u8, @intCast((s % 60) / 10));
    buf[n + 1] = '0' + @as(u8, @intCast(s % 10));
    return buf[0 .. n + 2];
}

/// `ELIM 3` (eliminations).
pub fn elims_label(buf: *[8]u8, kills: u8) []const u8 {
    var d: [2]u8 = undefined;
    return join(buf, &.{ "ELIM ", d[0..put(&d, kills)] });
}

/// The bar notes and pops of a round.
pub const safe_mode = "SAFE MODE";
pub const stack_smash = "STACK SMASH!";
pub const smashed = "STACK SMASHED";
pub const clean_landing = "CLEAN LANDING";
pub const time_up = "TIME UP";
pub const last_standing = "LAST ONE STANDING";
pub const reaped = "REAPED";
/// The feed: `SNOUTY kill -9 KIDDIE` (the middle word), `KIDDIE REAPED`.
pub const feed_kill = " kill -9 ";
pub const feed_reaped = " REAPED";
pub const feed_smash = " SMASHED ";

/// The bar line when the round ends.
pub fn end_note(e: world.BattleEnd) []const u8 {
    return switch (e) {
        .time => time_up,
        .lives => last_standing,
        .none => "",
    };
}

// --- The results (results.zig) ------------------------------------------------------

/// A standings row's second line: `LIVES 2`, `WRECKS 3` (INF lives), or
/// `OUT 1:42` (the time it survived).
pub fn standing_line(buf: *[16]u8, w: *const world.World, i: usize) []const u8 {
    const c = &w.cars[i];
    var d: [2]u8 = undefined;
    if (w.battle.out & (@as(u8, 1) << @intCast(i)) != 0) {
        var t: [5]u8 = undefined;
        return join(buf, &.{ "OUT ", clock(&t, c.finish_tick) });
    }
    if (w.battle.lives == 0) return join(buf, &.{ "WRECKS ", d[0..put(&d, c.wrecks)] });
    return join(buf, &.{ "LIVES ", d[0..put(&d, c.lives)] });
}

/// The winner card's header by how the round ended.
pub fn winner_title(e: world.BattleEnd) []const u8 {
    return if (e == .lives) "LAST PROCESS UP" else "TOP KILLER";
}

// --- LINK BATTLE in the lobby (link_ui.zig, main.zig) -------------------------------

/// The lobby's rows: MODE, TRACK (the ARENA in battle), CREWS, then LIVES
/// and TIME in LINK BATTLE only, then the racer select.
pub const LobbyRow = enum(u8) { mode, track, crews, lives, time, racer };

/// Is lobby row `r` shown for mode `m`?
pub fn lobby_shows(r: LobbyRow, m: world.Mode) bool {
    return switch (r) {
        .lives, .time => m == .battle,
        else => true,
    };
}

/// The rows shown, in order, into `out`; returns how many.
pub fn lobby_rows(m: world.Mode, out: *[6]LobbyRow) usize {
    var n: usize = 0;
    for (0..6) |i| {
        const r: LobbyRow = @fromBackingInt(@intCast(i));
        if (!lobby_shows(r, m)) continue;
        out[n] = r;
        n += 1;
    }
    return n;
}

/// Up / Down from row `r` (`step` -1 or 1) over the rows mode `m` shows,
/// wrapping.
pub fn lobby_move(r: LobbyRow, step: i32, m: world.Mode) LobbyRow {
    var rows: [6]LobbyRow = undefined;
    const n = lobby_rows(m, &rows);
    var k: usize = 0;
    for (rows[0..n], 0..) |x, i| {
        if (x == r) k = i;
    }
    return rows[@intCast(@mod(@as(i32, @intCast(k)) + step, @as(i32, @intCast(n))))];
}

/// The lobby's modes in Left / Right order.
pub const link_modes = [_]world.Mode{ .race, .gc, .battle };

pub fn mode_name(m: world.Mode) []const u8 {
    return switch (m) {
        .gc => "LINK GC",
        .battle => "LINK BATTLE",
        else => "LINK RACE",
    };
}

/// Host: Left / Right on lobby row `r`. Switching into or out of LINK
/// BATTLE moves the track to the first arena or track (`race_track`: the
/// race track to come back to).
pub fn lobby_change(rules: *net.Rules, r: LobbyRow, step: i32, race_track: *u8) void {
    switch (r) {
        .mode => {
            const was = rules.mode;
            var k: usize = 0;
            for (link_modes, 0..) |m, i| {
                if (m == rules.mode) k = i;
            }
            rules.mode = link_modes[@intCast(@mod(@as(i32, @intCast(k)) + step, @as(i32, link_modes.len)))];
            if (was != .battle and rules.mode == .battle) {
                race_track.* = rules.track;
                rules.track = 0;
            } else if (was == .battle and rules.mode != .battle) {
                rules.track = race_track.*;
            }
        },
        .track => {
            const n: i32 = @intCast(if (rules.mode == .battle) track.arenas.len else track.tracks.len);
            rules.track = @intCast(@mod(@as(i32, rules.track) + step, n));
        },
        .crews => rules.crews = next_crews(&crew_steps_link, rules.crews, step),
        .lives => {
            rules.lives = next_lives(rules.lives, step);
            rules.minutes = fix_minutes(rules.lives, rules.minutes);
        },
        .time => rules.minutes = next_minutes(rules.minutes, step, rules.lives),
        .racer => {},
    }
}

/// The track or arena name the rules name.
pub fn place_name(rules: net.Rules) []const u8 {
    if (rules.mode == .battle) return track.arenas[rules.track % track.arenas.len].name;
    return track.tracks[rules.track % track.tracks.len].name;
}

/// Every fixed line above that sits in a 152 px panel (the host test).
pub const panel_lines = [_][]const u8{
    title,     footer,        time_inf_note, card_prompt,   card_line1, card_line2,
    safe_mode, stack_smash,   smashed,       clean_landing, time_up,    last_standing,
    reaped,    "LINK BATTLE", "LINK RACE",   "LINK GC",
};

test {
    std.testing.refAllDecls(@This());
}
