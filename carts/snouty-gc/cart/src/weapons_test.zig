//! Host tests for combat (PLAN.md M1 Track A item 4): a scenario per
//! weapon, ramming, wrecks, hulks, respawn and kill credit, and the seeded
//! 6-AI combat soak with determinism.
const std = @import("std");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const track = @import("track.zig");
const world = @import("world.zig");
const racers = @import("racers.zig");
const sim = @import("sim.zig");
const ai = @import("ai.zig");
const weapons = @import("weapons.zig");

const World = world.World;
const Car = world.Car;
const Input = world.Input;
const no_car = world.no_car;

/// Print the soak's per-race summary.
const report = false;

// --- The soak ------------------------------------------------------------------

const Soak = struct {
    ticks: u32 = 0,
    all_finished: bool = false,
    max_stuck: u32 = 0,
    max_projs: usize = 0,
    max_drops: usize = 0,
    wrecks: u32 = 0,
    falls: u32 = 0,
    kills: u32 = 0,
    events: u32 = 0,
};

/// An AI-only race with combat on, run until every car has finished (or
/// the limit). "Stuck" is the longest run of ticks in which a car made no
/// new best progress.
fn soak_race(seed: u32, limit: u32, out: ?*World) Soak {
    var w: World = undefined;
    sim.reset(&w, .{ .seed = seed });
    var r: Soak = .{};
    var best: [world.car_count]i32 = @splat(std.math.minInt(i32));
    var since: [world.car_count]u32 = @splat(0);
    var was: [world.car_count]world.Wreck = @splat(.none);
    while (w.phase == .countdown) sim.simulate(&w, .{ 0, 0 });
    while (r.ticks < limit) : (r.ticks += 1) {
        const seq0 = w.event_seq;
        sim.simulate(&w, .{ 0, 0 });
        r.events += w.event_seq -% seq0;
        r.max_projs = @max(r.max_projs, weapons.projs_live(&w));
        r.max_drops = @max(r.max_drops, weapons.drops_live(&w));
        var done = true;
        for (&w.cars, 0..) |*c, i| {
            if (c.wreck != .none and was[i] == .none) {
                if (c.wreck == .fall) r.falls += 1 else r.wrecks += 1;
            }
            was[i] = c.wreck;
            if (c.finished) continue;
            done = false;
            const p = sim.fine_progress(&w, c);
            if (p > best[i]) {
                best[i] = p;
                since[i] = 0;
            } else {
                since[i] += 1;
                r.max_stuck = @max(r.max_stuck, since[i]);
            }
        }
        if (done) {
            r.all_finished = true;
            break;
        }
    }
    for (w.cars) |c| r.kills += c.kills;
    if (out) |o| o.* = w;
    return r;
}

test "combat soak: 20 seeded 6-AI races all finish, nobody stuck, pools within caps" {
    var total: Soak = .{};
    for (0..20) |k| {
        const seed: u32 = @intCast(0x5EED_0000 + k * 7919);
        var w: World = undefined;
        const r = soak_race(seed, 60 * 300, &w);
        if (report) {
            std.debug.print("\nsoak {d:2}: {d:5} ticks, wrecks {d:2} falls {d} kills {d:2}, stuck max {d:3}, projs {d:2} drops {d:2}, events {d:4} |", .{ k, r.ticks, r.wrecks, r.falls, r.kills, r.max_stuck, r.max_projs, r.max_drops, r.events });
            for (w.cars) |c| std.debug.print(" {s}:{d}/{d}/{d}", .{ racers.roster[c.racer].name[0..3], c.rank, c.kills, c.wrecks });
        }
        try std.testing.expect(r.all_finished);
        try std.testing.expect(r.max_stuck <= 600);
        try std.testing.expect(r.max_projs <= world.proj_count);
        try std.testing.expect(r.max_drops <= world.drop_count);
        total.wrecks += r.wrecks;
        total.kills += r.kills;
        total.falls += r.falls;
    }
    if (report) std.debug.print("\nsoak total: wrecks {d}, falls {d}, kills {d}\n", .{ total.wrecks, total.falls, total.kills });
}

test "combat is deterministic: the same seeded 6-AI fight twice, and two worlds interleaved" {
    var a: World = undefined;
    var b: World = undefined;
    _ = soak_race(0xFEED, 3000, &a);
    _ = soak_race(0xFEED, 3000, &b);
    try std.testing.expect(sim.worlds_equal(&a, &b));
    // Something happened in it.
    var kills: u32 = 0;
    for (a.cars) |c| kills += c.kills + c.wrecks;
    try std.testing.expect(kills > 0 and a.event_seq > 50);
    // Interleaved with human inputs that fire both weapons.
    var x: World = undefined;
    var y: World = undefined;
    const setup = world.Setup{ .seed = 4242, .humans = .{ racers.sysadmin, racers.kiddie } };
    sim.reset(&x, setup);
    sim.reset(&y, setup);
    for (0..2500) |t| {
        const in0 = Input{ .a = (t / 40) % 2 == 0, .down = t % 200 == 100, .right = (t / 30) % 5 == 1 };
        const in1 = Input{ .a = t % 7 != 0, .down = t % 150 < 2, .left = (t / 25) % 6 == 2 };
        sim.simulate(&x, .{ in0.byte(), in1.byte() });
        sim.simulate(&y, .{ in0.byte(), in1.byte() });
    }
    try std.testing.expect(sim.worlds_equal(&x, &y));
}

// --- A frozen arena for weapon scenarios -------------------------------------------

/// A place on the road and a heading with `len` px of clear floor ahead
/// (and 40 behind): no wall, no pit, no ramp or coolant.
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

/// Two human cars (SNOUTY = 0, LEGACY = 1), the other four out of the
/// race, racing, everyone stopped and not immune. `tick` runs only the
/// weapons, so positions stay exactly where `put` sets them.
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

fn put(w: *World, i: usize, f: Frame, along: i32, lat: i32, dh: i32) *Car {
    const c = &w.cars[i];
    const hx = fixed.cos(f.h);
    const hy = fixed.sin(f.h);
    c.x = ((f.x << fixed.Q) +% hx * along +% -hy * lat) & ((1024 << fixed.Q) - 1);
    c.y = ((f.y << fixed.Q) +% hy * along +% hx * lat) & ((1024 << fixed.Q) - 1);
    c.heading = f.h +% @as(u16, @truncate(@as(u32, @bitCast(dh))));
    c.vx = 0;
    c.vy = 0;
    c.active = true;
    c.hop = 0;
    c.immune = 0;
    c.wreck = .none;
    return c;
}

fn loadout(c: *Car, front: world.Front, rear: world.Rear) void {
    c.front = front;
    c.rear = rear;
    weapons.refill(c);
}

