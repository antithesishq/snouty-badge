//! Pickups (SPEC 6.3, 6.4): RMA crates, the roulette and rank-weighted
//! rolls, the 15 non-league pickups and their status effects, the DDOS
//! drones and the KERNEL PANIC packet. New for Snouty GC (M2).
//!
//! Part of `sim.simulate`, so pure in the World: no cart API, no clock, no
//! floats, no globals written; the world PRNG is the only randomness. The
//! crate spawn positions come from `track.crate_spots`, a cache of the
//! track data filled by `track.select` (like `map_ram`).
//!
//! Hooks, in the order `sim.simulate` calls them for each car: `filter`
//! (the status effects on the race byte), the driving step with
//! `thrust_q8` and `limit`, `control` (the CAPTCHA mini-game and B), then
//! after the weapons `update` (forks, crates, drones, timers, swaps).
//! `weapons` calls `update_packet`, `shoot_drone`, `duck_takes` and
//! `drop_touch`; `sim.wreck` calls `on_wreck`.
//!
//! `duck_pos` and `chain_anchor` are render-side helpers (pure reads).
const std = @import("std");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const track = @import("track.zig");
const sim = @import("sim.zig");
const gc_mode = @import("gc_mode.zig");
const weapons = @import("weapons.zig");
const ai = @import("ai.zig");

const World = world.World;
const Car = world.Car;
const Input = world.Input;
const Pickup = world.Pickup;
const no_car = world.no_car;

const world_mask: i32 = (1024 << fixed.Q) - 1;

inline fn wrap_px(d: i32) i32 {
    return ((d + 512) & 1023) - 512;
}

inline fn dpx(a: i32, b: i32) i32 {
    return weapons.dq(a, b) >> fixed.Q;
}

// --- Render-side helpers ---------------------------------------------------------

/// A world point, Q16.16.
pub const Point = struct { x: i32, y: i32 };

/// Where a car's RUBBER DUCK bobs: `duck_behind` px behind it, Q16.
pub fn duck_pos(c: *const Car) Point {
    return .{
        .x = (c.x -% fixed.cos(c.heading) * tuning.duck_behind) & world_mask,
        .y = (c.y -% fixed.sin(c.heading) * tuning.duck_behind) & world_mask,
    };
}

/// The far end of car `i`'s DEADLOCK chain, Q16: the partner car, or for a
/// wall chain the track edge nearer the car at its centerline sample.
pub fn chain_anchor(w: *const World, i: usize) Point {
    const c = &w.cars[i];
    if (c.chain != no_car) {
        const o = &w.cars[c.chain % world.car_count];
        return .{ .x = o.x, .y = o.y };
    }
    const s = sim.track_of(w).sample(c.progress);
    const rx = -fixed.sin(s.tangent);
    const ry = fixed.cos(s.tangent);
    const ox = wrap_px((c.x >> fixed.Q) - @as(i32, s.x));
    const oy = wrap_px((c.y >> fixed.Q) - @as(i32, s.y));
    const lat = (ox * rx + oy * ry) >> fixed.Q;
    const edge: i32 = if (lat >= 0) s.half else -@as(i32, s.half);
    return .{
        .x = ((@as(i32, s.x) << fixed.Q) +% rx * edge) & world_mask,
        .y = ((@as(i32, s.y) << fixed.Q) +% ry * edge) & world_mask,
    };
}

// --- Rolls (SPEC 6.4) ----------------------------------------------------------------

pub const Tier = enum(u8) { a, b, c };

pub fn tier_of(p: Pickup) Tier {
    const v = @backingInt(p);
    return if (v <= @backingInt(Pickup.spaghetti)) .a else if (v <= @backingInt(Pickup.race_condition)) .b else .c;
}

/// One roll for a car at `rank` (1..6): a tier by the rank's odds, then a
/// pickup uniformly within the tier. KERNEL PANIC never rolls for 1st;
/// ZERO-DAY only for 5th and 6th, and only when `zero_day_ok`.
pub fn roll_pickup(w: *World, rank: u8, zero_day_ok: bool) Pickup {
    const r = std.math.clamp(rank, 1, world.car_count);
    const odds = tuning.roll_odds[r - 1];
    const d = weapons.rand(w) % 100;
    const tier: Tier = if (d < odds[0]) .a else if (d < @as(u32, odds[0]) + odds[1]) .b else .c;
    var pool: [6]Pickup = undefined;
    var n: u32 = 0;
    switch (tier) {
        .a => for ([_]Pickup{ .prefetch, .honeypot, .duck, .hot_patch, .spaghetti }) |p| {
            pool[n] = p;
            n += 1;
        },
        .b => for ([_]Pickup{ .fork_bomb, .bit_flip, .deadlock, .ddos, .heisenbug, .race_condition }) |p| {
            pool[n] = p;
            n += 1;
        },
        .c => {
            if (r != 1) {
                pool[n] = .kernel_panic;
                n += 1;
            }
            pool[n] = .captcha;
            pool[n + 1] = .sudo;
            n += 2;
            if (r >= 5 and zero_day_ok) {
                pool[n] = .zero_day;
                n += 1;
            }
        },
    }
    return pool[weapons.rand(w) % n];
}

