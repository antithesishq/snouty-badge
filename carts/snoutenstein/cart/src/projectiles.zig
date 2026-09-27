//! Enemy projectiles (spit, web): movement, wall collision, player hits.
//! Called once per tick from `sim.step` after `ai.update`. Fixed point
//! only, no cart-api. M3 track B replaces this stub.
const std = @import("std");
const fixed = @import("fixed.zig");
const state = @import("state.zig");
const levels = @import("levels.zig");
const sim = @import("sim.zig");

const GameState = state.GameState;
const Level = levels.Level;
const Fixed = fixed.Fixed;

pub const kind_none: u8 = 0;
pub const kind_spit: u8 = 1;
pub const kind_web: u8 = 2;

/// Launch a projectile of `kind` from (x, y) along `angle`. Returns false
/// when the pool is full.
pub fn spawn(s: *GameState, x: Fixed, y: Fixed, angle: fixed.Angle, kind: u8) bool {
    _ = s;
    _ = x;
    _ = y;
    _ = angle;
    _ = kind;
    return false;
}

pub fn update(s: *GameState, level: *const Level) void {
    _ = s;
    _ = level;
}
