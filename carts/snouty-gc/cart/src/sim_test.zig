//! Host tests for the simulation (PLAN.md M0 item 6): determinism (the
//! lockstep of M4 rests on it), lap counting, driving, the grid, and the
//! completable test on every committed track.
const std = @import("std");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const track = @import("track.zig");
const world = @import("world.zig");
const racers = @import("racers.zig");
const sim = @import("sim.zig");
const ai = @import("ai.zig");

const World = world.World;
const Input = world.Input;

/// Print race summaries (finish ticks, ranks).
const report = false;

fn run_countdown(w: *World) void {
    while (w.phase == .countdown) sim.simulate(w, .{ 0, 0 });
}

fn solo(seed: u32) world.Setup {
    return .{ .seed = seed, .humans = .{ racers.snouty, world.no_human } };
}

test "World size (a CRC over it every 32 ticks must stay cheap)" {
    std.debug.print("\n@sizeOf(World) = {d} bytes, @sizeOf(Car) = {d}\n", .{ @sizeOf(World), @sizeOf(world.Car) });
    // M1 pools (48 shots, 32 drops, 16 events) put it near 2 KB; no rewind
    // keeps copies of it, so the cap only bounds the M4 CRC cost.
    try std.testing.expect(@sizeOf(World) <= 2560);
}

test "simulate twice from one state is equal" {
    var w: World = undefined;
    sim.reset(&w, solo(7));
    run_countdown(&w);
    for (0..300) |t| {
        const in = Input{ .right = (t / 40) % 3 == 1, .up = t == 100 };
        sim.simulate(&w, .{ in.byte(), 0 });
    }
    var a = w;
    var b = w;
    for (0..400) |t| {
        const in = Input{ .left = (t / 30) % 4 == 1, .down = (t / 50) % 5 == 2 };
        sim.simulate(&a, .{ in.byte(), 0 });
        sim.simulate(&b, .{ in.byte(), 0 });
        try std.testing.expect(sim.worlds_equal(&a, &b));
    }
    // The copies started from equal worlds and stay byte-for-byte equal in
    // every field; a different input changes the outcome.
    var c = w;
    for (0..400) |_| sim.simulate(&c, .{ (Input{ .right = true }).byte(), 0 });
    try std.testing.expect(!sim.worlds_equal(&a, &c));
}

/// A run of `ticks` with pseudo-random inputs on both human slots.
fn random_run(seed: u32, ticks: u32) World {
    var w: World = undefined;
    sim.reset(&w, .{ .seed = seed, .humans = .{ racers.snouty, racers.kiddie } });
    var r = fixed.Rng{ .s = seed ^ 0x9E37_79B9 };
    var held = [2]u8{ 0, 0 };
    for (0..ticks) |_| {
        // Change each slot's buttons now and then, as a hand would.
        for (&held) |*h| {
            if (r.below(12) == 0) h.* = @truncate(r.next());
        }
        sim.simulate(&w, held);
    }
    return w;
}

test "2000 ticks of random inputs on two human slots run equal twice" {
    for ([_]u32{ 1, 0xC0FFEE, 0xDEAD_BEEF }) |seed| {
        const a = random_run(seed, 2000);
        const b = random_run(seed, 2000);
        try std.testing.expect(sim.worlds_equal(&a, &b));
        try std.testing.expect(a.tick > 1500);
    }
    // Another seed is another race.
    const a = random_run(1, 2000);
    const c = random_run(2, 2000);
    try std.testing.expect(!sim.worlds_equal(&a, &c));
}

test "a race is a pure function of setup and inputs (two worlds, interleaved)" {
    // Two independent worlds stepped alternately stay equal: nothing in
    // `simulate` leaks state between them through globals.
    var a: World = undefined;
    var b: World = undefined;
    sim.reset(&a, solo(99));
    sim.reset(&b, solo(99));
    for (0..1500) |t| {
        const in = Input{ .right = (t / 25) % 3 == 0, .down = t % 90 < 10, .up = t % 400 == 300 };
        sim.simulate(&a, .{ in.byte(), 0 });
        sim.simulate(&b, .{ in.byte(), 0 });
    }
    try std.testing.expect(sim.worlds_equal(&a, &b));
}