// --- Who is where ----------------------------------------------------------------------

/// May this car use a pickup, be hit by one, take a crate?
fn racing(w: *const World, c: *const Car) bool {
    return w.combat and w.phase == .racing and c.active and c.wreck == .none and !c.finished;
}

/// A car a pickup may pick as its target: racing, and (for an `observe`
/// pickup) not under HEISENBUG and not root.
fn pickable(w: *const World, o: *const Car, observe: bool) bool {
    return racing(w, o) and !(observe and (o.heisen > 0 or o.sudo > 0));
}

/// The nearest car ahead of car `i` in race progress within `range` px
/// (`maxInt` for any), skipping `skip`; `no_car` when there is none.
pub fn ahead(w: *const World, i: usize, range: i32, observe: bool, skip: u8) u8 {
    const me = sim.progress_px(w, &w.cars[i]);
    var best: u8 = no_car;
    var best_d: i32 = range;
    for (&w.cars, 0..) |*o, j| {
        if (j == i or j == skip or !pickable(w, o, observe)) continue;
        const d = sim.progress_px(w, o) - me;
        if (d <= 0 or d > best_d) continue;
        best_d = d;
        best = @intCast(j);
    }
    return best;
}

/// Is a homing weapon on car `i` (SPEC 6.5's RUBBER DUCK trigger): a SPEAR
/// PHISH lock or missile, a DDOS drone or a KERNEL PANIC packet.
pub fn threatened(w: *const World, i: usize) bool {
    for (&w.cars) |*o| {
        if (o.lock == i) return true;
    }
    for (&w.projs) |*p| {
        if ((p.kind == .phish or p.kind == .panic) and p.target == i) return true;
    }
    for (&w.drones) |*d| {
        if (d.state != .none and d.target == i) return true;
    }
    return false;
}

// --- Input and driving hooks -----------------------------------------------------------

/// The race byte as the car's status lets it act this tick: nothing while
/// frozen, no steering while spinning, Left and Right swapped by BIT FLIP.
pub fn filter(w: *const World, i: usize, in: Input) Input {
    const c = &w.cars[i];
    if (c.frozen > 0) return .{};
    var out = in;
    if (c.spin > 0) {
        out.left = false;
        out.right = false;
    }
    if (c.bit_flip > 0) {
        out.left = in.right and c.spin == 0;
        out.right = in.left and c.spin == 0;
    }
    return out;
}

fn drones_on(w: *const World, i: usize) bool {
    for (&w.drones) |*d| {
        if (d.state == .orbit and d.target == i) return true;
    }
    return false;
}

/// Thrust multiplier (1/256) from the car's pickups: the terminal speed
/// scales with it (PREFETCH +40%, SUDO +20%, a SPAGHETTI strand -10%, a
/// DDOS swarm -20%).
pub fn thrust_q8(w: *const World, i: usize) i32 {
    const c = &w.cars[i];
    var m: i32 = 256;
    if (c.prefetch > 0) m = (m * tuning.prefetch_q8) >> 8;
    if (c.sudo > 0) m = (m * tuning.sudo_q8) >> 8;
    if (c.strand > 0 and c.tangle == 0) m = (m * tuning.strand_q8) >> 8;
    if (drones_on(w, i)) m = (m * tuning.ddos_q8) >> 8;
    return m;
}

/// Clamp a car's velocity to `pct`% of its top speed.
fn cap_speed(c: *Car, pct: i32) void {
    const cap = @divTrunc(sim.top_of(c) * pct, 100);
    const spd = sim.speed(c);
    if (spd <= cap or spd == 0) return;
    c.vx = @intCast(@divTrunc(@as(i64, c.vx) * cap, spd));
    c.vy = @intCast(@divTrunc(@as(i64, c.vy) * cap, spd));
}

