//! Host tests for the pickups (PLAN.md M2 Track A item 6): roll odds,
//! crates and the roulette, a scenario per pickup, AI pickup policies, the
//! chaos soak with pickups and determinism with pickups on.
const std = @import("std");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const track = @import("track.zig");
const world = @import("world.zig");
const racers = @import("racers.zig");
const sim = @import("sim.zig");
const ai = @import("ai.zig");
const weapons = @import("weapons.zig");
const pickups = @import("pickups.zig");

const World = world.World;
const Car = world.Car;
const Input = world.Input;
const Pickup = world.Pickup;
const no_car = world.no_car;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// Print the soak's per-race summary and the pickup tallies.
const report = false;

// --- A frozen arena (as weapons_test's) -------------------------------------------

const Frame = struct { x: i32, y: i32, h: fixed.Turn };

/// A place on the road with `len` px of clear floor ahead and 40 behind.
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

/// SNOUTY (car 0, human slot 0) and LEGACY (car 1, slot 1) racing, the
/// other four out of the race; everyone stopped and not immune.
fn arena() World {
    var w: World = undefined;
    sim.reset(&w, .{ .seed = 99, .humans = .{ racers.snouty, racers.legacy } });
    while (w.phase == .countdown) sim.simulate(&w, .{ 0, 0 });
    for (&w.cars, 0..) |*c, i| {
        c.active = i < 2;
        c.vx = 0;
        c.vy = 0;
        c.immune = 0;
        c.pickup = .none;
        c.roll_ticks = 0;
    }
    w.crates = @splat(tuning.crate_respawn); // crates out of the way unless a test wants them
    return w;
}

/// The nearest centerline sample to the car (its `progress`).
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
    settle(w, c);
    return c;
}

/// One frozen tick: every active car's status filter, B and fire (cars 0
/// and 1 take `in0`/`in1`), the pools, the pickups, the locks. Cars do not
/// drive, so positions stay where `put` left them.
fn tick(w: *World, in0: Input, in1: Input) void {
    w.rng = sim.step_rng(w.rng);
    for (&w.cars, 0..) |*c, i| {
        if (!c.active) continue;
        const in = pickups.filter(w, i, if (i == 0) in0 else if (i == 1) in1 else .{});
        pickups.control(w, i, in);
        weapons.fire(w, i, in);
    }
    weapons.update(w);
    pickups.update(w);
    for (0..world.car_count) |i| weapons.update_lock(w, i);
}

fn ticks(w: *World, n: usize) void {
    for (0..n) |_| tick(w, .{}, .{});
}

/// Give car `i` a ready pickup.
fn give(w: *World, i: usize, p: Pickup) void {
    w.cars[i].pickup = p;
    w.cars[i].roll_ticks = 0;
    w.cars[i].b_was = false;
}

/// Car 0 (or 1) presses B for one tick, then lets go.
fn press_b(w: *World, slot: usize, down: bool) void {
    const in = Input{ .b = true, .down = down };
    if (slot == 0) tick(w, in, .{}) else tick(w, .{}, in);
    tick(w, .{}, .{});
}

/// Events of `kind` since `seq`; `last` gets the latest one.
fn count(w: *const World, seq: u16, kind: world.EventKind, last: ?*world.Event) u32 {
    var n: u32 = 0;
    var s = seq;
    while (s != w.event_seq) : (s +%= 1) {
        const e = w.events[s % world.event_count];
        if (e.seq != s or e.kind != kind) continue;
        n += 1;
        if (last) |l| l.* = e;
    }
    return n;
}

fn drops_of(w: *const World, kind: world.DropKind) u32 {
    var n: u32 = 0;
    for (&w.drops) |*d| n += @intFromBool(d.kind == kind);
    return n;
}

fn first_drop(w: *World, kind: world.DropKind) ?*world.Drop {
    for (&w.drops) |*d| {
        if (d.kind == kind) return d;
    }
    return null;
}

fn px_dist(ax: i32, ay: i32, bx: i32, by: i32) i32 {
    const dx = weapons.dq(ax, bx) >> fixed.Q;
    const dy = weapons.dq(ay, by) >> fixed.Q;
    return @intCast(fixed.isqrt(@intCast(dx * dx + dy * dy)));
}

// --- Rolls and crates ---------------------------------------------------------------

test "roll odds: tiers by rank within 1.5 points of SPEC 6.4, uniform in a tier, KERNEL PANIC never for 1st, ZERO-DAY only 5th and 6th" {
    var w = arena();
    w.rng = 0xC0FFEE;
    const n = 40000;
    for (1..7) |r| {
        var tiers = [3]u32{ 0, 0, 0 };
        var each: [17]u32 = @splat(0);
        for (0..n) |_| {
            const p = pickups.roll_pickup(&w, @intCast(r), true);
            tiers[@intFromEnum(pickups.tier_of(p))] += 1;
            each[@intFromEnum(p)] += 1;
        }
        const odds = tuning.roll_odds[r - 1];
        for (0..3) |t| {
            const pct1000 = tiers[t] * 1000 / n;
            if (report) std.debug.print("\nrank {d} tier {d}: {d} per mille (table {d}0)", .{ r, t, pct1000, odds[t] });
            try expect(@abs(@as(i32, @intCast(pct1000)) - @as(i32, odds[t]) * 10) <= 15);
        }
        if (r == 1) try expectEqual(@as(u32, 0), each[@intFromEnum(Pickup.kernel_panic)]);
        if (r < 5) try expectEqual(@as(u32, 0), each[@intFromEnum(Pickup.zero_day)]);
        if (r >= 5) try expect(each[@intFromEnum(Pickup.zero_day)] > 0);
        try expectEqual(@as(u32, 0), each[@intFromEnum(Pickup.prompt_injection)]);
        // Uniform within tier A (5) and B (6): each within 15% of its share.
        for (0..11) |k| {
            const share = tiers[if (k < 5) 0 else 1] / @as(u32, if (k < 5) 5 else 6);
            if (share < 500) continue;
            try expect(each[k] * 100 >= share * 85 and each[k] * 100 <= share * 115);
        }
    }
    // Without the once-per-race allowance ZERO-DAY never rolls.
    for (0..5000) |_| try expect(pickups.roll_pickup(&w, 6, false) != .zero_day);
}

test "crate rows come from the track: rows of 3 or 4 on plain road" {
    var w = arena();
    _ = &w;
    try expect(track.crate_n >= 6 and track.crate_n <= world.crate_max);
    const t = sim.track_of(&w);
    var rows: u32 = 0;
    for (0..256) |k| {
        const s = t.sample(k);
        if (s.flags & track.flag_crates != 0) rows += 1;
    }
    try expect(rows >= 2);
    for (track.crate_spots[0..track.crate_n]) |s| {
        try expectEqual(track.Attr.surface, t.attr_at(s.x, s.y));
    }
}