test "grid: six cars apart on the floor, humans at the back" {
    var w: World = undefined;
    sim.reset(&w, solo(3));
    const t = sim.track_of(&w);
    try std.testing.expect(w.lap_px >= 3500 and w.lap_px <= 4500);
    for (&w.cars, 0..) |*c, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), c.racer);
        const a = t.attr_at(c.x >> fixed.Q, c.y >> fixed.Q);
        try std.testing.expect(a != .off and a != .wall);
        for (w.cars[i + 1 ..]) |*o| {
            const dx = ((o.x - c.x) >> fixed.Q);
            const dy = ((o.y - c.y) >> fixed.Q);
            try std.testing.expect(dx * dx + dy * dy >= 4 * tuning.car_radius * tuning.car_radius);
        }
    }
    try std.testing.expectEqual(@as(u8, 0), w.cars[racers.snouty].human);
    for (w.cars[1..]) |c| try std.testing.expectEqual(world.no_human, c.human);
    // The back row is level: the human ranks 5th or 6th at the start.
    try std.testing.expect(w.cars[racers.snouty].rank >= 5);
    // Chassis multipliers by racer (SPEC 4.2).
    try std.testing.expectEqual(tuning.mainframe.top_q8, w.cars[racers.legacy].top_q8);
    try std.testing.expectEqual(tuning.thin_client.mass_q8, w.cars[racers.kiddie].mass_q8);
    try std.testing.expectEqual(tuning.workstation.armor, w.cars[racers.sysadmin].armor_max);
    try std.testing.expectEqual(tuning.thin_client.accel_q8, w.cars[racers.rootkit].accel_q8);
    try std.testing.expectEqual(tuning.mainframe.mass_q8, w.cars[racers.botnet].mass_q8);
    // The AI grid order comes from the seed.
    var other: World = undefined;
    sim.reset(&other, solo(4));
    var same = true;
    for (w.cars, other.cars) |a, b| same = same and a.x == b.x and a.y == b.y;
    var differs = !same;
    var s: u32 = 5;
    while (!differs and s < 20) : (s += 1) {
        sim.reset(&other, solo(s));
        for (w.cars, other.cars) |a, b| differs = differs or a.x != b.x;
    }
    try std.testing.expect(differs);
}

test "CREWS: the AI cars past the count stay off the grid; the default keeps all (M4)" {
    // The default is the old grid exactly (single player is unchanged).
    var a: World = undefined;
    var b: World = undefined;
    sim.reset(&a, solo(7));
    var s7 = solo(7);
    s7.crews = 5;
    sim.reset(&b, s7);
    try std.testing.expect(sim.worlds_equal(&a, &b));
    const duo = [2]u8{ racers.legacy, racers.kiddie };
    for ([_]u8{ 4, 2, 0 }) |crews| {
        sim.reset(&a, .{ .seed = 11, .humans = duo, .crews = crews });
        var on: u8 = 0;
        for (&a.cars) |*c| {
            if (!c.active) {
                try std.testing.expectEqual(world.no_human, c.human);
                try std.testing.expectEqual(@as(u8, 0), c.rank);
                continue;
            }
            on += 1;
            try std.testing.expect(c.rank >= 1 and c.rank <= 2 + crews);
        }
        try std.testing.expectEqual(2 + crews, on);
        // The humans start on the back row of the shorter grid.
        try std.testing.expect(a.cars[racers.legacy].rank > crews and a.cars[racers.kiddie].rank > crews);
        // And the race runs to its finish with the cars off the grid still out.
        var guard: u32 = 0;
        while (a.phase != .finished and guard < 20_000) : (guard += 1) {
            sim.simulate(&a, .{ ai.drive(&a, racers.legacy).byte(), ai.drive(&a, racers.kiddie).byte() });
        }
        try std.testing.expectEqual(world.Phase.finished, a.phase);
        var still: u8 = 0;
        for (&a.cars) |*c| still += @intFromBool(c.active);
        try std.testing.expectEqual(2 + crews, still);
    }
}

test "auto-throttle: with no input the car drives to its top speed" {
    var w: World = undefined;
    sim.reset(&w, solo(1));
    run_countdown(&w);
    // Straight-line physics without tiles: step a copy of the car by hand.
    for ([_]u8{ racers.snouty, racers.kiddie, racers.legacy }) |r| {
        var c = w.cars[r];
        c.heading = 0;
        c.vx = 0;
        c.vy = 0;
        const thrust = (((tuning.accel * @as(i32, c.top_q8)) >> 8) * @as(i32, c.accel_q8)) >> 8;
        const keep = fixed.one - ((tuning.drag * @as(i32, c.accel_q8)) >> 8);
        for (0..900) |_| {
            c.vx += thrust;
            c.vx = fixed.mul(c.vx, keep);
        }
        const top = sim.top_of(&c);
        try std.testing.expect(@abs(sim.speed(&c) - top) < @divTrunc(top, 50));
    }
    // In the race: no buttons at all, and the player's car moves.
    const x0 = w.cars[0].x;
    const y0 = w.cars[0].y;
    for (0..60) |_| sim.simulate(&w, .{ 0, 0 });
    try std.testing.expect(sim.speed(&w.cars[0]) > fixed.one);
    try std.testing.expect(w.cars[0].x != x0 or w.cars[0].y != y0);
    // THIN CLIENT is faster than WORKSTATION, MAINFRAME slower (SPEC 4.2).
    try std.testing.expect(sim.top_of(&w.cars[racers.kiddie]) > sim.top_of(&w.cars[racers.snouty]));
    try std.testing.expect(sim.top_of(&w.cars[racers.legacy]) < sim.top_of(&w.cars[racers.snouty]));
}