/// After the driving step, before the move: the HONEYPOT spin and the
/// speed limits (frozen 0, CAPTCHA 10%, DEADLOCK 30%, tangled 40% of the
/// car's top speed).
pub fn limit(c: *Car) void {
    if (c.spin > 0) {
        c.heading +%= tuning.spin_rate;
        c.vx = fixed.mul(c.vx, tuning.spin_keep);
        c.vy = fixed.mul(c.vy, tuning.spin_keep);
    }
    if (c.frozen > 0) {
        c.vx = 0;
        c.vy = 0;
        return;
    }
    var pct: i32 = 100;
    if (c.captcha > 0) pct = @min(pct, tuning.captcha_pct);
    if (c.chain_ticks > 0) pct = @min(pct, tuning.deadlock_pct);
    if (c.tangle > 0) pct = @min(pct, tuning.tangle_pct);
    if (pct < 100) cap_speed(c, pct);
}

/// The CAPTCHA mini-game (a human's A presses) and B (use the held
/// pickup; Down+B backward). `in` is the filtered race byte; called after
/// the car's driving step and before `weapons.fire` (which keeps `a_was`).
/// A solved board frees the car at the end of the tick, so the solving
/// press does not also fire.
pub fn control(w: *World, i: usize, in: Input) void {
    const c = &w.cars[i];
    const b_edge = in.b and !c.b_was;
    c.b_was = in.b;
    if (!racing(w, c)) return;
    if (c.captcha > 0 and c.human < 2 and in.a and !in.down and !c.a_was) {
        const bit = @as(u16, 1) << @intCast(c.captcha_cursor % 9);
        if (c.captcha_lit & bit != 0) {
            c.captcha_done |= bit;
            if (c.captcha_done == c.captcha_lit) c.captcha = 1;
        } else c.captcha_done = 0;
    }
    if (b_edge and c.pickup != .none and c.roll_ticks == 0 and c.frozen == 0 and c.safe == 0) use(w, i, in.down);
}

// --- Using a pickup ----------------------------------------------------------------------

fn emit_at(w: *World, kind: world.EventKind, a: u8, b: u8, c: u8, o: *const Car) void {
    weapons.emit(w, kind, a, b, c, o.x, o.y);
}

fn effect(w: *World, src: u8, j: usize, p: Pickup) void {
    emit_at(w, .effect, src, @intCast(j), @backingInt(p), &w.cars[j]);
}

/// Is the point at (x, y) Q16 on floor a drop may lie on (not a wall, not
/// off the track)?
fn floor_ok(w: *const World, x: i32, y: i32) bool {
    const a = sim.track_of(w).attr_at(x >> fixed.Q, y >> fixed.Q);
    return a != .off and a != .wall;
}

/// Lay a drop `dist` px along the car's heading (negative: behind), pulled
/// back toward the car in 6 px steps until it lands on floor.
fn place(w: *World, i: usize, kind: world.DropKind, dist: i32) *world.Drop {
    const c = &w.cars[i];
    const hx = fixed.cos(c.heading);
    const hy = fixed.sin(c.heading);
    var d = dist;
    while (true) {
        const x = (c.x +% hx * d) & world_mask;
        const y = (c.y +% hy * d) & world_mask;
        const back = if (dist < 0) d >= -tuning.drop_behind else d <= tuning.drop_behind;
        if (floor_ok(w, x, y) or back) {
            const slot = weapons.drop_slot(w);
            slot.* = .{ .x = x, .y = y, .kind = kind, .owner = @intCast(i), .dir = @intCast(c.heading >> 8) };
            return slot;
        }
        d += if (dist < 0) 6 else -6;
    }
}

