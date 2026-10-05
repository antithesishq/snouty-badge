//! M8 party deathmatch: the N-player core in match.zig (up to 16 slots,
//! teams, spawns, hand-over to bot.zig, the end rules), pure host tests.
//! `zig test cart/src/match_party_test.zig` runs them alone; host_tests.zig
//! pulls them into `zig build test`.
const std = @import("std");
const fixed = @import("fixed.zig");
const state = @import("state.zig");
const levels = @import("levels.zig");
const level_parse = @import("level_parse.zig");
const sim = @import("sim.zig");
const match = @import("match.zig");

const testing = std.testing;
const World = match.World;
const Buttons = state.Buttons;
const Level = levels.Level;
const max_players = state.max_players;

/// Print the measurements (sizes, ticks to the limit, host ns per tick).
const report = false;

const idle: [max_players]Buttons = @splat(.{});

// A 14x7 room, four spawns in the corners, a charge in the middle.
const room_src =
    \\11111111111111
    \\1P..........P1
    \\1............1
    \\1......+.....1
    \\1............1
    \\1P..........P1
    \\11111111111111
;

fn room(st: *level_parse.Parsed) !Level {
    return level_parse.parse_level(st, "room", room_src, 0);
}

fn place(w: *World, slot: usize, x: f32, y: f32, angle: fixed.Angle) void {
    const p = &w.m.players[slot];
    p.x = @intFromFloat(x * 65536.0);
    p.y = @intFromFloat(y * 65536.0);
    p.angle = angle;
}

test "Match is padding-free and sized for 16" {
    var n: usize = 0;
    inline for (@typeInfo(state.Match).@"struct".field_types) |ft| n += @sizeOf(ft);
    try testing.expectEqual(n, @sizeOf(state.Match));
    // M8 812 B; M9 arsenal +752 (per-slot ammo/owned/spin, pad items, 32 DmShots).
    try testing.expectEqual(@as(usize, 1564), @sizeOf(state.Match));
    try testing.expectEqual(@sizeOf(state.GameState) + @sizeOf(state.Match), @sizeOf(World));
    try testing.expectEqual(@as(usize, 16), @typeInfo(@TypeOf(@as(state.Match, undefined).players)).array.len);
    if (report) std.debug.print("\nMatch {d} B, World {d} B, GameState {d} B\n", .{ @sizeOf(state.Match), @sizeOf(World), @sizeOf(state.GameState) });
}

test "Rules: 2-byte round trip, and byte 0 is M7's byte for M7's values" {
    for (0..levels.arena_indices.len) |a| {
        for (0..match.frag_limits.len) |f| {
            for ([2]bool{ false, true }) |bugs| {
                for (match.team_modes) |t| {
                    const r: match.Rules = .{ .arena = @intCast(a), .frags = @intCast(f), .bugs = bugs, .teams = t };
                    try testing.expectEqual(r, match.Rules.decode2(r.encode2()));
                    const b = r.encode2();
                    try testing.expectEqual(@as(u8, 0), b[0] & 0xC0);
                    try testing.expectEqual(@as(u8, 0), b[1] & 0xFC);
                    if (f < 4) {
                        // M7: arena 0-1, frags 2-3, bugs 4.
                        const m7: u8 = @as(u8, @intCast(a)) | (@as(u8, @intCast(f)) << 2) | (@as(u8, @intFromBool(bugs)) << 4);
                        try testing.expectEqual(m7, b[0]);
                    }
                }
            }
        }
    }
    try testing.expectEqual(@as(u8, 25), (match.Rules{ .frags = 4 }).frag_limit());
    // Junk decodes to defaults, never out of range.
    const j = match.Rules.decode2(.{ 0xFF, 0xFF });
    try testing.expect(j.arena < levels.arena_indices.len);
    try testing.expectEqual(@as(u8, 0), j.teams);
    try testing.expectEqual(@as(u8, 25), j.frag_limit());
}

