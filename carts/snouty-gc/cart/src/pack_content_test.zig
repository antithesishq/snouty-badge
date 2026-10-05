//! M7 Track B: the content packs' host tests (Dead Mall, The Boneyard).
//! Each loads the committed pack (cart/src/gen/packs/, written by
//! tools/packs/make_packs.py; host tests only, the badge cart embeds no
//! pack) through `pack.load_bytes` and runs it in the sim:
//!
//! - every race track is completable: the autopilot drives 3 laps, combat
//!   off, on three chassis (SNOUTY, LEGACY's MAINFRAME, KIDDIE's THIN
//!   CLIENT) as sim_test does for the built-in tracks, with at most
//!   `autopilot_falls_max` falls a race (M9.1: the crust bites the car
//!   behind; before it, no fall at all);
//! - six AI crews in a full combat race all finish their 3 laps (crust,
//!   movers, blasts and props live), nobody stuck;
//! - every arena: the navigation field reaches every node from every crate
//!   pad and spawn pad's cell, and seeded 3-life rounds of five hunters
//!   plus the autopilot end by lives with AI-on-AI eliminations, as
//!   battle_test does for The Sandbox.
//!
//! `autopilot_gate`, `six_ai_gate` and `Tally` are shared with
//! seabed_test.zig and cold_storage_test.zig (M9.1).
//!
//! Registered by pack_test.zig. Owned by Track B (PLAN M7).
const std = @import("std");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const track = @import("track.zig");
const sim = @import("sim.zig");
const ai = @import("ai.zig");
const racers = @import("racers.zig");
const pack = @import("pack.zig");
const fmt = @import("pack_format.zig");

const World = world.World;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Content = struct { file: []const u8, bytes: []const u8, tracks: u8, names: []const []const u8, arena: []const u8 };
const contents = [_]Content{
    .{ .file = "DEADMALL.GCP", .bytes = @embedFile("gen/packs/DEADMALL.GCP"), .tracks = 3, .names = &.{ "ANCHOR STORE", "FOOD COURT", "PARKING DECK" }, .arena = "THE FOOD COURT" },
    .{ .file = "BONEYARD.GCP", .bytes = @embedFile("gen/packs/BONEYARD.GCP"), .tracks = 3, .names = &.{ "MOTHBALL MILE", "WING ROW", "REENTRY FIELD" }, .arena = "HANGAR 18" },
};

/// Print every race's and round's numbers (PLAN M7 status Track B).
const report = true;

fn run_countdown(w: *World) void {
    while (w.phase == .countdown) sim.simulate(w, .{ 0, 0 });
}

fn load(c: Content, k: u8) !void {
    try expectEqual(fmt.Refusal.ok, pack.load_bytes(c.bytes, k));
}

test "pack content: both packs load, with their tracks, arena and league names" {
    for (contents) |c| {
        for (0..c.tracks) |k| {
            try load(c, @intCast(k));
            try std.testing.expectEqualStrings(c.names[k], track.pack_track.name);
            try expectEqual(@as(u8, 3), track.pack_track.laps);
            track.select(&track.pack_track);
            try expect(track.crate_n >= 6);
            try expect(track.prop_n > 0);
        }
        try load(c, c.tracks);
        try std.testing.expectEqualStrings(c.arena, track.pack_track.name);
        track.select(&track.pack_track);
        try expectEqual(@as(u8, 6), track.arena.spawn_n);
        try expectEqual(@as(u8, 8), track.crate_n);
        try expect(track.hazard_n >= 1);
    }
}

// --- The race gates, shared with seabed_test.zig and cold_storage_test.zig ------

/// M9.1: the most falls the autopilot may take in one 3-lap race on a pack
/// track (combat off, the five AI crews racing ahead of it and cracking
/// the crust: a band that bites can take the car behind them). PLAN L182.
pub const autopilot_falls_max: u32 = 2;

/// What a race's events added up to.
pub const Tally = struct {
    wrecks: u32 = 0,
    falls: u32 = 0,
    /// Falls with the car's centre on a crust tile: broken crust took it.
    crust: u32 = 0,
    hazard_hits: u32 = 0,
    /// Car `only`'s share (no_car: every car's).
    only: u8 = world.no_car,

    fn add(t: *Tally, w: *const World, e: world.Event) void {
        switch (e.kind) {
            .wreck => {
                if (t.only != world.no_car and e.a != t.only) return;
                t.wrecks += 1;
                if (e.c != @backingInt(world.Wreck.fall)) return;
                t.falls += 1;
                if (sim.track_of(w).attr_at(e.x, e.y) == .crust) t.crust += 1;
            },
            .hazard_hit => t.hazard_hits += 1,
            else => {},
        }
    }

    /// Every event since `seq.*`.
    pub fn read(t: *Tally, w: *const World, seq: *u16) void {
        while (seq.* != w.event_seq) : (seq.* +%= 1) t.add(w, w.events[seq.* % world.event_count]);
    }
};

