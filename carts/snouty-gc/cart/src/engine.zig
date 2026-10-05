//! Forked from snouty-zero/cart/src/engine.zig at f8f6962.
//! The engine sound's model (Zero SPEC 9): pitch and level from what the
//! followed car is doing (no rewind warble: GC has no rewind). sound.zig
//! plays it; no cart API here, so the host tests cover it.
const std = @import("std");
const tuning = @import("tuning.zig");

/// What the engine hears this frame (main.zig `engine_cue`).
pub const Engine = struct {
    /// The followed car's speed, Q16.16 px/tick (`sim.speed`).
    speed: i32,
    /// Thrust (the auto-throttle, off on the brake), BURST running, in the
    /// air, on a coolant tile.
    throttle: bool,
    boost: bool,
    air: bool,
    rough: bool,
    /// On the grid before GO (the engine idles high).
    grid: bool,
    /// Frame counter for the rough wobble.
    frame: u32,
};

/// Engine pitch from 70 Hz at rest to 290 Hz at top speed, up an eighth
/// in the air and another under BURST (about 435 Hz at its terminal).
pub fn hz(e: Engine) u32 {
    const spd: u32 = @intCast(std.math.clamp(e.speed, 0, tuning.top_speed * 2));
    var f: u32 = 70 + @as(u32, @intCast(@as(u64, spd) * 220 / @as(u64, tuning.top_speed)));
    if (e.grid and e.throttle) f = 150;
    if (e.boost) f += f / 8;
    if (e.air) f += f / 8;
    // Coolant shudders: +-6% on alternate frames.
    if (e.rough and e.frame & 2 != 0) f += f / 16;
    return f;
}

/// Engine level 0..127: louder under thrust and BURST.
pub fn level(e: Engine) u8 {
    if (e.boost) return 48;
    return if (e.throttle) 40 else 26;
}

test "engine: pitch rises with speed, revs on the grid" {
    const rest: Engine = .{ .speed = 0, .throttle = false, .boost = false, .air = false, .rough = false, .grid = false, .frame = 0 };
    try std.testing.expectEqual(@as(u32, 70), hz(rest));
    var top = rest;
    top.speed = tuning.top_speed;
    try std.testing.expectEqual(@as(u32, 290), hz(top));
    top.boost = true;
    try std.testing.expect(hz(top) > 290);
    var grid = rest;
    grid.grid = true;
    grid.throttle = true;
    try std.testing.expectEqual(@as(u32, 150), hz(grid));
    // A reversing world (negative speed never happens, but clamp anyway).
    var back = rest;
    back.speed = -5000;
    try std.testing.expectEqual(@as(u32, 70), hz(back));
}