test "start positions: spread over the spawns, then the farthest rule" {
    var st: level_parse.Parsed = undefined;
    const L = try room(&st);
    var w: World = undefined;
    // Two players on four spawns start two apart (the stride).
    for (0..8) |seed| {
        match.init_n(&w, &L, 0, .{}, 0b11, null, @intCast(seed));
        const a = w.m.players[0];
        const b = w.m.players[1];
        try testing.expect(a.x != b.x or a.y != b.y);
    }
    // Six players (sparse slots) on four spawns: the first four on distinct
    // spawns, everyone on a spawn cell, the absent slots zero HP.
    const present: u16 = 0b1010_1100_0110_0000;
    match.init_n(&w, &L, 0, .{}, present, null, 99);
    try testing.expectEqual(present, w.m.present);
    var seen: u16 = 0;
    var k: usize = 0;
    for (0..max_players) |i| {
        const p = w.m.players[i];
        if (!w.m.is_present(i)) {
            try testing.expectEqual(@as(i16, 0), p.hp);
            try testing.expect(!w.m.alive(i));
            continue;
        }
        try testing.expectEqual(@as(i16, 100), p.hp);
        var sp_i: ?usize = null;
        for (L.spawns, 0..) |sp, n| {
            if (fixed.from_int(sp.x) + fixed.half == p.x and fixed.from_int(sp.y) + fixed.half == p.y) sp_i = n;
        }
        try testing.expect(sp_i != null);
        if (k < 4) {
            try testing.expect(seen & (@as(u16, 1) << @intCast(sp_i.?)) == 0);
            seen |= @as(u16, 1) << @intCast(sp_i.?);
        }
        k += 1;
    }
    try testing.expectEqual(@as(u16, 0xF), seen);
    try testing.expectEqual(w.m.players[5], w.gs.player); // the first present slot
}

test "spawn choice: farthest from the nearest living foe, teammates and the dead ignored" {
    var st: level_parse.Parsed = undefined;
    const L = try room(&st);
    var w: World = undefined;
    match.init_n(&w, &L, 0, .{ .teams = 2 }, 0b1111, null, 1);
    // Teams: 0 and 2 vs 1 and 3. Slot 0 respawns.
    w.m.players[0].hp = 0;
    // A foe near the NW corner, another near the SW: the east side is far.
    place(&w, 1, 2.5, 1.5, 0);
    place(&w, 3, 2.5, 5.5, 0);
    // A teammate on the NE spawn: not a foe, but the spawn is taken.
    place(&w, 2, 12.5, 1.5, 0);
    var sp = match.pick_spawn(&L, &w.m, 0);
    try testing.expectEqual(@as(u8, 12), sp.x);
    try testing.expectEqual(@as(u8, 5), sp.y); // SE, not the taken NE
    // Dead foes do not count: slot 3 dies beside the SE spawn, the
    // teammate on NE dies too (no longer taking it). Counting the corpse
    // would give NE; ignoring it, SE is the farthest from slot 1.
    place(&w, 3, 11.5, 5.5, 0);
    w.m.dead[3] = 5;
    w.m.dead[2] = 5;
    sp = match.pick_spawn(&L, &w.m, 0);
    try testing.expectEqual(@as(u8, 12), sp.x);
    try testing.expectEqual(@as(u8, 5), sp.y);
    // Every spawn taken (team 0 = 0, 2, 4 on NW and SW; team 1 = 1, 3 on
    // NE and SE): the farthest anyway; NW and SW tie at 11 cells from the
    // nearest foe, the lower index (NW) wins.
    match.init_n(&w, &L, 0, .{ .teams = 2 }, 0b11111, null, 1);
    place(&w, 2, 1.5, 1.5, 0);
    place(&w, 1, 12.5, 1.5, 0);
    place(&w, 4, 1.5, 5.5, 0);
    place(&w, 3, 12.5, 5.5, 0);
    w.m.players[0].hp = 0;
    sp = match.pick_spawn(&L, &w.m, 0);
    try testing.expectEqual(@as(u8, 1), sp.x);
    try testing.expectEqual(@as(u8, 1), sp.y);
}

