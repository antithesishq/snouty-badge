//! step(state, level, buttons): the whole simulation for one tick.
//! Pure over GameState, 16.16 fixed point only, no cart-api import, so
//! `zig test cart/src/sim.zig` runs on the host and replays are
//! bit-identical between the simulator and the badge (SPEC.md 9.3).
//! M0 stub: turn and walk with no collision. M1 track B replaces it.
const std = @import("std");
const fixed = @import("fixed.zig");
const state = @import("state.zig");
const levels = @import("levels.zig");

pub const GameState = state.GameState;

pub const turn_speed: fixed.Angle = 455; // 2.5 degrees per tick
pub const walk_speed: fixed.Fixed = fixed.from_float(0.045);
pub const back_speed: fixed.Fixed = fixed.from_float(0.03);

/// Fresh state at the start of `level`.
pub fn init(s: *GameState, level: *const levels.Level, level_index: u8, seed: u32) void {
    s.* = .{
        .player = .{
            .x = fixed.from_int(level.start_x) + fixed.half,
            .y = fixed.from_int(level.start_y) + fixed.half,
            .angle = level.start_angle,
        },
        .level = level_index,
        .rng = if (seed == 0) 0x2545F491 else seed,
    };
    for (level.enemies, 0..) |e, i| {
        s.enemies[i] = .{
            .x = fixed.from_int(e.x) + fixed.half,
            .y = fixed.from_int(e.y) + fixed.half,
            .kind = e.kind,
            .state = .dormant,
            .hp = 1,
        };
    }
}

pub fn step(s: *GameState, level: *const levels.Level, b: state.Buttons) void {
    _ = level;
    const p = &s.player;
    if (b.left) p.angle -%= turn_speed;
    if (b.right) p.angle +%= turn_speed;
    var move: fixed.Fixed = 0;
    if (b.up) move = walk_speed;
    if (b.down) move = -back_speed;
    if (move != 0) {
        p.x += fixed.mul(fixed.cos(p.angle), move);
        p.y += fixed.mul(fixed.sin(p.angle), move);
    }
    p.prev = b;
    s.tick += 1;
}

test "init places the player at the start cell centre" {
    var s: GameState = undefined;
    init(&s, &levels.all[0], 0, 1);
    try std.testing.expectEqual(fixed.from_int(3) + fixed.half, s.player.x);
    step(&s, &levels.all[0], .{ .up = true });
    try std.testing.expect(s.player.x > fixed.from_int(3) + fixed.half);
}
