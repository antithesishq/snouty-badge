//! Pickups (SPEC 6.3, 6.4): RMA crates, the roulette and rank-weighted
//! rolls, the 15 non-league pickups and their status effects, the DDOS
//! drones and the KERNEL PANIC packet. New for Snouty GC (M2).
//!
//! Part of `sim.simulate`, so pure in the World: no cart API, no clock, no
//! floats, no globals written; the world PRNG is the only randomness.
//! `duck_pos` and `chain_anchor` are render-side helpers (pure reads).
const std = @import("std");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const sim = @import("sim.zig");

const World = world.World;
const Car = world.Car;
const no_car = world.no_car;

const world_mask: i32 = (1024 << fixed.Q) - 1;

/// Where a car's RUBBER DUCK bobs: `duck_behind` px behind it, Q16.
pub fn duck_pos(c: *const Car) struct { x: i32, y: i32 } {
    return .{
        .x = (c.x -% fixed.cos(c.heading) * tuning.duck_behind) & world_mask,
        .y = (c.y -% fixed.sin(c.heading) * tuning.duck_behind) & world_mask,
    };
}

/// The far end of car `i`'s DEADLOCK chain, Q16: the partner car, or for a
/// wall chain the track edge nearer the car at its centerline sample.
pub fn chain_anchor(w: *const World, i: usize) struct { x: i32, y: i32 } {
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

inline fn wrap_px(d: i32) i32 {
    return ((d + 512) & 1023) - 512;
}
