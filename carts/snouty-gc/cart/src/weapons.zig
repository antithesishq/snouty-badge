//! Weapons (SPEC 6.1, 6.2): firing from the race byte, the projectile and
//! drop pools, hit resolution, the SPEAR PHISH lock. New for Snouty GC.
//!
//! Part of `sim.simulate`, so pure in the World: no cart API, no clock, no
//! floats, no globals; the world PRNG (`rand`) is the only randomness.
//! Pools never grow: a new shot takes a free slot or the one closest to
//! expiry, a new drop a free slot or the oldest.
const std = @import("std");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const sim = @import("sim.zig");
const pickups = @import("pickups.zig");

const World = world.World;
const Car = world.Car;
const Input = world.Input;
const Projectile = world.Projectile;
const Drop = world.Drop;
const no_car = world.no_car;

const world_mask: i32 = (1024 << fixed.Q) - 1;
const half_q: i32 = 512 << fixed.Q;

/// `b - a` for wrapping Q16 coordinates, Q16 (-512..512 px).
pub inline fn dq(a: i32, b: i32) i32 {
    return ((b -% a +% half_q) & world_mask) - half_q;
}

/// `b - a` in whole world px.
inline fn dpx(a: i32, b: i32) i32 {
    return dq(a, b) >> fixed.Q;
}

/// The next value of the world PRNG.
pub fn rand(w: *World) u32 {
    w.rng = sim.step_rng(w.rng);
    return w.rng;
}

/// Append to the event ring (render reads it with its own cursor).
pub fn emit(w: *World, kind: world.EventKind, a: u8, b: u8, c: u8, x: i32, y: i32) void {
    w.events[w.event_seq % world.event_count] = .{
        .seq = w.event_seq,
        .kind = kind,
        .a = a,
        .b = b,
        .c = c,
        .x = @intCast((x >> fixed.Q) & 1023),
        .y = @intCast((y >> fixed.Q) & 1023),
    };
    w.event_seq +%= 1;
}

/// A full lap's ammo for the car's loadout (start line, reset): front L2+
/// +25%, rear L2+ one more (SPEC 9.2).
pub fn refill(c: *Car) void {
    const f = tuning.front_ammo[@backingInt(c.front)];
    c.ammo_front = if (c.front_level >= 2) up25(f) else f;
    c.ammo_rear = tuning.rear_ammo[@backingInt(c.rear)] + (if (c.rear_level >= 2) tuning.rear_level_ammo else 0);
}

/// x 1.25, rounded up (the garage's +25%).
pub fn up25(x: u8) u8 {
    return x +| (x + 3) / 4;
}

/// A front weapon's damage `base` from car `owner`: L3 deals +25%.
fn front_dmg(w: *const World, owner: u8, base: u8) u8 {
    return if (owner < world.car_count and w.cars[owner].front_level >= 3) up25(base) else base;
}

/// A rear weapon's effect `base` (damage, ticks, px) from car `owner`: L3 +25%.
fn rear_fx(w: *const World, owner: u8, base: u8) u8 {
    return if (owner < world.car_count and w.cars[owner].rear_level >= 3) up25(base) else base;
}

/// May this car fire this tick?
fn armed(w: *const World, c: *const Car) bool {
    return w.combat and w.phase == .racing and c.active and c.wreck == .none and !c.finished;
}

/// A car shots and drops can touch: on the ground, in the race, not
/// wrecked, not immune (respawn) and not finished.
fn touchable(c: *const Car) bool {
    return c.active and c.wreck == .none and c.hop == 0 and c.immune == 0 and !c.finished;
}

/// A car a lock or the AI may aim at.
pub fn targetable(c: *const Car) bool {
    return c.active and c.wreck == .none and !c.finished;
}

inline fn turn_of(d: i32) fixed.Turn {
    return @bitCast(@as(i16, @intCast(d)));
}

// --- Firing ------------------------------------------------------------------------

