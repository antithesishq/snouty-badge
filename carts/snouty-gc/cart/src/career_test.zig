//! Host tests for M5 (PLAN.md "M5 Circuit and polish"): the stock setup
//! reproduces the M0-M4 races exactly, every garage upgrade's effect in the
//! sim (ECC's L3 rule among them), the cycle chips, the CYCLES accounting
//! and the garage, the AI upgrade plans, and a scripted full circuit with
//! the autopilot driving, from the first race of the Dumps to the end card.
const std = @import("std");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const track = @import("track.zig");
const world = @import("world.zig");
const racers = @import("racers.zig");
const sim = @import("sim.zig");
const ai = @import("ai.zig");
const weapons = @import("weapons.zig");
const career = @import("career.zig");
const roster_text = @import("roster_text.zig");

const World = world.World;
const Car = world.Car;
const Input = world.Input;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// Print the circuit soak's race-by-race summary.
const report = false;

// --- The stock setup is the M0-M4 car ------------------------------------------------

/// A fingerprint of a race: the clock, the PRNG, the event count, and every
/// car's position, heading, armor, lap, kills, wrecks and rank.
fn fingerprint(w: *const World) u32 {
    var s: u32 = w.tick ^ w.rng ^ (@as(u32, w.event_seq) << 16);
    for (&w.cars) |*c| {
        s = s *% 31 +% @as(u32, @bitCast(c.x)) +% @as(u32, @bitCast(c.y)) *% 7 +% c.heading;
        s = s *% 31 +% c.armor +% @as(u32, c.lap) * 256 +% @as(u32, c.kills) * 65536 +% @as(u32, c.wrecks) * 4096 +% c.rank;
    }
    return s;
}

const Golden = struct { track: u8, mode: world.Mode, seed: u32, racer: u8, print: u32 };
/// Recorded on gc/present at 90683be4 (M4, before any M5 change): 4,000
/// ticks of each setup with the autopilot driving the human.
const golden = [_]Golden{
    .{ .track = 0, .mode = .race, .seed = 11, .racer = racers.snouty, .print = 1735267406 },
    .{ .track = 3, .mode = .race, .seed = 22, .racer = racers.kiddie, .print = 1595809947 },
    .{ .track = 4, .mode = .race, .seed = 33, .racer = racers.legacy, .print = 3925607225 },
    .{ .track = 1, .mode = .gc, .seed = 44, .racer = racers.sysadmin, .print = 3292629708 },
    .{ .track = 5, .mode = .attract, .seed = 55, .racer = world.no_human, .print = 3138622903 },
};

fn golden_run(g: Golden, explicit: bool) u32 {
    var setup = world.Setup{ .track = g.track, .seed = g.seed, .mode = g.mode, .humans = .{ g.racer, world.no_human } };
    if (explicit) {
        // The stock cars spelled out: own guns at L1, every slot L0.
        for (&setup.loadouts, 0..) |*lo, i| lo.* = .{ .front = racers.roster[i].front, .rear = racers.roster[i].rear };
    }
    var w: World = undefined;
    sim.reset(&w, setup);
    for (0..4000) |_| {
        const b: u8 = if (g.racer < racers.count) ai.drive(&w, g.racer).byte() else 0;
        sim.simulate(&w, .{ b, 0 });
    }
    return fingerprint(&w);
}

test "M5 changes nothing outside the CIRCUIT: the M0-M4 races replay to their recorded fingerprints" {
    for (golden) |g| {
        try expectEqual(g.print, golden_run(g, false));
        try expectEqual(g.print, golden_run(g, true));
    }
}

test "World stays under its cap with the M5 fields" {
    try expect(@sizeOf(World) <= 2560);
}

// --- Upgrades in the sim (SPEC 9.2) ------------------------------------------------

fn reset_with(lo: world.Loadout) World {
    var setup = world.Setup{ .seed = 5, .humans = .{ racers.snouty, world.no_human } };
    setup.loadouts[racers.snouty] = lo;
    var w: World = undefined;
    sim.reset(&w, setup);
    return w;
}

