//! The BATTLE hunter (SPEC 8.3, M6): how an AI crew drives and fights in
//! an arena, where there is no centerline to follow. New for Snouty GC.
//!
//! M6.0 stub: steer at the nearest car and fight with the crews' race
//! habits (`ai.arm`, `ai.want_use`). Track A replaces it with the target
//! choice per crew, the navigation field and its jumps, the rear drops
//! when chased and the retreat to a service bay.
//!
//! Pure: reads the World it is given (and the arena cache), no globals
//! written, no cart API.
const std = @import("std");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const sim = @import("sim.zig");
const ai = @import("ai.zig");

const World = world.World;
const Input = world.Input;
const no_car = world.no_car;

/// One tick of input for car `i` in battle, by its crew.
pub fn drive(w: *const World, i: usize, cr: *const ai.Crew) Input {
    var b: Input = .{};
    const c = &w.cars[i];
    var best: u8 = no_car;
    var best_d: i32 = std.math.maxInt(i32);
    for (&w.cars, 0..) |*o, j| {
        if (j == i or !o.active or o.wreck != .none) continue;
        const dx = wrap_px((o.x - c.x) >> fixed.Q);
        const dy = wrap_px((o.y - c.y) >> fixed.Q);
        const d = dx * dx + dy * dy;
        if (d < best_d) {
            best_d = d;
            best = @intCast(j);
        }
    }
    if (best == no_car) return b;
    const o = &w.cars[best];
    const want = fixed.atan2(wrap_px((o.y - c.y) >> fixed.Q), wrap_px((o.x - c.x) >> fixed.Q));
    const err = fixed.turn_diff(c.heading, want);
    if (err > 400) b.right = true;
    if (err < -400) b.left = true;
    if (@abs(err) > 12000 and sim.speed(c) > tuning.top_speed / 2) b.down = true;
    const fight = w.combat and w.phase == .racing and !c.finished and c.wreck == .none and c.safe == 0;
    if (fight) ai.arm(w, i, cr, &b, 0);
    return b;
}

inline fn wrap_px(d: i32) i32 {
    return ((d + 512) & 1023) - 512;
}
