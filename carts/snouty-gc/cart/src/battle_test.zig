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