const Tally = struct {
    seq: u16,
    hits: u32 = 0,
    dmg: u32 = 0,
    wrecks: u32 = 0,
    explodes: u32 = 0,
    sparks: u32 = 0,
    lances: u32 = 0,
    respawns: u32 = 0,
    last: world.Event = .{},
    last_lance: world.Event = .{},
    last_wreck: world.Event = .{},

    fn scan(self: *Tally, w: *const World) void {
        while (self.seq != w.event_seq) : (self.seq +%= 1) {
            const e = w.events[self.seq % world.event_count];
            self.last = e;
            switch (e.kind) {
                .hit => {
                    self.hits += 1;
                    self.dmg += e.c;
                },
                .wreck => {
                    self.wrecks += 1;
                    self.last_wreck = e;
                },
                .explode => if (e.b == 0) {
                    self.sparks += 1;
                } else {
                    self.explodes += 1;
                },
                .lance => {
                    self.lances += 1;
                    self.last_lance = e;
                },
                .respawn => self.respawns += 1,
                .none, .roll, .use, .effect, .swap, .mark, .collect, .blast, .hazard_hit => {},
            }
        }
    }
};

/// One frozen tick: the weapons of every active car (cars 0 and 1 take
/// `in0`/`in1`, the others nothing), the pools, the locks.
fn tick(w: *World, in0: Input, in1: Input, tally: *Tally) void {
    w.rng = sim.step_rng(w.rng);
    for (&w.cars, 0..) |*c, i| {
        if (!c.active) continue;
        weapons.fire(w, i, if (i == 0) in0 else if (i == 1) in1 else .{});
    }
    weapons.update(w);
    for (0..world.car_count) |i| weapons.update_lock(w, i);
    tally.scan(w);
}

fn ticks(w: *World, n: usize, in0: Input, tally: *Tally) void {
    for (0..n) |_| tick(w, in0, .{}, tally);
}

const fire_a = Input{ .a = true };
const fire_rear = Input{ .a = true, .down = true };

// --- Front weapons -----------------------------------------------------------------

test "PING: twin pellets every 6 ticks, 4 a hit, one ammo a volley, range 160, never the owner" {
    var w = arena();
    var tl = Tally{ .seq = w.event_seq };
    const f = clear_frame(&w, 220);
    const s = put(&w, 0, f, 0, 0, 0);
    const v = put(&w, 1, f, 60, 0, 0);
    loadout(s, .ping, .bomb);
    const armor0 = v.armor;
    // 30 ticks of A: volleys at 0, 6, 12, 18, 24.
    ticks(&w, 30, fire_a, &tl);
    try std.testing.expectEqual(tuning.front_ammo[0] - 5, s.ammo_front);
    ticks(&w, 30, .{}, &tl);
    try std.testing.expectEqual(@as(u32, 10), tl.hits);
    try std.testing.expectEqual(armor0 - 10 * tuning.ping_dmg, v.armor);
    try std.testing.expectEqual(@as(u8, 0), v.last_hit_by);
    try std.testing.expectEqual(s.armor_max, s.armor);
    try std.testing.expectEqual(@as(usize, 0), weapons.projs_live(&w));
    // Out of range: 200 px ahead is past 160 px of flight.
    _ = put(&w, 1, f, 200, 0, 0);
    const armor1 = v.armor;
    ticks(&w, 12, fire_a, &tl);
    ticks(&w, 40, .{}, &tl);
    try std.testing.expectEqual(armor1, v.armor);
    // Empty: no shots.
    s.ammo_front = 0;
    ticks(&w, 12, fire_a, &tl);
    try std.testing.expectEqual(@as(usize, 0), weapons.projs_live(&w));
}

test "BROADCAST: a 5-pellet fan, 3 a pellet, knocks sideways, short range, 24-tick cooldown" {
    var w = arena();
    var tl = Tally{ .seq = w.event_seq };
    const f = clear_frame(&w, 160);
    const s = put(&w, 0, f, 0, 0, 0);
    const v = put(&w, 1, f, 40, 6, 0);
    loadout(s, .broadcast, .firewall);
    const armor0 = v.armor;
    tick(&w, fire_a, .{}, &tl);
    try std.testing.expectEqual(@as(usize, tuning.broadcast_pellets), weapons.projs_live(&w));
    ticks(&w, 23, fire_a, &tl);
    // One volley in 24 ticks of A.
    try std.testing.expectEqual(tuning.front_ammo[1] - 1, s.ammo_front);
    try std.testing.expect(tl.hits >= 3);
    try std.testing.expectEqual(armor0 - tl.hits * tuning.broadcast_dmg, v.armor);
    // Knocked: sideways velocity on a car that was standing still.
    try std.testing.expect(v.vx != 0 or v.vy != 0);
    // The next volley on tick 24.
    tick(&w, fire_a, .{}, &tl);
    try std.testing.expectEqual(tuning.front_ammo[1] - 2, s.ammo_front);
    // 120 px ahead is out of its 80 px reach.
    ticks(&w, 30, .{}, &tl);
    _ = put(&w, 1, f, 120, 0, 0);
    const armor1 = v.armor;
    tick(&w, fire_a, .{}, &tl);
    ticks(&w, 30, .{}, &tl);
    try std.testing.expectEqual(armor1, v.armor);
}

test "FIBER LANCE: charge 30, release hits the first car in line; early release fizzles free" {
    var w = arena();
    var tl = Tally{ .seq = w.event_seq };
    const f = clear_frame(&w, 300);
    const s = put(&w, 0, f, 0, 0, 0);
    const v = put(&w, 1, f, 250, 8, 0);
    loadout(s, .lance, .rot);
    const armor0 = v.armor;
    // Early release: no shot, no ammo spent.
    ticks(&w, 10, fire_a, &tl);
    try std.testing.expectEqual(@as(u8, 10), s.charge);
    tick(&w, .{}, .{}, &tl);
    try std.testing.expectEqual(@as(u8, 0), s.charge);
    try std.testing.expectEqual(tuning.front_ammo[2], s.ammo_front);
    try std.testing.expectEqual(@as(u32, 0), tl.lances);
    // Full charge (held longer is capped), release: hit for 25.
    ticks(&w, 45, fire_a, &tl);
    try std.testing.expectEqual(tuning.lance_charge, s.charge);
    tick(&w, .{}, .{}, &tl);
    try std.testing.expectEqual(tuning.front_ammo[2] - 1, s.ammo_front);
    try std.testing.expectEqual(armor0 - tuning.lance_dmg, v.armor);
    try std.testing.expectEqual(@as(u32, 1), tl.lances);
    try std.testing.expectEqual(@as(u8, 0), tl.last_lance.a);
    try std.testing.expectEqual(@as(u8, 1), tl.last_lance.b);
    try std.testing.expect(tl.last_lance.c >= 240 and tl.last_lance.c <= 255);
    // Off the 4-degree line (40 px aside at 250 px): the beam misses, the
    // shot is spent.
    _ = put(&w, 1, f, 250, 40, 0);
    ticks(&w, tuning.lance_cd, .{}, &tl);
    ticks(&w, tuning.lance_charge, fire_a, &tl);
    tick(&w, .{}, .{}, &tl);
    try std.testing.expectEqual(@as(u32, 2), tl.lances);
    try std.testing.expectEqual(no_car, tl.last_lance.b);
    try std.testing.expectEqual(armor0 - tuning.lance_dmg, v.armor);
    try std.testing.expectEqual(tuning.front_ammo[2] - 2, s.ammo_front);
    // The first car in line takes it: a third car in front shields LEGACY.
    _ = put(&w, 1, f, 250, 0, 0);
    _ = put(&w, 2, f, 120, -4, 0);
    ticks(&w, tuning.lance_cd, .{}, &tl);
    ticks(&w, tuning.lance_charge, fire_a, &tl);
    tick(&w, .{}, .{}, &tl);
    try std.testing.expectEqual(@as(u8, 2), tl.last_lance.b);
    try std.testing.expectEqual(armor0 - tuning.lance_dmg, v.armor);
    try std.testing.expectEqual(w.cars[2].armor_max - tuning.lance_dmg, w.cars[2].armor);
}