test "a crate starts the 45-tick roulette by rank; B waits for it; the crate is back 180 ticks later; a full car drives through" {
    var w = arena();
    const s = track.crate_spots[0];
    w.crates[0] = 0;
    const c = &w.cars[0];
    c.x = @as(i32, s.x) << fixed.Q;
    c.y = @as(i32, s.y) << fixed.Q;
    c.rank = 6;
    const seq = w.event_seq;
    tick(&w, .{}, .{});
    try expect(c.pickup != .none);
    try expectEqual(tuning.roll_ticks - 1, c.roll_ticks);
    try expectEqual(tuning.crate_respawn, w.crates[0]);
    var e: world.Event = .{};
    try expectEqual(@as(u32, 1), count(&w, seq, .roll, &e));
    try expectEqual(@as(u8, 0), e.a);
    try expectEqual(@intFromEnum(c.pickup), e.b);
    // B during the roulette does nothing.
    const held = c.pickup;
    press_b(&w, 0, false);
    try expectEqual(held, c.pickup);
    for (0..tuning.roll_ticks) |_| tick(&w, .{}, .{});
    try expectEqual(@as(u8, 0), c.roll_ticks);
    // Back after 180 ticks; the car still holds its pickup and drives
    // through (the crate stays).
    for (0..tuning.crate_respawn) |_| tick(&w, .{}, .{});
    try expectEqual(@as(u8, 0), w.crates[0]);
    ticks(&w, 5);
    try expectEqual(@as(u8, 0), w.crates[0]);
    try expectEqual(held, c.pickup);
    // An airborne car passes over crates.
    c.pickup = .none;
    c.hop = 10;
    tick(&w, .{}, .{});
    try expectEqual(@as(u8, 0), w.crates[0]);
    c.hop = 0;
    tick(&w, .{}, .{});
    try expect(w.crates[0] > 0 and c.pickup != .none);
}

test "ZERO-DAY rolls at most once per car per race" {
    var w = arena();
    const c = &w.cars[0];
    c.rank = 6;
    const s = track.crate_spots[0];
    c.x = @as(i32, s.x) << fixed.Q;
    c.y = @as(i32, s.y) << fixed.Q;
    var zero_days: u32 = 0;
    for (0..400) |_| {
        c.pickup = .none;
        c.roll_ticks = 0;
        w.crates[0] = 0;
        tick(&w, .{}, .{});
        zero_days += @intFromBool(c.pickup == .zero_day);
    }
    try expectEqual(@as(u32, 1), zero_days);
    try expect(c.zero_day_used);
}

// --- Tier A -------------------------------------------------------------------------

test "PREFETCH: +40% top speed for 90 ticks, wall damage halved" {
    var w = arena();
    const f = clear_frame(&w, 240);
    w.cars[1].active = false;
    _ = put(&w, 0, f, 0, 0, 0);
    try expectEqual(@as(i32, 256), pickups.thrust_q8(&w, 0));
    give(&w, 0, .prefetch);
    var boosted = w;
    pickups.use(&boosted, 0, false);
    try expectEqual(tuning.prefetch_ticks, boosted.cars[0].prefetch);
    try expectEqual(tuning.prefetch_q8, pickups.thrust_q8(&boosted, 0));
    for (0..50) |_| {
        sim.simulate(&w, .{ 0, 0 });
        sim.simulate(&boosted, .{ 0, 0 });
    }
    const v0 = sim.speed(&w.cars[0]);
    const v1 = sim.speed(&boosted.cars[0]);
    try expect(v1 * 100 >= v0 * 125);
    for (0..40) |_| sim.simulate(&boosted, .{ 0, 0 });
    try expectEqual(@as(u8, 0), boosted.cars[0].prefetch);

    // Into the wall beside the straight at 3 px/tick: half the damage.
    var loss: [2]i32 = undefined;
    for (0..2) |k| {
        var a = arena();
        a.cars[1].active = false;
        const t = sim.track_of(&a);
        var wall: i32 = 0;
        while (wall < 120) : (wall += 1) {
            const hx = fixed.cos(f.h);
            const hy = fixed.sin(f.h);
            if (t.attr_at(f.x + ((-hy * wall) >> fixed.Q), f.y + ((hx * wall) >> fixed.Q)) == .wall) break;
        }
        const c = put(&a, 0, f, 60, wall - 18, 16384);
        c.vx = fixed.mul(fixed.cos(c.heading), 3 << 16);
        c.vy = fixed.mul(fixed.sin(c.heading), 3 << 16);
        if (k == 1) c.prefetch = 90;
        const before: i32 = c.armor;
        for (0..12) |_| sim.simulate(&a, .{ 0, 0 });
        loss[k] = before - c.armor;
    }
    try expect(loss[0] >= 4);
    try expect(loss[1] * 2 <= loss[0] + 1 and loss[1] * 2 >= loss[0] - 2);
}

test "HONEYPOT: B throws it 60 px ahead, Down+B drops it behind; touching it deals 30 and spins" {
    var w = arena();
    const f = clear_frame(&w, 120);
    const s = put(&w, 0, f, 0, 0, 0);
    give(&w, 0, .honeypot);
    const seq = w.event_seq;
    press_b(&w, 0, false);
    try expectEqual(Pickup.none, s.pickup);
    try expectEqual(@as(u32, 1), count(&w, seq, .use, null));
    const hp = first_drop(&w, .honeypot).?;
    const d = px_dist(s.x, s.y, hp.x, hp.y);
    try expect(d >= 56 and d <= 62);
    // The thrower is spared while it is fresh.
    s.x = hp.x;
    s.y = hp.y;
    tick(&w, .{}, .{});
    try expect(first_drop(&w, .honeypot) != null);
    // LEGACY drives onto it: 30, a spin, the burst event, gone.
    const v = put(&w, 1, f, 0, 0, 0);
    v.x = hp.x;
    v.y = hp.y;
    _ = put(&w, 0, f, -100, 0, 0);
    const seq2 = w.event_seq;
    const armor = v.armor;
    tick(&w, .{}, .{});
    try expectEqual(armor - tuning.honeypot_dmg, v.armor);
    try expectEqual(tuning.spin_ticks - 1, v.spin);
    var e: world.Event = .{};
    try expectEqual(@as(u32, 1), count(&w, seq2, .effect, &e));
    try expectEqual(@intFromEnum(Pickup.honeypot), e.c);
    try expectEqual(@as(u32, 0), drops_of(&w, .honeypot));
    // Spinning: no steering gets through.
    try expect(!pickups.filter(&w, 1, .{ .left = true }).left);
    // Down+B lays it behind.
    give(&w, 0, .honeypot);
    press_b(&w, 0, true);
    const hp2 = first_drop(&w, .honeypot).?;
    const c0 = &w.cars[0];
    const along = (weapons.dq(c0.x, hp2.x) >> fixed.Q) * fixed.cos(c0.heading) + (weapons.dq(c0.y, hp2.y) >> fixed.Q) * fixed.sin(c0.heading);
    try expect(along < 0);
}

