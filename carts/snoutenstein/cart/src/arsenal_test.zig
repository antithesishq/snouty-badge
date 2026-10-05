//! Host tests of the M9 deathmatch arsenal (`arsenal.zig` wired into
//! `match.zig`): each weapon frags at its tuned rate, self-damage, pads
//! and their timers, Select cycling, the respawn loss, and a 16-bot match
//! that runs the same twice. Mini-levels are parsed at run time.
const std = @import("std");
const fixed = @import("fixed.zig");
const state = @import("state.zig");
const levels = @import("levels.zig");
const level_parse = @import("level_parse.zig");
const sim = @import("sim.zig");
const match = @import("match.zig");
const arsenal = @import("arsenal.zig");

const testing = std.testing;
const Fixed = fixed.Fixed;
const Buttons = state.Buttons;
const World = match.World;
const Level = levels.Level;

// Five pads (k = 0..4) and the Debugger (k = 5) between two spawns.
const pads_src =
    \\1111111111111
    \\1P.........P1
    \\1...........1
    \\1.@.@.@.@.@.1
    \\1.&.........1
    \\1111111111111
;

// A plain hall: spawns at (1, 1) facing east and (10, 1) facing west.
const hall_src =
    \\111111111111
    \\1P........P1
    \\1..........1
    \\1..........1
    \\111111111111
;

// A wall stub at (3, 1) right in front of the west spawn; a gnat in the
// east of the bottom row.
const stub_src =
    \\1111111111111
    \\1P.1........1
    \\1...........1
    \\1.........aP1
    \\1111111111111
;

const fire = [2]Buttons{ .{ .a = true }, .{} };
const idle = [2]Buttons{ .{}, .{} };

fn new_world(w: *World, st: *level_parse.Parsed, src: []const u8, bugs: bool) !Level {
    const L = try level_parse.parse_level(st, "t", src, 0);
    // 25 frags: no test ends the match by accident.
    match.init(w, &L, 0, .{ .frags = 4, .bugs = bugs }, 1234);
    return L;
}

fn run(w: *World, L: *const Level, in: [2]Buttons, n: usize) void {
    for (0..n) |_| match.step(w, L, in);
}

fn put(p: *state.Player, x: f32, y: f32) void {
    p.x = @intFromFloat(x * 65536.0);
    p.y = @intFromFloat(y * 65536.0);
}

fn arm(w: *World, i: usize, wp: state.Weapon) void {
    w.m.owned[i] |= arsenal.owned_bit(wp);
    w.m.players[i].weapon = wp;
    switch (wp) {
        .fuzzer => w.m.ammo_fuzzer[i] = arsenal.max_fuzzer,
        .fork_bomb => w.m.ammo_bomb[i] = arsenal.max_bomb,
        .ship_it => w.m.ammo_rocket[i] = arsenal.max_rocket,
        else => {},
    }
}

/// Steps until slot `i` dies; returns the steps taken (fails past `max`).
fn until_dead(w: *World, L: *const Level, in: [2]Buttons, i: usize, max: usize) !usize {
    var n: usize = 0;
    while (w.m.dead[i] == 0) : (n += 1) {
        if (n >= max) return error.TestUnexpectedResult;
        match.step(w, L, in);
    }
    return n;
}

test "pads start staggered along the rotation, rotate on pickup, come back after 15 s" {
    var st: level_parse.Parsed = undefined;
    var w: World = undefined;
    const L = try new_world(&w, &st, pads_src, false);
    try testing.expectEqual(@as(usize, 6), L.pickups.len);
    try testing.expectEqual([6]u8{ 4, 5, 6, 7, 2, 0 }, w.m.pad_item[0..6].*);
    // Onto pad 0 (2, 3): the FUZZER, selected, 50 rounds.
    put(&w.m.players[0], 2.5, 3.5);
    match.step(&w, &L, idle);
    try testing.expect(!state.pickup_present(&w.gs, 0));
    try testing.expectEqual(state.Weapon.fuzzer, w.m.players[0].weapon);
    try testing.expectEqual(arsenal.owned_bit(.fuzzer), w.m.owned[0]);
    try testing.expectEqual(arsenal.fuzzer_pickup, w.m.ammo_fuzzer[0]);
    try testing.expectEqual(arsenal.pad_respawn - 1, w.m.pickup_timer[0]);
    try testing.expectEqual(@as(u8, 5), w.m.pad_item[0]); // shows the fork bomb next
    run(&w, &L, idle, arsenal.pad_respawn - 2);
    try testing.expect(!state.pickup_present(&w.gs, 0));
    match.step(&w, &L, idle);
    try testing.expect(state.pickup_present(&w.gs, 0));
    // Still standing on it: taken again at once, the fork bomb this time
    // (newly owned: selected).
    match.step(&w, &L, idle);
    try testing.expectEqual(state.Weapon.fork_bomb, w.m.players[0].weapon);
    try testing.expectEqual(arsenal.bomb_pickup, w.m.ammo_bomb[0]);
    try testing.expectEqual(@as(u8, 6), w.m.pad_item[0]);
    // Pad 4 shows the spray: a spray can.
    put(&w.m.players[1], 10.5, 3.5);
    match.step(&w, &L, idle);
    try testing.expect(w.m.players[1].has_spray);
    try testing.expectEqual(state.Weapon.spray, w.m.players[1].weapon);
    try testing.expectEqual(@as(u8, 4), w.m.pad_item[4]); // wraps to the fuzzer
}