test "teams: no friendly fire, shots pass a teammate, a self-burst still costs" {
    var st: level_parse.Parsed = undefined;
    const L = try room(&st);
    var w: World = undefined;
    match.init_n(&w, &L, 0, .{ .teams = 2 }, 0b111, null, 1);
    // Team 0 = slots 0, 2; team 1 = slot 1. All in row 3, facing east.
    place(&w, 0, 2.5, 3.5, 0);
    place(&w, 2, 4.5, 3.5, 0);
    place(&w, 1, 8.5, 3.5, 0);
    var in = idle;
    in[0] = .{ .a = true };
    match.step_n(&w, &L, &in);
    try testing.expectEqual(@as(i16, 100), w.m.players[2].hp);
    try testing.expectEqual(@as(i16, 100 - 3 * match.pvp_scale), w.m.players[1].hp);
    try testing.expectEqual(@as(u8, 0), w.m.last_hit[1]);
    try testing.expectEqual(@as(u16, 1), w.m.hits[0]);
    // The teammate fires back west through... nothing: slot 0 is a teammate.
    in = idle;
    in[2] = .{ .a = true };
    w.m.players[2].angle = fixed.deg(180);
    match.step_n(&w, &L, &in);
    try testing.expectEqual(@as(i16, 100), w.m.players[0].hp);
    try testing.expectEqual(@as(u16, 1), w.m.shots[2]);
    try testing.expectEqual(@as(u16, 0), w.m.hits[2]);
    // A Debugger bolt does not burst on a teammate, and its burst near the
    // owner spares the teammate standing beside it but not the owner.
    match.init_n(&w, &L, 0, .{ .teams = 2 }, 0b111, null, 1);
    place(&w, 0, 1.5, 3.5, fixed.deg(180)); // facing the west wall
    place(&w, 2, 1.5, 4.2, 0);
    place(&w, 1, 10.5, 3.5, 0);
    const p = &w.m.players[0];
    p.has_debugger = true;
    p.ammo_debugger = 9;
    p.weapon = .debugger;
    p.hp = 50;
    in = idle;
    in[0] = .{ .a = true };
    match.step_n(&w, &L, &in);
    var n: usize = 0;
    while (w.m.dead[0] == 0) : (n += 1) {
        try testing.expect(n < 20);
        match.step_n(&w, &L, &idle);
    }
    try testing.expectEqual(@as(i16, 100), w.m.players[2].hp);
    try testing.expectEqual(@as(i16, -1), w.m.frags[0]);
    try testing.expectEqual(@as(i16, -1), w.m.team_frags[0]);
    try testing.expectEqual(@as(i16, 0), w.m.team_frags[1]);
    try testing.expectEqual(@as(u8, 0), w.m.killer);
    // FFA: the same zapper shot hits the player in front, not the one behind.
    match.init_n(&w, &L, 0, .{}, 0b111, null, 1);
    place(&w, 0, 2.5, 3.5, 0);
    place(&w, 2, 4.5, 3.5, 0);
    place(&w, 1, 8.5, 3.5, 0);
    in = idle;
    in[0] = .{ .a = true };
    match.step_n(&w, &L, &in);
    try testing.expectEqual(@as(i16, 100 - 3 * match.pvp_scale), w.m.players[2].hp);
    try testing.expectEqual(@as(i16, 100), w.m.players[1].hp);
}

test "hand-over: the leaver's slot becomes a bot, frags kept; the last human wins" {
    var st: level_parse.Parsed = undefined;
    const L = try room(&st);
    var w: World = undefined;
    match.init_n(&w, &L, 0, .{}, 0b1011, null, 5);
    w.m.frags[1] = 3;
    match.hand_over(&w, 1);
    try testing.expectEqual(@as(u16, 0b0010), w.m.bots);
    try testing.expect(!w.m.over);
    try testing.expectEqual(@as(i16, 3), w.m.frags[1]);
    // The bot plays: its slot ignores the input it is given and moves on its own.
    var in = idle;
    in[1] = .{ .left = true }; // ignored
    const a0 = w.m.players[1].angle;
    const x0 = w.m.players[1].x;
    const y0 = w.m.players[1].y;
    for (0..120) |_| match.step_n(&w, &L, &in);
    const p1 = w.m.players[1];
    try testing.expect(p1.x != x0 or p1.y != y0 or p1.angle != a0);
    // Absent and repeated hand-overs do nothing.
    match.hand_over(&w, 2);
    match.hand_over(&w, 1);
    try testing.expectEqual(@as(u16, 0b0010), w.m.bots);
    try testing.expect(!w.m.over);
    // Slot 3 leaves: slot 0 is the one human left, a forfeit win.
    match.hand_over(&w, 3);
    try testing.expect(w.m.over and w.m.forfeit);
    try testing.expectEqual(@as(u8, 0), w.m.winner);
    const h = match.hash(&w);
    for (0..30) |_| match.step_n(&w, &L, &in);
    try testing.expectEqual(h, match.hash(&w));
    // Teams: when every human left is on one team, that team wins.
    match.init_n(&w, &L, 0, .{ .teams = 2 }, 0b1111, null, 5);
    match.hand_over(&w, 1); // team 1 keeps slot 3
    try testing.expect(!w.m.over);
    match.hand_over(&w, 3); // team 0's humans (0, 2) are all that is left
    try testing.expect(w.m.over and w.m.forfeit);
    try testing.expectEqual(state.team_win | 0, w.m.winner);
    // The M7 adapter: G.hand_over is the forfeit it always was.
    match.init(&w, &L, 0, .{}, 5);
    match.G.hand_over(&w, 0);
    try testing.expectEqual(@as(u8, 1), w.m.winner);
    try testing.expect(w.m.forfeit);
}

