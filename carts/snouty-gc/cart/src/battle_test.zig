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

test "soak: rounds with INF lives end by time, scored on eliminations" {
    for (0..3) |k| {
        const st = play(0, 2, 77 + @as(u32, @intCast(k)) * 104729, 60 * 60 * 3);
        std.debug.print("\nbattle INF lives 2 min seed {d}: {d} ticks, end {s}, {d} elims ({d} AI on AI), {d} wrecks ({d} falls)", .{ k, st.ticks, @tagName(st.end), st.elims, st.ai_on_ai, st.wrecks, st.falls });
        try expectEqual(world.BattleEnd.time, st.end);
        try expectEqual(@as(u32, 2 * tuning.battle_minute), st.ticks);
        try expect(st.elims > 3);
        try expectEqual(@as(u32, 0), st.stuck);
    }
}

// --- Scenarios on a quiet arena: the cars not in the scenario leave the grid.

/// A round after the countdown with only the cars in `keep` (bits) on it.
fn quiet(keep: u8) World {
    var w = new_round(3, 3, 99, world.no_human);
    run_countdown(&w);
    for (&w.cars, 0..) |*c, i| {
        if (keep & (@as(u8, 1) << @intCast(i)) == 0) c.active = false;
    }
    battle.update_ranks(&w);
    return w;
}

/// Put car `i` at world px (x, y), heading `h`, moving at `v` (Q16) along it.
fn put(w: *World, i: usize, x: i32, y: i32, h: fixed.Turn, v: i32) void {
    const c = &w.cars[i];
    c.x = x << fixed.Q;
    c.y = y << fixed.Q;
    c.heading = h;
    c.vx = fixed.mul(fixed.cos(h), v);
    c.vy = fixed.mul(fixed.sin(h), v);
    c.hop = 0;
}

/// Events of `kind` since `from` (and the last one).
fn events(w: *const World, from: u16, kind: world.EventKind) struct { n: u32, last: world.Event } {
    var n: u32 = 0;
    var last: world.Event = .{};
    var s = from;
    while (s != w.event_seq) : (s +%= 1) {
        const e = w.events[s % world.event_count];
        if (e.kind == kind) {
            n += 1;
            last = e;
        }
    }
    return .{ .n = n, .last = last };
}

test "a wreck within 180 ticks of a hit is the hitter's elimination; a later one scores nobody" {
    var w = quiet(0b000111);
    const seq = w.event_seq;
    const v = &w.cars[1];
    v.last_hit_by = 2;
    v.last_hit_ticks = tuning.credit_ticks - 1;
    sim.wreck(&w, 1, .armor);
    try expectEqual(@as(u8, 1), w.cars[2].kills);
    try expectEqual(@as(u8, 2), w.cars[1].lives);
    const e = events(&w, seq, .eliminated);
    try expectEqual(@as(u32, 1), e.n);
    try expectEqual(@as(u8, 2), e.last.a);
    try expectEqual(@as(u8, 1), e.last.b);
    try expectEqual(@as(u8, 1), e.last.c);
    // The pit (or a wall, the Sweeper) with no recent hit: a life, no score.
    var w2 = quiet(0b000111);
    const seq2 = w2.event_seq;
    w2.cars[1].last_hit_by = 2;
    w2.cars[1].last_hit_ticks = tuning.credit_ticks;
    sim.wreck(&w2, 1, .fall);
    try expectEqual(@as(u8, 0), w2.cars[2].kills);
    try expectEqual(@as(u8, 2), w2.cars[1].lives);
    try expectEqual(@as(u32, 0), events(&w2, seq2, .eliminated).n);
}