/// The car's weapons for this tick's input (SPEC 5.1): A alone is the front
/// weapon (held: auto-fire on its cooldown, or the LANCE charge), Down+A
/// is the rear weapon on its press edge. Called for every car every racing
/// tick, after its move; keeps the press edges current even when it may
/// not fire.
pub fn fire(w: *World, i: usize, in: Input) void {
    const c = &w.cars[i];
    const front_held = in.a and !in.down;
    const rear_chord = in.a and in.down;
    const a_was = c.a_was;
    const rear_was = c.rear_was;
    c.a_was = front_held;
    c.rear_was = rear_chord;
    if (c.fire_cd > 0) c.fire_cd -= 1;
    if (c.rear_cd > 0) c.rear_cd -= 1;
    // Frozen (KERNEL PANIC) and CAPTCHA cars do not fire (A plays the
    // CAPTCHA board).
    if (!armed(w, c) or c.frozen > 0 or c.captcha > 0) {
        c.charge = 0;
        return;
    }
    if (rear_chord and !rear_was and c.rear_cd == 0 and c.ammo_rear > 0) {
        c.ammo_rear -= 1;
        c.rear_cd = tuning.rear_cd;
        drop_rear(w, i);
    }
    switch (c.front) {
        .lance => {
            if (front_held) {
                if (c.charge > 0 or (c.ammo_front > 0 and c.fire_cd == 0)) c.charge = @min(c.charge + 1, tuning.lance_charge);
            } else {
                // Released: a full charge fires, an early one fizzles free.
                if (a_was and c.charge >= tuning.lance_charge and c.ammo_front > 0) {
                    c.ammo_front -= 1;
                    c.fire_cd = tuning.lance_cd;
                    fire_lance(w, i);
                }
                c.charge = 0;
            }
        },
        else => if (front_held and c.fire_cd == 0 and c.ammo_front > 0) {
            c.ammo_front -= 1;
            shoot(w, i);
        },
    }
}

/// A free projectile slot, or the one closest to expiry (a KERNEL PANIC
/// packet, which has no expiry, last).
pub fn proj_slot(w: *World) *Projectile {
    var best: usize = 0;
    var best_ttl: u16 = 0xFFFF;
    for (&w.projs, 0..) |*p, k| {
        if (p.kind == .none) return p;
        const ttl: u16 = if (p.kind == .panic) 0x100 else p.ttl;
        if (ttl < best_ttl) {
            best = k;
            best_ttl = ttl;
        }
    }
    return &w.projs[best];
}

/// A free drop slot, or the oldest drop.
pub fn drop_slot(w: *World) *Drop {
    var best: usize = 0;
    for (&w.drops, 0..) |*d, k| {
        if (d.kind == .none) return d;
        if (d.age > w.drops[best].age) best = k;
    }
    return &w.drops[best];
}

/// Spawn a shot at (x, y) along turn `a` at `spd` (Q16) plus the car's
/// velocity (SPEC 6: shots inherit it).
fn spawn(w: *World, i: usize, kind: world.ProjKind, x: i32, y: i32, a: fixed.Turn, spd: i32, ttl: u8, target: u8) void {
    const c = &w.cars[i];
    const vx = c.vx + fixed.mul(fixed.cos(a), spd);
    const vy = c.vy + fixed.mul(fixed.sin(a), spd);
    proj_slot(w).* = .{
        .x = x & world_mask,
        .y = y & world_mask,
        .vx = @intCast(vx >> 8),
        .vy = @intCast(vy >> 8),
        .kind = kind,
        .owner = @intCast(i),
        .ttl = ttl,
        .target = target,
    };
}

fn shoot(w: *World, i: usize) void {
    const c = &w.cars[i];
    const hx = fixed.cos(c.heading);
    const hy = fixed.sin(c.heading);
    // The muzzle is the car's nose.
    const mx = c.x +% hx * tuning.half_len;
    const my = c.y +% hy * tuning.half_len;
    switch (c.front) {
        .ping => {
            c.fire_cd = tuning.ping_cd;
            for ([2]i32{ -tuning.ping_gap, tuning.ping_gap }) |side| {
                spawn(w, i, .ping, mx +% -hy * side, my +% hx * side, c.heading, tuning.ping_speed, tuning.ping_ttl, no_car);
            }
        },
        .broadcast => {
            c.fire_cd = tuning.broadcast_cd;
            const n: i32 = tuning.broadcast_pellets;
            var k: i32 = 0;
            while (k < n) : (k += 1) {
                const a = c.heading +% turn_of((2 * k - (n - 1)) * @divTrunc(tuning.broadcast_step, 2));
                spawn(w, i, .broadcast, mx, my, a, tuning.broadcast_speed, tuning.broadcast_ttl, no_car);
            }
        },
        .phish => {
            c.fire_cd = tuning.phish_cd;
            spawn(w, i, .phish, mx, my, c.heading, tuning.phish_speed, tuning.phish_ttl, c.lock);
        },
        .lance => unreachable,
    }
}