test "a pad weapon already owned gives ammo up to the cap, no reselect" {
    var st: level_parse.Parsed = undefined;
    var w: World = undefined;
    const L = try new_world(&w, &st, pads_src, false);
    w.m.owned[0] = arsenal.owned_bit(.fuzzer);
    w.m.ammo_fuzzer[0] = 140;
    _ = arsenal.take_pad(&w, 0, 0);
    try testing.expectEqual(arsenal.max_fuzzer, w.m.ammo_fuzzer[0]);
    try testing.expectEqual(state.Weapon.zapper, w.m.players[0].weapon);
    // A Garbage Collector taken twice is just owned.
    w.m.pad_item[1] = @backingInt(state.Weapon.gc);
    try testing.expectEqual(arsenal.pad_respawn, arsenal.take_pad(&w, 0, 1));
    try testing.expectEqual(state.Weapon.gc, w.m.players[0].weapon);
    w.m.players[0].weapon = .zapper;
    w.m.pad_item[1] = @backingInt(state.Weapon.gc);
    _ = arsenal.take_pad(&w, 0, 1);
    try testing.expectEqual(state.Weapon.zapper, w.m.players[0].weapon);
    try testing.expect(arsenal.has_ammo(&w.m, 0, .gc));
    try testing.expectEqual(@as(?u8, 40), arsenal.ammo(&w.m, 0)); // the zapper's
    w.m.players[0].weapon = .gc;
    try testing.expectEqual(@as(?u8, null), arsenal.ammo(&w.m, 0));
    w.m.players[0].weapon = .fuzzer;
    try testing.expectEqual(@as(?u8, 150), arsenal.ammo(&w.m, 0));
    _ = L;
}

test "the Debugger pad never rotates and comes back after 60 s" {
    var st: level_parse.Parsed = undefined;
    var w: World = undefined;
    const L = try new_world(&w, &st, pads_src, false);
    try testing.expectEqual(levels.PickupKind.debugger, L.pickups[5].kind);
    put(&w.m.players[0], 2.5, 4.5);
    match.step(&w, &L, idle);
    try testing.expect(w.m.players[0].has_debugger);
    try testing.expectEqual(state.Weapon.debugger, w.m.players[0].weapon);
    try testing.expectEqual(arsenal.debugger_respawn - 1, w.m.pickup_timer[5]);
    try testing.expectEqual(@as(u16, 3600), arsenal.respawn_ticks(.debugger));
    try testing.expectEqual(match.pickup_respawn, arsenal.respawn_ticks(.hotfix));
    put(&w.m.players[0], 4.5, 1.5);
    run(&w, &L, idle, arsenal.debugger_respawn - 1);
    try testing.expect(state.pickup_present(&w.gs, 5));
}

test "the FUZZER frags in 9 hits, 5 ticks apart" {
    var st: level_parse.Parsed = undefined;
    var w: World = undefined;
    const L = try new_world(&w, &st, hall_src, false);
    put(&w.m.players[1], 3.5, 1.5); // 2 cells: the jitter cannot miss
    arm(&w, 0, .fuzzer);
    match.step(&w, &L, fire);
    try testing.expectEqual(@as(i16, 100 - arsenal.fuzzer_damage * match.pvp_scale), w.m.players[1].hp);
    const n = try until_dead(&w, &L, fire, 1, 100);
    try testing.expectEqual(@as(usize, 8 * arsenal.fuzzer_rate), n);
    try testing.expectEqual(@as(i16, 1), w.m.frags[0]);
    try testing.expectEqual(@as(u16, 9), w.m.hits[0]);
    try testing.expectEqual(@as(u16, 9), w.m.shots[0]);
    try testing.expectEqual(arsenal.max_fuzzer - 9, w.m.ammo_fuzzer[0]);
}