test "a respawn is on the pad farthest from the nearest enemy, in SAFE MODE for 90 ticks" {
    var w = quiet(0b000111);
    const a = &track.arena;
    // Both enemies sit on pad 0; the pad farthest from both is the answer.
    for ([2]usize{ 1, 2 }) |j| put(&w, j, a.spawns[0].x, a.spawns[0].y, 0, 0);
    var far: usize = 0;
    var far_d: i32 = -1;
    for (a.spawns[0..a.spawn_n], 0..) |s, k| {
        const dx = @as(i32, s.x) - a.spawns[0].x;
        const dy = @as(i32, s.y) - a.spawns[0].y;
        if (dx * dx + dy * dy > far_d) {
            far_d = dx * dx + dy * dy;
            far = k;
        }
    }
    try expectEqual(far, battle.pad_for(&w, 0));
    battle.respawn(&w, 0);
    const c = &w.cars[0];
    try expectEqual(@as(i32, a.spawns[far].x), c.x >> fixed.Q);
    try expectEqual(a.spawns[far].heading, c.heading);
    try expectEqual(tuning.battle_safe, c.safe);
    try expectEqual(c.armor_max, c.armor);
    // SAFE MODE: no damage, no shots, no pickup.
    sim.damage(&w, 0, 1, 50);
    try expectEqual(c.armor_max, c.armor);
    c.pickup = .prefetch;
    const shots = @import("weapons.zig").projs_live(&w);
    for (0..10) |_| {
        sim.simulate(&w, .{ 0, 0 });
        // Car 0 is AI-driven here; fire and use for it directly.
        @import("weapons.zig").fire(&w, 0, .{ .a = true });
        @import("pickups.zig").control(&w, 0, .{ .b = true });
        c.b_was = false;
    }
    try expectEqual(shots, countOwn(&w, 0));
    try expectEqual(world.Pickup.prefetch, c.pickup);
    for (0..tuning.battle_safe) |_| sim.simulate(&w, .{ 0, 0 });
    try expectEqual(@as(u8, 0), c.safe);
}

fn countOwn(w: *const World, i: u8) usize {
    var n: usize = 0;
    for (&w.projs) |*p| n += @intFromBool(p.kind != .none and p.owner == i);
    return n;
}

test "out of lives: the car leaves the round with an out event; the last car left wins" {
    var w = quiet(0b000111);
    for ([2]usize{ 1, 2 }) |j| w.cars[j].lives = 1;
    w.cars[1].last_hit_by = 0;
    w.cars[1].last_hit_ticks = 0;
    const seq = w.event_seq;
    sim.wreck(&w, 1, .armor);
    try expect(!w.cars[1].active);
    try expectEqual(@as(u8, 0b10), w.battle.out);
    const o = events(&w, seq, .out);
    try expectEqual(@as(u32, 1), o.n);
    try expectEqual(@as(u8, 1), o.last.a);
    try expectEqual(@as(u8, 2), o.last.b);
    sim.simulate(&w, .{ 0, 0 });
    try expectEqual(world.Phase.racing, w.phase);
    sim.wreck(&w, 2, .fall);
    sim.simulate(&w, .{ 0, 0 });
    try expectEqual(world.Phase.finished, w.phase);
    try expectEqual(world.BattleEnd.lives, w.battle.end);
    try expect(w.cars[0].finished);
    // Ranks: car 0 (1 elimination) first; car 2 (out later) over car 1.
    try expectEqual(@as(u8, 1), w.cars[0].rank);
    try expectEqual(@as(u8, 2), w.cars[2].rank);
    try expectEqual(@as(u8, 3), w.cars[1].rank);
    try expectEqual(@as(u8, 0), w.cars[3].rank);
}

test "the clock ends the round; standings go by eliminations, lives, then time survived" {
    var w = quiet(0b001111);
    w.cars[3].kills = 2;
    w.cars[1].kills = 1;
    w.cars[2].kills = 1;
    w.cars[2].lives = 1;
    w.cars[0].lives = 2;
    w.tick = w.battle.limit - 1;
    sim.simulate(&w, .{ 0, 0 });
    try expectEqual(world.BattleEnd.time, w.battle.end);
    try expectEqual(world.Phase.finished, w.phase);
    try expectEqual(@as(u8, 1), w.cars[3].rank);
    try expectEqual(@as(u8, 2), w.cars[1].rank); // 1 elimination, 3 lives
    try expectEqual(@as(u8, 3), w.cars[2].rank); // 1 elimination, 1 life
    try expectEqual(@as(u8, 4), w.cars[0].rank);
    try expectEqual(@as(u8, 3), w.battle.leader);
}