test "PLATING: armor +30 a level, ECC at L3 only" {
    for (0..4) |lv| {
        const w = reset_with(.{ .plating = @intCast(lv) });
        const c = &w.cars[racers.snouty];
        try expectEqual(@as(u8, @intCast(100 + 30 * lv)), c.armor_max);
        try expectEqual(c.armor_max, c.armor);
        try expectEqual(lv == 3, c.ecc);
    }
    // A MAINFRAME at L3 still fits a byte.
    var setup = world.Setup{};
    setup.loadouts[racers.legacy] = .{ .plating = 3 };
    var w: World = undefined;
    sim.reset(&w, setup);
    try expectEqual(@as(u8, 230), w.cars[racers.legacy].armor_max);
}

test "ECC (PLATING L3): a hit of 4 or less is ignored, 5 is not; PING L3 gets through" {
    var w = reset_with(.{ .plating = 3 });
    while (w.phase == .countdown) sim.simulate(&w, .{ 0, 0 });
    const c = &w.cars[racers.snouty];
    c.immune = 0;
    const a0 = c.armor;
    for (1..5) |d| sim.damage(&w, racers.snouty, racers.kiddie, @intCast(d));
    try expectEqual(a0, c.armor);
    // An ignored hit is not a hit: no kill credit starts.
    try expectEqual(world.no_car, c.last_hit_by);
    sim.damage(&w, racers.snouty, racers.kiddie, 5);
    try expectEqual(a0 - 5, c.armor);
    try expectEqual(racers.kiddie, c.last_hit_by);
    // Without ECC every hit counts.
    var p = reset_with(.{ .plating = 2 });
    while (p.phase == .countdown) sim.simulate(&p, .{ 0, 0 });
    p.cars[racers.snouty].immune = 0;
    sim.damage(&p, racers.snouty, racers.kiddie, 4);
    try expectEqual(p.cars[racers.snouty].armor_max - 4, p.cars[racers.snouty].armor);
    // A PING pellet is 4 (cannot chip ECC), 5 from a PING at L3.
    try expectEqual(@as(u8, 5), weapons.up25(tuning.ping_dmg));
    try expect(tuning.ping_dmg <= tuning.ecc_ignore);
}

test "a PING L3 pellet chips ECC, a stock one does not (frozen scenario)" {
    for ([_]u8{ 1, 3 }) |lv| {
        var w = arena();
        const f = clear_frame(&w, 120);
        const s = put(&w, 0, f, 0, 0);
        const v = put(&w, 1, f, 50, 0);
        s.front = .ping;
        s.front_level = lv;
        weapons.refill(s);
        v.ecc = true;
        const a0 = v.armor;
        for (0..30) |_| frozen_tick(&w, .{ .a = true });
        for (0..30) |_| frozen_tick(&w, .{});
        if (lv == 3) try expect(v.armor < a0) else try expectEqual(a0, v.armor);
        if (lv == 3) try expectEqual(@as(u32, 0), (a0 - v.armor) % 5);
    }
}

test "CLOCK: top speed +4% a level, and the car is faster on a straight" {
    var speeds: [4]i32 = undefined;
    for (0..4) |lv| {
        var w = reset_with(.{ .clock = @intCast(lv) });
        const c = &w.cars[racers.snouty];
        try expectEqual(@as(u16, @intCast(256 * (100 + 4 * lv) / 100)), c.top_q8);
        // Terminal speed of the stock thrust and drag (sim.top_of) grows.
        speeds[lv] = sim.top_of(c);
    }
    try expect(speeds[0] < speeds[1] and speeds[1] < speeds[2] and speeds[2] < speeds[3]);
    try expect(speeds[3] * 100 >= speeds[0] * 111);
    // On the move: 300 ticks from a standstill on the same straight.
    var dist: [2]i32 = undefined;
    for ([_]u8{ 0, 3 }, 0..) |lv, k| {
        var w = arena();
        const f = clear_frame(&w, 40);
        const c = put(&w, 0, f, 0, 0);
        c.top_q8 = @intCast(256 * (100 + 4 * @as(u32, lv)) / 100);
        for (0..120) |_| {
            sim.simulate(&w, .{ 0, 0 });
            // Stay on the straight: back to the frame each tick, keep the speed.
            const vx = c.vx;
            const vy = c.vy;
            _ = put(&w, 0, f, 0, 0);
            c.vx = vx;
            c.vy = vy;
        }
        dist[k] = sim.speed(c);
    }
    try expect(dist[1] > dist[0]);
}