/// Along / lateral offsets (px) of `o` in the frame of `c`'s heading.
pub const Rel = struct { along: i32, lat: i32, d2: i32 };
pub fn rel(c: *const Car, o: *const Car) Rel {
    const dx = dpx(c.x, o.x);
    const dy = dpx(c.y, o.y);
    const hx = fixed.cos(c.heading);
    const hy = fixed.sin(c.heading);
    return .{
        .along = (dx * hx + dy * hy) >> fixed.Q,
        .lat = (dx * -hy + dy * hx) >> fixed.Q,
        .d2 = dx * dx + dy * dy,
    };
}

/// FIBER LANCE: a hitscan beam along the heading; the first car (or hulk)
/// in the 4-degree line within range takes it, a wall stops it.
fn fire_lance(w: *World, i: usize) void {
    const c = &w.cars[i];
    var best: u8 = no_car;
    var best_along: i32 = tuning.lance_range;
    for (&w.cars, 0..) |*o, j| {
        if (j == i or !o.active or o.hop != 0) continue;
        if (o.wreck != .none and !sim.is_hulk(o)) continue;
        const r = rel(c, o);
        if (r.along <= 0 or r.along > best_along) continue;
        const half = tuning.car_radius + ((r.along * tuning.lance_spread_q8) >> 8);
        if (@abs(r.lat) > half) continue;
        best = @intCast(j);
        best_along = r.along;
    }
    const hx = fixed.cos(c.heading);
    const hy = fixed.sin(c.heading);
    const t = sim.track_of(w);
    var len: i32 = tuning.lance_step;
    while (len < best_along) : (len += tuning.lance_step) {
        if (t.attr_at((c.x >> fixed.Q) + ((hx * len) >> fixed.Q), (c.y >> fixed.Q) + ((hy * len) >> fixed.Q)) == .wall) {
            best = no_car;
            break;
        }
    }
    len = @min(len, best_along);
    var hit: u8 = no_car;
    if (best != no_car and w.cars[best].wreck == .none) hit = best;
    emit(w, .lance, @intCast(i), hit, @intCast(@min(len, 255)), c.x +% hx * len, c.y +% hy * len);
    if (hit != no_car and !pickups.duck_takes(w, @intCast(i), hit, c.x, c.y, false)) sim.damage(w, hit, @intCast(i), front_dmg(w, @intCast(i), tuning.lance_dmg));
}

/// SPEAR PHISH lock (SPEC 6.1): the nearest targetable car in the 24-degree
/// cone within 400 px, or none. Updated at the end of every tick, so the
/// reticle drawn is the lock the next A fires at.
pub fn update_lock(w: *World, i: usize) void {
    const c = &w.cars[i];
    c.lock = no_car;
    if (c.front != .phish or !armed(w, c)) return;
    var best_d2: i32 = tuning.phish_range * tuning.phish_range + 1;
    for (&w.cars, 0..) |*o, j| {
        if (j == i or !targetable(o) or o.heisen > 0) continue;
        const r = rel(c, o);
        if (r.along <= 0 or r.d2 >= best_d2) continue;
        if (@abs(r.lat) * 256 > r.along * tuning.phish_spread_q8) continue;
        best_d2 = r.d2;
        c.lock = @intCast(j);
    }
}

// --- Drops -----------------------------------------------------------------------