/// Use car `i`'s held pickup (SPEC 6.3); `back` is Down+B.
pub fn use(w: *World, i: usize, back: bool) void {
    const c = &w.cars[i];
    const p = c.pickup;
    c.pickup = .none;
    const me: u8 = @intCast(i);
    switch (p) {
        .none, .prompt_injection => emit_at(w, .use, me, @backingInt(p), no_car, c),
        .prefetch => {
            // An instant kick along the heading, then the raised top speed.
            c.prefetch = tuning.prefetch_ticks;
            c.vx += fixed.mul(fixed.cos(c.heading), tuning.prefetch_kick);
            c.vy += fixed.mul(fixed.sin(c.heading), tuning.prefetch_kick);
            emit_at(w, .use, me, @backingInt(p), no_car, c);
        },
        .duck => {
            c.duck = tuning.duck_ticks;
            emit_at(w, .use, me, @backingInt(p), no_car, c);
        },
        .hot_patch => {
            c.patch = tuning.patch_ticks;
            c.bit_flip = 0;
            unchain(w, i);
            emit_at(w, .use, me, @backingInt(p), no_car, c);
        },
        .honeypot, .spaghetti, .fork_bomb => {
            const kind: world.DropKind = switch (p) {
                .honeypot => .honeypot,
                .spaghetti => .spaghetti,
                else => .fork,
            };
            const fwd = !back and p != .fork_bomb;
            const d = place(w, i, kind, if (fwd) tuning.throw_dist else -tuning.drop_behind);
            weapons.emit(w, .use, me, @backingInt(p), no_car, d.x, d.y);
        },
        .bit_flip => {
            const t = ahead(w, i, tuning.ahead_range, true, no_car);
            emit_use_at(w, me, p, t);
            if (t != no_car) {
                const o = &w.cars[t];
                if (o.duck > 0) {
                    pop_duck(w, me, t);
                } else {
                    o.bit_flip = tuning.bit_flip_ticks;
                    effect(w, me, t, p);
                }
            }
        },
        .deadlock => {
            const a = ahead(w, i, tuning.ahead_range, true, no_car);
            const b = if (a == no_car) no_car else ahead(w, i, tuning.ahead_range, true, a);
            emit_use_at(w, me, p, a);
            if (a != no_car) {
                chain(w, a, b);
                effect(w, me, a, p);
            }
            if (b != no_car) {
                chain(w, b, a);
                effect(w, me, b, p);
            }
        },
        .ddos => {
            const t = ahead(w, i, std.math.maxInt(i32), true, no_car);
            emit_use_at(w, me, p, t);
            if (t != no_car) {
                for (&w.drones, 0..) |*d, k| d.* = .{
                    .x = c.x,
                    .y = c.y,
                    .state = .flying,
                    .owner = me,
                    .target = t,
                    .ttl = tuning.ddos_ticks,
                    .angle = @intCast(k * (256 / world.drone_count)),
                };
            }
        },
        .heisenbug => {
            c.heisen = tuning.heisen_ticks;
            // Unobservable at once: locks and homing let go.
            for (&w.cars) |*o| {
                if (o.lock == i) o.lock = no_car;
                if (o.aim == i) {
                    o.aim = no_car;
                    o.aim_ticks = 0;
                }
            }
            for (&w.projs) |*q| {
                if (q.kind == .phish and q.target == i) q.target = no_car;
            }
            for (&w.drones) |*d| {
                if (d.target == i) d.state = .none;
            }
            emit_at(w, .use, me, @backingInt(p), no_car, c);
        },
        .race_condition => {
            const t = ahead(w, i, tuning.race_range, true, no_car);
            emit_use_at(w, me, p, t);
            if (t != no_car) {
                const o = &w.cars[t];
                c.swap_with = t;
                c.swap_ticks = tuning.race_ticks;
                o.swap_with = me;
                o.swap_ticks = tuning.race_ticks;
            }
        },
        .kernel_panic => {
            // The car in 1st, or 2nd when the user is 1st: the best-ranked
            // racing car other than the user.
            var t: u8 = no_car;
            for (&w.cars, 0..) |*o, j| {
                if (j == i or !racing(w, o)) continue;
                if (t == no_car or o.rank < w.cars[t].rank) t = @intCast(j);
            }
            emit_use_at(w, me, p, t);
            if (t != no_car) {
                const back_run = sim.progress_px(w, &w.cars[t]) < sim.progress_px(w, c);
                const slot = weapons.proj_slot(w);
                slot.* = .{
                    .x = c.x,
                    .y = c.y,
                    .kind = .panic,
                    .owner = me,
                    .target = t,
                    .seg = if (back_run) c.progress else c.progress +% 1,
                    .ttl = @intFromBool(back_run),
                };
            }
        },
        .captcha => {
            emit_at(w, .use, me, @backingInt(p), no_car, c);
            for (&w.cars, 0..) |*o, j| {
                if (j == i or !racing(w, o) or o.sudo > 0) continue;
                start_captcha(w, j);
            }
        },
        .sudo => {
            c.sudo = tuning.sudo_ticks;
            emit_at(w, .use, me, @backingInt(p), no_car, c);
        },
        .zero_day => {
            // Through armor, RUBBER DUCK, HEISENBUG and root.
            const t = ahead(w, i, std.math.maxInt(i32), false, no_car);
            emit_use_at(w, me, p, t);
            if (t != no_car) {
                const o = &w.cars[t];
                effect(w, me, t, p);
                o.last_hit_by = me;
                o.last_hit_ticks = 0;
                // A weapon hit for GARBAGE COLLECTION's tag.
                gc_mode.on_hit(w, me, t);
                sim.wreck(w, t, .zero_day);
            }
        },
    }
}

fn emit_use_at(w: *World, me: u8, p: Pickup, t: u8) void {
    const at = if (t != no_car) &w.cars[t] else &w.cars[me];
    emit_at(w, .use, me, @backingInt(p), t, at);
}

fn pop_duck(w: *World, src: u8, j: usize) void {
    w.cars[j].duck = 0;
    effect(w, src, j, .duck);
}