test "the FUZZER's jitter misses some shots at range" {
    var st: level_parse.Parsed = undefined;
    var w: World = undefined;
    const L = try new_world(&w, &st, hall_src, false);
    arm(&w, 0, .fuzzer); // 9 cells: +-4 degrees is +-0.63 cells
    run(&w, &L, fire, 20 * arsenal.fuzzer_rate);
    try testing.expectEqual(@as(u16, 20), w.m.shots[0]);
    try testing.expect(w.m.hits[0] > 3 and w.m.hits[0] < 18);
}

test "SHIP IT: a direct hit takes 96, a splash off the wall finishes" {
    var st: level_parse.Parsed = undefined;
    var w: World = undefined;
    const L = try new_world(&w, &st, hall_src, false);
    put(&w.m.players[1], 5.5, 1.5);
    arm(&w, 0, .ship_it);
    match.step(&w, &L, fire);
    try testing.expectEqual(arsenal.kind_rocket, w.m.dm_shots[0].kind);
    try testing.expectEqual(arsenal.max_rocket - 1, w.m.ammo_rocket[0]);
    var n: usize = 0;
    while (w.m.dm_shots[0].kind == arsenal.kind_rocket) : (n += 1) {
        try testing.expect(n < 30);
        match.step(&w, &L, idle);
    }
    try testing.expectEqual(arsenal.kind_blast, w.m.dm_shots[0].kind);
    try testing.expectEqual(@as(u8, 1), w.m.dm_shots[0].aux);
    try testing.expectEqual(arsenal.blast_ticks, w.m.dm_shots[0].ttl);
    try testing.expectEqual(@as(i16, 100 - arsenal.rocket_damage * match.pvp_scale), w.m.players[1].hp);
    try testing.expectEqual(@as(i16, 100), w.m.players[0].hp); // 4 cells away
    try testing.expectEqual(@as(u16, 1), w.m.hits[0]);
    // The blast shows for blast_ticks, then the entry is free.
    run(&w, &L, idle, arsenal.blast_ticks);
    try testing.expectEqual(arsenal.kind_none, w.m.dm_shots[0].kind);
    // Off to the side of the east wall: the rocket misses the body and the
    // blast on the wall reaches it.
    put(&w.m.players[1], 10.5, 2.5);
    run(&w, &L, idle, 50);
    match.step(&w, &L, fire);
    const k = try until_dead(&w, &L, idle, 1, 60);
    try testing.expect(k > 30); // 9.5 cells at 0.25
    try testing.expectEqual(@as(i16, 1), w.m.frags[0]);
    try testing.expectEqual(@as(u16, 2), w.m.hits[0]);
}

test "your own rocket at point-blank is a self-frag" {
    var st: level_parse.Parsed = undefined;
    var w: World = undefined;
    const L = try new_world(&w, &st, hall_src, false);
    arm(&w, 0, .ship_it);
    w.m.players[0].angle = fixed.deg(180); // the west wall, 0.5 away
    w.m.players[0].hp = 60;
    match.step(&w, &L, fire);
    _ = try until_dead(&w, &L, idle, 0, 10);
    try testing.expectEqual(@as(i16, -1), w.m.frags[0]);
    try testing.expectEqual(@as(u8, 0), w.m.killer);
    try testing.expectEqual(@as(u16, 0), w.m.hits[0]);
}

test "a rocket blows up on a bug" {
    var st: level_parse.Parsed = undefined;
    var w: World = undefined;
    const L = try new_world(&w, &st, stub_src, true);
    put(&w.m.players[0], 1.5, 3.5);
    w.m.players[0].angle = 0;
    put(&w.m.players[1], 6.5, 1.5); // off the rocket's row, out of the splash
    arm(&w, 0, .ship_it);
    match.step(&w, &L, fire);
    var n: usize = 0;
    while (w.m.dm_shots[0].kind == arsenal.kind_rocket) : (n += 1) {
        try testing.expect(n < 40);
        match.step(&w, &L, idle);
    }
    try testing.expectEqual(@as(u16, 1), w.gs.kills);
    try testing.expect(w.m.dm_shots[0].x < fixed.from_float(10.5));
}

