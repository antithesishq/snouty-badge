//! Track hazards and the service bay (SPEC 3.3, 19.4, M3). New for Snouty GC.
//!
//! The hazards are generic kinds driven by the track data
//! (`track.HazardSpec`, one per `World.hazards` slot), so a data-only track
//! pack (M7) can place them with its own numbers: a timed blast across the
//! track (the Runoff's exhaust vents) and a crossing mover shuttling over
//! it (the Dumps' Sweeper). Turrets and breakable crust are reserved kinds
//! and stay idle here.
//!
//! Part of `sim.simulate`, so pure in the World: no cart API, no clock, no
//! floats, no globals written (the spec cache `track.hazard_specs` is the
//! track data, filled by `track.select` at reset). `at` is a pure function
//! of a spec and a cycle tick, which the AI uses to look ahead.
const std = @import("std");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const track = @import("track.zig");
const sim = @import("sim.zig");
const weapons = @import("weapons.zig");

const World = world.World;
const Car = world.Car;
const HazardSpec = track.HazardSpec;
const no_car = world.no_car;

const world_mask: i32 = (1024 << fixed.Q) - 1;

/// Where a hazard is at one tick of its cycle.
pub const Phase = struct {
    state: world.HazardState = .idle,
    /// Mover: 0 going (or waiting to go) from end A to end B, 1 back.
    leg: u8 = 0,
    /// Mover: its centre, Q16 world px (wrapping); blast: the mouth.
    x: i32 = 0,
    y: i32 = 0,
    /// Mover: its velocity while crossing, Q16 px/tick.
    vx: i32 = 0,
    vy: i32 = 0,
};

/// The hazard's phase at cycle tick `t` (0 .. period - 1). A blast is idle,
/// then warns for `warn` ticks, then fires for the last `on` ticks of the
/// period. A mover spends each half of the period waiting at one end, then
/// warning, then crossing to the other end in `travel` ticks.
pub fn at(h: *const HazardSpec, t: u16) Phase {
    var p = Phase{ .x = h.x0 << fixed.Q, .y = h.y0 << fixed.Q };
    switch (h.kind) {
        .blast => {
            const fire_at = h.period -| h.on;
            if (t >= fire_at) {
                p.state = .active;
            } else if (t + h.warn >= fire_at) p.state = .warn;
        },
        .mover => {
            const half = h.period / 2;
            p.leg = @intFromBool(t >= half);
            const u = t - @as(u16, p.leg) * half;
            const move_at = half -| h.travel;
            // From A on leg 0, from B on leg 1.
            const sx: i32 = if (p.leg == 0) h.x0 else h.x1;
            const sy: i32 = if (p.leg == 0) h.y0 else h.y1;
            const dir: i32 = if (p.leg == 0) 1 else -1;
            p.x = sx << fixed.Q;
            p.y = sy << fixed.Q;
            if (u >= move_at and h.travel > 0) {
                p.state = .active;
                // Distance covered, Q16 px, never past the far end.
                const run = @min(@as(i32, u - move_at + 1) * h.speed, h.len << fixed.Q);
                p.x += dir * fixed.mul(h.ux, run);
                p.y += dir * fixed.mul(h.uy, run);
                p.vx = dir * fixed.mul(h.ux, h.speed);
                p.vy = dir * fixed.mul(h.uy, h.speed);
            } else if (u + h.warn >= move_at) p.state = .warn;
            p.x &= world_mask;
            p.y &= world_mask;
        },
        .none, .turret, .crust => {},
    }
    return p;
}

/// `b - a` for wrapping Q16 coordinates, in whole px.
inline fn dpx(a: i32, b: i32) i32 {
    return weapons.dq(a, b) >> fixed.Q;
}

/// Can a hazard touch this car? On the ground, in the race, not wrecked
/// (airborne cars fly over the vents and the Sweeper).
fn reachable(c: *const Car) bool {
    return c.active and c.wreck == .none and c.hop == 0;
}

/// Is car `c` in a blast's lane: its centre between the mouth and the far
/// end, within the lane's half width plus half a car.
pub fn in_lane(h: *const HazardSpec, c: *const Car) bool {
    const dx = dpx(h.x0 << fixed.Q, c.x);
    const dy = dpx(h.y0 << fixed.Q, c.y);
    const along = (dx * h.ux + dy * h.uy) >> fixed.Q;
    const lat = (dx * -h.uy + dy * h.ux) >> fixed.Q;
    return along >= 0 and along <= h.len and @abs(lat) <= h.size + tuning.hazard_reach;
}