fn drop_rear(w: *World, i: usize) void {
    const c = &w.cars[i];
    const hx = fixed.cos(c.heading);
    const hy = fixed.sin(c.heading);
    const bx = c.x -% hx * tuning.drop_behind;
    const by = c.y -% hy * tuning.drop_behind;
    const owner: u8 = @intCast(i);
    switch (c.rear) {
        .leak => drop_slot(w).* = .{ .x = bx & world_mask, .y = by & world_mask, .kind = .leak, .owner = owner, .size = tuning.leak_r0 },
        .bomb => drop_slot(w).* = .{ .x = bx & world_mask, .y = by & world_mask, .kind = .bomb, .owner = owner },
        .firewall => drop_slot(w).* = .{
            .x = (bx -% hx * tuning.firewall_depth) & world_mask,
            .y = (by -% hy * tuning.firewall_depth) & world_mask,
            .kind = .firewall,
            .owner = owner,
            .size = rear_fx(w, owner, tuning.firewall_half),
            .dir = @intCast(c.heading >> 8),
        },
        .rot => {
            var k: i32 = 0;
            while (k < tuning.rot_count) : (k += 1) {
                const lat = @divTrunc((2 * k - (tuning.rot_count - 1)) * tuning.rot_gap, 2);
                drop_slot(w).* = .{ .x = (bx +% -hy * lat) & world_mask, .y = (by +% hx * lat) & world_mask, .kind = .caltrop, .owner = owner };
            }
        },
    }
}

/// Can drop `d` touch car `j` (airborne cars skip drops, SPEC 3.3; a fresh
/// drop spares its owner)?
fn drop_touches(d: *const Drop, j: usize, o: *const Car) bool {
    if (!touchable(o) or !pickups.drop_touch(o)) return false;
    return !(j == d.owner and d.age < tuning.drop_owner_grace);
}

fn dist2_to(d: *const Drop, o: *const Car) i32 {
    const dx = dpx(d.x, o.x);
    const dy = dpx(d.y, o.y);
    return dx * dx + dy * dy;
}

/// LOGIC BOMB blast: every car on the ground within the blast takes the
/// damage and a push away from the bomb.
fn blast(w: *World, d: *const Drop) void {
    emit(w, .explode, no_car, @intCast(tuning.bomb_blast), 0, d.x, d.y);
    const r2 = tuning.bomb_blast * tuning.bomb_blast;
    for (&w.cars, 0..) |*o, j| {
        if (!touchable(o) or !pickups.drop_touch(o)) continue;
        const dx = dpx(d.x, o.x);
        const dy = dpx(d.y, o.y);
        const d2 = dx * dx + dy * dy;
        if (d2 > r2) continue;
        const dist: i32 = @intCast(fixed.isqrt(@intCast(d2)));
        if (dist > 0) {
            o.vx += @divTrunc(dx * tuning.bomb_push, dist);
            o.vy += @divTrunc(dy * tuning.bomb_push, dist);
        }
        sim.damage(w, j, d.owner, rear_fx(w, d.owner, tuning.bomb_dmg));
    }
}

/// A root (SUDO) car touched drop `d`: destroyed without triggering.
fn root_clears(w: *World, d: *Drop) void {
    emit(w, .explode, no_car, 0, 0, d.x, d.y);
    d.* = .{};
}