test "FORK BOMB: bounces off a wall, blows after the fuse, hurts the thrower" {
    var st: level_parse.Parsed = undefined;
    var w: World = undefined;
    const L = try new_world(&w, &st, stub_src, false);
    arm(&w, 0, .fork_bomb);
    w.m.players[0].angle = 0; // the stub 1.5 cells east
    w.m.players[0].hp = 60;
    match.step(&w, &L, fire);
    try testing.expectEqual(arsenal.kind_bomb, w.m.dm_shots[0].kind);
    try testing.expectEqual(arsenal.bomb_fuse, w.m.dm_shots[0].ttl);
    var max_x: Fixed = 0;
    var bounced = false;
    for (0..arsenal.bomb_fuse - 1) |_| {
        match.step(&w, &L, idle);
        const b = w.m.dm_shots[0];
        try testing.expectEqual(arsenal.kind_bomb, b.kind);
        max_x = @max(max_x, b.x);
        if (b.vx < 0) bounced = true;
    }
    try testing.expect(bounced);
    try testing.expect(max_x < fixed.from_int(3));
    try testing.expect(max_x > fixed.from_float(2.8));
    try testing.expectEqual(@as(i16, 60), w.m.players[0].hp);
    match.step(&w, &L, idle);
    try testing.expectEqual(arsenal.kind_blast, w.m.dm_shots[0].kind);
    try testing.expectEqual(@as(u8, 0), w.m.dm_shots[0].aux);
    // Back near the thrower: more than 60 HP of the 90 at the centre.
    try testing.expectEqual(match.death_ticks, w.m.dead[0]);
    try testing.expectEqual(@as(i16, -1), w.m.frags[0]);
    try testing.expectEqual(@as(i16, 0), w.m.frags[1]);
}

test "FORK BOMB: a foe beside it is fragged, a teammate is spared" {
    var st: level_parse.Parsed = undefined;
    var w: World = undefined;
    const L = try level_parse.parse_level(&st, "t", hall_src, 0);
    var team: [16]u8 = @splat(0);
    team[1] = 1;
    match.init_n(&w, &L, 0, .{ .frags = 4, .teams = 2 }, 0b111, &team, 9);
    arm(&w, 0, .fork_bomb);
    put(&w.m.players[0], 1.5, 1.5);
    w.m.players[0].angle = 0;
    // Where the bomb comes to rest (2.88 cells): a foe and a teammate.
    put(&w.m.players[1], 4.4, 2.0);
    put(&w.m.players[2], 4.4, 1.0);
    var in: [16]Buttons = @splat(.{});
    in[0].a = true;
    match.step_n(&w, &L, &in);
    in[0].a = false;
    for (0..arsenal.bomb_fuse) |_| match.step_n(&w, &L, &in);
    try testing.expectEqual(arsenal.kind_blast, w.m.dm_shots[0].kind);
    try testing.expect(w.m.players[1].hp < 40);
    try testing.expectEqual(@as(u8, 0), w.m.last_hit[1]);
    try testing.expectEqual(@as(i16, 100), w.m.players[2].hp);
    try testing.expectEqual(@as(u16, 1), w.m.hits[0]);
}

test "GARBAGE COLLECTOR: spins up, then shreds every 4 ticks; slows walking" {
    var st: level_parse.Parsed = undefined;
    var w: World = undefined;
    const L = try new_world(&w, &st, hall_src, false);
    arm(&w, 0, .gc);
    put(&w.m.players[1], 2.3, 1.5); // 0.8 cells in front
    run(&w, &L, fire, arsenal.gc_spinup);
    try testing.expectEqual(arsenal.gc_spinup, w.m.gc_spin[0]);
    try testing.expectEqual(@as(i16, 100), w.m.players[1].hp);
    try testing.expectEqual(@as(u16, 0), w.m.shots[0]);
    match.step(&w, &L, fire);
    try testing.expectEqual(@as(i16, 100 - arsenal.gc_damage * match.pvp_scale), w.m.players[1].hp);
    const n = try until_dead(&w, &L, fire, 1, 60);
    try testing.expectEqual(@as(usize, 8 * arsenal.gc_rate), n);
    try testing.expectEqual(@as(i16, 1), w.m.frags[0]);
    try testing.expectEqual(@as(u16, 9), w.m.shots[0]);
    // Releasing A spins it down at once; walking while it spins is slower.
    match.step(&w, &L, idle);
    try testing.expectEqual(@as(u8, 0), w.m.gc_spin[0]);
    try testing.expectEqual(fixed.one, arsenal.walk_scale(&w.m, 0));
    w.m.players[0].angle = fixed.deg(90);
    const y0 = w.m.players[0].y;
    match.step(&w, &L, .{ .{ .up = true, .a = true }, .{} });
    match.step(&w, &L, .{ .{ .up = true, .a = true }, .{} });
    try testing.expectEqual(y0 + sim.walk_speed + fixed.mul(sim.walk_speed, arsenal.gc_slow), w.m.players[0].y);
}