test "RUBBER DUCK: takes the first hit from behind and draws SPEAR PHISH; shots from the front still hurt; 600 ticks" {
    var w = arena();
    const f = clear_frame(&w, 200);
    const d = put(&w, 1, f, 80, 0, 0);
    const s = put(&w, 0, f, 0, 0, 0);
    give(&w, 1, .duck);
    press_b(&w, 1, false);
    try expect(d.duck > 0);
    s.front = .ping;
    weapons.refill(s);
    const armor = d.armor;
    const seq = w.event_seq;
    // One twin volley from behind: the duck takes the first pellet.
    tick(&w, .{ .a = true }, .{});
    for (0..30) |_| tick(&w, .{}, .{});
    var e: world.Event = .{};
    try expectEqual(@as(u32, 1), count(&w, seq, .effect, &e));
    try expectEqual(@intFromEnum(Pickup.duck), e.c);
    try expectEqual(@as(u8, 1), e.b);
    try expectEqual(@as(u16, 0), d.duck);
    // The twin pellet behind it hit (the duck took only the first).
    try expect(d.armor >= armor - tuning.ping_dmg);
    // A fresh duck and a shot from the front: it hurts, the duck stays.
    give(&w, 1, .duck);
    press_b(&w, 1, false);
    _ = put(&w, 1, f, 80, 0, 32768);
    const a2 = d.armor;
    tick(&w, .{ .a = true }, .{});
    for (0..30) |_| tick(&w, .{}, .{});
    try expect(d.armor < a2);
    try expect(d.duck > 0);
    // SPEAR PHISH: homes on the duck and pops it, whatever the side.
    _ = put(&w, 1, f, 150, 0, 0);
    s.front = .phish;
    weapons.refill(s);
    s.fire_cd = 0;
    tick(&w, .{}, .{});
    try expectEqual(@as(u8, 1), s.lock);
    const a3 = d.armor;
    tick(&w, .{ .a = true }, .{});
    for (0..80) |_| tick(&w, .{}, .{});
    try expectEqual(@as(u16, 0), d.duck);
    try expectEqual(a3, d.armor);
    // Expiry.
    give(&w, 1, .duck);
    press_b(&w, 1, false);
    _ = put(&w, 1, f, -300, 0, 0);
    ticks(&w, tuning.duck_ticks);
    try expectEqual(@as(u16, 0), d.duck);
}

test "HOT PATCH: 40 armor over 60 ticks, clears BIT FLIP and DEADLOCK" {
    var w = arena();
    const f = clear_frame(&w, 100);
    const c = put(&w, 0, f, 0, 0, 0);
    _ = put(&w, 1, f, 40, 0, 0);
    c.armor = 30;
    c.bit_flip = 100;
    c.chain = 1;
    c.chain_ticks = 100;
    w.cars[1].chain = 0;
    w.cars[1].chain_ticks = 100;
    give(&w, 0, .hot_patch);
    tick(&w, .{ .b = true }, .{});
    try expectEqual(@as(u8, 0), c.bit_flip);
    try expectEqual(@as(u8, 0), c.chain_ticks);
    try expectEqual(no_car, w.cars[1].chain);
    ticks(&w, 30);
    try expect(c.armor > 40 and c.armor < 70);
    ticks(&w, 40);
    try expectEqual(@as(u8, 70), c.armor);
    // Capped at the chassis armor.
    c.armor = 90;
    give(&w, 0, .hot_patch);
    press_b(&w, 0, false);
    ticks(&w, 70);
    try expectEqual(c.armor_max, c.armor);
}

test "SPAGHETTI CODE: a car through the tangle crawls at 40% for 60 ticks, then drags a strand at -10%" {
    var w = arena();
    const f = clear_frame(&w, 200);
    const s = put(&w, 0, f, 0, 0, 0);
    give(&w, 0, .spaghetti);
    press_b(&w, 0, false);
    const sp = first_drop(&w, .spaghetti).?;
    const d = px_dist(s.x, s.y, sp.x, sp.y);
    try expect(d >= 56 and d <= 62);
    // LEGACY at top speed into it.
    const v = put(&w, 1, f, 0, 0, 0);
    v.x = sp.x;
    v.y = sp.y;
    _ = put(&w, 0, f, -150, 0, 0);
    const seq = w.event_seq;
    tick(&w, .{}, .{});
    try expectEqual(@as(u32, 0), drops_of(&w, .spaghetti));
    var e: world.Event = .{};
    try expectEqual(@as(u32, 1), count(&w, seq, .effect, &e));
    try expectEqual(@intFromEnum(Pickup.spaghetti), e.c);
    try expect(v.tangle > 0 and v.strand == tuning.strand_ticks);
    v.vx = fixed.mul(fixed.cos(v.heading), sim.top_of(v));
    v.vy = fixed.mul(fixed.sin(v.heading), sim.top_of(v));
    pickups.limit(v);
    try expect(sim.speed(v) <= @divTrunc(sim.top_of(v) * 40, 100) + 256);
    try expectEqual(@as(i32, 256), pickups.thrust_q8(&w, 1));
    ticks(&w, tuning.tangle_ticks);
    try expectEqual(@as(u8, 0), v.tangle);
    try expectEqual(tuning.strand_q8, pickups.thrust_q8(&w, 1));
    ticks(&w, tuning.strand_ticks);
    try expectEqual(@as(i32, 256), pickups.thrust_q8(&w, 1));
}

// --- Tier B -------------------------------------------------------------------------