test "Down brakes, but not with A or B (aim back)" {
    var w: World = undefined;
    // Combat off: Down+A drops a LOGIC BOMB into the pack otherwise.
    var setup = solo(1);
    setup.combat = false;
    sim.reset(&w, setup);
    run_countdown(&w);
    for (0..90) |_| sim.simulate(&w, .{ 0, 0 });
    var braked = w;
    var aimed = w;
    for (0..20) |_| {
        sim.simulate(&braked, .{ (Input{ .down = true }).byte(), 0 });
        sim.simulate(&aimed, .{ (Input{ .down = true, .a = true }).byte(), 0 });
    }
    try std.testing.expect(sim.speed(&braked.cars[0]) < sim.speed(&aimed.cars[0]) - fixed.one / 4);
}

test "BURST: one charge per lap on the Up press edge" {
    var w: World = undefined;
    sim.reset(&w, solo(1));
    // Up held through GO does not fire on the first tick.
    while (w.phase == .countdown) sim.simulate(&w, .{ (Input{ .up = true }).byte(), 0 });
    sim.simulate(&w, .{ (Input{ .up = true }).byte(), 0 });
    const c = &w.cars[0];
    try std.testing.expectEqual(@as(u8, 0), c.burst);
    sim.simulate(&w, .{ 0, 0 });
    sim.simulate(&w, .{ (Input{ .up = true }).byte(), 0 });
    try std.testing.expectEqual(tuning.burst_ticks, c.burst);
    try std.testing.expectEqual(@as(u8, 0), c.burst_charges);
    // Spent: a second press does nothing until the next lap.
    for (0..tuning.burst_ticks) |_| sim.simulate(&w, .{ 0, 0 });
    sim.simulate(&w, .{ (Input{ .up = true }).byte(), 0 });
    try std.testing.expectEqual(@as(u8, 0), c.burst);
}

test "lap needs both sectors" {
    var w: World = undefined;
    sim.reset(&w, solo(1));
    run_countdown(&w);
    const t = sim.track_of(&w);
    const c = &w.cars[0];
    const s = t.sample(250);
    const s2 = t.sample(2);
    // Teleport across the start line without sectors: no lap. Each step
    // moves one simulated tick with the car parked on a sample.
    const park = struct {
        fn at(ww: *World, cc: *world.Car, smp: track.Sample) void {
            cc.x = @as(i32, smp.x) << fixed.Q;
            cc.y = @as(i32, smp.y) << fixed.Q;
            cc.vx = 0;
            cc.vy = 0;
            cc.heading = smp.tangent;
            sim.simulate(ww, .{ 0, 0 });
        }
    };
    c.progress = 250;
    park.at(&w, c, s);
    park.at(&w, c, s2);
    try std.testing.expectEqual(@as(u8, 0), c.lap);
    // With both sectors seen: one lap, BURST charges back.
    c.progress = 250;
    park.at(&w, c, s);
    c.sectors = 3;
    c.burst_charges = 0;
    park.at(&w, c, s2);
    try std.testing.expectEqual(@as(u8, 1), c.lap);
    try std.testing.expectEqual(@as(u8, 0), c.sectors);
    try std.testing.expectEqual(tuning.burst_per_lap, c.burst_charges);
}

test "a fall into the pit wrecks the car; the WATCHDOG respawns it" {
    var w: World = undefined;
    sim.reset(&w, solo(1));
    run_countdown(&w);
    const c = &w.cars[0];
    // Park the car on the sand far from the track.
    c.x = 8 << fixed.Q;
    c.y = 8 << fixed.Q;
    c.immune = 0;
    sim.simulate(&w, .{ 0, 0 });
    try std.testing.expectEqual(world.Wreck.fall, c.wreck);
    try std.testing.expectEqual(world.Message.fall, c.msg);
    for (0..tuning.watchdog_ticks) |_| sim.simulate(&w, .{ 0, 0 });
    try std.testing.expectEqual(world.Wreck.none, c.wreck);
    const a = sim.track_of(&w).attr_at(c.x >> fixed.Q, c.y >> fixed.Q);
    try std.testing.expect(a != .off and a != .wall);
    try std.testing.expect(c.immune > 0);
}