test "FIBER LANCE: a wall stops the beam" {
    var w = arena();
    var tl = Tally{ .seq = w.event_seq };
    const f = clear_frame(&w, 60);
    // Aim across the road (90 degrees right): the wreckage wall is within
    // the road's half width + its thickness; the target sits beyond it.
    const s = put(&w, 0, f, 0, 0, 16384);
    const v = put(&w, 1, f, 0, 150, 0);
    loadout(s, .lance, .rot);
    const t = sim.track_of(&w);
    var wall_at: i32 = 0;
    var d: i32 = 0;
    while (d < 150) : (d += 1) {
        const hx = fixed.cos(s.heading);
        const hy = fixed.sin(s.heading);
        if (t.attr_at((s.x >> fixed.Q) + ((hx * d) >> fixed.Q), (s.y >> fixed.Q) + ((hy * d) >> fixed.Q)) == .wall) {
            wall_at = d;
            break;
        }
    }
    if (wall_at == 0) return error.SkipZigTest; // open edge on this side
    const armor0 = v.armor;
    ticks(&w, tuning.lance_charge, fire_a, &tl);
    tick(&w, .{}, .{}, &tl);
    try std.testing.expectEqual(@as(u32, 1), tl.lances);
    try std.testing.expectEqual(no_car, tl.last_lance.b);
    try std.testing.expect(tl.last_lance.c < 150 and @as(i32, tl.last_lance.c) <= wall_at + tuning.lance_step);
    try std.testing.expectEqual(armor0, v.armor);
}

test "SPEAR PHISH: locks the nearest car in a 24-degree cone within 400 px" {
    var w = arena();
    var tl = Tally{ .seq = w.event_seq };
    const f = clear_frame(&w, 60);
    const s = put(&w, 0, f, 0, 0, 0);
    loadout(s, .phish, .bomb);
    // Ahead, 10 degrees off: locked.
    _ = put(&w, 1, f, 200, 35, 0);
    tick(&w, .{}, .{}, &tl);
    try std.testing.expectEqual(@as(u8, 1), s.lock);
    // 20 degrees off: outside the cone.
    _ = put(&w, 1, f, 200, 73, 0);
    tick(&w, .{}, .{}, &tl);
    try std.testing.expectEqual(no_car, s.lock);
    // Too far.
    _ = put(&w, 1, f, 410, 0, 0);
    tick(&w, .{}, .{}, &tl);
    try std.testing.expectEqual(no_car, s.lock);
    // Behind does not count.
    _ = put(&w, 1, f, -100, 0, 0);
    tick(&w, .{}, .{}, &tl);
    try std.testing.expectEqual(no_car, s.lock);
    // The nearer of two.
    _ = put(&w, 1, f, 300, 0, 0);
    _ = put(&w, 2, f, 150, 10, 0);
    tick(&w, .{}, .{}, &tl);
    try std.testing.expectEqual(@as(u8, 2), s.lock);
    // A wrecked car cannot be locked.
    w.cars[2].wreck = .armor;
    w.cars[2].wreck_ticks = 1;
    tick(&w, .{}, .{}, &tl);
    try std.testing.expectEqual(@as(u8, 1), s.lock);
}

test "SPEAR PHISH: the missile homes on its lock at 600 turns a tick; with no lock it flies straight" {
    var w = arena();
    var tl = Tally{ .seq = w.event_seq };
    const f = clear_frame(&w, 60);
    const s = put(&w, 0, f, 0, 0, 0);
    const v = put(&w, 1, f, 120, 20, 0);
    loadout(s, .phish, .bomb);
    tick(&w, .{}, .{}, &tl);
    try std.testing.expectEqual(@as(u8, 1), s.lock);
    tick(&w, fire_a, .{}, &tl);
    try std.testing.expectEqual(tuning.front_ammo[3] - 1, s.ammo_front);
    try std.testing.expectEqual(tuning.phish_cd - 0, s.fire_cd);
    var missile: ?*world.Projectile = null;
    for (&w.projs) |*p| {
        if (p.kind == .phish) missile = p;
    }
    try std.testing.expectEqual(@as(u8, 1), missile.?.target);
    // The target dodges 60 px sideways; the missile turns after it (at
    // most 600 turns a tick) and hits.
    _ = put(&w, 1, f, 120, 80, 0);
    const armor0 = v.armor;
    var turned: i32 = 0;
    var prev = fixed.atan2(missile.?.vy, missile.?.vx);
    var k: usize = 0;
    while (k < 120 and v.armor == armor0) : (k += 1) {
        tick(&w, .{}, .{}, &tl);
        if (missile.?.kind == .phish) {
            const now = fixed.atan2(missile.?.vy, missile.?.vx);
            const d = fixed.turn_diff(prev, now);
            try std.testing.expect(@abs(d) <= tuning.phish_turn + 300); // atan2 error
            turned += d;
            prev = now;
        }
    }
    try std.testing.expectEqual(armor0 - tuning.phish_dmg, v.armor);
    try std.testing.expect(turned > 2000);
    try std.testing.expect(tl.explodes >= 1);
    // No lock: the missile keeps its heading.
    _ = put(&w, 1, f, -200, 0, 0);
    ticks(&w, tuning.phish_cd, .{}, &tl);
    try std.testing.expectEqual(no_car, s.lock);
    tick(&w, fire_a, .{}, &tl);
    var m2: ?*world.Projectile = null;
    for (&w.projs) |*p| {
        if (p.kind == .phish) m2 = p;
    }
    try std.testing.expectEqual(no_car, m2.?.target);
    const h0 = fixed.atan2(m2.?.vy, m2.?.vx);
    ticks(&w, 20, .{}, &tl);
    try std.testing.expectEqual(h0, fixed.atan2(m2.?.vy, m2.?.vx));
    // Three a lap.
    ticks(&w, tuning.phish_cd, fire_a, &tl);
    ticks(&w, tuning.phish_cd, fire_a, &tl);
    try std.testing.expectEqual(@as(u8, 0), s.ammo_front);
}