test "FORK BOMB: one & behind, forks every 60 ticks: 8 at tick 180 spread across the track, none at 481; 15 a hit" {
    var w = arena();
    const f = clear_frame(&w, 100);
    const s = put(&w, 0, f, 0, 0, 0);
    give(&w, 0, .fork_bomb);
    tick(&w, .{ .b = true }, .{});
    try expectEqual(@as(u32, 1), drops_of(&w, .fork));
    // Out of the way: no car near the bombs.
    s.active = false;
    w.cars[1].active = false;
    var at: [482]u32 = undefined;
    at[1] = drops_of(&w, .fork);
    for (2..482) |t| {
        tick(&w, .{}, .{});
        at[t] = drops_of(&w, .fork);
    }
    try expectEqual(@as(u32, 1), at[59]);
    try expectEqual(@as(u32, 2), at[60]);
    try expectEqual(@as(u32, 4), at[120]);
    try expectEqual(@as(u32, 8), at[180]);
    try expectEqual(@as(u32, 8), at[479]);
    try expectEqual(@as(u32, 0), at[481]);

    // Spread: rerun to tick 220 and measure the lateral span; all on floor.
    var w2 = arena();
    const s2 = put(&w2, 0, f, 0, 0, 0);
    give(&w2, 0, .fork_bomb);
    tick(&w2, .{ .b = true }, .{});
    s2.active = false;
    w2.cars[1].active = false;
    ticks(&w2, 220);
    var lo: i32 = 1000;
    var hi: i32 = -1000;
    const hx = fixed.cos(f.h);
    const hy = fixed.sin(f.h);
    for (&w2.drops) |*d| {
        if (d.kind != .fork) continue;
        const lat = ((weapons.dq(f.x << fixed.Q, d.x) >> fixed.Q) * -hy + (weapons.dq(f.y << fixed.Q, d.y) >> fixed.Q) * hx) >> fixed.Q;
        lo = @min(lo, lat);
        hi = @max(hi, lat);
        const a = sim.track_of(&w2).attr_at(d.x >> fixed.Q, d.y >> fixed.Q);
        try expect(a != .wall and a != .off);
    }
    try expect(hi - lo >= 60);
    // A car on a bomb: 15, the bomb is gone.
    const bomb = first_drop(&w2, .fork).?;
    const v = &w2.cars[1];
    v.active = true;
    v.x = bomb.x;
    v.y = bomb.y;
    const armor = v.armor;
    tick(&w2, .{}, .{});
    // Bombs a few px apart: the car may sit on more than one.
    const hits = (armor - v.armor) / tuning.fork_dmg;
    try expect(hits >= 1 and (armor - v.armor) % tuning.fork_dmg == 0);
    try expectEqual(8 - @as(u32, hits), drops_of(&w2, .fork));
}

test "BIT FLIP: the nearest car ahead within 400 px steers mirrored for 180 ticks; out of range, nothing" {
    var w = arena();
    const f = clear_frame(&w, 200);
    _ = put(&w, 0, f, 0, 0, 0);
    const v = put(&w, 1, f, 120, 0, 0);
    give(&w, 0, .bit_flip);
    const seq = w.event_seq;
    press_b(&w, 0, false);
    try expect(v.bit_flip > tuning.bit_flip_ticks - 3);
    var e: world.Event = .{};
    try expectEqual(@as(u32, 1), count(&w, seq, .effect, &e));
    try expectEqual(@intFromEnum(Pickup.bit_flip), e.c);
    const in = pickups.filter(&w, 1, .{ .left = true });
    try expect(in.right and !in.left);
    // Driven: Left turns the car right.
    var d = w;
    const h0 = d.cars[1].heading;
    for (0..5) |_| sim.simulate(&d, .{ 0, (Input{ .left = true }).byte() });
    try expect(fixed.turn_diff(h0, d.cars[1].heading) > 0);
    ticks(&w, tuning.bit_flip_ticks);
    try expectEqual(@as(u8, 0), v.bit_flip);
    // Behind, or beyond 400 px of progress: no target.
    var w2 = arena();
    _ = put(&w2, 0, f, 0, 0, 0);
    const b = put(&w2, 1, f, -60, 0, 0);
    give(&w2, 0, .bit_flip);
    press_b(&w2, 0, false);
    try expectEqual(@as(u8, 0), b.bit_flip);
    try expectEqual(Pickup.none, w2.cars[0].pickup);
}

test "DEADLOCK: the two nearest cars ahead chained at 30% until they touch or 150 ticks; one car alone is chained to a wall" {
    var w = arena();
    const f = clear_frame(&w, 240);
    _ = put(&w, 0, f, 0, 0, 0);
    const a = put(&w, 1, f, 100, -20, 0);
    const b = put(&w, 2, f, 160, 20, 0);
    _ = put(&w, 3, f, 600, 0, 0); // beyond 400 px
    w.cars[3].active = false;
    give(&w, 0, .deadlock);
    const seq = w.event_seq;
    press_b(&w, 0, false);
    try expectEqual(@as(u8, 2), a.chain);
    try expectEqual(@as(u8, 1), b.chain);
    try expect(a.chain_ticks > 0 and b.chain_ticks > 0);
    try expectEqual(@as(u32, 2), count(&w, seq, .effect, null));
    a.vx = fixed.mul(fixed.cos(a.heading), sim.top_of(a));
    a.vy = fixed.mul(fixed.sin(a.heading), sim.top_of(a));
    pickups.limit(a);
    try expect(sim.speed(a) <= @divTrunc(sim.top_of(a) * 30, 100) + 256);
    const end = pickups.chain_anchor(&w, 1);
    try expectEqual(b.x, end.x);
    // The chain pulls them together; touching frees both.
    var d = w;
    var freed: ?usize = null;
    for (0..150) |t| {
        sim.simulate(&d, .{ 0, 0 });
        if (d.cars[1].chain_ticks == 0) {
            freed = t;
            break;
        }
    }
    try expect(freed != null);
    try expectEqual(no_car, d.cars[2].chain);
    // Apart, it times out at 150.
    ticks(&w, tuning.deadlock_ticks);
    try expectEqual(@as(u8, 0), a.chain_ticks);
    try expectEqual(no_car, a.chain);
    // One car in range: chained to the wall.
    var w2 = arena();
    _ = put(&w2, 0, f, 0, 0, 0);
    const lone = put(&w2, 1, f, 100, 10, 0);
    give(&w2, 0, .deadlock);
    press_b(&w2, 0, false);
    try expectEqual(no_car, lone.chain);
    try expect(lone.chain_ticks > 0);
    const anchor = pickups.chain_anchor(&w2, 1);
    const s = sim.track_of(&w2).sample(lone.progress);
    const r = px_dist(anchor.x, anchor.y, @as(i32, s.x) << fixed.Q, @as(i32, s.y) << fixed.Q);
    try expect(@abs(r - @as(i32, s.half)) <= 2);
}