test "frag limit: the top score wins, a shared top score draws, teams by team total" {
    var st: level_parse.Parsed = undefined;
    const L = try room(&st);
    var w: World = undefined;
    // FFA, frags 5: slots 0 and 2 frag slot 1 on the same tick, but 2 was
    // at 3, so 0 (4 -> 5) wins alone ... both shooters credited? No: one
    // victim has one killer, so set up two victims.
    match.init_n(&w, &L, 0, .{ .frags = 0 }, 0b1111, null, 1);
    place(&w, 0, 1.5, 1.5, 0);
    place(&w, 1, 4.5, 1.5, 0);
    place(&w, 2, 1.5, 5.5, 0);
    place(&w, 3, 4.5, 5.5, 0);
    w.m.frags[0] = 4;
    w.m.frags[2] = 4;
    w.m.players[1].hp = 18;
    w.m.players[3].hp = 18;
    var in = idle;
    in[0] = .{ .a = true };
    in[2] = .{ .a = true };
    match.step_n(&w, &L, &in);
    try testing.expect(w.m.over and !w.m.forfeit);
    try testing.expectEqual(state.no_one, w.m.winner); // 5 and 5: a draw
    // The same with slot 2 one short: slot 0 wins.
    match.init_n(&w, &L, 0, .{ .frags = 0 }, 0b1111, null, 1);
    place(&w, 0, 1.5, 1.5, 0);
    place(&w, 1, 4.5, 1.5, 0);
    place(&w, 2, 1.5, 5.5, 0);
    place(&w, 3, 4.5, 5.5, 0);
    w.m.frags[0] = 4;
    w.m.frags[2] = 3;
    w.m.players[1].hp = 18;
    w.m.players[3].hp = 18;
    match.step_n(&w, &L, &in);
    try testing.expect(w.m.over);
    try testing.expectEqual(@as(u8, 0), w.m.winner);
    // Teams (2): team 0 = {0, 2}, team 1 = {1, 3}. Team totals count, not
    // players: 0 and 2 at 2 each, one more frag makes 5.
    match.init_n(&w, &L, 0, .{ .frags = 0, .teams = 2 }, 0b1111, null, 1);
    place(&w, 0, 1.5, 1.5, 0);
    place(&w, 1, 4.5, 1.5, 0);
    place(&w, 2, 1.5, 5.5, 0);
    place(&w, 3, 9.5, 5.5, 0);
    w.m.frags[0] = 2;
    w.m.frags[2] = 2;
    w.m.team_frags[0] = 4;
    w.m.players[1].hp = 18;
    in = idle;
    in[0] = .{ .a = true };
    match.step_n(&w, &L, &in);
    try testing.expect(w.m.over);
    try testing.expectEqual(state.team_win | 0, w.m.winner);
    try testing.expectEqual(@as(i16, 5), w.m.team_frags[0]);
    try testing.expectEqual(@as(i16, 3), w.m.frags[0]);
}

test "a bug targets the nearest living player of many" {
    const src =
        \\1111111111111
        \\1P....a....P1
        \\1...........1
        \\1P.........P1
        \\1111111111111
    ;
    var st: level_parse.Parsed = undefined;
    const L = try level_parse.parse_level(&st, "bugroom", src, 0);
    var w: World = undefined;
    match.init_n(&w, &L, 0, .{ .bugs = true }, 0b1111_0000, null, 3);
    // Slot 6 right next to the gnat; the others far.
    for (4..8) |i| place(&w, i, 1.5, 3.5, 0);
    place(&w, 5, 11.5, 3.5, 0);
    place(&w, 6, 7.5, 1.5, fixed.deg(180));
    place(&w, 7, 11.5, 1.5, 0);
    var n: usize = 0;
    while (w.m.players[6].hp == 100 and n < 600) : (n += 1) match.step_n(&w, &L, &idle);
    try testing.expect(w.m.players[6].hp < 100);
    try testing.expectEqual(state.by_bug, w.m.last_hit[6]);
    for ([_]usize{ 4, 5, 7 }) |i| try testing.expectEqual(@as(i16, 100), w.m.players[i].hp);
}