test "INF lives: nobody is ever out, and fewer wrecks rank first among equals" {
    var w = new_round(0, 2, 5, world.no_human);
    run_countdown(&w);
    for (0..5) |_| {
        sim.wreck(&w, 4, .fall);
        w.cars[4].wreck = .none;
    }
    try expect(w.cars[4].active);
    try expectEqual(@as(u8, 0), w.battle.out);
    battle.update_ranks(&w);
    try expectEqual(@as(u8, 6), w.cars[4].rank);
}

test "ammo and burst charges refill every 1200 ticks" {
    var w = quiet(0b000011);
    const c = &w.cars[0];
    c.ammo_front = 0;
    c.ammo_rear = 0;
    c.burst_charges = 0;
    w.battle.refill = 1;
    sim.simulate(&w, .{ 0, 0 });
    try expect(c.ammo_front > 0 and c.ammo_rear > 0);
    try expectEqual(c.burst_max, c.burst_charges);
    try expectEqual(tuning.battle_refill, w.battle.refill);
}

/// An open spot of floor: the north plaza's middle.
fn plaza(w: *const World) [2]i32 {
    _ = w;
    for (track.arena.nodes[0..track.arena.node_n]) |n| {
        if (n.need() != 0 and n.x > 400 and n.x < 600 and n.y < 400) return .{ n.x, n.y - 24 };
    }
    unreachable;
}

test "STACK SMASH: landing on a car deals 40 and counts as the hit; CLEAN LANDING gives a burst back" {
    var w = quiet(0b000011);
    const p = plaza(&w);
    put(&w, 0, p[0], p[1], 0, 0);
    put(&w, 1, p[0] + 4, p[1], 0, 0);
    w.cars[0].hop = 1;
    w.cars[1].ammo_front = 0;
    const seq = w.event_seq;
    const before = w.cars[1].armor;
    sim.simulate(&w, .{ 0, 0 });
    const s = events(&w, seq, .stack_smash);
    try expectEqual(@as(u32, 1), s.n);
    try expectEqual(@as(u8, 0), s.last.a);
    try expectEqual(tuning.smash_damage, s.last.c);
    try expect(before - w.cars[1].armor >= tuning.smash_damage);
    try expectEqual(@as(u8, 0), w.cars[1].last_hit_by);
    // A landing on open floor with no car under it.
    var w2 = quiet(0b000011);
    put(&w2, 0, p[0], p[1], 0, fixed.one);
    put(&w2, 1, p[0] + 200, p[1] + 200, 0, 0);
    w2.cars[0].hop = 1;
    w2.cars[0].burst_charges = 0;
    const seq2 = w2.event_seq;
    sim.simulate(&w2, .{ 0, 0 });
    try expectEqual(@as(u8, 1), w2.cars[0].burst_charges);
    try expectEqual(@as(u32, 1), events(&w2, seq2, .clean_landing).n);
}

test "the bit bucket: a kicker at speed jumps it, a crawl falls in" {
    const a = &track.arena;
    track.select(track.arenas[0]);
    // Every jump node pair over the pit: (approach, landing).
    var jumps: u32 = 0;
    for (a.nodes[0..a.node_n]) |n| {
        if (n.jump == track.no_node or n.need() == 0) continue;
        const l = a.nodes[n.jump];
        const h = fixed.atan2(@as(i32, l.y) - n.y, @as(i32, l.x) - n.x);
        // The bit bucket's jumps are the long ones; a crawl over a corner
        // gap can make it on the ramp's relaunch, so only the bucket's
        // crawl must fall.
        const span = @abs(@as(i32, l.y) - n.y) + @abs(@as(i32, l.x) - n.x);
        for ([2]bool{ true, false }) |fast| {
            if (!fast and span < 250) continue;
            var w = quiet(0b000001);
            w.combat = false;
            const v: i32 = if (fast) sim.top_of(&w.cars[0]) else fixed.one;
            // The crawl starts 50 px down the run-up (clear of the Sweeper).
            const run: i32 = if (fast) 0 else 50;
            put(&w, 0, n.x + ((fixed.cos(h) * run) >> fixed.Q), n.y + ((fixed.sin(h) * run) >> fixed.Q), h, v);
            w.cars[0].human = 0;
            var fell = false;
            var t: u32 = 0;
            // The crawl holds the brake (about 0.7 px/tick).
            while (t < 260) : (t += 1) {
                sim.simulate(&w, .{ if (fast) 0 else world.Input.byte(.{ .down = true }), 0 });
                if (w.cars[0].wreck == .fall) fell = true;
            }
            try expectEqual(!fast, fell);
        }
        jumps += 1;
    }
    try expectEqual(@as(u32, 12), jumps);
}