test "DDOS: 8 drones swarm the car ahead, orbit 180 ticks for 2 each every 30, slow it 20%; shots down drones" {
    var w = arena();
    const f = clear_frame(&w, 200);
    _ = put(&w, 0, f, 0, 0, 0);
    const v = put(&w, 1, f, 150, 0, 0); // LEGACY, 140 armor
    give(&w, 0, .ddos);
    const seq = w.event_seq;
    press_b(&w, 0, false);
    try expectEqual(@as(usize, 8), pickups.drones_live(&w));
    var arrived: usize = 0;
    while (arrived < 60 and w.drones[0].state != .orbit) : (arrived += 1) tick(&w, .{}, .{});
    try expect(arrived < 40);
    var e: world.Event = .{};
    try expectEqual(@as(u32, 1), count(&w, seq, .effect, &e));
    try expectEqual(@intFromEnum(Pickup.ddos), e.c);
    try expectEqual(tuning.ddos_q8, pickups.thrust_q8(&w, 1));
    for (&w.drones) |*d| try expect(px_dist(d.x, d.y, v.x, v.y) <= tuning.drone_orbit + 8);
    const armor = v.armor;
    ticks(&w, 200);
    try expectEqual(@as(usize, 0), pickups.drones_live(&w));
    // 8 drones x 2 x 6 pulses.
    try expectEqual(@as(u8, @intCast(armor - 96)), v.armor);
    try expectEqual(@as(i32, 256), pickups.thrust_q8(&w, 1));

    // The victim shoots one down.
    var w2 = arena();
    _ = put(&w2, 0, f, 0, 0, 0);
    const t = put(&w2, 1, f, 120, 0, 0);
    t.front = .ping;
    weapons.refill(t);
    give(&w2, 0, .ddos);
    press_b(&w2, 0, false);
    while (w2.drones[0].state == .flying) tick(&w2, .{}, .{});
    const seq2 = w2.event_seq;
    for (0..30) |_| tick(&w2, .{}, .{ .a = true });
    try expect(pickups.drones_live(&w2) < 8);
    var sparks: world.Event = .{};
    try expect(count(&w2, seq2, .explode, &sparks) >= 1);
}

test "HEISENBUG: no lock, the AI ignores it, cars and drops pass through" {
    var w = arena();
    const f = clear_frame(&w, 200);
    const s = put(&w, 0, f, 0, 0, 0);
    const h = put(&w, 1, f, 100, 0, 0);
    tick(&w, .{}, .{});
    try expectEqual(@as(u8, 1), s.lock);
    give(&w, 1, .heisenbug);
    press_b(&w, 1, false);
    try expect(h.heisen > 0);
    try expectEqual(no_car, s.lock);
    // A SPEAR PHISH in flight loses it.
    s.front = .phish;
    weapons.refill(s);
    h.heisen = 0;
    tick(&w, .{}, .{});
    try expectEqual(@as(u8, 1), s.lock);
    tick(&w, .{ .a = true }, .{});
    give(&w, 1, .heisenbug);
    press_b(&w, 1, false);
    for (&w.projs) |*p| {
        if (p.kind == .phish) try expectEqual(no_car, p.target);
    }
    // The AI does not aim at it.
    const k = put(&w, racers.kiddie, f, 40, 0, 0);
    ai.update_aim(&w, racers.kiddie);
    try expectEqual(no_car, k.aim);
    // A LOGIC BOMB under it does not go off.
    w.drops[0] = .{ .x = h.x, .y = h.y, .kind = .bomb, .owner = racers.kiddie, .age = 100 };
    const armor = h.armor;
    tick(&w, .{}, .{});
    try expectEqual(world.DropKind.bomb, w.drops[0].kind);
    try expectEqual(armor, h.armor);
    // Cars pass through: two cars on one spot are not pushed apart.
    var d = w;
    d.cars[racers.kiddie].active = false;
    d.cars[0].x = d.cars[1].x;
    d.cars[0].y = d.cars[1].y;
    sim.collide_all(&d);
    try expectEqual(d.cars[1].x, d.cars[0].x);
}

test "RACE CONDITION: 6 ticks of tearing, then exactly the two cars trade places; out of range, nothing" {
    var w = arena();
    const f = clear_frame(&w, 260);
    const a = put(&w, 0, f, 0, -10, 0);
    const b = put(&w, 1, f, 200, 15, 0);
    const o = put(&w, 2, f, 100, 0, 0);
    o.active = true;
    // The next car ahead is car 2 (100 px); move it out so car 1 (200) is.
    o.active = false;
    b.vx = 3 << 16;
    const ax = a.x;
    const bx = b.x;
    const by = b.y;
    const bvx = b.vx;
    give(&w, 0, .race_condition);
    const seq = w.event_seq;
    tick(&w, .{ .b = true }, .{});
    try expectEqual(@as(u8, 1), a.swap_with);
    try expectEqual(@as(u8, 0), b.swap_with);
    try expect(a.swap_ticks > 0 and b.swap_ticks > 0);
    try expectEqual(ax, a.x);
    ticks(&w, tuning.race_ticks);
    try expectEqual(@as(u32, 1), count(&w, seq, .swap, null));
    try expectEqual(bx, a.x);
    try expectEqual(by, a.y);
    try expectEqual(bvx, a.vx);
    try expectEqual(ax, b.x);
    try expectEqual(@as(u8, 0), a.swap_ticks);
    try expectEqual(no_car, b.swap_with);
    // Beyond 300 px: nothing.
    var w2 = arena();
    _ = put(&w2, 0, f, 0, 0, 0);
    const far = put(&w2, 1, f, 0, 0, 0);
    far.progress +%= 30; // ~430 px ahead along the line
    give(&w2, 0, .race_condition);
    press_b(&w2, 0, false);
    try expectEqual(@as(u8, 0), far.swap_ticks);
}

test "RACE CONDITION across the start line keeps the laps whole" {
    var w = arena();
    const t = sim.track_of(&w);
    // A just short of the line with both sectors, B just past it a lap on.
    const a = &w.cars[0];
    const b = &w.cars[1];
    const sa = t.sample(252);
    const sb = t.sample(3);
    a.x = @as(i32, sa.x) << fixed.Q;
    a.y = @as(i32, sa.y) << fixed.Q;
    a.heading = sa.tangent;
    a.progress = 252;
    a.sectors = 3;
    a.lap = 1;
    b.x = @as(i32, sb.x) << fixed.Q;
    b.y = @as(i32, sb.y) << fixed.Q;
    b.heading = sb.tangent;
    b.progress = 3;
    b.sectors = 0;
    b.lap = 2;
    const pa = sim.progress_px(&w, a);
    const pb = sim.progress_px(&w, b);
    try expect(pb > pa and pb - pa < 300);
    give(&w, 0, .race_condition);
    tick(&w, .{ .b = true }, .{});
    ticks(&w, tuning.race_ticks);
    try expectEqual(@as(u8, 2), a.lap);
    try expectEqual(@as(u8, 1), b.lap);
    try expectEqual(pb, sim.progress_px(&w, a));
    try expectEqual(pa, sim.progress_px(&w, b));
}