/// Does car `j`'s RUBBER DUCK take a hit from a shot or beam whose source
/// is at (sx, sy) Q16 (`homing`: a SPEAR PHISH, which the duck always
/// draws)? The first hit from behind pops the duck instead of hurting.
pub fn duck_takes(w: *World, src: u8, j: usize, sx: i32, sy: i32, homing: bool) bool {
    const o = &w.cars[j];
    if (o.duck == 0) return false;
    if (!homing) {
        const along = dpx(o.x, sx) * fixed.cos(o.heading) + dpx(o.y, sy) * fixed.sin(o.heading);
        if (along >= 0) return false;
    }
    pop_duck(w, src, j);
    return true;
}

/// Chain car `j` to car `to` (`no_car`: the nearest wall) for DEADLOCK.
fn chain(w: *World, j: u8, to: u8) void {
    unchain(w, j);
    const o = &w.cars[j];
    o.chain = to;
    o.chain_ticks = tuning.deadlock_ticks;
}

/// Release car `i`'s chain, and its partner's end of it.
pub fn unchain(w: *World, i: usize) void {
    const c = &w.cars[i];
    const p = c.chain;
    c.chain = no_car;
    c.chain_ticks = 0;
    if (p != no_car) {
        const o = &w.cars[p % world.car_count];
        if (o.chain == i) {
            o.chain = no_car;
            o.chain_ticks = 0;
        }
    }
}

/// A chained pair touched (sim's contact): both go free.
pub fn touched(w: *World, a: usize, b: usize) void {
    if (w.cars[a].chain == b) unchain(w, a);
}

fn start_captcha(w: *World, j: usize) void {
    const o = &w.cars[j];
    o.captcha = if (o.human < 2) tuning.captcha_human else ai.crew_of(o).captcha_solve;
    o.captcha_cursor = 0;
    o.captcha_done = 0;
    // `captcha_lights` distinct cells of the nine.
    var lit: u16 = 0;
    var n: u32 = 0;
    while (n < tuning.captcha_lights) {
        const bit = @as(u16, 1) << @intCast(weapons.rand(w) % 9);
        if (lit & bit != 0) continue;
        lit |= bit;
        n += 1;
    }
    o.captcha_lit = lit;
}

fn end_captcha(c: *Car) void {
    c.captcha = 0;
    c.captcha_cursor = 0;
    c.captcha_lit = 0;
    c.captcha_done = 0;
}

// --- Hits by pickups -----------------------------------------------------------------------

/// The KERNEL PANIC packet reaches its target: 40 damage and 90 ticks
/// frozen, unless root.
fn panic_hit(w: *World, owner: u8, j: usize) void {
    const o = &w.cars[j];
    effect(w, owner, j, .kernel_panic);
    if (o.sudo > 0) return;
    sim.damage(w, j, owner, tuning.panic_dmg);
    if (o.wreck != .none) return;
    o.frozen = tuning.panic_freeze;
    o.frozen_by = .panic;
    o.vx = 0;
    o.vy = 0;
}

/// Can a pickup drop touch car `o` this tick? Like the weapons' drops, plus
/// HEISENBUG (passes through drops).
pub fn drop_touch(o: *const Car) bool {
    return o.heisen == 0;
}

/// A car touches a pickup drop `d` (the weapons' drop loop found the
/// contact): the drop is used up. FORK BOMB 15 and a small blast; HONEYPOT
/// 30 and a spin; SPAGHETTI tangles. A root car destroys it untriggered.
pub fn hit_drop(w: *World, d: *world.Drop, j: usize) void {
    const o = &w.cars[j];
    const drop = d.*;
    d.* = .{};
    if (o.sudo > 0) {
        weapons.emit(w, .explode, no_car, 0, 0, drop.x, drop.y);
        return;
    }
    switch (drop.kind) {
        .fork => {
            weapons.emit(w, .explode, @intCast(j), tuning.fork_blast, 0, drop.x, drop.y);
            sim.damage(w, j, drop.owner, tuning.fork_dmg);
        },
        .honeypot => {
            effect(w, drop.owner, j, .honeypot);
            o.spin = tuning.spin_ticks;
            sim.damage(w, j, drop.owner, tuning.honeypot_dmg);
        },
        .spaghetti => {
            effect(w, drop.owner, j, .spaghetti);
            o.tangle = tuning.tangle_ticks;
            o.strand = tuning.strand_ticks;
        },
        else => {},
    }
}

// --- The KERNEL PANIC packet ----------------------------------------------------------------

