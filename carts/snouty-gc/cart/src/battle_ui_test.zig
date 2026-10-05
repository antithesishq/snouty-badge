//! M6 Track B's host tests (the BATTLE presentation, battle_text.zig):
//! every line fits its 152 px panel, the setup's LIVES / TIME / CREWS rows
//! cycle SPEC 8.3's values (TIME NONE never with INF lives), the KILL -9
//! card's window, the round clock, the standings lines, and the LINK
//! lobby's rows and rule changes for LINK RACE / LINK GC / LINK BATTLE.
//! Registered in host_tests.zig by the M6.0 interface commit.
const std = @import("std");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const track = @import("track.zig");
const net = @import("net.zig");
const text = @import("battle_text.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// 152 px of panel, 8 px a character, a 4 px margin a side.
const panel_chars = 18;

fn fits(line: []const u8) !void {
    if (line.len == 0 or line.len > panel_chars) {
        std.debug.print("battle line of {d} chars (max {d}): \"{s}\"\n", .{ line.len, panel_chars, line });
        return error.TestUnexpectedResult;
    }
    for (line) |ch| try expect(ch >= 32 and ch < 127);
}

test "battle text fits the panels: fixed lines, hints, every option label and rules line" {
    for (text.panel_lines) |l| try fits(l);
    for (0..text.row_count) |i| try fits(text.hint(@fromBackingInt(@intCast(i))));
    var b: [16]u8 = undefined;
    var r: [24]u8 = undefined;
    for (tuning.battle_lives_opts) |l| {
        try fits(text.lives_label(&b, l));
        for (tuning.battle_minutes_opts) |m| try fits(text.rules_line(&r, l, m));
    }
    for (tuning.battle_minutes_opts) |m| try fits(text.time_label(&b, m));
    for (text.crew_steps_solo) |c| try fits(text.crews_label(&b, c));
    for (text.crew_steps_link) |c| try fits(text.crews_label(&b, c));
    var e: [8]u8 = undefined;
    try fits(text.elims_label(&e, 99));
    for ([_]world.BattleEnd{ .lives, .time }) |end| {
        try fits(text.end_note(end));
        try fits(text.winner_title(end));
    }
    for (track.arenas) |a| try fits(a.name);
    // The card: KILL -9 at 2x is 112 px; its two lines and the prompt
    // inside the 152 px card.
    try expect(text.card_title.len * 16 <= 152 - 8);
    try fits(text.card_line1);
    try fits(text.card_line2);
}

test "battle labels read as the menus show them" {
    var b: [16]u8 = undefined;
    var r: [24]u8 = undefined;
    try expectEqualStrings("LIVES: INF", text.lives_label(&b, 0));
    try expectEqualStrings("LIVES: 9", text.lives_label(&b, 9));
    try expectEqualStrings("TIME: NONE", text.time_label(&b, 0));
    try expectEqualStrings("TIME: 5 MIN", text.time_label(&b, 5));
    try expectEqualStrings("CREWS: 5 AI", text.crews_label(&b, 5));
    try expectEqualStrings("3 LIVES, 3 MIN", text.rules_line(&r, 3, 3));
    try expectEqualStrings("1 LIFE, NO LIMIT", text.rules_line(&r, 1, 0));
    // INF with NONE is read as 3 minutes, as the sim does.
    try expectEqualStrings("INF LIVES, 3 MIN", text.rules_line(&r, 0, 0));
}

test "setup rows: LIVES and TIME cycle SPEC 8.3's values, NONE never with INF" {
    // LIVES: 1, 3, 5, 9, INF and round, both ways.
    var v: u8 = 1;
    var seen: [5]u8 = undefined;
    for (&seen) |*s| {
        s.* = v;
        v = text.next_lives(v, 1);
    }
    try expectEqual([5]u8{ 1, 3, 5, 9, 0 }, seen);
    try expectEqual(@as(u8, 1), v);
    try expectEqual(@as(u8, 0), text.next_lives(1, -1));
    // TIME with lives: 2, 3, 5, NONE; with INF: 2, 3, 5 only.
    try expectEqual(@as(u8, 0), text.next_minutes(5, 1, 3));
    try expectEqual(@as(u8, 2), text.next_minutes(5, 1, 0));
    try expectEqual(@as(u8, 5), text.next_minutes(2, -1, 0));
    for (tuning.battle_minutes_opts) |m| {
        for ([_]i32{ -1, 1 }) |step| {
            try expect(text.next_minutes(m, step, 0) != 0);
        }
    }
    // Switching LIVES to INF on TIME NONE puts the default 3 minutes back.
    var o: text.Options = .{ .lives = 9, .minutes = 0 };
    text.change(&o, .lives, 1, track.arenas.len);
    try expectEqual(@as(u8, 0), o.lives);
    try expectEqual(@as(u8, 3), o.minutes);
    // Every state the rows can reach is a valid setup: walk them all.
    o = .{};
    var k: u32 = 0;
    while (k < 400) : (k += 1) {
        const row: text.Row = @fromBackingInt(@intCast(k % 4));
        text.change(&o, row, if (k % 7 < 4) 1 else -1, track.arenas.len);
        try expect(std.mem.indexOfScalar(u8, &tuning.battle_lives_opts, o.lives) != null);
        try expect(std.mem.indexOfScalar(u8, &tuning.battle_minutes_opts, o.minutes) != null);
        try expect(!(o.lives == 0 and o.minutes == 0));
        try expect(o.crews >= 1 and o.crews <= 5);
        try expect(o.arena < track.arenas.len);
    }
    // CREWS 5..1 single player, 4 / 2 / 0 on the link.
    try expectEqual(@as(u8, 4), text.next_crews(&text.crew_steps_solo, 5, 1));
    try expectEqual(@as(u8, 5), text.next_crews(&text.crew_steps_solo, 1, 1));
    try expectEqual(@as(u8, 0), text.next_crews(&text.crew_steps_link, 4, -1));
}

test "the KILL -9 card covers READY and 3, then the countdown shows" {
    const step = tuning.countdown_step;
    try expect(text.card_up(4 * step));
    try expect(text.card_up(2 * step + 1));
    try expect(!text.card_up(2 * step));
    try expect(!text.card_up(0));
}

test "the round clock: M:SS rounded up, 0:00 only at the end" {
    var b: [5]u8 = undefined;
    try expectEqualStrings("3:00", text.clock(&b, 3 * tuning.battle_minute));
    try expectEqualStrings("3:00", text.clock(&b, 3 * tuning.battle_minute - 59));
    try expectEqualStrings("2:59", text.clock(&b, 3 * tuning.battle_minute - 60));
    try expectEqualStrings("0:01", text.clock(&b, 1));
    try expectEqualStrings("0:00", text.clock(&b, 0));
    try expectEqualStrings("1:01", text.clock(&b, 3601));
    try expectEqualStrings("10:00", text.clock(&b, 10 * tuning.battle_minute));
}

test "standings lines: LIVES, WRECKS with INF, OUT and the time survived" {
    var w: world.World = .{};
    w.mode = .battle;
    w.battle.lives = 3;
    w.cars[0].lives = 2;
    w.cars[1].finish_tick = 102 * 60;
    w.battle.out = 0b10;
    var b: [16]u8 = undefined;
    try expectEqualStrings("LIVES 2", text.standing_line(&b, &w, 0));
    try expectEqualStrings("OUT 1:42", text.standing_line(&b, &w, 1));
    w.battle.lives = 0;
    w.battle.out = 0;
    w.cars[2].wrecks = 3;
    try expectEqualStrings("WRECKS 3", text.standing_line(&b, &w, 2));
}

test "LINK lobby: LIVES and TIME rows only in LINK BATTLE, Up and Down skip the rest" {
    var rows: [6]text.LobbyRow = undefined;
    try expectEqual(@as(usize, 4), text.lobby_rows(.race, &rows));
    try expectEqual(@as(usize, 4), text.lobby_rows(.gc, &rows));
    try expectEqual(@as(usize, 6), text.lobby_rows(.battle, &rows));
    try expectEqual(text.LobbyRow.racer, text.lobby_move(.crews, 1, .race));
    try expectEqual(text.LobbyRow.lives, text.lobby_move(.crews, 1, .battle));
    try expectEqual(text.LobbyRow.racer, text.lobby_move(.mode, -1, .battle));
    try expectEqual(text.LobbyRow.mode, text.lobby_move(.racer, 1, .gc));
}

test "LINK lobby: the mode cycles RACE, GC, BATTLE; the track goes to the arena and back" {
    var r: net.Rules = .{ .track = 4 };
    var keep: u8 = 0;
    text.lobby_change(&r, .mode, 1, &keep);
    try expectEqual(world.Mode.gc, r.mode);
    try expectEqual(@as(u8, 4), r.track);
    text.lobby_change(&r, .mode, 1, &keep);
    try expectEqual(world.Mode.battle, r.mode);
    try expectEqual(@as(u8, 0), r.track);
    try expectEqualStrings(track.arenas[0].name, text.place_name(r));
    text.lobby_change(&r, .track, 1, &keep);
    try expect(r.track < track.arenas.len);
    text.lobby_change(&r, .mode, 1, &keep);
    try expectEqual(world.Mode.race, r.mode);
    try expectEqual(@as(u8, 4), r.track);
    try expectEqualStrings(track.tracks[4].name, text.place_name(r));
    text.lobby_change(&r, .mode, -1, &keep);
    try expectEqual(world.Mode.battle, r.mode);
    // LIVES to INF on TIME NONE: 3 minutes; TIME then skips NONE.
    r.lives = 9;
    r.minutes = 0;
    text.lobby_change(&r, .lives, 1, &keep);
    try expectEqual(@as(u8, 0), r.lives);
    try expectEqual(@as(u8, 3), r.minutes);
    for (0..8) |_| {
        text.lobby_change(&r, .time, 1, &keep);
        try expect(r.minutes != 0);
    }
    // CREWS 4, 2, 0 round.
    r.crews = 4;
    text.lobby_change(&r, .crews, 1, &keep);
    try expectEqual(@as(u8, 2), r.crews);
    text.lobby_change(&r, .crews, 1, &keep);
    try expectEqual(@as(u8, 0), r.crews);
    text.lobby_change(&r, .crews, 1, &keep);
    try expectEqual(@as(u8, 4), r.crews);
    // Whatever the host does, the five bytes decode to the same rules.
    try expect(std.meta.eql(r, net.Rules.decode(r.encode())));
}

test "a LINK BATTLE's agreed setup: the arena, LIVES and TIME; races keep the M5.1 setup" {
    const race = net.Race{ .id = 3, .rules = .{ .mode = .battle, .track = 7, .crews = 2, .lives = 5, .minutes = 0 }, .racers = .{ 1, 4 }, .seed = 99 };
    const s = net.setup_of(race);
    try expectEqual(world.Mode.battle, s.mode);
    try expect(s.track < track.arenas.len);
    try expectEqual(@as(u8, 5), s.lives);
    try expectEqual(@as(u8, 0), s.minutes);
    try expectEqual(@as(u8, 2), s.crews);
    // A race's setup carries the default lives and minutes (unused).
    const r2 = net.Race{ .id = 4, .rules = .{ .mode = .gc, .track = 2, .crews = 4, .lives = 9, .minutes = 5 }, .racers = .{ 0, 5 }, .seed = 7 };
    const s2 = net.setup_of(r2);
    try expectEqual(world.Mode.gc, s2.mode);
    try expectEqual(@as(u8, 2), s2.track);
    try expect(std.meta.eql(world.Setup{ .track = 2, .seed = 7, .humans = .{ 0, 5 }, .mode = .gc, .crews = 4 }, s2));
}