fn update_drops(w: *World) void {
    for (&w.cars) |*c| c.on_leak = false;
    for (&w.drops) |*d| {
        if (d.kind == .none) continue;
        d.age +|= 1;
        switch (d.kind) {
            .none => {},
            .leak => {
                if (d.age >= tuning.leak_life) {
                    d.* = .{};
                    continue;
                }
                const g: i32 = @min(d.age, tuning.leak_grow);
                const r1: i32 = rear_fx(w, d.owner, @intCast(tuning.leak_r1));
                d.size = @intCast(tuning.leak_r0 + @divTrunc((r1 - tuning.leak_r0) * g, tuning.leak_grow));
                const r2 = @as(i32, d.size) * d.size;
                for (&w.cars, 0..) |*o, j| {
                    if (!drop_touches(d, j, o) or dist2_to(d, o) > r2) continue;
                    if (o.sudo > 0) {
                        root_clears(w, d);
                        break;
                    }
                    o.on_leak = true;
                    const kick: i32 = @as(i32, @intCast(rand(w) % (2 * tuning.leak_yaw + 1))) - @as(i32, tuning.leak_yaw);
                    o.heading +%= turn_of(kick);
                }
            },
            .bomb => {
                if (d.age >= tuning.bomb_life) {
                    d.* = .{};
                    continue;
                }
                if (d.age < tuning.bomb_arm) continue;
                for (&w.cars, 0..) |*o, j| {
                    if (!drop_touches(d, j, o) or dist2_to(d, o) > tuning.bomb_trigger * tuning.bomb_trigger) continue;
                    if (o.sudo > 0) {
                        root_clears(w, d);
                        break;
                    }
                    const copy = d.*;
                    d.* = .{};
                    blast(w, &copy);
                    break;
                }
            },
            .caltrop => {
                if (d.age >= tuning.rot_life) {
                    d.* = .{};
                    continue;
                }
                for (&w.cars, 0..) |*o, j| {
                    if (!drop_touches(d, j, o) or dist2_to(d, o) > tuning.rot_hit * tuning.rot_hit) continue;
                    if (o.sudo > 0) {
                        root_clears(w, d);
                        break;
                    }
                    const owner = d.owner;
                    o.rot_ticks = rear_fx(w, owner, tuning.rot_ticks);
                    d.* = .{};
                    sim.damage(w, j, owner, rear_fx(w, owner, tuning.rot_dmg));
                    break;
                }
            },
            .firewall => {
                if (d.age >= tuning.firewall_life) {
                    d.* = .{};
                    continue;
                }
                const a: fixed.Turn = @as(u16, d.dir) << 8;
                const hx = fixed.cos(a);
                const hy = fixed.sin(a);
                for (&w.cars, 0..) |*o, j| {
                    if (!drop_touches(d, j, o)) continue;
                    const dx = dpx(d.x, o.x);
                    const dy = dpx(d.y, o.y);
                    const along = (dx * hx + dy * hy) >> fixed.Q;
                    const lat = (dx * -hy + dy * hx) >> fixed.Q;
                    if (@abs(along) > tuning.firewall_depth or @abs(lat) > @as(i32, d.size) + 4) continue;
                    if (o.sudo > 0) {
                        root_clears(w, d);
                        break;
                    }
                    sim.damage(w, j, d.owner, tuning.firewall_dmg);
                }
            },
            .fork, .honeypot, .spaghetti => {
                const life = if (d.kind == .fork) tuning.fork_life else tuning.pickup_drop_life;
                if (d.age >= life) {
                    d.* = .{};
                    continue;
                }
                if (d.kind == .fork) pickups.drift_fork(w, d);
                const r: i32 = switch (d.kind) {
                    .fork => tuning.fork_touch,
                    .honeypot => tuning.crate_touch,
                    else => tuning.spaghetti_touch,
                };
                for (&w.cars, 0..) |*o, j| {
                    if (!drop_touches(d, j, o) or dist2_to(d, o) > r * r) continue;
                    pickups.hit_drop(w, d, j);
                    break;
                }
            },
        }
    }
}

// --- Projectiles -------------------------------------------------------------------

/// SPEAR PHISH homing: turn the velocity toward the target by at most
/// `phish_turn` a tick (the sine table steps 256 turns).
fn home(w: *const World, p: *Projectile) void {
    const t = &w.cars[p.target % world.car_count];
    if (!targetable(t) or t.heisen > 0) {
        p.target = no_car;
        return;
    }
    // A RUBBER DUCK draws homing weapons (SPEC 6.3).
    const aim: pickups.Point = if (t.duck > 0) pickups.duck_pos(t) else .{ .x = t.x, .y = t.y };
    const want = fixed.atan2(dpx(p.y, aim.y), dpx(p.x, aim.x));
    const have = fixed.atan2(p.vy, p.vx);
    const d = std.math.clamp(fixed.turn_diff(have, want), -tuning.phish_turn, tuning.phish_turn);
    const cs = fixed.cos(turn_of(d));
    const sn = fixed.sin(turn_of(d));
    const vx: i32 = p.vx;
    const vy: i32 = p.vy;
    p.vx = @intCast((vx * cs - vy * sn + (1 << 15)) >> fixed.Q);
    p.vy = @intCast((vx * sn + vy * cs + (1 << 15)) >> fixed.Q);
}

