//! Neopixels (SPEC section 9): off by default, Select toggles. Dim brick
//! while walking, a purple pulse on a smiley flip, white during a
//! teleport, slow breathing overhead. Every channel stays at or below 10.
//!
//! M3 stub: Track C3 implements `update`.
const cart = @import("cart-api");
const math = @import("math.zig");
const autopilot = @import("autopilot.zig");

pub var enabled: bool = false;

pub fn toggle() void {
    enabled = !enabled;
}

/// Writes all five neopixels for this tick. `flips` and `teleports` are
/// the actor event counters; a change since the last call starts the
/// matching effect.
pub fn update(state: autopilot.State, flips: u32, teleports: u32) void {
    _ = state;
    _ = flips;
    _ = teleports;
    _ = math;
    const off: cart.NeopixelColor = .{ .g = 0, .r = 0, .b = 0 };
    for (0..cart.neopixels.len) |i| cart.neopixels[i] = off;
}