test "TRACTION: grip +0.03 a level on every chassis" {
    for (0..4) |lv| {
        const w = reset_with(.{ .traction = @intCast(lv) });
        try expectEqual(@as(u16, @intCast(256 + 8 * lv)), w.cars[racers.snouty].grip_q8);
    }
    var setup = world.Setup{};
    setup.loadouts[racers.kiddie] = .{ .traction = 2 };
    var w: World = undefined;
    sim.reset(&w, setup);
    try expectEqual(tuning.thin_client.grip_q8 + 16, w.cars[racers.kiddie].grip_q8);
}

test "BURST BUFFER: 1 to 4 charges a lap, refilled on the line" {
    for (0..4) |lv| {
        var w = reset_with(.{ .burst = @intCast(lv) });
        const c = &w.cars[racers.snouty];
        try expectEqual(@as(u8, @intCast(1 + lv)), c.burst_max);
        try expectEqual(c.burst_max, c.burst_charges);
        while (w.phase == .countdown) sim.simulate(&w, .{ 0, 0 });
        // Spend them all, one press at a time.
        var used: u8 = 0;
        var t: u32 = 0;
        while (c.burst_charges > 0 and t < 2000) : (t += 1) {
            const up = c.burst == 0 and t % 2 == 0;
            sim.simulate(&w, .{ (Input{ .up = up }).byte(), 0 });
            if (up and c.burst == tuning.burst_ticks) used += 1;
        }
        try expectEqual(c.burst_max, used);
        // The next line crossing refills to the level's count.
        const lap0 = c.lap;
        t = 0;
        while (c.lap == lap0 and t < 4000) : (t += 1) sim.simulate(&w, .{ ai.drive(&w, racers.snouty).byte() & ~@as(u8, 1), 0 });
        try expect(c.lap > lap0);
        try expectEqual(c.burst_max, c.burst_charges);
    }
}

test "WATCHDOG: respawn after 120 / 90 / 60 / 40 ticks; the hulk burns 90 or all of a shorter delay" {
    for (0..4) |lv| {
        var w = reset_with(.{ .watchdog = @intCast(lv) });
        while (w.phase == .countdown) sim.simulate(&w, .{ 0, 0 });
        const c = &w.cars[racers.snouty];
        c.immune = 0;
        try expectEqual(tuning.watchdog_levels[lv], c.watchdog);
        sim.damage(&w, racers.snouty, racers.legacy, 255);
        try expectEqual(world.Wreck.armor, c.wreck);
        try expect(sim.is_hulk(c));
        var t: u32 = 0;
        var hulk_ticks: u32 = 0;
        while (c.wreck != .none and t < 300) : (t += 1) {
            sim.simulate(&w, .{ 0, 0 });
            if (sim.is_hulk(c)) hulk_ticks += 1;
        }
        try expectEqual(@as(u32, tuning.watchdog_levels[lv]), t);
        try expectEqual(@min(@as(u32, tuning.hulk_ticks) - 1, t - 1), hulk_ticks);
        try expectEqual(c.armor_max, c.armor);
    }
}

test "weapon levels: front L2 +25% ammo, L3 +25% damage; rear L2 +1 drop, L3 +25% effect; swaps" {
    var w = reset_with(.{ .front = .ping, .front_level = 2, .rear = .bomb, .rear_level = 2 });
    const c = &w.cars[racers.snouty];
    try expectEqual(world.Front.ping, c.front);
    try expectEqual(@as(u8, 50), c.ammo_front);
    try expectEqual(tuning.rear_ammo[@backingInt(world.Rear.bomb)] + 1, c.ammo_rear);
    // The other guns at L2: BROADCAST 13, LANCE 8, SPEAR PHISH 4.
    try expectEqual(@as(u8, 13), weapons.up25(10));
    try expectEqual(@as(u8, 8), weapons.up25(6));
    try expectEqual(@as(u8, 4), weapons.up25(3));
    // A swap on another racer.
    var setup = world.Setup{};
    setup.loadouts[racers.legacy] = .{ .front = .lance, .rear = .rot };
    var x: World = undefined;
    sim.reset(&x, setup);
    try expectEqual(world.Front.lance, x.cars[racers.legacy].front);
    try expectEqual(world.Rear.rot, x.cars[racers.legacy].rear);
    try expectEqual(tuning.front_ammo[@backingInt(world.Front.lance)], x.cars[racers.legacy].ammo_front);
}