test "car contact: pushed apart, the heavier car keeps more of its speed" {
    var w: World = undefined;
    sim.reset(&w, solo(1));
    run_countdown(&w);
    const t = sim.track_of(&w);
    const s = t.sample(60);
    for (&w.cars) |*c| c.active = false;
    const a = &w.cars[racers.kiddie]; // THIN CLIENT, mass 0.7
    const b = &w.cars[racers.legacy]; // MAINFRAME, mass 1.6
    a.active = true;
    b.active = true;
    a.x = (@as(i32, s.x) - 8) << fixed.Q;
    a.y = @as(i32, s.y) << fixed.Q;
    a.vx = fixed.one;
    a.vy = 0;
    b.x = (@as(i32, s.x) + 8) << fixed.Q;
    b.y = @as(i32, s.y) << fixed.Q;
    b.vx = -fixed.one;
    b.vy = 0;
    sim.collide_all(&w);
    try std.testing.expect(((b.x - a.x) >> fixed.Q) >= 2 * tuning.car_radius - 1);
    // Light KIDDIE loses more of its 1 px/tick than heavy LEGACY.
    try std.testing.expect(fixed.one - a.vx > b.vx + fixed.one);
}

/// Drive the autopilot as human slot 0 (`racer`) for at most `limit` ticks.
const RaceResult = struct { finish: u32, wrecks: u32, rank: u8, best: u32 };
fn autopilot_race(t: u8, racer: u8, seed: u32, limit: u32) RaceResult {
    var w: World = undefined;
    // Combat off: the content gate is the track, not the fight (SPEC 12).
    sim.reset(&w, .{ .track = t, .seed = seed, .humans = .{ racer, world.no_human }, .combat = false });
    run_countdown(&w);
    var wrecks: u32 = 0;
    var ticks: u32 = 0;
    var was = world.Wreck.none;
    while (w.phase != .finished and ticks < limit) : (ticks += 1) {
        sim.simulate(&w, .{ ai.drive(&w, racer).byte(), 0 });
        const c = &w.cars[racer];
        if (c.wreck != .none and was == .none) wrecks += 1;
        was = c.wreck;
    }
    const c = &w.cars[racer];
    if (report) std.debug.print("\n{s} racer {d} seed {d}: finish {d} ticks, best lap {d}, rank {d}, wrecks {d}\n", .{ track.tracks[t].name, racer, seed, c.finish_tick, c.best_lap, c.rank, wrecks });
    return .{ .finish = if (c.finished) c.finish_tick else std.math.maxInt(u32), .wrecks = wrecks, .rank = c.rank, .best = c.best_lap };
}

test "every committed track is completable: the autopilot drives 3 laps with no fall (combat off)" {
    // About 22 s a lap (SPEC 5.2); the bound is 50 s a lap.
    const limit: u32 = 60 * 50 * @as(u32, tuning.laps);
    for (0..track.tracks.len) |t| {
        const r = autopilot_race(@intCast(t), racers.snouty, 1, limit);
        try std.testing.expect(r.finish < limit);
        try std.testing.expectEqual(@as(u32, 0), r.wrecks);
        try std.testing.expect(r.rank >= 1 and r.rank <= 6);
        std.debug.print("\n{s}: SNOUTY autopilot finishes 3 laps at tick {d} (best lap {d} ticks), rank {d}\n", .{ track.tracks[t].name, r.finish, r.best, r.rank });
    }
}

test "every racer's chassis completes Landfill Loop under the autopilot (combat off)" {
    const limit: u32 = 60 * 50 * @as(u32, tuning.laps);
    for (0..racers.count) |r| {
        const res = autopilot_race(0, @intCast(r), 11, limit);
        try std.testing.expect(res.finish < limit);
        try std.testing.expect(res.wrecks <= 1);
    }
}

test "an AI-only race (attract) finishes with every car ranked" {
    var w: World = undefined;
    sim.reset(&w, .{ .seed = 42 });
    var ticks: u32 = 0;
    while (w.phase != .finished and ticks < 60 * 200) : (ticks += 1) sim.simulate(&w, .{ 0, 0 });
    try std.testing.expectEqual(world.Phase.finished, w.phase);
    var seen: u8 = 0;
    for (w.cars) |c| seen |= @as(u8, 1) << @intCast(c.rank - 1);
    try std.testing.expectEqual(@as(u8, 0x3F), seen);
}