/// Every race track of pack `c` is completable by the autopilot: 3 laps,
/// combat off, on three chassis (SNOUTY, LEGACY's MAINFRAME, KIDDIE's THIN
/// CLIENT, each driven by its racer's crew as the cart's autopilot is), at
/// most `autopilot_falls_max` falls a race. `c` is a test's `Content`.
pub fn autopilot_gate(c: anytype) !void {
    const limit: u32 = 60 * 50 * @as(u32, tuning.laps);
    for (0..c.tracks) |k| {
        for ([_]u8{ racers.snouty, racers.legacy, racers.kiddie }) |racer| {
            try expectEqual(fmt.Refusal.ok, pack.load_bytes(c.bytes, @intCast(k)));
            var w: World = undefined;
            sim.reset(&w, .{ .track = track.pack_base, .seed = 1, .humans = .{ racer, world.no_human }, .combat = false });
            run_countdown(&w);
            var tl = Tally{ .only = racer };
            var seq = w.event_seq;
            var ticks: u32 = 0;
            while (w.phase != .finished and ticks < limit) : (ticks += 1) {
                sim.simulate(&w, .{ ai.drive(&w, racer).byte(), 0 });
                tl.read(&w, &seq);
            }
            const car = &w.cars[racer];
            if (report) std.debug.print("\npack {s} {s} racer {d}: finished {} at tick {d}, best lap {d}, wrecks {d}, falls {d} (crust {d})", .{ c.file, c.names[k], racer, car.finished, car.finish_tick, car.best_lap, tl.wrecks, tl.falls, tl.crust });
            try expect(car.finished);
            try expect(tl.falls <= autopilot_falls_max);
        }
    }
}

/// Six AI crews in a full combat race all finish their 3 laps on every
/// race track of pack `c` (3 seeds a track), nobody stuck. Returns the
/// crust falls in all.
pub fn six_ai_gate(c: anytype) !u32 {
    var crust: u32 = 0;
    for (0..c.tracks) |k| {
        for (0..3) |s| {
            try expectEqual(fmt.Refusal.ok, pack.load_bytes(c.bytes, @intCast(k)));
            var w: World = undefined;
            sim.reset(&w, .{ .track = track.pack_base, .seed = @intCast(0xC0DE + s * 7919 + k), .humans = .{ world.no_human, world.no_human } });
            run_countdown(&w);
            var tl = Tally{};
            var seq = w.event_seq;
            var slow: [world.car_count]u32 = @splat(0);
            var max_slow: u32 = 0;
            var ticks: u32 = 0;
            var all = false;
            while (!all and ticks < 60 * 300) : (ticks += 1) {
                sim.simulate(&w, .{ 0, 0 });
                tl.read(&w, &seq);
                all = true;
                for (&w.cars, 0..) |*car, i| {
                    all = all and (!car.active or car.finished);
                    if (car.finished or car.wreck != .none or sim.speed(car) > fixed.one / 4) {
                        slow[i] = 0;
                    } else {
                        slow[i] += 1;
                        max_slow = @max(max_slow, slow[i]);
                    }
                }
            }
            var best: u32 = std.math.maxInt(u32);
            for (w.cars) |car| {
                if (car.best_lap > 0) best = @min(best, car.best_lap);
            }
            if (report) std.debug.print("\npack {s} {s} 6-AI seed {d}: all finished {} by tick {d}, best lap {d}, wrecks {d} (falls {d}, crust {d}), hazard hits {d}, stuck max {d}", .{ c.file, c.names[k], s, all, ticks, best, tl.wrecks, tl.falls, tl.crust, tl.hazard_hits, max_slow });
            try expect(all);
            try expect(max_slow <= 600);
            crust += tl.crust;
        }
    }
    return crust;
}

test "pack content: every race track is completable by the autopilot, 3 laps, at most autopilot_falls_max falls (combat off)" {
    for (contents) |c| try autopilot_gate(c);
}