test "LOGIC BOMB L3: 44 instead of 35 (frozen scenario)" {
    for ([_]u8{ 1, 3 }) |lv| {
        var w = arena();
        const f = clear_frame(&w, 60);
        const s = put(&w, 0, f, 0, 0);
        s.rear = .bomb;
        s.rear_level = lv;
        weapons.refill(s);
        frozen_tick(&w, .{ .a = true, .down = true });
        const v = put(&w, 1, f, -tuning.drop_behind + 4, 0);
        _ = put(&w, 0, f, 100, 0);
        const a0 = v.armor;
        for (0..tuning.bomb_arm + 2) |_| frozen_tick(&w, .{});
        try expectEqual(a0 - (if (lv == 3) @as(u8, 44) else tuning.bomb_dmg), v.armor);
    }
}

// --- Cycle chips (SPEC 9.1) ------------------------------------------------------

test "chips: 20 or more on every track, on the road, off unless the CIRCUIT asks" {
    for (track.tracks, 0..) |t, k| {
        track.select(t);
        try expect(track.chip_n >= 20 and track.chip_n <= world.chip_max);
        for (track.chip_spots[0..track.chip_n]) |sp| {
            const a = t.attr_at(sp.x, sp.y);
            try expect(a != .off and a != .wall);
        }
        var w: World = undefined;
        sim.reset(&w, .{ .track = @intCast(k) });
        try expect(!w.chips_on);
    }
}

test "chips: the autopilot picks some up, each a chip event; taken chips come back every 4 s" {
    var w: World = undefined;
    sim.reset(&w, .{ .seed = 9, .humans = .{ racers.snouty, world.no_human }, .chips = true });
    try expect(w.chips_on);
    var seq = w.event_seq;
    var events: u32 = 0;
    var refills: u32 = 0;
    var was: u32 = 0;
    for (0..5000) |_| {
        sim.simulate(&w, .{ ai.drive(&w, racers.snouty).byte(), 0 });
        while (seq != w.event_seq) : (seq +%= 1) {
            const e = w.events[seq % world.event_count];
            if (e.kind == .chip) {
                events += 1;
                try expect(e.b < track.chip_n);
            }
        }
        if (@popCount(w.chips) < @popCount(was)) refills += 1;
        was = w.chips;
    }
    var taken: u32 = 0;
    for (w.cars) |c| taken += c.chips;
    try expect(w.cars[racers.snouty].chips > 0);
    try expectEqual(taken, events);
    try expect(refills >= 1);
    // Without chips nobody takes any (the M0-M4 races).
    var q: World = undefined;
    sim.reset(&q, .{ .seed = 9, .humans = .{ racers.snouty, world.no_human } });
    for (0..3000) |_| sim.simulate(&q, .{ ai.drive(&q, racers.snouty).byte(), 0 });
    for (q.cars) |c| try expectEqual(@as(u8, 0), c.chips);
}

// --- CYCLES, points, the garage --------------------------------------------------

/// A finished World with the given places, kills and chips per car.
fn result(places: [6]u8, kills: [6]u8, chips: [6]u8) World {
    var w: World = .{};
    for (&w.cars, 0..) |*c, i| {
        c.racer = @intCast(i);
        c.rank = places[i];
        c.kills = kills[i];
        c.chips = chips[i];
    }
    w.phase = .finished;
    return w;
}

test "CYCLES: place, last-hit wrecks and chips for the player; points for everyone" {
    var c = career.Career.init(racers.kiddie);
    const w = result(.{ 1, 2, 3, 4, 5, 6 }, .{ 0, 1, 2, 0, 0, 3 }, .{ 0, 0, 7, 0, 0, 1 });
    const a = c.finish_race(&w);
    try expectEqual(@as(u8, 3), a.place);
    try expectEqual(@as(u16, 400), a.place_cycles);
    try expectEqual(@as(u16, 300), a.kill_cycles);
    try expectEqual(@as(u16, 70), a.chip_cycles);
    try expectEqual(@as(u32, 770), a.total);
    try expectEqual(@as(u32, 770), c.cycles);
    try expectEqual([6]u16{ 9, 6, 4, 3, 2, 1 }, c.points);
    // The AIs' budgets: BOTNET 6th with 3 kills and a chip.
    try expectEqual(@as(u32, 100 + 450 + 10), c.earned[racers.botnet]);
    try expectEqual(@as(u32, 1000), c.earned[racers.snouty]);
    try expectEqual(@as(u8, 1), c.race);
    try expectEqual(@as(u8, 1), c.track_index());
    // The setup of the next race: the Dumps' second track, chips on.
    const s = c.setup(1234);
    try expectEqual(@as(u8, 1), s.track);
    try expect(s.chips);
    try expectEqual(racers.kiddie, s.humans[0]);
}