/// One racing tick: advance every hazard, hit the cars it touches, and run
/// the service bays. Called by `sim.simulate` after the car contacts.
pub fn update(w: *World) void {
    for (track.hazard_specs[0..track.hazard_n], 0..) |*h, k| {
        const hz = &w.hazards[k];
        if (h.kind == .crust) {
            crust_update(w, k, h);
            continue;
        }
        hz.timer = @intCast((@as(u32, hz.timer) + 1) % h.period);
        const p = at(h, hz.timer);
        if (p.state == .active and hz.state != .active) {
            hz.hit = 0;
            weapons.emit(w, .blast, @intCast(k), @backingInt(h.kind), 0, p.x, p.y);
        }
        hz.state = p.state;
        hz.leg = p.leg;
        hz.x = p.x;
        hz.y = p.y;
        if (p.state != .active) continue;
        switch (h.kind) {
            .blast => blast_hits(w, k, h),
            .mover => mover_hits(w, k, h, &p),
            .none, .turret, .crust => {},
        }
    }
    service(w);
}

// --- Breakable crust (M7, SPEC 19.4) ---------------------------------------------
//
// A crust hazard's World slot: `state` idle (intact), warn (cracked: a car
// on the ground touched one of its crust tiles; `timer` counts to the
// spec's `warn`), active (broken: `timer` counts to `period`, then it is
// intact again). `x`, `y` hold the region's centre (Q16) for the fx.

/// Is (x, y) world px inside a broken crust region? (Its tiles' attribute
/// is `crust`; the caller has read that.)
pub fn crust_broken(w: *const World, x: i32, y: i32) bool {
    const px = x & 1023;
    const py = y & 1023;
    for (track.hazard_specs[0..track.hazard_n], 0..) |*h, k| {
        if (h.kind != .crust or w.hazards[k].state != .active) continue;
        if (px >= h.x0 and px < h.x1 and py >= h.y0 and py < h.y1) return true;
    }
    return false;
}

fn crust_update(w: *World, k: usize, h: *const HazardSpec) void {
    const hz = &w.hazards[k];
    hz.x = ((h.x0 + h.x1) >> 1) << fixed.Q;
    hz.y = ((h.y0 + h.y1) >> 1) << fixed.Q;
    switch (hz.state) {
        .idle => {
            // The first car on the ground with its centre on a crust tile
            // of the region cracks it.
            const t = sim.track_of(w);
            for (&w.cars) |*c| {
                if (!reachable(c)) continue;
                const cx = c.x >> fixed.Q;
                const cy = c.y >> fixed.Q;
                if (cx < h.x0 or cx >= h.x1 or cy < h.y0 or cy >= h.y1) continue;
                if (t.attr_at(cx, cy) != .crust) continue;
                hz.state = .warn;
                hz.timer = 0;
                break;
            }
        },
        .warn => {
            hz.timer +|= 1;
            if (hz.timer >= h.warn) {
                hz.state = .active;
                hz.timer = 0;
                weapons.emit(w, .blast, @intCast(k), @backingInt(h.kind), 0, hz.x, hz.y);
            }
        },
        .active => {
            hz.timer +|= 1;
            if (hz.timer >= h.period) {
                hz.state = .idle;
                hz.timer = 0;
            }
        },
    }
}

/// A firing vent: every car in its lane takes the damage once a firing and
/// a shove along the lane (sideways across the track).
fn blast_hits(w: *World, k: usize, h: *const HazardSpec) void {
    const hz = &w.hazards[k];
    for (&w.cars, 0..) |*c, i| {
        const bit = @as(u8, 1) << @intCast(i);
        if (hz.hit & bit != 0 or !reachable(c) or !in_lane(h, c)) continue;
        hz.hit |= bit;
        c.vx += fixed.mul(h.ux, h.push);
        c.vy += fixed.mul(h.uy, h.push);
        c.shake = 6;
        hit(w, k, i, h.damage);
    }
}

/// A crossing mover: a car it touches is pushed out of its body, and takes
/// the damage and a shove (away from it plus its own velocity) once a
/// crossing.
fn mover_hits(w: *World, k: usize, h: *const HazardSpec, p: *const Phase) void {
    const hz = &w.hazards[k];
    const reach = h.size + tuning.car_radius;
    for (&w.cars, 0..) |*c, i| {
        if (!reachable(c)) continue;
        const dx = dpx(p.x, c.x);
        const dy = dpx(p.y, c.y);
        if (@abs(dx) >= reach or @abs(dy) >= reach) continue;
        const d2 = dx * dx + dy * dy;
        if (d2 >= reach * reach) continue;
        // Unit normal from the mover to the car (along its travel if centred),
        // Q16; push the car out of the body unless that puts it in a wall.
        const d: i32 = @intCast(fixed.isqrt(@intCast(d2)));
        const dir: i32 = if (p.leg == 0) 1 else -1;
        const nx: i32 = if (d == 0) dir * h.ux else @divTrunc(dx << fixed.Q, d);
        const ny: i32 = if (d == 0) dir * h.uy else @divTrunc(dy << fixed.Q, d);
        sim.nudge(w, c, nx * (reach - d), ny * (reach - d));
        const bit = @as(u8, 1) << @intCast(i);
        if (hz.hit & bit != 0) continue;
        hz.hit |= bit;
        c.vx += fixed.mul(nx, h.push) + p.vx;
        c.vy += fixed.mul(ny, h.push) + p.vy;
        c.shake = 8;
        hit(w, k, i, h.damage);
    }
}