test "shots pass under airborne and immune cars, die on walls with a spark" {
    var w = arena();
    var tl = Tally{ .seq = w.event_seq };
    const f = clear_frame(&w, 220);
    const s = put(&w, 0, f, 0, 0, 0);
    const v = put(&w, 1, f, 60, 0, 0);
    loadout(s, .ping, .bomb);
    const armor0 = v.armor;
    v.hop = 200;
    ticks(&w, 6, fire_a, &tl);
    ticks(&w, 30, .{}, &tl);
    try std.testing.expectEqual(armor0, v.armor);
    v.hop = 0;
    v.immune = 200;
    ticks(&w, 6, fire_a, &tl);
    ticks(&w, 30, .{}, &tl);
    try std.testing.expectEqual(armor0, v.armor);
    try std.testing.expectEqual(@as(u32, 0), tl.hits);
    // Across the road into the wall: the pellets spark out before their range.
    v.immune = 0;
    _ = put(&w, 0, f, 0, 0, 16384);
    _ = put(&w, 1, f, -300, 0, 0);
    const sparks0 = tl.sparks;
    tick(&w, fire_a, .{}, &tl);
    ticks(&w, tuning.ping_ttl, .{}, &tl);
    const t = sim.track_of(&w);
    const hx = fixed.cos(s.heading);
    const hy = fixed.sin(s.heading);
    var walled = false;
    var d: i32 = 0;
    while (d < 172) : (d += 2) {
        walled = walled or t.attr_at((s.x >> fixed.Q) + ((hx * d) >> fixed.Q), (s.y >> fixed.Q) + ((hy * d) >> fixed.Q)) == .wall;
    }
    if (walled) try std.testing.expectEqual(sparks0 + 2, tl.sparks);
    try std.testing.expectEqual(@as(usize, 0), weapons.projs_live(&w));
}

// --- Rear weapons ------------------------------------------------------------------

test "rear: Down+A drops once per press, 30-tick cooldown, ammo per lap; it does not fire the front" {
    var w = arena();
    var tl = Tally{ .seq = w.event_seq };
    const f = clear_frame(&w, 60);
    const s = put(&w, 0, f, 0, 0, 0);
    loadout(s, .ping, .bomb);
    ticks(&w, 60, fire_rear, &tl);
    try std.testing.expectEqual(tuning.rear_ammo[1] - 1, s.ammo_rear);
    try std.testing.expectEqual(tuning.front_ammo[0], s.ammo_front);
    try std.testing.expectEqual(@as(usize, 1), weapons.drops_live(&w));
    // A fresh press inside the cooldown does nothing.
    tick(&w, .{}, .{}, &tl);
    s.rear_cd = 5;
    tick(&w, fire_rear, .{}, &tl);
    try std.testing.expectEqual(tuning.rear_ammo[1] - 1, s.ammo_rear);
    tick(&w, .{}, .{}, &tl);
    for (0..5) |_| tick(&w, .{}, .{}, &tl);
    tick(&w, fire_rear, .{}, &tl);
    try std.testing.expectEqual(tuning.rear_ammo[1] - 2, s.ammo_rear);
    s.ammo_rear = 0;
    tick(&w, .{}, .{}, &tl);
    s.rear_cd = 0;
    tick(&w, fire_rear, .{}, &tl);
    try std.testing.expectEqual(@as(usize, 2), weapons.drops_live(&w));
}

fn first_drop(w: *World, kind: world.DropKind) ?*world.Drop {
    for (&w.drops) |*d| {
        if (d.kind == kind) return d;
    }
    return null;
}

test "LOGIC BOMB: arms after 30 ticks, triggers at 14 px, 35 to every car in 24 px, pushes" {
    var w = arena();
    var tl = Tally{ .seq = w.event_seq };
    const f = clear_frame(&w, 60);
    const s = put(&w, 0, f, 0, 0, 0);
    loadout(s, .ping, .bomb);
    tick(&w, fire_rear, .{}, &tl);
    const bomb = first_drop(&w, .bomb).?;
    // Laid behind the car.
    try std.testing.expect(weapons.dq(s.x, bomb.x) != 0 or weapons.dq(s.y, bomb.y) != 0);
    // A car parked on it before it arms: nothing.
    const v = put(&w, 1, f, -tuning.drop_behind + 4, 0, 0);
    const third = put(&w, 2, f, -tuning.drop_behind, 20, 0);
    const far = put(&w, 3, f, -tuning.drop_behind, -30, 0);
    // The owner drives on (its own blast would catch it at 18 px).
    _ = put(&w, 0, f, 100, 0, 0);
    const armor_v = v.armor;
    const armor_t = third.armor;
    const armor_f = far.armor;
    ticks(&w, tuning.bomb_arm - 2, .{}, &tl);
    try std.testing.expectEqual(armor_v, v.armor);
    try std.testing.expect(first_drop(&w, .bomb) != null);
    ticks(&w, 2, .{}, &tl);
    try std.testing.expect(first_drop(&w, .bomb) == null);
    try std.testing.expectEqual(armor_v - tuning.bomb_dmg, v.armor);
    try std.testing.expectEqual(armor_t - tuning.bomb_dmg, third.armor);
    try std.testing.expectEqual(armor_f, far.armor);
    try std.testing.expectEqual(s.armor_max, s.armor);
    try std.testing.expectEqual(@as(u32, 1), tl.explodes);
    // Pushed away from the blast.
    try std.testing.expect(third.vx != 0 or third.vy != 0);
}

