//! BATTLE, `KILL -9` (SPEC 8.3, M6): the arena rules. New for Snouty GC.
//!
//! Every wreck costs a life (unless lives are INF); the car that wrecks
//! you (the last hit within `tuning.credit_ticks`, `sim.wreck`'s credit)
//! scores an elimination, and a wreck with no recent hit scores nobody. A
//! car with lives left respawns after its WATCHDOG delay on the spawn pad
//! farthest from the nearest enemy, in SAFE MODE (`Car.safe`) for
//! `tuning.battle_safe` ticks. A car out of lives leaves the round (the
//! claw). The round ends when one car has lives left or the clock
//! (`World.tick` against `battle.limit`) runs out. Ranks are the
//! standings: eliminations, then lives left (INF: fewer wrecks), then time
//! survived, ties to the lower index. No laps, so ammo and burst charges
//! refill every `tuning.battle_refill` ticks.
//!
//! Part of `sim.simulate`, so pure in the World: no cart API, no clock, no
//! floats, no globals written (the arena cache `track.arena` is the track
//! data, filled by `track.select` at reset).
const std = @import("std");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const track = @import("track.zig");
const weapons = @import("weapons.zig");

const World = world.World;
const Car = world.Car;
const no_car = world.no_car;

const world_mask: i32 = (1024 << fixed.Q) - 1;

/// The round's rules from the setup (called by `sim.reset`).
pub fn init(w: *World, setup: world.Setup) void {
    const minutes: u16 = if (setup.minutes == 0 and setup.lives == 0) 3 else setup.minutes;
    w.battle = .{
        .lives = setup.lives,
        .limit = minutes * tuning.battle_minute,
        .refill = tuning.battle_refill,
    };
}

/// Put the cars on the grid (`order[0..n]`, as `sim.reset` shuffled them)
/// on the spawn pads, facing in, with their lives.
pub fn place(w: *World, order: []const u8) void {
    const a = &track.arena;
    for (order, 0..) |ci, slot| {
        const c = &w.cars[ci];
        if (a.spawn_n > 0) put_on(c, a.spawns[slot % a.spawn_n]);
        c.lives = w.battle.lives;
        c.progress = 0;
    }
}

fn put_on(c: *Car, s: track.Spawn) void {
    c.x = @as(i32, s.x) << fixed.Q;
    c.y = @as(i32, s.y) << fixed.Q;
    c.heading = s.heading;
    c.vx = 0;
    c.vy = 0;
}

/// Is car `c` still in the round (on the grid, not out of lives)?
pub fn in_round(c: *const Car) bool {
    return c.active;
}

/// Cars still in the round.
pub fn in_count(w: *const World) u8 {
    var n: u8 = 0;
    for (&w.cars) |*c| n += @intFromBool(c.active);
    return n;
}

/// The car's last stretch for the AI's saved pickups (`sim.last_lap`): its
/// last life, or the round's last minute.
pub fn final_stretch(w: *const World, c: *const Car) bool {
    if (w.battle.lives != 0 and c.lives <= 1) return true;
    return w.battle.limit != 0 and w.tick + tuning.battle_minute >= w.battle.limit;
}

/// A wreck in battle (`sim.wreck`, after its kill credit): the elimination
/// for `killer`, a life lost, and out of lives the car leaves the round.
pub fn on_wreck(w: *World, i: usize, killer: u8) void {
    const c = &w.cars[i];
    if (killer != no_car) weapons.emit(w, .eliminated, killer, @intCast(i), w.cars[killer].kills, c.x, c.y);
    if (w.battle.lives == 0) return;
    c.lives -|= 1;
    if (c.lives == 0) out(w, i);
}

/// Car `i` is out of lives: it leaves the round (`active = false`, its bit
/// in `battle.out`, `finish_tick` the tick it went out) and the claw comes
/// for its hulk (the `out` event: the cars still in after it).
fn out(w: *World, i: usize) void {
    const c = &w.cars[i];
    c.active = false;
    c.lock = no_car;
    c.aim = no_car;
    c.finish_tick = w.tick;
    w.battle.out |= @as(u8, 1) << @intCast(i);
    weapons.emit(w, .out, @intCast(i), in_count(w), 0, c.x, c.y);
}

/// After the WATCHDOG delay (`sim.respawn` in battle): back on the spawn
/// pad farthest from the nearest enemy, stopped, full armor, kept ammo, in
/// SAFE MODE.
pub fn respawn(w: *World, i: usize) void {
    const c = &w.cars[i];
    const a = &track.arena;
    if (a.spawn_n > 0) put_on(c, a.spawns[pad_for(w, i)]);
    c.vx = 0;
    c.vy = 0;
    c.immune = tuning.battle_safe;
    c.safe = tuning.battle_safe;
    c.wreck = .none;
    c.hitstop = 0;
    c.armor = c.armor_max;
    c.nav = track.no_node;
    weapons.emit(w, .respawn, @intCast(i), 0, 0, c.x, c.y);
}