test "a league: three races, the champion's 1500, top 3 opens the Runoff, else a replay" {
    // KIDDIE wins all three: the Dumps is won, the Runoff opens.
    var c = career.Career.init(racers.kiddie);
    const win = result(.{ 2, 3, 1, 4, 5, 6 }, @splat(0), @splat(0));
    for (0..3) |_| _ = c.finish_race(&win);
    try expect(c.league_over());
    try expectEqual(@as(u32, 3000), c.cycles);
    try expectEqual(career.Outcome.won, c.close_league());
    try expectEqual(@as(u32, 4500), c.cycles);
    try expectEqual(@as(u8, 1), c.league);
    try expectEqual(@as(u8, 2), c.open);
    try expect(c.unlocked and !c.done);
    try expectEqual(@as(u8, 3), c.track_index());
    // 4th three times in the Runoff: failed, replay it with the CYCLES kept.
    const fourth = result(.{ 1, 2, 4, 5, 6, 3 }, @splat(0), @splat(0));
    for (0..3) |_| _ = c.finish_race(&fourth);
    const kept = c.cycles;
    try expectEqual(career.Outcome.failed, c.close_league());
    try expectEqual(kept, c.cycles);
    try expectEqual(@as(u8, 1), c.league);
    try expectEqual(@as(u8, 2), c.tries);
    try expectEqual(@as(u8, 0), c.race);
    try expect(!c.unlocked and !c.done);
    try expectEqual([6]u16{ 0, 0, 0, 0, 0, 0 }, c.points);
    // 3rd: cleared, and the last league ends the circuit.
    const third = result(.{ 1, 2, 3, 4, 6, 5 }, @splat(0), @splat(0));
    for (0..3) |_| _ = c.finish_race(&third);
    try expectEqual(@as(u8, 3), c.place_of(racers.kiddie));
    try expectEqual(career.Outcome.cleared, c.close_league());
    try expect(c.done);
    try expectEqual(racers.snouty, c.champion);
}

test "standings: points first, then the last race's place" {
    var c = career.Career.init(racers.snouty);
    _ = c.finish_race(&result(.{ 1, 2, 3, 4, 5, 6 }, @splat(0), @splat(0)));
    _ = c.finish_race(&result(.{ 2, 1, 3, 4, 5, 6 }, @splat(0), @splat(0)));
    // SNOUTY and LEGACY both have 15: LEGACY won the last one.
    const o = c.standings();
    try expectEqual(racers.legacy, o[0]);
    try expectEqual(racers.snouty, o[1]);
    try expectEqual(racers.kiddie, o[2]);
}