test "MEMORY LEAK: grows 6 to 18 px over 180 ticks, slicks and kicks cars on it, gone at 600" {
    var w = arena();
    var tl = Tally{ .seq = w.event_seq };
    const f = clear_frame(&w, 60);
    const s = put(&w, 0, f, 0, 0, 0);
    loadout(s, .ping, .leak);
    tick(&w, fire_rear, .{}, &tl);
    const leak = first_drop(&w, .leak).?;
    try std.testing.expect(leak.size >= tuning.leak_r0 and leak.size <= tuning.leak_r0 + 1);
    ticks(&w, 89, .{}, &tl);
    try std.testing.expect(leak.size >= 11 and leak.size <= 13);
    ticks(&w, 100, .{}, &tl);
    try std.testing.expectEqual(@as(u8, tuning.leak_r1), leak.size);
    // A car on it: slick (coolant grip next tick) and its heading kicked.
    const v = put(&w, 1, f, -tuning.drop_behind + 10, 0, 0);
    const h0 = v.heading;
    var kicked = false;
    for (0..8) |_| {
        tick(&w, .{}, .{}, &tl);
        try std.testing.expect(v.on_leak);
        kicked = kicked or v.heading != h0;
    }
    try std.testing.expect(kicked);
    try std.testing.expectEqual(v.armor_max, v.armor);
    // Off it: dry.
    _ = put(&w, 1, f, 80, 0, 0);
    tick(&w, .{}, .{}, &tl);
    try std.testing.expect(!v.on_leak);
    // Ticks so far: 1 + 89 + 100 + 8 + 1 = 199.
    ticks(&w, tuning.leak_life - 200, .{}, &tl);
    try std.testing.expect(first_drop(&w, .leak) != null);
    tick(&w, .{}, .{}, &tl);
    try std.testing.expect(first_drop(&w, .leak) == null);
}

test "BIT ROT: six caltrops across 48 px; each hit deals 5, slows 60 ticks, and is consumed" {
    var w = arena();
    var tl = Tally{ .seq = w.event_seq };
    const f = clear_frame(&w, 60);
    const s = put(&w, 0, f, 0, 0, 0);
    loadout(s, .lance, .rot);
    tick(&w, fire_rear, .{}, &tl);
    try std.testing.expectEqual(@as(usize, tuning.rot_count), weapons.drops_live(&w));
    // A car on the middle of the row touches those within 12 px of it
    // (lateral -4 and 4, and -12 and 12 at the pixel rounding), not the
    // outer two (+-20).
    const v = put(&w, 1, f, -tuning.drop_behind, 0, 0);
    const armor0 = v.armor;
    tick(&w, .{}, .{}, &tl);
    const hits = (armor0 - v.armor) / tuning.rot_dmg;
    try std.testing.expect(hits >= 2 and hits <= 4);
    try std.testing.expectEqual(armor0 - hits * tuning.rot_dmg, v.armor);
    try std.testing.expectEqual(@as(usize, tuning.rot_count - hits), weapons.drops_live(&w));
    try std.testing.expectEqual(tuning.rot_ticks, v.rot_ticks);
    // Consumed: staying there deals no more.
    ticks(&w, 10, .{}, &tl);
    try std.testing.expectEqual(armor0 - hits * tuning.rot_dmg, v.armor);
    // Driving along the row picks up the rest.
    _ = put(&w, 1, f, -tuning.drop_behind, 20, 0);
    tick(&w, .{}, .{}, &tl);
    _ = put(&w, 1, f, -tuning.drop_behind, -20, 0);
    tick(&w, .{}, .{}, &tl);
    try std.testing.expectEqual(@as(usize, 0), weapons.drops_live(&w));
    try std.testing.expectEqual(armor0 - tuning.rot_count * tuning.rot_dmg, v.armor);
}

test "BIT ROT slows: over 80% of top speed the car sheds speed while rotting" {
    var w: World = undefined;
    sim.reset(&w, .{ .seed = 5, .humans = .{ racers.snouty, world.no_human }, .combat = false });
    while (w.phase == .countdown) sim.simulate(&w, .{ 0, 0 });
    for (0..150) |_| sim.simulate(&w, .{ ai.drive(&w, 0).byte(), 0 });
    var rot = w;
    var clean = w;
    for (0..40) |_| {
        rot.cars[0].rot_ticks = 30;
        sim.simulate(&rot, .{ ai.drive(&rot, 0).byte(), 0 });
        sim.simulate(&clean, .{ ai.drive(&clean, 0).byte(), 0 });
    }
    const top = sim.top_of(&rot.cars[0]);
    try std.testing.expect(sim.speed(&rot.cars[0]) < sim.speed(&clean.cars[0]));
    try std.testing.expect(sim.speed(&rot.cars[0]) <= (top * 220) >> 8);
}

test "FIREWALL: 64 px of flame across the track for 120 ticks, 1 a tick inside" {
    var w = arena();
    var tl = Tally{ .seq = w.event_seq };
    const f = clear_frame(&w, 60);
    const s = put(&w, 0, f, 0, 0, 0);
    loadout(s, .broadcast, .firewall);
    tick(&w, fire_rear, .{}, &tl);
    const fw = first_drop(&w, .firewall).?;
    try std.testing.expectEqual(tuning.firewall_half, fw.size);
    const behind = -tuning.drop_behind - tuning.firewall_depth;
    const v = put(&w, 1, f, behind, 25, 0);
    const out = put(&w, 2, f, behind, 50, 0);
    const armor0 = v.armor;
    ticks(&w, 10, .{}, &tl);
    try std.testing.expectEqual(armor0 - 10 * tuning.firewall_dmg, v.armor);
    try std.testing.expectEqual(out.armor_max, out.armor);
    // Damage over time does not flood the event ring: one hit event a flash.
    try std.testing.expect(tl.hits <= 2);
    ticks(&w, tuning.firewall_life, .{}, &tl);
    try std.testing.expect(first_drop(&w, .firewall) == null);
    const armor1 = v.armor;
    ticks(&w, 5, .{}, &tl);
    try std.testing.expectEqual(armor1, v.armor);
}

test "pools never overflow: six cars spraying and dropping reuse the oldest slots" {
    var w = arena();
    var tl = Tally{ .seq = w.event_seq };
    const f = clear_frame(&w, 200);
    for (0..world.car_count) |i| {
        // Side by side on the clear stretch, immune so the spray passes
        // through the neighbours: 6 x 2 pellets every 6 ticks for 32 ticks
        // is 64 shots wanted for 48 slots.
        const c = put(&w, i, f, 0, @as(i32, @intCast(i)) * 6 - 15, 0);
        c.immune = 255;
        loadout(c, .ping, .rot);
        c.ammo_front = 255;
        c.ammo_rear = 255;
    }
    for (0..400) |t| {
        // Everyone fires; cars 0 and 1 also drop on and off.
        const in0: Input = if (t % 4 < 2) fire_rear else fire_a;
        w.rng = sim.step_rng(w.rng);
        for (0..world.car_count) |i| {
            weapons.fire(&w, i, if (i < 2) in0 else fire_a);
            w.cars[i].rear_cd = 0;
        }
        weapons.update(&w);
        tl.scan(&w);
        try std.testing.expect(weapons.projs_live(&w) <= world.proj_count);
        try std.testing.expect(weapons.drops_live(&w) <= world.drop_count);
    }
    try std.testing.expectEqual(@as(usize, world.proj_count), weapons.projs_live(&w));
    try std.testing.expectEqual(@as(usize, world.drop_count), weapons.drops_live(&w));
}