/// The first car the shot's path this tick (from (ox, oy) along its
/// velocity) passes within the car radius of, or `no_car`. Immune,
/// airborne and finished cars let shots through; hulks stop them.
fn first_hit(w: *const World, p: *const Projectile, ox: i32, oy: i32) u8 {
    const r: i64 = (tuning.car_radius + tuning.shot_radius) << 8;
    const mx: i64 = p.vx;
    const my: i64 = p.vy;
    const mm = mx * mx + my * my;
    var best: u8 = no_car;
    var best_t: i64 = std.math.maxInt(i64);
    for (&w.cars, 0..) |*o, j| {
        if (j == p.owner) continue;
        if (!touchable(o) and !(sim.is_hulk(o) and o.hop == 0)) continue;
        const d0x: i64 = dq(o.x, ox) >> 8;
        const d0y: i64 = dq(o.y, oy) >> 8;
        if (@abs(d0x) > (64 << 8) or @abs(d0y) > (64 << 8)) continue;
        var t: i64 = -(d0x * mx + d0y * my);
        t = std.math.clamp(t, 0, mm);
        const cx = d0x + (if (mm > 0) @divTrunc(mx * t, mm) else 0);
        const cy = d0y + (if (mm > 0) @divTrunc(my * t, mm) else 0);
        if (cx * cx + cy * cy > r * r or t >= best_t) continue;
        best = @intCast(j);
        best_t = t;
    }
    return best;
}

fn update_projs(w: *World) void {
    const t = sim.track_of(w);
    for (&w.projs) |*p| {
        if (p.kind == .none) continue;
        if (p.kind == .panic) {
            pickups.update_packet(w, p);
            continue;
        }
        if (p.kind == .phish and p.target != no_car) home(w, p);
        const ox = p.x;
        const oy = p.y;
        if (pickups.shoot_drone(w, p, ox, oy)) {
            p.* = .{};
            continue;
        }
        p.x = (p.x +% (@as(i32, p.vx) << 8)) & world_mask;
        p.y = (p.y +% (@as(i32, p.vy) << 8)) & world_mask;
        const j = first_hit(w, p, ox, oy);
        if (j != no_car) {
            const o = &w.cars[j];
            const shot = p.*;
            p.* = .{};
            if (o.wreck != .none or o.sudo > 0) {
                // A hulk or a root car: the shot sparks on it.
                emit(w, .explode, no_car, 0, 0, shot.x, shot.y);
                continue;
            }
            if (pickups.duck_takes(w, shot.owner, j, ox, oy, shot.kind == .phish)) continue;
            switch (shot.kind) {
                .none => {},
                .ping => sim.damage(w, j, shot.owner, front_dmg(w, shot.owner, tuning.ping_dmg)),
                .broadcast => {
                    // Knock sideways, away from the pellet's side.
                    const hx = fixed.cos(o.heading);
                    const hy = fixed.sin(o.heading);
                    const side = @as(i32, shot.vx) * -hy + @as(i32, shot.vy) * hx;
                    const k: i32 = if (side >= 0) tuning.broadcast_knock else -tuning.broadcast_knock;
                    o.vx += fixed.mul(-hy, k);
                    o.vy += fixed.mul(hx, k);
                    sim.damage(w, j, shot.owner, front_dmg(w, shot.owner, tuning.broadcast_dmg));
                },
                .phish => {
                    emit(w, .explode, j, 12, 0, shot.x, shot.y);
                    sim.damage(w, j, shot.owner, front_dmg(w, shot.owner, tuning.phish_dmg));
                },
                .panic => unreachable,
            }
            continue;
        }
        if (t.attr_at(p.x >> fixed.Q, p.y >> fixed.Q) == .wall) {
            // Walls kill shots with a spark (an explode of radius 0).
            emit(w, .explode, no_car, 0, 0, p.x, p.y);
            p.* = .{};
            continue;
        }
        p.ttl -|= 1;
        if (p.ttl == 0) p.* = .{};
    }
}

/// Shots and drops for one tick, after the cars have moved and collided.
pub fn update(w: *World) void {
    update_projs(w);
    update_drops(w);
}

/// Pool occupancy (tests, the soak).
pub fn projs_live(w: *const World) usize {
    var n: usize = 0;
    for (&w.projs) |*p| n += @intFromBool(p.kind != .none);
    return n;
}
pub fn drops_live(w: *const World) usize {
    var n: usize = 0;
    for (&w.drops) |*d| n += @intFromBool(d.kind != .none);
    return n;
}