test "garage: prices from SPEC 9.2, levels to 3, swaps at L1, too poor, maxed" {
    var c = career.Career.init(racers.snouty);
    c.cycles = 100_000;
    const prices = [_]struct { slot: career.Slot, p: [3]u16 }{
        .{ .slot = .plating, .p = .{ 500, 900, 1400 } },
        .{ .slot = .clock, .p = .{ 600, 1000, 1500 } },
        .{ .slot = .traction, .p = .{ 400, 700, 1000 } },
        .{ .slot = .burst, .p = .{ 400, 800, 1200 } },
        .{ .slot = .watchdog, .p = .{ 500, 900, 1300 } },
    };
    for (prices) |row| {
        for (row.p, 0..) |p, lv| {
            const o = c.offer(c.racer, row.slot, 0);
            try expectEqual(p, o.price);
            try expectEqual(@as(u8, @intCast(lv + 1)), o.level);
            try expectEqual(career.Buy.ok, c.buy(row.slot, 0));
        }
        try expectEqual(career.Buy.maxed, c.buy(row.slot, 0));
        try expectEqual(@as(u8, 3), c.level(c.racer, row.slot));
    }
    // SNOUTY's own SPEAR PHISH: L2 400, L3 800; another gun is an 800 swap.
    const phish: u8 = @backingInt(world.Front.phish);
    try expectEqual(@as(u16, 400), c.offer(c.racer, .front, phish).price);
    try expectEqual(@as(u16, 800), c.offer(c.racer, .front, @backingInt(world.Front.ping)).price);
    try expectEqual(career.Buy.ok, c.buy(.front, phish));
    try expectEqual(career.Buy.ok, c.buy(.front, phish));
    try expectEqual(career.Buy.maxed, c.buy(.front, phish));
    try expectEqual(career.Buy.ok, c.buy(.front, @backingInt(world.Front.lance)));
    try expectEqual(world.Front.lance, c.front_of(c.racer));
    try expectEqual(@as(u8, 1), c.level(c.racer, .front));
    // Rear: 300, 600, swap 600.
    const bomb: u8 = @backingInt(world.Rear.bomb);
    try expectEqual(@as(u16, 300), c.offer(c.racer, .rear, bomb).price);
    try expectEqual(@as(u16, 600), c.offer(c.racer, .rear, @backingInt(world.Rear.leak)).price);
    // The loadout reaches the World.
    var w: World = undefined;
    sim.reset(&w, c.setup(1));
    const car = &w.cars[racers.snouty];
    try expectEqual(world.Front.lance, car.front);
    try expectEqual(@as(u8, 190), car.armor_max);
    try expect(car.ecc);
    try expectEqual(@as(u8, 4), car.burst_max);
    try expectEqual(@as(u8, 40), car.watchdog);
    // Too poor: nothing changes.
    var p = career.Career.init(racers.legacy);
    p.cycles = 499;
    try expectEqual(career.Buy.poor, p.buy(.plating, 0));
    try expectEqual(@as(u32, 499), p.cycles);
    try expectEqual(@as(u8, 0), p.level(racers.legacy, .plating));
    try expectEqual(@as(u32, 0), p.spent[racers.legacy]);
}

test "every racer has a reaction for every purchase, each fitting two rows of 19" {
    for (0..racers.count) |r| {
        for (roster_text.reactions[r].lines) |line| {
            try expect(line.len > 0);
            const k = roster_text.wrap(line, 19);
            try expect(k <= 19);
            const rest = if (k < line.len) line[k + 1 ..] else "";
            try expect(rest.len <= 19);
        }
    }
}

// --- AI plans ---------------------------------------------------------------------

test "AI plans: LEGACY never buys CLOCK, KIDDIE never PLATING; every plan is a real order" {
    for (career.plans[racers.legacy]) |s| try expect(s != .clock);
    for (career.plans[racers.kiddie]) |s| try expect(s != .plating);
    try expectEqual(career.Slot.plating, career.plans[racers.legacy][0]);
    try expectEqual(career.Slot.front, career.plans[racers.legacy][1]);
    try expectEqual(career.Slot.clock, career.plans[racers.kiddie][0]);
}