test "pack content: six AI crews in a combat race all finish 3 laps on every track" {
    var crust: u32 = 0;
    for (contents) |c| crust += try six_ai_gate(c);
    // FOOD COURT's ceiling tiles and REENTRY FIELD's furrow crust bite.
    try expect(crust > 0);
}

test "pack content: every arena's navigation field reaches every node from every pad" {
    for (contents) |c| {
        try load(c, c.tracks);
        track.select(&track.pack_track);
        const a = &track.arena;
        var spots: [track.spawn_max + world.crate_max][2]i32 = undefined;
        var n: usize = 0;
        for (a.spawns[0..a.spawn_n]) |s| {
            spots[n] = .{ s.x, s.y };
            n += 1;
        }
        for (track.crate_spots[0..track.crate_n]) |p| {
            spots[n] = .{ p.x, p.y };
            n += 1;
        }
        for (spots[0..n]) |p| {
            const from = a.cell_node(p[0], p[1]);
            try expect(from < a.node_n);
            for (0..a.node_n) |to| {
                var at = from;
                var steps: usize = 0;
                while (at != to) : (steps += 1) {
                    at = a.hop(at, @intCast(to));
                    try expect(at < a.node_n and steps < a.node_n);
                }
                // And over the ground alone (a car too slow for the jumps).
                at = from;
                steps = 0;
                while (at != to) : (steps += 1) {
                    at = a.ground_hop(at, @intCast(to));
                    try expect(at < a.node_n and steps < a.node_n);
                }
            }
        }
    }
}

test "pack content: arena soaks, 3 lives: rounds end by lives with AI-on-AI eliminations" {
    for (contents) |c| {
        var ai_on_ai: u32 = 0;
        var total_ticks: u32 = 0;
        const rounds = 6;
        for (0..rounds) |k| {
            try load(c, c.tracks);
            var w: World = undefined;
            sim.reset(&w, .{ .track = track.pack_base, .mode = .battle, .seed = 1000 + @as(u32, @intCast(k)) * 7919, .lives = 3, .minutes = 0, .humans = .{ racers.snouty, world.no_human } });
            run_countdown(&w);
            var seq = w.event_seq;
            var elims: u32 = 0;
            var aa: u32 = 0;
            var wrecks: u32 = 0;
            var falls: u32 = 0;
            var smash: u32 = 0;
            var clean: u32 = 0;
            while (w.phase == .racing and w.tick < 60 * 60 * 8) {
                sim.simulate(&w, .{ ai.drive(&w, racers.snouty).byte(), 0 });
                while (seq != w.event_seq) : (seq +%= 1) {
                    const e = w.events[seq % world.event_count];
                    switch (e.kind) {
                        .eliminated => {
                            elims += 1;
                            if (e.a != racers.snouty and e.b != racers.snouty) aa += 1;
                        },
                        .wreck => {
                            wrecks += 1;
                            if (e.c == @backingInt(world.Wreck.fall)) falls += 1;
                        },
                        .stack_smash => smash += 1,
                        .clean_landing => clean += 1,
                        else => {},
                    }
                }
            }
            if (report) std.debug.print("\npack {s} {s} seed {d}: {d} s, end {s}, {d} elims ({d} AI on AI), {d} wrecks ({d} falls), {d} smashes, {d} clean landings", .{ c.file, c.arena, k, w.tick / 60, @tagName(w.battle.end), elims, aa, wrecks, falls, smash, clean });
            try expectEqual(world.BattleEnd.lives, w.battle.end);
            ai_on_ai += aa;
            total_ticks += w.tick;
        }
        if (report) std.debug.print("\npack {s} {s}: mean {d} s a round, {d} AI-on-AI eliminations in {d} rounds\n", .{ c.file, c.arena, total_ticks / rounds / 60, ai_on_ai, rounds });
        try expect(ai_on_ai > 0);
    }
}

test "pack content: a pack race is deterministic (the same seed twice)" {
    var sums: [2]u64 = undefined;
    for (&sums) |*sum| {
        try load(contents[1], 2); // REENTRY FIELD: crust, the ramp, props
        var w: World = undefined;
        sim.reset(&w, .{ .track = track.pack_base, .seed = 99 });
        for (0..4000) |_| sim.simulate(&w, .{ 0, 0 });
        sum.* = std.hash.Wyhash.hash(0, std.mem.asBytes(&w));
    }
    try expectEqual(sums[0], sums[1]);
}