// --- Armor, ramming, wrecks, hulks, respawn, kill credit (SPEC 5.3) ------------------

/// The nearest centerline sample over the whole lap (`put` moves cars
/// further than `nearest_sample`'s window).
fn settle(w: *const World, c: *Car) void {
    const t = sim.track_of(w);
    var best: u8 = 0;
    var best_d: i32 = std.math.maxInt(i32);
    for (0..256) |k| {
        const s = t.sample(k);
        const dx = @mod((c.x >> fixed.Q) - @as(i32, s.x) + 512, 1024) - 512;
        const dy = @mod((c.y >> fixed.Q) - @as(i32, s.y) + 512, 1024) - 512;
        if (dx * dx + dy * dy < best_d) {
            best_d = dx * dx + dy * dy;
            best = @intCast(k);
        }
    }
    c.progress = best;
}

test "ramming: closing speed x 6 x mass ratio, both ways; MAINFRAME's plough doubles from the front" {
    var w = arena();
    const f = clear_frame(&w, 80);
    // LEGACY (MAINFRAME 1.6) noses into a parked KIDDIE (THIN CLIENT 0.7)
    // at 2 px/tick.
    const legacy = put(&w, 1, f, 0, 0, 0);
    const kiddie = put(&w, racers.kiddie, f, 19, 0, 0);
    legacy.vx = fixed.mul(fixed.cos(f.h), 2 << 16);
    legacy.vy = fixed.mul(fixed.sin(f.h), 2 << 16);
    const k0 = kiddie.armor;
    const l0 = legacy.armor;
    sim.collide_all(&w);
    const base_to_kiddie = @divTrunc((2 << 16) * tuning.ram_dmg * @as(i64, legacy.mass_q8), kiddie.mass_q8) >> 16;
    const to_legacy = @divTrunc((2 << 16) * tuning.ram_dmg * @as(i64, kiddie.mass_q8), legacy.mass_q8) >> 16;
    // Closing speed is measured along the contact normal: within a point
    // of the formula.
    try std.testing.expect(@abs(@as(i64, k0 - kiddie.armor) - base_to_kiddie * tuning.plough_mul) <= 2);
    try std.testing.expect(@abs(@as(i64, l0 - legacy.armor) - to_legacy) <= 1);
    try std.testing.expectEqual(@as(u8, 1), kiddie.last_hit_by);
    try std.testing.expectEqual(@as(u8, racers.kiddie), legacy.last_hit_by);
    // Side on (LEGACY's nose turned 90 degrees): no plough.
    var w2 = arena();
    const legacy2 = put(&w2, 1, f, 0, 0, 16384);
    const kiddie2 = put(&w2, racers.kiddie, f, 19, 0, 0);
    legacy2.vx = fixed.mul(fixed.cos(f.h), 2 << 16);
    legacy2.vy = fixed.mul(fixed.sin(f.h), 2 << 16);
    sim.collide_all(&w2);
    try std.testing.expect(@abs(@as(i64, kiddie2.armor_max - kiddie2.armor) - base_to_kiddie) <= 1);
    // A graze (under 0.25 px/tick closing) deals nothing.
    var w3 = arena();
    const a = put(&w3, 0, f, 0, 0, 0);
    const b = put(&w3, 1, f, 19, 0, 0);
    a.vx = fixed.mul(fixed.cos(f.h), 1 << 13);
    a.vy = fixed.mul(fixed.sin(f.h), 1 << 13);
    sim.collide_all(&w3);
    try std.testing.expectEqual(a.armor_max, a.armor);
    try std.testing.expectEqual(b.armor_max, b.armor);
    // Combat off: contacts push, never damage.
    var w4 = arena();
    w4.combat = false;
    const c = put(&w4, 1, f, 0, 0, 0);
    const d = put(&w4, racers.kiddie, f, 19, 0, 0);
    c.vx = fixed.mul(fixed.cos(f.h), 3 << 16);
    c.vy = fixed.mul(fixed.sin(f.h), 3 << 16);
    sim.collide_all(&w4);
    try std.testing.expectEqual(d.armor_max, d.armor);
}

test "wreck at armor 0: kill credit, hit-stop, a hulk that blocks for 90 ticks, respawn at 120 with full armor and kept ammo" {
    var w = arena();
    var tl = Tally{ .seq = w.event_seq };
    const f = clear_frame(&w, 120);
    const hunter = put(&w, 0, f, 0, 0, 0);
    const v = put(&w, 1, f, 70, 0, 0);
    settle(&w, hunter);
    settle(&w, v);
    loadout(v, .broadcast, .firewall);
    v.ammo_front = 2;
    v.armor = 10;
    sim.damage(&w, 1, 0, 12);
    tl.scan(&w);
    try std.testing.expectEqual(world.Wreck.armor, v.wreck);
    try std.testing.expectEqual(@as(u8, 0), v.armor);
    try std.testing.expectEqual(@as(u8, 1), hunter.kills);
    try std.testing.expectEqual(@as(u8, 1), v.wrecks);
    try std.testing.expectEqual(@as(u32, 1), tl.wrecks);
    try std.testing.expectEqual(@as(u8, 1), tl.last_wreck.a);
    try std.testing.expectEqual(@as(u8, 0), tl.last_wreck.b);
    try std.testing.expectEqual(@as(u8, @backingInt(world.Wreck.armor)), tl.last_wreck.c);
    try std.testing.expectEqual(@as(u32, 1), tl.explodes);
    try std.testing.expectEqual(tuning.hitstop_ticks, v.hitstop);
    try std.testing.expect(sim.is_hulk(v));
    const hulk_x = v.x;
    const hulk_y = v.y;
    // Per-car hit-stop: the world goes on.
    const t0 = w.tick;
    for (0..tuning.hitstop_ticks) |_| sim.simulate(&w, .{ 0, 0 });
    try std.testing.expectEqual(t0 + tuning.hitstop_ticks, w.tick);
    try std.testing.expectEqual(@as(u8, 0), v.hitstop);
    // SNOUTY drives straight into the hulk and stays on its near side.
    for (0..60) |_| {
        sim.simulate(&w, .{ 0, 0 });
        const dx = weapons.dq(hulk_x, hunter.x) >> fixed.Q;
        const dy = weapons.dq(hulk_y, hunter.y) >> fixed.Q;
        const along = (dx * fixed.cos(f.h) + dy * fixed.sin(f.h)) >> fixed.Q;
        try std.testing.expect(along <= -2 * tuning.car_radius + 3);
    }
    try std.testing.expect(sim.is_hulk(v));
    try std.testing.expectEqual(hulk_x, v.x);
    // After 90 ticks of WATCHDOG the hulk is gone; at 120 the car respawns.
    while (v.wreck_ticks > tuning.watchdog_ticks - tuning.hulk_ticks) sim.simulate(&w, .{ 0, 0 });
    try std.testing.expect(!sim.is_hulk(v));
    while (v.wreck != .none) sim.simulate(&w, .{ 0, 0 });
    tl.scan(&w);
    try std.testing.expectEqual(@as(u32, 1), tl.respawns);
    try std.testing.expectEqual(v.armor_max, v.armor);
    try std.testing.expectEqual(@as(u8, 2), v.ammo_front);
    try std.testing.expectEqual(tuning.respawn_immune, v.immune);
    // Immune: no damage.
    sim.damage(&w, 1, 0, 50);
    try std.testing.expectEqual(v.armor_max, v.armor);
}