test "AI plans are deterministic and rise with the player's spending" {
    // Two careers fed the same results and the same purchases end equal.
    var a = career.Career.init(racers.snouty);
    var b = career.Career.init(racers.snouty);
    const r1 = result(.{ 4, 1, 2, 3, 5, 6 }, .{ 1, 2, 0, 1, 0, 0 }, .{ 5, 0, 3, 0, 0, 0 });
    for ([_]*career.Career{ &a, &b }) |c| {
        _ = c.finish_race(&r1);
        c.cycles = 2000;
        try expectEqual(career.Buy.ok, c.buy(.plating, 0));
        try expectEqual(career.Buy.ok, c.buy(.traction, 0));
        c.ai_shop();
    }
    try expect(std.meta.eql(a.loadouts, b.loadouts));
    try expect(std.meta.eql(a.spent, b.spent));
    // The player spent 900, so each AI has 675: LEGACY bought PLATING L1
    // (500), its plan's first step, and cannot afford front L2 (400).
    try expectEqual(@as(u8, 1), a.loadouts[racers.legacy].plating);
    try expectEqual(@as(u8, 1), a.loadouts[racers.legacy].front_level);
    try expectEqual(@as(u32, 500), a.spent[racers.legacy]);
    // KIDDIE bought CLOCK L1 (600), BURST next.
    try expectEqual(@as(u8, 1), a.loadouts[racers.kiddie].clock);
    try expectEqual(@as(u8, 0), a.loadouts[racers.kiddie].burst);
    // A player who spends more drags the field up with them.
    var rich = career.Career.init(racers.snouty);
    var poor = career.Career.init(racers.snouty);
    _ = rich.finish_race(&r1);
    _ = poor.finish_race(&r1);
    rich.cycles = 20_000;
    for ([_]career.Slot{ .plating, .plating, .clock, .clock, .traction, .watchdog, .watchdog, .burst }) |s| {
        try expectEqual(career.Buy.ok, rich.buy(s, 0));
    }
    rich.ai_shop();
    poor.ai_shop();
    var rich_n: u32 = 0;
    var poor_n: u32 = 0;
    for (0..racers.count) |r| {
        if (r == racers.snouty) continue;
        rich_n += rich.upgrades(@intCast(r));
        poor_n += poor.upgrades(@intCast(r));
        // Never past what the budget allows.
        try expect(rich.spent[r] <= rich.ai_allowance(@intCast(r)));
    }
    try expect(rich_n > poor_n + 10);
    // LEGACY never touches the engine, however rich.
    try expectEqual(@as(u8, 0), rich.loadouts[racers.legacy].clock);
    try expectEqual(@as(u8, 0), rich.loadouts[racers.kiddie].plating);
}

// --- The whole circuit -----------------------------------------------------------

const Soak = struct {
    races: u32 = 0,
    leagues: u32 = 0,
    failed: u32 = 0,
    wrecks: u32 = 0,
    kills: u32 = 0,
    chips: u32 = 0,
    bought: u32 = 0,
};

/// The garage policy of the soak's player: the cheapest next level the
/// wallet allows, again while it can (never a swap).
fn shop(c: *career.Career) u32 {
    var n: u32 = 0;
    while (true) {
        var best: ?career.Slot = null;
        var best_p: u16 = 0xFFFF;
        for (0..career.slot_count) |k| {
            const s: career.Slot = @fromBackingInt(@intCast(k));
            const own: u8 = switch (s) {
                .front => @backingInt(c.front_of(c.racer)),
                .rear => @backingInt(c.rear_of(c.racer)),
                else => 0,
            };
            const o = c.offer(c.racer, s, own);
            if (o.kind == .maxed or o.price > c.cycles or o.price >= best_p) continue;
            best = s;
            best_p = o.price;
        }
        const s = best orelse return n;
        const own: u8 = switch (s) {
            .front => @backingInt(c.front_of(c.racer)),
            .rear => @backingInt(c.rear_of(c.racer)),
            else => 0,
        };
        std.debug.assert(c.buy(s, own) == .ok);
        n += 1;
    }
}

/// One CIRCUIT race with the autopilot driving the player, to the finish.
fn circuit_race(c: *career.Career, seed: u32, soak: *Soak) !void {
    c.ai_shop();
    var w: World = undefined;
    sim.reset(&w, c.setup(seed));
    var t: u32 = 0;
    var was = false;
    while (w.phase != .finished and t < 60 * 400) : (t += 1) {
        sim.simulate(&w, .{ ai.drive_crew(&w, c.racer, &ai.crews[racers.snouty]).byte(), 0 });
        const me = &w.cars[c.racer];
        if (me.wreck != .none and !was) soak.wrecks += 1;
        was = me.wreck != .none;
    }
    try expectEqual(world.Phase.finished, w.phase);
    const a = c.finish_race(&w);
    soak.races += 1;
    soak.kills += a.kills;
    soak.chips += a.chips;
    if (report) {
        std.debug.print("\ncircuit {s} L{d} R{d}: {d} ticks, place {d}, +{d} (K{d} C{d}), wallet {d}, wrecks so far {d} |", .{ racers.roster[c.racer].name, c.league, c.race, w.tick, a.place, a.total, a.kills, a.chips, c.cycles, soak.wrecks });
        for (0..racers.count) |r| std.debug.print(" {s}:{d}", .{ racers.roster[r].name[0..3], c.upgrades(@intCast(r)) });
    }
}