// --- Tier C -------------------------------------------------------------------------

test "KERNEL PANIC: the packet runs the centerline to 1st: 40 and 90 ticks frozen; from 1st it goes back to 2nd" {
    var w = arena();
    const f = clear_frame(&w, 260);
    const u = put(&w, 0, f, 0, 0, 0);
    const v = put(&w, 1, f, 220, 25, 0);
    u.rank = 2;
    v.rank = 1;
    give(&w, 0, .kernel_panic);
    const seq = w.event_seq;
    tick(&w, .{ .b = true }, .{});
    var packet: ?*world.Projectile = null;
    for (&w.projs) |*p| {
        if (p.kind == .panic) packet = p;
    }
    try expectEqual(@as(u8, 1), packet.?.target);
    const armor = v.armor;
    var n: usize = 0;
    while (n < 200 and v.frozen == 0) : (n += 1) tick(&w, .{}, .{});
    // 220 px at 6 px a tick.
    try expect(n >= 30 and n <= 50);
    try expectEqual(armor - tuning.panic_dmg, v.armor);
    try expectEqual(world.Freeze.panic, v.frozen_by);
    var e: world.Event = .{};
    try expectEqual(@as(u32, 1), count(&w, seq, .effect, &e));
    try expectEqual(@intFromEnum(Pickup.kernel_panic), e.c);
    try expectEqual(@as(u8, 1), e.b);
    // Frozen: no input gets through and the car does not move.
    try expectEqual(@as(u8, 0), pickups.filter(&w, 1, .{ .left = true, .a = true, .b = true }).byte());
    var d = w;
    const x0 = d.cars[1].x;
    for (0..20) |_| sim.simulate(&d, .{ 0, (Input{ .right = true }).byte() });
    try expectEqual(x0, d.cars[1].x);
    ticks(&w, tuning.panic_freeze);
    try expectEqual(@as(u8, 0), v.frozen);
    try expectEqual(world.Freeze.none, v.frozen_by);

    // The user in 1st: it runs back to the car in 2nd.
    var w2 = arena();
    const user2 = put(&w2, 0, f, 200, 0, 0);
    const vic2 = put(&w2, 1, f, 0, -20, 0);
    user2.rank = 1;
    vic2.rank = 2;
    give(&w2, 0, .kernel_panic);
    tick(&w2, .{ .b = true }, .{});
    n = 0;
    while (n < 200 and vic2.frozen == 0) : (n += 1) tick(&w2, .{}, .{});
    try expect(n < 60);
    // Root shrugs it off.
    var w3 = arena();
    _ = put(&w3, 0, f, 0, 0, 0);
    const r = put(&w3, 1, f, 100, 0, 0);
    w3.cars[0].rank = 2;
    r.rank = 1;
    r.sudo = 300;
    give(&w3, 0, .kernel_panic);
    tick(&w3, .{ .b = true }, .{});
    ticks(&w3, 60);
    try expectEqual(@as(u8, 0), r.frozen);
    try expectEqual(r.armor_max, r.armor);
}

test "CAPTCHA: every other car held to 10%; AIs solve by character (KIDDIE slowest); a human plays the board" {
    var w = arena();
    const f = clear_frame(&w, 200);
    for (0..6) |i| _ = put(&w, i, f, @as(i32, @intCast(i)) * 30, 0, 0);
    give(&w, 0, .captcha);
    tick(&w, .{ .b = true }, .{});
    try expectEqual(@as(u8, 0), w.cars[0].captcha);
    for (1..6) |i| try expect(w.cars[i].captcha > 0);
    const human = &w.cars[1];
    try expectEqual(@as(u32, tuning.captcha_lights), @popCount(human.captcha_lit));
    // Held to 10%.
    human.vx = fixed.mul(fixed.cos(human.heading), sim.top_of(human));
    human.vy = fixed.mul(fixed.sin(human.heading), sim.top_of(human));
    pickups.limit(human);
    try expect(sim.speed(human) <= @divTrunc(sim.top_of(human), 10) + 256);
    // The human plays: A on each lit cell as the cursor reaches it.
    var freed: [6]?usize = @splat(null);
    var pressed = false;
    const ammo = human.ammo_front;
    for (2..200) |t| {
        const bit = @as(u16, 1) << @intCast(human.captcha_cursor);
        const press = human.captcha > 0 and human.captcha_lit & bit != 0 and human.captcha_done & bit == 0 and !pressed;
        tick(&w, .{}, .{ .a = press });
        pressed = press;
        for (1..6) |i| {
            if (freed[i] == null and w.cars[i].captcha == 0) freed[i] = t;
        }
    }
    try expect(freed[1].? <= 50);
    // A presses on the board do not fire.
    try expectEqual(ammo, human.ammo_front);
    for (2..6) |i| {
        const want = ai.crews[i].captcha_solve;
        try expect(@abs(@as(i32, @intCast(freed[i].?)) - want) <= 1);
        if (i != racers.kiddie) try expect(freed[i].? < freed[racers.kiddie].?);
    }
    // A wrong press clears the board; left alone it frees after 120.
    var w2 = arena();
    _ = put(&w2, 0, f, 0, 0, 0);
    const h2 = put(&w2, 1, f, 40, 0, 0);
    give(&w2, 0, .captcha);
    tick(&w2, .{ .b = true }, .{});
    var t2: usize = 1;
    while (h2.captcha_lit & (@as(u16, 1) << @intCast(h2.captcha_cursor)) == 0) : (t2 += 1) tick(&w2, .{}, .{});
    tick(&w2, .{}, .{ .a = true });
    t2 += 1;
    try expect(h2.captcha_done != 0);
    while (h2.captcha_lit & (@as(u16, 1) << @intCast(h2.captcha_cursor)) != 0) : (t2 += 1) tick(&w2, .{}, .{});
    tick(&w2, .{}, .{ .a = true });
    t2 += 1;
    try expectEqual(@as(u16, 0), h2.captcha_done);
    while (h2.captcha > 0) : (t2 += 1) tick(&w2, .{}, .{});
    try expectEqual(@as(usize, tuning.captcha_human), t2);
}