/// The spawn pad whose nearest enemy (a car in the round, not wrecked) is
/// farthest away; ties to the lower pad.
pub fn pad_for(w: *const World, i: usize) usize {
    const a = &track.arena;
    var best: usize = 0;
    var best_d: i32 = -1;
    for (a.spawns[0..a.spawn_n], 0..) |s, k| {
        var near: i32 = std.math.maxInt(i32);
        for (&w.cars, 0..) |*o, j| {
            if (j == i or !o.active or o.wreck != .none) continue;
            const dx = wrap_px((o.x >> fixed.Q) - @as(i32, s.x));
            const dy = wrap_px((o.y >> fixed.Q) - @as(i32, s.y));
            near = @min(near, dx * dx + dy * dy);
        }
        if (near > best_d) {
            best_d = near;
            best = k;
        }
    }
    return best;
}

/// One racing tick, after the ranks: the refill clock, the kill leader,
/// and the round's end by lives or by time.
pub fn update(w: *World) void {
    if (w.mode != .battle or w.phase != .racing) return;
    w.battle.refill -|= 1;
    if (w.battle.refill == 0) {
        w.battle.refill = tuning.battle_refill;
        for (&w.cars) |*c| {
            if (!c.active) continue;
            weapons.refill(c);
            c.burst_charges = c.burst_max;
        }
    }
    w.battle.leader = leader(w);
    if (w.battle.lives != 0 and in_count(w) <= 1) return finish(w, .lives);
    if (w.battle.limit != 0 and w.tick >= w.battle.limit) return finish(w, .time);
}

/// The kill leader: most eliminations (at least one), ties to the better
/// rank; `no_car` while nobody has scored.
pub fn leader(w: *const World) u8 {
    var best: u8 = no_car;
    for (&w.cars, 0..) |*c, i| {
        if (c.kills == 0 or c.rank == 0) continue;
        if (best == no_car or c.kills > w.cars[best].kills or
            (c.kills == w.cars[best].kills and c.rank < w.cars[best].rank)) best = @intCast(i);
    }
    return best;
}

/// The round is over: every car still in finishes now, the ranks are final.
fn finish(w: *World, why: world.BattleEnd) void {
    w.battle.end = why;
    for (&w.cars) |*c| {
        if (!c.active) continue;
        c.finished = true;
        c.finish_tick = w.tick;
    }
    update_ranks(w);
    w.phase = .finished;
}

/// A car's place in the standings: on the grid (in the round or out).
fn standing(w: *const World, i: usize) bool {
    return w.cars[i].active or w.battle.out & (@as(u8, 1) << @intCast(i)) != 0;
}

/// Ranks 1..n over the cars that started (`sim.update_ranks` in battle):
/// eliminations, then lives left (INF: fewer wrecks), then time survived
/// (a car still in has survived to now), ties to the lower index. Cars
/// CREWS left off the grid rank 0.
pub fn update_ranks(w: *World) void {
    for (0..world.car_count) |i| {
        const c = &w.cars[i];
        if (!standing(w, i)) {
            c.rank = 0;
            continue;
        }
        var r: u8 = 1;
        for (0..world.car_count) |j| {
            if (j != i and standing(w, j) and ahead(w, j, i)) r += 1;
        }
        c.rank = r;
    }
}

/// Does car `a` stand ahead of car `b`?
fn ahead(w: *const World, a: usize, b: usize) bool {
    const ca = &w.cars[a];
    const cb = &w.cars[b];
    if (ca.kills != cb.kills) return ca.kills > cb.kills;
    if (w.battle.lives != 0) {
        if (ca.lives != cb.lives) return ca.lives > cb.lives;
    } else if (ca.wrecks != cb.wrecks) return ca.wrecks < cb.wrecks;
    const sa = survived(w, ca);
    const sb = survived(w, cb);
    if (sa != sb) return sa > sb;
    return a < b;
}

fn survived(w: *const World, c: *const Car) u32 {
    return if (c.active and !c.finished) w.tick else c.finish_tick;
}

inline fn wrap_px(d: i32) i32 {
    return ((d + 512) & 1023) - 512;
}

test "battle options: NONE with INF lives is read as 3 minutes" {
    var w: World = .{};
    init(&w, .{ .mode = .battle, .lives = 0, .minutes = 0 });
    try std.testing.expectEqual(@as(u16, 3 * tuning.battle_minute), w.battle.limit);
    init(&w, .{ .mode = .battle, .lives = 3, .minutes = 0 });
    try std.testing.expectEqual(@as(u16, 0), w.battle.limit);
    init(&w, .{ .mode = .battle, .lives = 5, .minutes = 5 });
    try std.testing.expectEqual(@as(u16, 5 * tuning.battle_minute), w.battle.limit);
    try std.testing.expectEqual(@as(u8, 5), w.battle.lives);
    _ = world_mask;
}