test "Select cycles every owned weapon with ammo in enum order" {
    var st: level_parse.Parsed = undefined;
    var w: World = undefined;
    const L = try new_world(&w, &st, hall_src, false);
    w.m.owned[0] = arsenal.owned_bit(.fuzzer) | arsenal.owned_bit(.ship_it) | arsenal.owned_bit(.gc);
    w.m.ammo_fuzzer[0] = 10; // ship it owned but empty
    const want = [_]state.Weapon{ .fuzzer, .gc, .swatter, .zapper, .fuzzer };
    for (want) |wp| {
        match.step(&w, &L, .{ .{ .select = true }, .{} });
        try testing.expectEqual(wp, w.m.players[0].weapon);
        match.step(&w, &L, .{ .{ .select = true }, .{} }); // held: no change
        try testing.expectEqual(wp, w.m.players[0].weapon);
        match.step(&w, &L, idle);
    }
    try testing.expect(!arsenal.has_ammo(&w.m, 0, .ship_it));
    try testing.expect(!arsenal.has_ammo(&w.m, 0, .fork_bomb));
    try testing.expect(arsenal.has_ammo(&w.m, 0, .fuzzer));
    try testing.expect(!arsenal.has_ammo(&w.m, 1, .fuzzer));
}

test "a respawn loses the arsenal" {
    var st: level_parse.Parsed = undefined;
    var w: World = undefined;
    const L = try new_world(&w, &st, hall_src, false);
    arm(&w, 1, .fuzzer);
    arm(&w, 1, .gc);
    w.m.gc_spin[1] = 3;
    w.m.players[1].hp = 0;
    match.step(&w, &L, idle);
    try testing.expectEqual(@as(u8, 0), w.m.gc_spin[1]);
    while (w.m.dead[1] > 0) match.step(&w, &L, idle);
    try testing.expectEqual(@as(u8, 0), w.m.owned[1]);
    try testing.expectEqual(@as(u8, 0), w.m.ammo_fuzzer[1]);
    try testing.expectEqual(state.Weapon.zapper, w.m.players[1].weapon);
}

test "16 armed players (8 bots, 8 random) in every arena: the same World twice" {
    for (0..levels.arena_indices.len) |a| {
        var hs: [2]u32 = undefined;
        var blasts: u32 = 0;
        for (&hs) |*h| {
            var w: World = undefined;
            match.init_party(&w, .{ .arena = @intCast(a), .frags = 4, .bugs = true }, 0xFFFF, null, 4242);
            w.m.bots = 0xFF00;
            for (0..16) |i| {
                arm(&w, i, .fuzzer);
                arm(&w, i, .fork_bomb);
                arm(&w, i, .gc);
                arm(&w, i, .ship_it);
                w.m.players[i].weapon = @fromBackingInt(@intCast(4 + i % 4));
            }
            var in: [16]Buttons = @splat(.{});
            var x: u32 = 77;
            for (0..2400) |_| {
                for (in[0..8]) |*b| {
                    x ^= x << 13;
                    x ^= x >> 17;
                    x ^= x << 5;
                    // Mostly walking and firing, now and then Select.
                    b.* = match.buttons_of(@truncate((x & 0x3B) | 0x10 | (if ((x >> 20) & 31 == 0) match.bit_select else 0)));
                }
                match.step_n(&w, match.arena_level(@intCast(a)), &in);
                for (w.m.dm_shots) |sh| {
                    if (sh.kind == arsenal.kind_blast and sh.ttl == arsenal.blast_ticks) blasts += 1;
                }
            }
            h.* = match.hash(&w);
        }
        try testing.expectEqual(hs[0], hs[1]);
        try testing.expect(blasts > 0);
    }
}