/// Move toward (tx, ty) Q16 by `spd` (Q16); true when it got there.
fn step_toward(x: *i32, y: *i32, vx: *i16, vy: *i16, tx: i32, ty: i32, spd: i32) bool {
    const dx = weapons.dq(x.*, tx);
    const dy = weapons.dq(y.*, ty);
    const dx4: i64 = dx >> 12;
    const dy4: i64 = dy >> 12;
    const dist4: i64 = fixed.isqrt(@intCast(dx4 * dx4 + dy4 * dy4));
    if (dist4 * 4096 <= spd) {
        x.* = tx & world_mask;
        y.* = ty & world_mask;
        return true;
    }
    const sx: i32 = @intCast(@divTrunc(dx4 * spd, dist4));
    const sy: i32 = @intCast(@divTrunc(dy4 * spd, dist4));
    x.* = (x.* +% sx) & world_mask;
    y.* = (y.* +% sy) & world_mask;
    vx.* = @intCast(sx >> 8);
    vy.* = @intCast(sy >> 8);
    return false;
}

/// One tick of a KERNEL PANIC packet (SPEC 6.3): along the centerline at
/// twice the top speed (backward when its target was behind the user,
/// `ttl == 1`), homing onto the target once within `panic_home` px or past
/// its sample. It waits behind a target it cannot touch (airborne,
/// respawning, HEISENBUG) and fizzles when the target leaves the race.
pub fn update_packet(w: *World, p: *world.Projectile) void {
    const ti = p.target % world.car_count;
    const t = &w.cars[ti];
    if (!racing(w, t)) {
        weapons.emit(w, .explode, no_car, 0, 0, p.x, p.y);
        p.* = .{};
        return;
    }
    const hittable = t.hop == 0 and t.immune == 0 and t.heisen == 0;
    const back = p.ttl == 1;
    // How far the target is ahead of the packet along its run, in samples;
    // "reached" when the packet is on it or just past it. (An i8 of the
    // difference read a target more than half a lap ahead as passed, and
    // the packet parked on the line until the target lapped round to it.)
    const ahead_d: u8 = if (back) p.seg -% t.progress else t.progress -% p.seg;
    const reached = ahead_d == 0 or @as(u16, ahead_d) + tuning.panic_passed >= 256;
    const near = blk: {
        const dx = dpx(p.x, t.x);
        const dy = dpx(p.y, t.y);
        break :blk dx * dx + dy * dy <= tuning.panic_home * tuning.panic_home;
    };
    if (hittable and (near or reached)) {
        if (step_toward(&p.x, &p.y, &p.vx, &p.vy, t.x, t.y, tuning.panic_speed)) {
            const owner = p.owner;
            p.* = .{};
            panic_hit(w, owner, ti);
        }
        return;
    }
    if (reached) return; // wait for the target to be touchable
    const s = sim.track_of(w).sample(p.seg);
    if (step_toward(&p.x, &p.y, &p.vx, &p.vy, @as(i32, s.x) << fixed.Q, @as(i32, s.y) << fixed.Q, tuning.panic_speed)) {
        p.seg = if (back) p.seg -% 1 else p.seg +% 1;
    }
}

// --- DDOS drones -------------------------------------------------------------------------------

/// Does a shot moving from (ox, oy) by its velocity this tick pass through
/// a drone? The first such drone is shot down (1 HP, a spark).
pub fn shoot_drone(w: *World, p: *const world.Projectile, ox: i32, oy: i32) bool {
    const r: i64 = (tuning.shot_radius + tuning.drone_radius) << 8;
    const mx: i64 = p.vx;
    const my: i64 = p.vy;
    const mm = mx * mx + my * my;
    for (&w.drones) |*d| {
        if (d.state == .none) continue;
        const d0x: i64 = weapons.dq(d.x, ox) >> 8;
        const d0y: i64 = weapons.dq(d.y, oy) >> 8;
        if (@abs(d0x) > (32 << 8) or @abs(d0y) > (32 << 8)) continue;
        var t: i64 = -(d0x * mx + d0y * my);
        t = std.math.clamp(t, 0, mm);
        const cx = d0x + (if (mm > 0) @divTrunc(mx * t, mm) else 0);
        const cy = d0y + (if (mm > 0) @divTrunc(my * t, mm) else 0);
        if (cx * cx + cy * cy > r * r) continue;
        d.state = .none;
        weapons.emit(w, .explode, no_car, 0, 0, d.x, d.y);
        return true;
    }
    return false;
}