test "ahead in an arena: the nearest car in the front cone, else the nearest" {
    const pickups = @import("pickups.zig");
    var w = quiet(0b001111);
    const p = plaza(&w);
    put(&w, 0, p[0], p[1], 0, 0); // facing east
    put(&w, 1, p[0] - 50, p[1], 0, 0); // behind, nearest
    put(&w, 2, p[0] + 100, p[1] + 90, 0, 0); // 42 degrees right, in the cone
    put(&w, 3, p[0] + 10, p[1] + 70, 0, 0); // off the cone's side
    try expectEqual(@as(u8, 2), pickups.ahead(&w, 0, std.math.maxInt(i32), true, world.no_car));
    w.cars[2].active = false;
    try expectEqual(@as(u8, 1), pickups.ahead(&w, 0, std.math.maxInt(i32), true, world.no_car));
    try expectEqual(world.no_car, pickups.ahead(&w, 0, 40, true, world.no_car));
}

test "ZERO-DAY rolls only for the bottom two of the battle standings" {
    const pickups = @import("pickups.zig");
    var w = quiet(0b011111);
    var seen: [6]bool = @splat(false);
    for (1..6) |rank| {
        for (0..2000) |_| {
            if (pickups.roll_pickup(&w, @intCast(rank), true) == .zero_day) seen[rank] = true;
        }
    }
    // Five cars stand: ranks 4 and 5 are the bottom two.
    try expect(!seen[1] and !seen[2] and !seen[3]);
    try expect(seen[4] and seen[5]);
}

test "KERNEL PANIC runs the navigation field to the kill leader" {
    const pickups = @import("pickups.zig");
    var w = quiet(0b000111);
    w.combat = true;
    w.cars[2].kills = 3;
    battle.update_ranks(&w);
    w.cars[0].pickup = .kernel_panic;
    w.cars[0].roll_ticks = 0;
    const seq = w.event_seq;
    pickups.use(&w, 0, false);
    const u = events(&w, seq, .use);
    try expectEqual(@as(u8, 2), u.last.c);
    var hit = false;
    var t: u32 = 0;
    while (t < 900 and !hit) : (t += 1) {
        sim.simulate(&w, .{ 0, 0 });
        hit = w.cars[2].frozen_by == .panic;
    }
    try expect(hit);
    // The leader's own packet goes to 2nd.
    w.cars[2].pickup = .kernel_panic;
    w.cars[1].kills = 1;
    battle.update_ranks(&w);
    const seq2 = w.event_seq;
    pickups.use(&w, 2, false);
    try expectEqual(@as(u8, 1), events(&w, seq2, .use).last.c);
}

test "a hunter below 30% armor makes for a service bay" {
    var w = quiet(0b000011);
    w.combat = false;
    const c = &w.cars[0];
    c.armor = c.armor_max / 5;
    var t: u32 = 0;
    var bay = false;
    while (t < 1500 and !bay) : (t += 1) {
        sim.simulate(&w, .{ 0, 0 });
        bay = c.on_bay;
        if (c.wreck != .none) break;
    }
    try expect(bay);
}

test "battle determinism: the same setup twice is the same round; a copy runs on alike" {
    var a = new_round(3, 3, 4242, racers.kiddie);
    var b = new_round(3, 3, 4242, racers.kiddie);
    run_countdown(&a);
    run_countdown(&b);
    for (0..2500) |_| {
        sim.simulate(&a, .{ ai.drive(&a, racers.kiddie).byte(), 0 });
        sim.simulate(&b, .{ ai.drive(&b, racers.kiddie).byte(), 0 });
    }
    try expect(sim.worlds_equal(&a, &b));
    var c = a;
    for (0..1500) |_| {
        sim.simulate(&a, .{ ai.drive(&a, racers.kiddie).byte(), 0 });
        sim.simulate(&c, .{ ai.drive(&c, racers.kiddie).byte(), 0 });
    }
    try expect(sim.worlds_equal(&a, &c));
}