/// `bots` slots of `present` are bot.zig; the rest get the same
/// pseudo-random bytes in both Worlds. Steps `a` and `b` side by side and
/// checks their hashes every 64 ticks; returns the ticks run.
fn party(a: *World, b: *World, L: *const Level, bots: u16, max_ticks: u32) !u32 {
    std.debug.assert(L == &levels.all[a.gs.level]);
    a.m.bots = bots;
    b.m.bots = bots;
    var x: u32 = 0x1234_5678;
    var t: u32 = 0;
    while (!a.m.over and t < max_ticks) : (t += 1) {
        var in: [max_players]u8 = @splat(0);
        for (&in) |*v| {
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            v.* = @truncate((x & 0x3B) | 0x01);
        }
        match.GN.simulate(a, &in, a.m.present);
        match.GN.simulate(b, &in, b.m.present);
        if (t % 64 == 0) try testing.expectEqual(match.GN.hash(a), match.GN.hash(b));
    }
    try testing.expectEqual(match.GN.hash(a), match.GN.hash(b));
    try testing.expect(std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b)));
    return t;
}

fn check_totals(m: *const state.Match) !void {
    if (m.teams == 0) return;
    var sum: [state.max_teams]i16 = @splat(0);
    for (0..max_players) |i| {
        if (m.is_present(i)) sum[m.team[i]] += m.frags[i];
    }
    try testing.expectEqual(sum, m.team_frags);
}

test "16 bots, FFA, bugs on: to the frag limit, two Worlds in sync" {
    var a: World = undefined;
    var b: World = undefined;
    @memset(std.mem.asBytes(&b), 0x5A);
    const rules: match.Rules = .{ .arena = 1, .frags = 0, .bugs = true };
    match.GN.start(&a, rules.encode2(), 0xFFFF, null, 42);
    match.GN.start(&b, rules.encode2(), 0xFFFF, null, 42);
    const ticks = try party(&a, &b, match.arena_level(1), 0xFFFF, 60 * 60 * 10);
    try testing.expect(a.m.over and !a.m.forfeit);
    var top: i16 = -100;
    for (a.m.frags) |f| top = @max(top, f);
    try testing.expect(top >= 5);
    if (a.m.winner != state.no_one) try testing.expectEqual(top, a.m.frags[a.m.winner]);
    var deaths: u32 = 0;
    var shots: u32 = 0;
    for (0..max_players) |i| {
        deaths += a.m.deaths[i];
        shots += a.m.shots[i];
    }
    try testing.expect(shots > 0);
    if (report) std.debug.print("\n16 bots FFA Build Farm DM, bugs on: {d} ticks, winner {d}, deaths {d}, shots {d}\n", .{ ticks, a.m.winner, deaths, shots });
}

test "16 players in 4 teams, half bots: to the team frag limit, in sync" {
    var a: World = undefined;
    var b: World = undefined;
    const rules: match.Rules = .{ .arena = 0, .frags = 1, .bugs = false, .teams = 4 };
    match.GN.start(&a, rules.encode2(), 0xFFFF, null, 7);
    b = a;
    for (0..max_players) |i| try testing.expectEqual(@as(u8, @intCast(i % 4)), a.m.team[i]);
    const ticks = try party(&a, &b, match.arena_level(0), 0x00FF, 60 * 60 * 15);
    try testing.expect(a.m.over and !a.m.forfeit);
    try check_totals(&a.m);
    try testing.expect(a.m.winner == state.no_one or a.m.winner & state.team_win != 0);
    var top: i16 = -100;
    for (a.m.team_frags) |f| top = @max(top, f);
    try testing.expect(top >= 10);
    if (a.m.winner != state.no_one) try testing.expectEqual(top, a.m.team_frags[a.m.winner & 3]);
    if (report) std.debug.print("\n16 players 4 teams Server Room: {d} ticks, winner {x}, team frags {any}\n", .{ ticks, a.m.winner, a.m.team_frags });
}

test "a hand-over mid-match lands the same in both Worlds" {
    var a: World = undefined;
    var b: World = undefined;
    const rules: match.Rules = .{ .arena = 0, .frags = 2, .bugs = true, .teams = 2 };
    match.GN.start(&a, rules.encode2(), 0b0011_1111, null, 9);
    b = a;
    _ = try party(&a, &b, match.arena_level(0), 0, 600);
    match.GN.hand_over(&a, 4);
    match.GN.hand_over(&b, 4);
    _ = try party(&a, &b, match.arena_level(0), 0b1_0000, 1200);
    try testing.expectEqual(@as(u16, 0b1_0000), a.m.bots);
    try check_totals(&a.m);
}