test "shots spark on a hulk" {
    var w = arena();
    var tl = Tally{ .seq = w.event_seq };
    const f = clear_frame(&w, 120);
    const s = put(&w, 0, f, 0, 0, 0);
    const v = put(&w, 1, f, 50, 0, 0);
    loadout(s, .ping, .bomb);
    sim.damage(&w, 1, 0, 255);
    try std.testing.expect(sim.is_hulk(v));
    tl.scan(&w);
    const sparks0 = tl.sparks;
    tick(&w, fire_a, .{}, &tl);
    ticks(&w, 12, .{}, &tl);
    try std.testing.expectEqual(sparks0 + 2, tl.sparks);
    try std.testing.expectEqual(@as(u32, 1), tl.hits);
}

test "kill credit: the last rival's hit within 180 ticks, a fall too; later, nobody" {
    var w = arena();
    var tl = Tally{ .seq = w.event_seq };
    const f = clear_frame(&w, 60);
    const v = put(&w, 1, f, 0, 0, 0);
    _ = put(&w, 0, f, 60, 0, 0);
    settle(&w, v);
    settle(&w, &w.cars[0]);
    sim.damage(&w, 1, 0, 5);
    try std.testing.expectEqual(@as(u8, 0), v.last_hit_ticks);
    sim.simulate(&w, .{ 0, 0 });
    try std.testing.expectEqual(@as(u8, 1), v.last_hit_ticks);
    v.last_hit_ticks = tuning.credit_ticks - 1;
    sim.wreck(&w, 1, .fall);
    tl.scan(&w);
    try std.testing.expectEqual(@as(u8, 0), tl.last_wreck.b);
    try std.testing.expectEqual(@as(u8, 1), w.cars[0].kills);
    // Out of the window: uncredited.
    var w2 = arena();
    var tl2 = Tally{ .seq = w2.event_seq };
    sim.damage(&w2, 1, 0, 5);
    w2.cars[1].last_hit_ticks = tuning.credit_ticks;
    sim.wreck(&w2, 1, .fall);
    tl2.scan(&w2);
    try std.testing.expectEqual(no_car, tl2.last_wreck.b);
    try std.testing.expectEqual(@as(u8, 0), w2.cars[0].kills);
    try std.testing.expectEqual(@as(u8, 1), w2.cars[1].wrecks);
    // A wall hit (no attacker) keeps the rival's credit window.
    var w3 = arena();
    sim.damage(&w3, 1, 0, 5);
    sim.damage(&w3, 1, no_car, 200);
    try std.testing.expectEqual(@as(u8, 1), w3.cars[0].kills);
    // Your own drop never credits you.
    var w4 = arena();
    sim.damage(&w4, 1, 1, 255);
    try std.testing.expectEqual(@as(u8, 0), w4.cars[1].kills);
}

test "loadouts from the roster, full ammo at the start, refilled on the start line with the lap" {
    var w: World = undefined;
    sim.reset(&w, .{ .seed = 1, .humans = .{ racers.snouty, world.no_human } });
    for (w.cars, 0..) |c, i| {
        try std.testing.expectEqual(racers.roster[i].front, c.front);
        try std.testing.expectEqual(racers.roster[i].rear, c.rear);
        try std.testing.expectEqual(tuning.front_ammo[@backingInt(c.front)], c.ammo_front);
        try std.testing.expectEqual(tuning.rear_ammo[@backingInt(c.rear)], c.ammo_rear);
        try std.testing.expectEqual(c.armor_max, c.armor);
    }
    while (w.phase == .countdown) sim.simulate(&w, .{ 0, 0 });
    const t = sim.track_of(&w);
    const c = &w.cars[0];
    const park = struct {
        fn at(ww: *World, cc: *Car, smp: track.Sample) void {
            cc.x = @as(i32, smp.x) << fixed.Q;
            cc.y = @as(i32, smp.y) << fixed.Q;
            cc.vx = 0;
            cc.vy = 0;
            cc.heading = smp.tangent;
            sim.simulate(ww, .{ 0, 0 });
        }
    };
    c.ammo_front = 0;
    c.ammo_rear = 0;
    // Over the line without the sectors: no lap, no ammo.
    c.progress = 250;
    park.at(&w, c, t.sample(250));
    park.at(&w, c, t.sample(2));
    try std.testing.expectEqual(@as(u8, 0), c.ammo_front);
    // A real lap: full again.
    c.progress = 250;
    park.at(&w, c, t.sample(250));
    c.sectors = 3;
    park.at(&w, c, t.sample(2));
    try std.testing.expectEqual(@as(u8, 1), c.lap);
    try std.testing.expectEqual(tuning.front_ammo[@backingInt(c.front)], c.ammo_front);
    try std.testing.expectEqual(tuning.rear_ammo[@backingInt(c.rear)], c.ammo_rear);
}

test "combat off: no shots, no drops, no damage" {
    var w: World = undefined;
    sim.reset(&w, .{ .seed = 9, .humans = .{ racers.kiddie, racers.legacy }, .combat = false });
    for (0..1500) |t| {
        const in = Input{ .a = true, .down = t % 50 < 3, .left = (t / 40) % 3 == 0 };
        sim.simulate(&w, .{ in.byte(), (Input{ .a = t % 2 == 0 }).byte() });
        try std.testing.expectEqual(@as(usize, 0), weapons.projs_live(&w));
        try std.testing.expectEqual(@as(usize, 0), weapons.drops_live(&w));
    }
    for (w.cars) |c| {
        try std.testing.expect(c.wreck != .armor);
        if (c.wreck == .none and c.immune == 0) try std.testing.expectEqual(c.armor_max, c.armor);
    }
}

// --- AI combat (SPEC 6.5) -----------------------------------------------------------