fn update_drones(w: *World) void {
    for (&w.drones, 0..) |*d, k| {
        if (d.state == .none) continue;
        const ti = d.target % world.car_count;
        const t = &w.cars[ti];
        if (!racing(w, t) or t.heisen > 0 or t.sudo > 0) {
            d.state = .none;
            continue;
        }
        d.angle +%= tuning.drone_spin;
        const a: fixed.Turn = @as(u16, d.angle) << 8;
        const ox = t.x +% fixed.cos(a) * tuning.drone_orbit;
        const oy = t.y +% fixed.sin(a) * tuning.drone_orbit;
        switch (d.state) {
            .none => {},
            .flying => {
                var vx: i16 = 0;
                var vy: i16 = 0;
                if (!step_toward(&d.x, &d.y, &vx, &vy, ox, oy, tuning.drone_speed)) continue;
                // Arrived. The RUBBER DUCK draws the swarm and pops; else the
                // first drone in announces the swarm.
                if (t.duck > 0) {
                    pop_duck(w, d.owner, ti);
                    for (&w.drones) |*e| {
                        if (e.target == ti) e.state = .none;
                    }
                    continue;
                }
                var first = true;
                for (&w.drones, 0..) |*e, m| {
                    if (m != k and e.state == .orbit and e.target == ti) first = false;
                }
                d.state = .orbit;
                if (first) effect(w, d.owner, ti, .ddos);
            },
            .orbit => {
                d.x = ox & world_mask;
                d.y = oy & world_mask;
                d.ttl -|= 1;
                if (d.ttl % tuning.ddos_every == 0) sim.damage(w, ti, d.owner, tuning.ddos_dmg);
                if (d.ttl == 0) d.state = .none;
            },
        }
    }
}

// --- FORK BOMB --------------------------------------------------------------------------------

/// FORK BOMB drift: a child moves across the track for `fork_drift` ticks
/// after its fork, `fork_spread >> (generation - 1)` px in all.
pub fn drift_fork(w: *const World, d: *world.Drop) void {
    const gen: u8 = d.size & 3;
    if (gen == 0) return;
    const since = @as(i32, d.age) - @as(i32, gen) * tuning.fork_every;
    if (since < 0 or since >= tuning.fork_drift) return;
    const a: fixed.Turn = @as(u16, d.dir) << 8;
    const side: i32 = if (d.size & 4 != 0) 1 else -1;
    const spd = @divTrunc((tuning.fork_spread << fixed.Q) >> @intCast(gen - 1), tuning.fork_drift) * side;
    const nx = (d.x +% fixed.mul(-fixed.sin(a), spd)) & world_mask;
    const ny = (d.y +% fixed.mul(fixed.cos(a), spd)) & world_mask;
    if (floor_ok(w, nx, ny)) {
        d.x = nx;
        d.y = ny;
    }
}

/// Every `fork_every` ticks each `&` forks in two (up to generation 3: 8
/// bombs); the pair drift apart across the track.
fn fork_pass(w: *World) void {
    var forking: [world.drop_count]u8 = undefined;
    var n: usize = 0;
    for (&w.drops, 0..) |*d, k| {
        if (d.kind != .fork or d.age == 0 or d.age % tuning.fork_every != 0) continue;
        if (d.size & 3 >= tuning.fork_gens or d.age / tuning.fork_every != (d.size & 3) + 1) continue;
        forking[n] = @intCast(k);
        n += 1;
    }
    for (forking[0..n]) |k| {
        const d = &w.drops[k];
        if (d.kind != .fork) continue; // reused by an earlier child
        const gen = (d.size & 3) + 1;
        d.size = gen;
        const child = d.*;
        const slot = weapons.drop_slot(w);
        slot.* = child;
        slot.size = gen | 4;
    }
}

// --- Per tick ------------------------------------------------------------------------------------

/// Pickups for one tick, after the weapons: forks, crates (contacts and
/// respawns), drones, every car's timers, RACE CONDITION swaps, DEADLOCK
/// pulls.
pub fn update(w: *World) void {
    fork_pass(w);
    update_crates(w);
    update_drones(w);
    for (0..world.car_count) |i| update_car(w, i);
}

fn update_crates(w: *World) void {
    for (&w.crates) |*t| t.* -|= 1;
    if (!w.combat or w.phase != .racing) return;
    const n = @min(track.crate_n, world.crate_max);
    for (&w.cars, 0..) |*c, i| {
        if (!racing(w, c) or c.hop != 0) continue;
        for (track.crate_spots[0..n], 0..) |s, k| {
            if (w.crates[k] != 0) continue;
            const dx = wrap_px((c.x >> fixed.Q) - @as(i32, s.x));
            const dy = wrap_px((c.y >> fixed.Q) - @as(i32, s.y));
            if (dx * dx + dy * dy > tuning.crate_touch * tuning.crate_touch) continue;
            // A car holding a pickup drives through (the crate stays).
            if (c.pickup != .none) break;
            w.crates[k] = tuning.crate_respawn;
            c.pickup = roll_pickup(w, c.rank, !c.zero_day_used);
            if (c.pickup == .zero_day) c.zero_day_used = true;
            c.roll_ticks = tuning.roll_ticks;
            weapons.emit(w, .roll, @intCast(i), @backingInt(c.pickup), @intCast(k), @as(i32, s.x) << fixed.Q, @as(i32, s.y) << fixed.Q);
            break;
        }
    }
}

