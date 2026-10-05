//! BATTLE, `KILL -9` (SPEC 8.3, M6): the arena's data and the rules on
//! The Sandbox. Track A's host tests.
const std = @import("std");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const track = @import("track.zig");
const sim = @import("sim.zig");
const battle = @import("battle.zig");
const racers = @import("racers.zig");
const ai = @import("ai.zig");

const World = world.World;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

fn new_round(lives: u8, minutes: u8, seed: u32, human: u8) World {
    var w: World = undefined;
    sim.reset(&w, .{ .mode = .battle, .track = 0, .seed = seed, .lives = lives, .minutes = minutes, .humans = .{ human, world.no_human } });
    return w;
}

fn run_countdown(w: *World) void {
    while (w.phase == .countdown) sim.simulate(w, .{ 0, 0 });
}

test "The Sandbox loads: map, pads, spawns and the navigation field" {
    const t = track.arenas[0];
    track.select(t);
    const a = &track.arena;
    try expectEqual(@as(u8, 6), a.spawn_n);
    try expectEqual(@as(u8, 8), track.crate_n);
    try expect(a.node_n > 8 and a.node_n <= track.nav_max);
    try expectEqual(@as(usize, @as(usize, a.node_n) * a.node_n), a.next.len);
    try expectEqual(@as(u8, 32), a.grid);
    for (a.spawns[0..a.spawn_n]) |s| try expectEqual(track.Attr.surface, t.attr_at(s.x, s.y));
    for (track.crate_spots[0..track.crate_n]) |p| try expectEqual(track.Attr.surface, t.attr_at(p.x, p.y));
    for (a.nodes[0..a.node_n], 0..) |n, k| {
        const at = t.attr_at(n.x, n.y);
        try expect(at == .surface or at == .bay);
        // Every node reaches every other through the next-hop table.
        for (0..a.node_n) |to| {
            var at_node: u8 = @intCast(k);
            var steps: usize = 0;
            while (at_node != to) : (steps += 1) {
                at_node = a.hop(at_node, @intCast(to));
                try expect(at_node < a.node_n and steps < a.node_n);
            }
        }
    }
    try expectEqual(@as(u8, 1), track.hazard_n);
    // A race track has no arena.
    track.select(track.tracks[0]);
    try expectEqual(@as(u8, 0), track.arena.node_n);
}

test "a battle round starts on the spawn pads with lives, the clock and the refill" {
    var w = new_round(3, 3, 7, racers.snouty);
    try expectEqual(world.Mode.battle, w.mode);
    try expectEqual(@as(u16, 3 * tuning.battle_minute), w.battle.limit);
    try expectEqual(tuning.battle_refill, w.battle.refill);
    for (&w.cars) |*c| {
        try expect(c.active);
        try expectEqual(@as(u8, 3), c.lives);
        var on_pad = false;
        for (track.arena.spawns[0..track.arena.spawn_n]) |s| {
            on_pad = on_pad or (c.x >> fixed.Q == s.x and c.y >> fixed.Q == s.y and c.heading == s.heading);
        }
        try expect(on_pad);
    }
    run_countdown(&w);
    for (0..600) |_| sim.simulate(&w, .{ ai.drive(&w, racers.snouty).byte(), 0 });
    try expect(w.phase == .racing);
}

/// One round with the autopilot on SNOUTY (car 0 is human slot 0) and
/// five AI hunters; returns its stats.
const Stats = struct { ticks: u32 = 0, end: world.BattleEnd = .none, elims: u32 = 0, wrecks: u32 = 0, falls: u32 = 0, ai_on_ai: u32 = 0, smash: u32 = 0, clean: u32 = 0, stuck: u32 = 0 };

fn play(lives: u8, minutes: u8, seed: u32, max_ticks: u32) Stats {
    var w = new_round(lives, minutes, seed, racers.snouty);
    run_countdown(&w);
    var st: Stats = .{};
    var seq = w.event_seq;
    var slow: [world.car_count]u32 = @splat(0);
    while (w.phase == .racing and w.tick < max_ticks) {
        sim.simulate(&w, .{ ai.drive(&w, racers.snouty).byte(), 0 });
        while (seq != w.event_seq) : (seq +%= 1) {
            const e = w.events[seq % world.event_count];
            switch (e.kind) {
                .eliminated => {
                    st.elims += 1;
                    if (e.a != racers.snouty and e.b != racers.snouty) st.ai_on_ai += 1;
                },
                .wreck => {
                    st.wrecks += 1;
                    if (e.c == @backingInt(world.Wreck.fall)) st.falls += 1;
                },
                .stack_smash => st.smash += 1,
                .clean_landing => st.clean += 1,
                else => {},
            }
        }
        for (&w.cars, 0..) |*c, i| {
            if (!c.active or c.wreck != .none or sim.speed(c) > fixed.one / 4) {
                slow[i] = 0;
            } else {
                slow[i] += 1;
                if (slow[i] == 600) st.stuck += 1;
            }
        }
    }
    st.ticks = w.tick;
    st.end = w.battle.end;
    return st;
}

test "soak: 5-AI rounds at 3 lives end by lives, with eliminations among the AIs" {
    var total: Stats = .{};
    const n = 8;
    for (0..n) |k| {
        const st = play(3, 0, 1000 + @as(u32, @intCast(k)) * 7919, 60 * 60 * 8);
        std.debug.print("\nbattle 3 lives seed {d}: {d} ticks ({d} s), end {s}, {d} elims ({d} AI on AI), {d} wrecks ({d} falls), {d} smashes, {d} clean landings, {d} stuck", .{ k, st.ticks, st.ticks / 60, @tagName(st.end), st.elims, st.ai_on_ai, st.wrecks, st.falls, st.smash, st.clean, st.stuck });
        try expectEqual(world.BattleEnd.lives, st.end);
        total.ticks += st.ticks;
        total.elims += st.elims;
        total.ai_on_ai += st.ai_on_ai;
        total.wrecks += st.wrecks;
        total.falls += st.falls;
        total.stuck += st.stuck;
    }
    std.debug.print("\nbattle soak: mean {d} s a round, {d} elims, {d} AI on AI, {d} wrecks, {d} falls, {d} stuck\n", .{ total.ticks / n / 60, total.elims, total.ai_on_ai, total.wrecks, total.falls, total.stuck });
    try expect(total.ai_on_ai > 0);
}