test "SUDO: invulnerable, +20% speed, rams deal 40 and bounce, drops it touches are destroyed" {
    var w = arena();
    const f = clear_frame(&w, 200);
    const r = put(&w, 1, f, 60, 0, 0);
    const s = put(&w, 0, f, 0, 0, 0);
    give(&w, 1, .sudo);
    press_b(&w, 1, false);
    try expect(r.sudo > 0);
    try expectEqual(tuning.sudo_q8, pickups.thrust_q8(&w, 1));
    s.front = .ping;
    weapons.refill(s);
    tick(&w, .{ .a = true }, .{});
    ticks(&w, 30);
    try expectEqual(r.armor_max, r.armor);
    // A LOGIC BOMB under it: gone, not set off.
    w.drops[0] = .{ .x = r.x, .y = r.y, .kind = .bomb, .owner = 0, .age = 100 };
    tick(&w, .{}, .{});
    try expectEqual(world.DropKind.none, w.drops[0].kind);
    try expectEqual(r.armor_max, r.armor);
    // Ramming SNOUTY at 1 px/tick: 40 and a bounce.
    _ = put(&w, 0, f, 0, 0, 0);
    _ = put(&w, 1, f, -19, 0, 0);
    r.sudo = 100;
    r.vx = fixed.mul(fixed.cos(f.h), 1 << 16);
    r.vy = fixed.mul(fixed.sin(f.h), 1 << 16);
    const armor = s.armor;
    sim.collide_all(&w);
    try expectEqual(armor - tuning.sudo_ram, s.armor);
    try expect(sim.speed(s) >= tuning.sudo_bounce);
    try expectEqual(r.armor_max, r.armor);
    // Expiry.
    ticks(&w, tuning.sudo_ticks);
    try expectEqual(@as(u16, 0), r.sudo);
}

test "ZERO-DAY: wrecks the nearest car ahead outright, through armor, duck, HEISENBUG and root, credited" {
    var w = arena();
    const f = clear_frame(&w, 200);
    _ = put(&w, 0, f, 0, 0, 0);
    const v = put(&w, 1, f, 150, 0, 0);
    v.duck = 100;
    v.heisen = 100;
    v.sudo = 100;
    give(&w, 0, .zero_day);
    const seq = w.event_seq;
    tick(&w, .{ .b = true }, .{});
    try expectEqual(world.Wreck.zero_day, v.wreck);
    try expectEqual(@as(u8, 1), w.cars[0].kills);
    var e: world.Event = .{};
    try expectEqual(@as(u32, 1), count(&w, seq, .wreck, &e));
    try expectEqual(@as(u8, 0), e.b);
    try expectEqual(@intFromEnum(world.Wreck.zero_day), e.c);
    try expectEqual(@as(u32, 1), count(&w, seq, .effect, null));
    // Statuses are gone with the wreck.
    try expectEqual(@as(u16, 0), v.duck);
    try expectEqual(@as(u8, 0), v.heisen);
}

test "a wreck clears statuses, ends a chain and a pending swap, disperses drones; the held pickup stays" {
    var w = arena();
    const f = clear_frame(&w, 200);
    _ = put(&w, 0, f, 0, 0, 0);
    const v = put(&w, 1, f, 100, 0, 0);
    give(&w, 0, .ddos);
    press_b(&w, 0, false);
    v.pickup = .sudo;
    v.chain = 0;
    v.chain_ticks = 50;
    w.cars[0].chain = 1;
    w.cars[0].chain_ticks = 50;
    v.bit_flip = 50;
    v.captcha = 50;
    sim.wreck(&w, 1, .armor);
    try expectEqual(@as(usize, 0), pickups.drones_live(&w));
    try expectEqual(no_car, w.cars[0].chain);
    try expectEqual(@as(u8, 0), v.bit_flip);
    try expectEqual(@as(u8, 0), v.captcha);
    try expectEqual(Pickup.sudo, v.pickup);
}

// --- AI pickup policies (SPEC 4.3, 6.5) -------------------------------------------

fn ai_arena() World {
    var w = arena();
    for (&w.cars) |*c| c.human = world.no_human;
    return w;
}

test "AI pickups: KIDDIE at once; SYSADMIN holds HOT PATCH and the duck for their trigger" {
    var w = ai_arena();
    const f = clear_frame(&w, 200);
    _ = put(&w, racers.kiddie, f, 0, 0, 0);
    give(&w, racers.kiddie, .duck);
    w.cars[racers.kiddie].roll_ticks = 3;
    try expect(!ai.drive(&w, racers.kiddie).b);
    w.cars[racers.kiddie].roll_ticks = 0;
    try expect(ai.drive(&w, racers.kiddie).b);
    give(&w, racers.kiddie, .bit_flip); // even with nobody ahead
    try expect(ai.drive(&w, racers.kiddie).b);

    const sa = put(&w, racers.sysadmin, f, 0, 30, 0);
    give(&w, racers.sysadmin, .hot_patch);
    try expect(!ai.drive(&w, racers.sysadmin).b);
    sa.armor = 30;
    try expect(ai.drive(&w, racers.sysadmin).b);
    give(&w, racers.sysadmin, .duck);
    try expect(!ai.drive(&w, racers.sysadmin).b);
    w.cars[0].lock = racers.sysadmin;
    try expect(ai.drive(&w, racers.sysadmin).b);
}

test "AI pickups: ROOTKIT saves HEISENBUG for the last lap; BOTNET saves KERNEL PANIC and DDOS for the leader" {
    var w = ai_arena();
    const f = clear_frame(&w, 200);
    const r = put(&w, racers.rootkit, f, 0, 0, 0);
    give(&w, racers.rootkit, .heisenbug);
    try expect(!ai.drive(&w, racers.rootkit).b);
    r.lap = tuning.laps - 1;
    try expect(ai.drive(&w, racers.rootkit).b);
    // Everyone else uses HEISENBUG at once.
    _ = put(&w, racers.legacy, f, 0, 30, 0);
    give(&w, racers.legacy, .heisenbug);
    try expect(ai.drive(&w, racers.legacy).b);

    w.cars[racers.rootkit].active = false;
    w.cars[racers.legacy].active = false;
    const b = put(&w, racers.botnet, f, 0, -30, 0);
    give(&w, racers.botnet, .kernel_panic);
    b.rank = 1;
    try expect(!ai.drive(&w, racers.botnet).b);
    b.rank = 3;
    try expect(ai.drive(&w, racers.botnet).b);
    give(&w, racers.botnet, .ddos);
    const ahead = put(&w, 0, f, 100, 0, 0);
    ahead.rank = 2;
    try expect(!ai.drive(&w, racers.botnet).b);
    ahead.rank = 1;
    try expect(ai.drive(&w, racers.botnet).b);
}