fn update_car(w: *World, i: usize) void {
    const c = &w.cars[i];
    c.roll_ticks -|= 1;
    if (c.wreck != .none) return;
    c.prefetch -|= 1;
    c.spin -|= 1;
    c.bit_flip -|= 1;
    c.heisen -|= 1;
    c.duck -|= 1;
    c.sudo -|= 1;
    if (c.frozen > 0) {
        c.frozen -= 1;
        if (c.frozen == 0) c.frozen_by = .none;
    }
    if (c.patch > 0) {
        c.patch -= 1;
        if (c.patch % tuning.patch_every == 0) c.armor = @min(c.armor_max, c.armor +| tuning.patch_step);
    }
    if (c.tangle > 0) c.tangle -= 1 else c.strand -|= 1;
    if (c.captcha > 0) {
        c.captcha -= 1;
        if (c.captcha == 0) {
            end_captcha(c);
        } else if (c.captcha % tuning.captcha_step == 0) c.captcha_cursor = (c.captcha_cursor + 1) % 9;
    }
    if (c.chain_ticks > 0) {
        c.chain_ticks -= 1;
        if (c.chain_ticks == 0) {
            unchain(w, i);
        } else if (c.chain != no_car) {
            // The chain pulls the pair together.
            const o = &w.cars[c.chain % world.car_count];
            const dx = dpx(c.x, o.x);
            const dy = dpx(c.y, o.y);
            const dist: i32 = @intCast(fixed.isqrt(@intCast(dx * dx + dy * dy)));
            if (dist > 0) {
                c.vx += @divTrunc(dx * tuning.chain_pull, dist);
                c.vy += @divTrunc(dy * tuning.chain_pull, dist);
            }
        }
    }
    if (c.swap_ticks > 0) {
        c.swap_ticks -= 1;
        if (c.swap_ticks == 0) {
            const j = c.swap_with;
            c.swap_with = no_car;
            if (j != no_car and j > i) {
                const o = &w.cars[j];
                if (o.swap_with == i and racing(w, o)) swap(w, i, j);
                o.swap_with = no_car;
                o.swap_ticks = 0;
            }
        }
    }
}

/// RACE CONDITION: the two cars trade places (position, velocity, heading,
/// air time and their place in the race: sample, sectors, laps), so the
/// rank changes hands and no lap is gained or lost overall.
fn swap(w: *World, i: usize, j: usize) void {
    const a = &w.cars[i];
    const b = &w.cars[j];
    const la = a.lap;
    const lb = b.lap;
    inline for (.{ "x", "y", "vx", "vy", "heading", "hop", "progress", "sectors", "lap" }) |f| {
        std.mem.swap(@TypeOf(@field(a.*, f)), &@field(a.*, f), &@field(b.*, f));
    }
    for ([2]*Car{ a, b }, [2]u8{ la, lb }) |c, old| {
        if (c.lap > old and c.lap == w.laps - 1 and w.mode != .gc) {
            c.msg = .final_lap;
            c.msg_ticks = tuning.message_ticks;
        }
    }
    weapons.emit(w, .swap, @intCast(i), @intCast(j), 0, a.x, a.y);
}

/// A wrecked car loses every status (SPEC 5.3 respawns it clean): the held
/// pickup and the roulette stay, as ammo does. A chain or a RACE CONDITION
/// it was part of ends for the other car too; drones on it disperse.
pub fn on_wreck(w: *World, i: usize) void {
    const c = &w.cars[i];
    unchain(w, i);
    if (c.swap_with != no_car) {
        const o = &w.cars[c.swap_with % world.car_count];
        if (o.swap_with == i) {
            o.swap_with = no_car;
            o.swap_ticks = 0;
        }
    }
    for (&w.drones) |*d| {
        if (d.target == i) d.state = .none;
    }
    c.prefetch = 0;
    c.duck = 0;
    c.patch = 0;
    c.tangle = 0;
    c.strand = 0;
    c.spin = 0;
    c.bit_flip = 0;
    c.heisen = 0;
    c.frozen = 0;
    c.frozen_by = .none;
    end_captcha(c);
    c.sudo = 0;
    c.swap_with = no_car;
    c.swap_ticks = 0;
}

/// Live drones (tests, the soak).
pub fn drones_live(w: *const World) usize {
    var n: usize = 0;
    for (&w.drones) |*d| n += @intFromBool(d.state != .none);
    return n;
}