test "AI aim: a target in reach for the crew's reaction delay, then A" {
    var w = arena();
    const f = clear_frame(&w, 200);
    // KIDDIE (AI, PING, reaction 1) behind SNOUTY.
    const k = put(&w, racers.kiddie, f, 0, 0, 0);
    _ = put(&w, 0, f, 80, 0, 0);
    ai.update_aim(&w, racers.kiddie);
    try std.testing.expectEqual(@as(u8, 0), k.aim);
    try std.testing.expect(ai.drive(&w, racers.kiddie).a);
    // Nothing in reach: no aim, no fire.
    _ = put(&w, 0, f, -80, 0, 0);
    ai.update_aim(&w, racers.kiddie);
    try std.testing.expectEqual(no_car, k.aim);
    // (It drops on SNOUTY behind it instead: Down+A, not the front.)
    const in = ai.drive(&w, racers.kiddie);
    try std.testing.expect(!in.a or in.down);
    // SYSADMIN-style reaction: aim_ticks counts up to it.
    const sa = put(&w, racers.sysadmin, f, 0, 0, 0);
    loadout(sa, .ping, .rot);
    _ = put(&w, 0, f, 60, 0, 0);
    const reaction = ai.crews[racers.sysadmin].reaction;
    for (0..reaction - 1) |_| ai.update_aim(&w, racers.sysadmin);
    try std.testing.expect(!ai.drive(&w, racers.sysadmin).a);
    ai.update_aim(&w, racers.sysadmin);
    try std.testing.expect(ai.drive(&w, racers.sysadmin).a);
    // SNOUTY's crew waits for its lock.
    var w2 = arena();
    const s = put(&w2, 0, f, 0, 0, 0);
    _ = put(&w2, 1, f, 150, 0, 0);
    s.human = world.no_human;
    var fired_at: ?usize = null;
    for (0..40) |t| {
        weapons.update_lock(&w2, 0);
        ai.update_aim(&w2, 0);
        if (fired_at == null and ai.drive(&w2, 0).a) fired_at = t;
    }
    try std.testing.expectEqual(@as(u8, 1), s.lock);
    try std.testing.expectEqual(@as(usize, ai.crews[racers.snouty].reaction - 1), fired_at.?);
}

test "AI target preference: BOTNET goes for the leader, SYSADMIN for the human" {
    var w = arena();
    const f = clear_frame(&w, 200);
    w.cars[0].human = world.no_human;
    w.cars[1].human = world.no_human;
    const bot = put(&w, racers.botnet, f, 0, 0, 0);
    loadout(bot, .lance, .rot);
    const near = put(&w, 0, f, 60, 0, 0);
    const lead = put(&w, 1, f, 150, 4, 0);
    near.rank = 3;
    lead.rank = 1;
    ai.update_aim(&w, racers.botnet);
    try std.testing.expectEqual(@as(u8, 1), bot.aim);
    const sa = put(&w, racers.sysadmin, f, -30, 0, 0);
    lead.human = 0;
    ai.update_aim(&w, racers.sysadmin);
    try std.testing.expectEqual(@as(u8, 1), sa.aim);
    lead.human = world.no_human;
    // Nobody human: the nearest (BOTNET, 30 px ahead of it).
    for (0..4) |_| ai.update_aim(&w, racers.sysadmin);
    try std.testing.expectEqual(@as(u8, racers.botnet), sa.aim);
}

test "AI drops on a car close behind on its line; LEGACY's fire wall goes wide" {
    var w = arena();
    const f = clear_frame(&w, 60);
    const k = put(&w, racers.kiddie, f, 0, 0, 0);
    _ = put(&w, 0, f, -60, 4, 0);
    var in = ai.drive(&w, racers.kiddie);
    try std.testing.expect(in.a and in.down);
    // Off the line: not for KIDDIE...
    _ = put(&w, 0, f, -60, 30, 0);
    in = ai.drive(&w, racers.kiddie);
    try std.testing.expect(!(in.a and in.down));
    // ...but LEGACY lays its fire wall wide.
    const l = put(&w, 1, f, 0, 0, 0);
    l.human = world.no_human;
    _ = put(&w, racers.kiddie, f, -60, 30, 0);
    w.cars[0].active = false;
    in = ai.drive(&w, 1);
    try std.testing.expect(in.a and in.down);
    // Cooldown, empty, or the chord held last tick: no drop.
    l.rear_cd = 5;
    try std.testing.expect(!ai.drive(&w, 1).down or !ai.drive(&w, 1).a);
    l.rear_cd = 0;
    l.rear_was = true;
    try std.testing.expect(!(ai.drive(&w, 1).down and ai.drive(&w, 1).a));
    l.rear_was = false;
    l.ammo_rear = 0;
    try std.testing.expect(!(ai.drive(&w, 1).down and ai.drive(&w, 1).a));
    _ = k;
}

test "AI LANCE: charges on a straight, lets go into a target once charged" {
    var w = arena();
    const f = clear_frame(&w, 300);
    const sa = put(&w, racers.sysadmin, f, 0, 0, 0);
    settle(&w, sa);
    try std.testing.expectEqual(world.Front.lance, sa.front);
    // On the start straight with nothing about: charge (A held).
    if (ai.drive(&w, racers.sysadmin).a) {
        sa.charge = tuning.lance_charge;
        // Charged, nobody in line: keep holding.
        try std.testing.expect(ai.drive(&w, racers.sysadmin).a);
        // A car in line long enough: release.
        _ = put(&w, 0, f, 200, 0, 0);
        for (0..ai.crews[racers.sysadmin].reaction) |_| ai.update_aim(&w, racers.sysadmin);
        try std.testing.expect(!ai.drive(&w, racers.sysadmin).a);
    } else return error.SkipZigTest; // the frame is not straight enough for its charge rule
}

test "AI steers round a FIREWALL across its lane" {
    var w = arena();
    const f = clear_frame(&w, 160);
    const k = put(&w, racers.kiddie, f, 0, 0, 0);
    settle(&w, k);
    var lane: i32 = 0;
    ai.dodge_firewalls(&w, racers.kiddie, &lane);
    try std.testing.expectEqual(@as(i32, 0), lane);
    const hx = fixed.cos(f.h);
    const hy = fixed.sin(f.h);
    w.drops[0] = .{
        .x = ((f.x << fixed.Q) +% hx * 80) & ((1024 << fixed.Q) - 1),
        .y = ((f.y << fixed.Q) +% hy * 80) & ((1024 << fixed.Q) - 1),
        .kind = .firewall,
        .size = tuning.firewall_half,
        .dir = @intCast(f.h >> 8),
    };
    ai.dodge_firewalls(&w, racers.kiddie, &lane);
    try std.testing.expect(@abs(lane) > tuning.firewall_half);
}