test "AI pickups: HONEYPOT dropped on a car behind, FORK BOMB with a car behind, RACE CONDITION on the last lap within 60 px" {
    var w = ai_arena();
    const f = clear_frame(&w, 200);
    _ = put(&w, racers.snouty, f, 60, 0, 0);
    give(&w, racers.snouty, .honeypot);
    try expect(!ai.drive(&w, racers.snouty).b);
    _ = put(&w, racers.legacy, f, 0, 0, 0);
    const in = ai.drive(&w, racers.snouty);
    try expect(in.b and in.down and !in.a);
    give(&w, racers.snouty, .fork_bomb);
    try expect(ai.drive(&w, racers.snouty).b);
    // LEGACY behind SNOUTY by 60 px: RACE CONDITION only on the last lap.
    give(&w, racers.legacy, .race_condition);
    try expect(!ai.drive(&w, racers.legacy).b);
    w.cars[racers.legacy].lap = tuning.laps - 1;
    w.cars[racers.snouty].lap = tuning.laps - 1;
    try expect(ai.drive(&w, racers.legacy).b);
}

// --- The soak and determinism -------------------------------------------------------

const Soak = struct {
    ticks: u32 = 0,
    all_finished: bool = false,
    max_stuck: u32 = 0,
    max_projs: usize = 0,
    max_drops: usize = 0,
    max_drones: usize = 0,
    wrecks: u32 = 0,
    rolls: [17]u32 = @splat(0),
    uses: [17]u32 = @splat(0),
    zero_days: [world.car_count]u32 = @splat(0),
};

fn soak_race(seed: u32, setup_humans: [2]u8, limit: u32, out: ?*World) Soak {
    var w: World = undefined;
    sim.reset(&w, .{ .seed = seed, .humans = setup_humans });
    var r: Soak = .{};
    var best: [world.car_count]i32 = @splat(std.math.minInt(i32));
    var since: [world.car_count]u32 = @splat(0);
    var was: [world.car_count]world.Wreck = @splat(.none);
    while (w.phase == .countdown) sim.simulate(&w, .{ 0, 0 });
    while (r.ticks < limit) : (r.ticks += 1) {
        const seq0 = w.event_seq;
        // Humans (if any) are driven by their racer's crew, as the autopilot.
        var ins: [2]u8 = .{ 0, 0 };
        for (&w.cars, 0..) |*c, i| {
            if (c.human < 2) ins[c.human] = ai.drive(&w, i).byte();
        }
        sim.simulate(&w, ins);
        var s = seq0;
        while (s != w.event_seq) : (s +%= 1) {
            const e = w.events[s % world.event_count];
            switch (e.kind) {
                .roll => {
                    r.rolls[e.b] += 1;
                    if (e.b == @intFromEnum(Pickup.zero_day)) r.zero_days[e.a] += 1;
                },
                .use => r.uses[e.b] += 1,
                else => {},
            }
        }
        r.max_projs = @max(r.max_projs, weapons.projs_live(&w));
        r.max_drops = @max(r.max_drops, weapons.drops_live(&w));
        r.max_drones = @max(r.max_drones, pickups.drones_live(&w));
        var done = true;
        for (&w.cars, 0..) |*c, i| {
            if (c.wreck != .none and was[i] == .none) r.wrecks += 1;
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
    if (out) |o| o.* = w;
    return r;
}

test "chaos soak with pickups: 20 seeded races finish, nobody stuck over 600 ticks, pools within caps, every pickup used" {
    var rolls: [17]u32 = @splat(0);
    var uses: [17]u32 = @splat(0);
    var wrecks: u32 = 0;
    var max_ticks: u32 = 0;
    var max_stuck: u32 = 0;
    for (0..20) |k| {
        const seed: u32 = @intCast(0xB0B0_0000 + k * 104729);
        // Half the races carry an autopiloted human (SNOUTY), as the attract.
        const humans: [2]u8 = if (k % 2 == 0) .{ world.no_human, world.no_human } else .{ racers.snouty, world.no_human };
        var w: World = undefined;
        const r = soak_race(seed, humans, 60 * 300, &w);
        if (report) {
            std.debug.print("\npsoak {d:2}: {d:5} ticks, wrecks {d:2}, stuck max {d:3}, projs {d:2} drops {d:2} drones {d} |", .{ k, r.ticks, r.wrecks, r.max_stuck, r.max_projs, r.max_drops, r.max_drones });
            for (w.cars) |c| std.debug.print(" {s}:{d}/{d}/{d}", .{ racers.roster[c.racer].name[0..3], c.rank, c.kills, c.wrecks });
        }
        try expect(r.all_finished);
        try expect(r.max_stuck <= 600);
        try expect(r.max_projs <= world.proj_count);
        try expect(r.max_drops <= world.drop_count);
        try expect(r.max_drones <= world.drone_count);
        for (r.zero_days) |z| try expect(z <= 1);
        for (0..17) |p| {
            rolls[p] += r.rolls[p];
            uses[p] += r.uses[p];
        }
        wrecks += r.wrecks;
        max_ticks = @max(max_ticks, r.ticks);
        max_stuck = @max(max_stuck, r.max_stuck);
    }
    if (report) {
        std.debug.print("\npsoak total: wrecks {d}, longest race {d} ticks, stuck max {d}\n", .{ wrecks, max_ticks, max_stuck });
        for (0..16) |p| std.debug.print("  {s:16} rolled {d:4} used {d:4}\n", .{ @tagName(@as(Pickup, @enumFromInt(p))), rolls[p], uses[p] });
    }
    for (0..15) |p| {
        try expect(rolls[p] > 0);
        try expect(uses[p] > 0);
    }
    try expectEqual(@as(u32, 0), rolls[@intFromEnum(Pickup.prompt_injection)]);
}

test "pickups are deterministic: the same seeded race twice, and two worlds interleaved with humans pressing B and A" {
    var a: World = undefined;
    var b: World = undefined;
    _ = soak_race(0xD00D, .{ racers.kiddie, world.no_human }, 4000, &a);
    _ = soak_race(0xD00D, .{ racers.kiddie, world.no_human }, 4000, &b);
    try expect(sim.worlds_equal(&a, &b));
    var x: World = undefined;
    var y: World = undefined;
    const setup = world.Setup{ .seed = 31337, .humans = .{ racers.rootkit, racers.botnet } };
    sim.reset(&x, setup);
    sim.reset(&y, setup);
    var rolls: u32 = 0;
    for (0..4000) |t| {
        const in0 = Input{ .b = t % 50 == 3, .a = t % 3 == 0, .down = t % 300 == 150, .right = (t / 30) % 5 == 1 };
        const in1 = Input{ .b = t % 70 == 9, .down = t % 70 == 9 and t % 140 == 9, .a = t % 4 == 1, .left = (t / 25) % 6 == 2 };
        const seq = x.event_seq;
        sim.simulate(&x, .{ in0.byte(), in1.byte() });
        sim.simulate(&y, .{ in0.byte(), in1.byte() });
        rolls += count(&x, seq, .roll, null);
    }
    try expect(sim.worlds_equal(&x, &y));
    try expect(rolls > 0);
}