/// Damage from hazard `k` (no attacker: a wreck goes to the last rival who
/// hit the car within the credit window, as for a wall) and its event.
fn hit(w: *World, k: usize, i: usize, dmg: u8) void {
    const c = &w.cars[i];
    weapons.emit(w, .hazard_hit, @intCast(k), @intCast(i), if (w.combat) dmg else 0, c.x, c.y);
    sim.damage(w, i, no_car, dmg);
}

/// Service bays (SPEC 3.3): a car on a bay tile gets 1 armor every
/// `tuning.bay_every` ticks (in a BATTLE arena at half that rate, SPEC
/// 8.3: a camper still loses).
fn service(w: *World) void {
    const every = if (w.mode == .battle) tuning.battle_bay_every else tuning.bay_every;
    if (!w.combat or w.tick % every != 0) return;
    for (&w.cars) |*c| {
        if (c.on_bay and c.active and c.wreck == .none and c.armor < c.armor_max) c.armor += 1;
    }
}

// --- Looking ahead (the AI) ---------------------------------------------------------

/// The hazard's phase `ahead` ticks from now.
pub fn future(w: *const World, k: usize, ahead: u32) Phase {
    const h = &track.hazard_specs[k];
    return at(h, @intCast((@as(u32, w.hazards[k].timer) + ahead) % h.period));
}

test "a blast cycle: idle, warn, then on for the last `on` ticks" {
    const h = HazardSpec{ .kind = .blast, .period = 240, .on = 30, .warn = 40, .x0 = 100, .y0 = 100, .x1 = 100, .y1 = 200 };
    try std.testing.expectEqual(world.HazardState.idle, at(&h, 0).state);
    try std.testing.expectEqual(world.HazardState.idle, at(&h, 169).state);
    try std.testing.expectEqual(world.HazardState.warn, at(&h, 170).state);
    try std.testing.expectEqual(world.HazardState.warn, at(&h, 209).state);
    try std.testing.expectEqual(world.HazardState.active, at(&h, 210).state);
    try std.testing.expectEqual(world.HazardState.active, at(&h, 239).state);
}

test "a mover waits, warns, crosses A to B, then comes back" {
    var hs: [world.hazard_max]HazardSpec = undefined;
    // A 20-byte record: mover, warn 60, radius 18, 60 damage, (100, 100) to
    // (100, 300), period 600, phase 0, push 2, speed 1.25 px/tick.
    var rec: [track.hazard_record]u8 = @splat(0);
    rec[0] = @backingInt(world.HazardKind.mover);
    rec[1] = 60;
    rec[2] = 18;
    rec[3] = 60;
    std.mem.writeInt(u16, rec[4..6], 100, .little);
    std.mem.writeInt(u16, rec[6..8], 100, .little);
    std.mem.writeInt(u16, rec[8..10], 100, .little);
    std.mem.writeInt(u16, rec[10..12], 300, .little);
    std.mem.writeInt(u16, rec[12..14], 600, .little);
    rec[18] = 64;
    rec[19] = 40;
    const t = track.Track{ .name = "T", .league = &track.dumps, .map_packed = &.{}, .attr = &.{}, .center = &.{}, .feat = &rec };
    try std.testing.expectEqual(@as(u8, 1), track.parse_hazards(&t, &hs));
    const h = &hs[0];
    try std.testing.expectEqual(@as(i32, 200), h.len);
    try std.testing.expectEqual(@as(u16, 160), h.travel);
    try std.testing.expectEqual(@as(i32, 2 << 16), h.push);
    // Leg 0: waits at A until 300 - 160 - 60 = 80, warns, crosses from 140.
    try std.testing.expectEqual(world.HazardState.idle, at(h, 79).state);
    try std.testing.expectEqual(world.HazardState.warn, at(h, 80).state);
    try std.testing.expectEqual(@as(i32, 100), at(h, 139).y >> 16);
    const mid = at(h, 140 + 79);
    try std.testing.expectEqual(world.HazardState.active, mid.state);
    try std.testing.expectEqual(@as(i32, 200), mid.y >> 16);
    try std.testing.expectEqual(@as(i32, 300), at(h, 299).y >> 16);
    // Leg 1: back from B.
    const back = at(h, 300 + 140 + 79);
    try std.testing.expectEqual(@as(u8, 1), back.leg);
    try std.testing.expectEqual(@as(i32, 200), back.y >> 16);
    try std.testing.expect(back.vy < 0);
}
