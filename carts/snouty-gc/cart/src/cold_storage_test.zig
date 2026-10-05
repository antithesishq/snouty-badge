//! M9 Track C: the Cold Storage pack's host tests (SPEC 19.8, 19.9),
//! mirroring pack_content_test.zig. It loads the committed COLDSTOR.GCP
//! (cart/src/gen/packs/, written by tools/packs/make_packs.py; host tests
//! only, the badge cart embeds no pack) through `pack.load_bytes` and runs
//! it in the sim:
//!
//! - every race track is completable: the autopilot drives 3 laps with no
//!   fall, combat off, on three chassis (SNOUTY, LEGACY's MAINFRAME,
//!   KIDDIE's THIN CLIENT) as sim_test does for the built-in tracks;
//! - six AI crews in a full combat race all finish their 3 laps (crust,
//!   movers, blasts and props live), nobody stuck;
//! - every arena: the navigation field reaches every node from every crate
//!   pad and spawn pad's cell, and seeded 3-life rounds of five hunters
//!   plus the autopilot end by lives with AI-on-AI eliminations, as
//!   battle_test does for The Sandbox (The Moon Pool: an all-glare-ice
//!   floor, so the rounds' length and the falls are printed too);
//! - a pack race is deterministic.
//!
//! Registered by host_tests.zig. Owned by M9 Track C (PLAN M9).
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
    .{ .file = "COLDSTOR.GCP", .bytes = @embedFile("gen/packs/COLDSTOR.GCP"), .tracks = 3, .names = &.{ "INTAKE SHELF", "CALVING FRONT", "EREBUS GRID" }, .arena = "THE MOON POOL" },
};

/// Print every race's and round's numbers (PLAN M9 status Track C).
const report = true;

fn run_countdown(w: *World) void {
    while (w.phase == .countdown) sim.simulate(w, .{ 0, 0 });
}

fn load(c: Content, k: u8) !void {
    try expectEqual(fmt.Refusal.ok, pack.load_bytes(c.bytes, k));
}

test "cold storage: the pack loads, with its tracks, arena and league name" {
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

test "cold storage: every race track is completable by the autopilot, 3 laps, no fall (combat off)" {
    const limit: u32 = 60 * 50 * @as(u32, tuning.laps);
    for (contents) |c| {
        for (0..c.tracks) |k| {
            for ([_]u8{ racers.snouty, racers.legacy, racers.kiddie }) |racer| {
                try load(c, @intCast(k));
                var w: World = undefined;
                sim.reset(&w, .{ .track = track.pack_base, .seed = 1, .humans = .{ racer, world.no_human }, .combat = false });
                run_countdown(&w);
                var wrecks: u32 = 0;
                var was = world.Wreck.none;
                var ticks: u32 = 0;
                while (w.phase != .finished and ticks < limit) : (ticks += 1) {
                    sim.simulate(&w, .{ ai.drive(&w, racer).byte(), 0 });
                    const car = &w.cars[racer];
                    if (car.wreck != .none and was == .none) wrecks += 1;
                    was = car.wreck;
                }
                const car = &w.cars[racer];
                if (report) std.debug.print("\npack {s} {s} racer {d}: finished {} at tick {d}, best lap {d}, wrecks {d}", .{ c.file, c.names[k], racer, car.finished, car.finish_tick, car.best_lap, wrecks });
                try expect(car.finished);
                try expectEqual(@as(u32, 0), wrecks);
            }
        }
    }
}

test "cold storage: six AI crews in a combat race all finish 3 laps on every track" {
    for (contents) |c| {
        for (0..c.tracks) |k| {
            for (0..3) |s| {
                try load(c, @intCast(k));
                var w: World = undefined;
                sim.reset(&w, .{ .track = track.pack_base, .seed = @intCast(0xC0DE + s * 7919 + k), .humans = .{ world.no_human, world.no_human } });
                run_countdown(&w);
                var wrecks: u32 = 0;
                var falls: u32 = 0;
                var hazard_hits: u32 = 0;
                var seq = w.event_seq;
                var slow: [world.car_count]u32 = @splat(0);
                var max_slow: u32 = 0;
                var ticks: u32 = 0;
                var all = false;
                while (!all and ticks < 60 * 300) : (ticks += 1) {
                    sim.simulate(&w, .{ 0, 0 });
                    while (seq != w.event_seq) : (seq +%= 1) {
                        const e = w.events[seq % world.event_count];
                        switch (e.kind) {
                            .wreck => {
                                wrecks += 1;
                                if (e.c == @backingInt(world.Wreck.fall)) falls += 1;
                            },
                            .hazard_hit => hazard_hits += 1,
                            else => {},
                        }
                    }
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
                if (report) std.debug.print("\npack {s} {s} 6-AI seed {d}: all finished {} by tick {d}, best lap {d}, wrecks {d} (falls {d}), hazard hits {d}, stuck max {d}", .{ c.file, c.names[k], s, all, ticks, best, wrecks, falls, hazard_hits, max_slow });
                try expect(all);
                try expect(max_slow <= 600);
            }
        }
    }
}

test "cold storage: every arena's navigation field reaches every node from every pad" {
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

test "cold storage: arena soaks, 3 lives: rounds end by lives with AI-on-AI eliminations" {
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

test "cold storage: a pack race is deterministic (the same seed twice)" {
    var sums: [2]u64 = undefined;
    for (&sums) |*sum| {
        try load(contents[0], 0); // INTAKE SHELF: crust, glare ice, the open sea, props
        var w: World = undefined;
        sim.reset(&w, .{ .track = track.pack_base, .seed = 99 });
        for (0..4000) |_| sim.simulate(&w, .{ 0, 0 });
        sum.* = std.hash.Wyhash.hash(0, std.mem.asBytes(&w));
    }
    try expectEqual(sums[0], sums[1]);
}