fn run_circuit(racer: u8, seed0: u32) !Soak {
    var c = career.Career.init(racer);
    var soak = Soak{};
    var seed = seed0;
    while (!c.done and soak.races < 24) {
        soak.bought += shop(&c);
        seed = sim.step_rng(seed);
        try circuit_race(&c, seed, &soak);
        if (c.league_over()) {
            soak.leagues += 1;
            const o = c.close_league();
            if (o == .failed) soak.failed += 1;
            if (report) std.debug.print("\n  league over: {s}, place {d}, champion {s}", .{ @tagName(o), c.league_place, racers.roster[c.champion].name });
        }
    }
    try expect(c.done);
    try expectEqual(@as(u8, 2), c.open);
    try expect(soak.bought > 0);
    return soak;
}

test "circuit soak: the autopilot drives a whole circuit to the end card, CYCLES spent along the way" {
    // The autopilot (SNOUTY's crew) drives SNOUTY's WORKSTATION and
    // KIDDIE's THIN CLIENT (PLAN M5 status: SYSADMIN takes 24 races, the
    // MAINFRAMEs stay 5th: the autopilot is about a 4th-place driver).
    for ([_]u8{ racers.snouty, racers.kiddie }, [_]u32{ 0xC1C0_0001, 0xC1C0_0002 }) |r, s| {
        const soak = try run_circuit(r, s);
        if (report) std.debug.print("\ncircuit {s}: {d} races, {d} leagues ({d} failed), {d} wrecks, {d} kills, {d} chips, {d} bought\n", .{ racers.roster[r].name, soak.races, soak.leagues, soak.failed, soak.wrecks, soak.kills, soak.chips, soak.bought });
        try expect(soak.races >= 6);
        try expect(soak.chips > 0);
        // Dangerous (SPEC 17.12): the careful autopilot still wrecks.
        try expect(soak.wrecks >= 2 * soak.races);
    }
}

// --- A frozen arena (as weapons_test.zig's) ---------------------------------------

const Frame = struct { x: i32, y: i32, h: fixed.Turn };

fn clear_frame(w: *const World, len: i32) Frame {
    const t = sim.track_of(w);
    for (0..256) |k| {
        const s = t.sample(k);
        const hx = fixed.cos(s.tangent);
        const hy = fixed.sin(s.tangent);
        var ok = true;
        var d: i32 = -40;
        while (ok and d <= len) : (d += 2) {
            var l: i32 = -12;
            while (ok and l <= 12) : (l += 12) {
                const a = t.attr_at(@as(i32, s.x) + ((hx * d - hy * l) >> fixed.Q), @as(i32, s.y) + ((hy * d + hx * l) >> fixed.Q));
                ok = a == .surface or a == .start or a == .sector1 or a == .sector2;
            }
        }
        if (ok) return .{ .x = s.x, .y = s.y, .h = s.tangent };
    }
    @panic("no clear straight on the track");
}

fn arena() World {
    var w: World = undefined;
    sim.reset(&w, .{ .seed = 77, .humans = .{ racers.snouty, racers.legacy } });
    while (w.phase == .countdown) sim.simulate(&w, .{ 0, 0 });
    for (&w.cars, 0..) |*c, i| {
        c.active = i < 2;
        c.vx = 0;
        c.vy = 0;
        c.immune = 0;
    }
    return w;
}

fn put(w: *World, i: usize, f: Frame, along: i32, lat: i32) *Car {
    const c = &w.cars[i];
    const hx = fixed.cos(f.h);
    const hy = fixed.sin(f.h);
    c.x = ((f.x << fixed.Q) +% hx * along +% -hy * lat) & ((1024 << fixed.Q) - 1);
    c.y = ((f.y << fixed.Q) +% hy * along +% hx * lat) & ((1024 << fixed.Q) - 1);
    c.heading = f.h;
    c.vx = 0;
    c.vy = 0;
    c.active = true;
    c.hop = 0;
    c.immune = 0;
    c.wreck = .none;
    return c;
}

/// Only the weapons run (positions stay where `put` set them); car 0
/// takes `in0`.
fn frozen_tick(w: *World, in0: Input) void {
    w.rng = sim.step_rng(w.rng);
    for (&w.cars, 0..) |*c, i| {
        if (!c.active) continue;
        weapons.fire(w, i, if (i == 0) in0 else .{});
    }
    weapons.update(w);
}
