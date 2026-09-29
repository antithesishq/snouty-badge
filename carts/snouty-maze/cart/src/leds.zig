//! Neopixels (SPEC section 9): off by default, Select toggles. Dim brick
//! while walking, a purple pulse on a smiley flip, white during a
//! teleport, slow breathing overhead, amber in MANUAL (M4 takeover).
//! Every channel stays at or below 10.
//!
//! PLAN.md M3 "LEDs": the base colour comes from the autopilot state, a
//! change in `flips` adds a 90-tick fading purple pulse on top, each
//! channel clamped to `max_level`. All five pixels show the same colour.
const cart = @import("cart-api");
const math = @import("math.zig");
const autopilot = @import("autopilot.zig");

pub var enabled: bool = false;

pub fn toggle() void {
    enabled = !enabled;
}

/// Hard ceiling for every channel (the badge LEDs are blinding above it).
pub const max_level: u8 = 10;
pub const pulse_ticks: u32 = 90;
pub const breath_ticks: u32 = 180;

const Rgb = struct { r: u8, g: u8, b: u8 };

const brick: Rgb = .{ .r = 6, .g = 2, .b = 1 };
/// MANUAL (joystick takeover): brick shifted to amber, so the badge shows
/// who is driving.
const amber: Rgb = .{ .r = 6, .g = 4, .b = 0 };
const purple: Rgb = .{ .r = 6, .g = 0, .b = 10 };
const white: Rgb = .{ .r = 10, .g = 10, .b = 10 };

/// Ticks since start (wraps harmlessly; only `% breath_ticks` is used).
var tick: u32 = 0;
var last_flips: u32 = 0;
/// Ticks left in the purple pulse (0 = none).
var pulse_left: u32 = 0;

/// Writes all five neopixels for this tick. `flips` and `teleports` are
/// the actor event counters; a change in `flips` since the last call
/// starts the purple pulse. The teleport flash follows the TELEPORT state
/// itself, so `teleports` is not needed beyond the interface.
pub fn update(state: autopilot.State, flips: u32, teleports: u32) void {
    _ = teleports;
    tick +%= 1;
    // Track events even while disabled so turning the LEDs on later does
    // not replay a stale pulse.
    if (flips != last_flips) {
        last_flips = flips;
        pulse_left = pulse_ticks;
    }
    const pulse = pulse_left;
    if (pulse_left > 0) pulse_left -= 1;

    const c = if (enabled) colour(state, pulse) else Rgb{ .r = 0, .g = 0, .b = 0 };
    const px: cart.NeopixelColor = .{ .g = c.g, .r = c.r, .b = c.b };
    for (0..cart.neopixels.len) |i| cart.neopixels[i] = px;
}

/// Base colour for the state plus the pulse (`pulse` ticks left of
/// `pulse_ticks`), every channel clamped to `max_level`.
fn colour(state: autopilot.State, pulse: u32) Rgb {
    var c: Rgb = switch (state) {
        .teleport => white,
        .overhead => breath(),
        .manual => amber,
        else => brick,
    };
    if (pulse > 0) {
        // (1 - t) with t = age / pulse_ticks, age = pulse_ticks - pulse.
        c.r = add_clamped(c.r, scale(purple.r, pulse, pulse_ticks));
        c.g = add_clamped(c.g, scale(purple.g, pulse, pulse_ticks));
        c.b = add_clamped(c.b, scale(purple.b, pulse, pulse_ticks));
    }
    return c;
}

/// Brick hue at level 1 + 9 * (0.5 + 0.5 * sin(tick / 180 turns)), so the
/// red channel breathes 1..10 and green and blue keep the brick ratio.
fn breath() Rgb {
    const turns = @as(f32, @floatFromInt(tick % breath_ticks)) / @as(f32, @floatFromInt(breath_ticks));
    const lf = 1.0 + 9.0 * (0.5 + 0.5 * math.sin_turns(turns));
    const level: u32 = @min(@as(u32, @intFromFloat(lf + 0.5)), max_level);
    // Scale the brick colour so its red channel (the largest) equals level.
    return .{
        .r = scale(brick.r, level, brick.r),
        .g = scale(brick.g, level, brick.r),
        .b = scale(brick.b, level, brick.r),
    };
}

/// round(v * num / den), clamped to max_level.
fn scale(v: u8, num: u32, den: u32) u8 {
    const s = (@as(u32, v) * num + den / 2) / den;
    return @intCast(@min(s, max_level));
}

fn add_clamped(a: u8, b: u8) u8 {
    return @intCast(@min(@as(u32, a) + b, max_level));
}
