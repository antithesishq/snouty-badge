//! Rank (PLAN.md M7 "Rank", SPEC.md 5.5): one number 0..1000 computed from
//! World state (stage, loop, stage clock, weapon level, forks and `mercy`),
//! read at the moment of use, so a rewind rewinds it too. The formula and
//! the effects table are pure, in `rank_math.zig` (host tested); this module
//! reads the World and applies them. Only `mercy` is stored
//! (`world.w.mercy`): +80 at each auto-rewind resume
//! (`player.on_rewound_hit`), -1 every 120 ticks.
const world = @import("world.zig");
const math = @import("rank_math.zig");
const bullets = @import("bullets.zig");
const enemies = @import("enemies.zig");
const patterns = @import("patterns.zig");
const player = @import("player.zig");

comptime {
    // `rank_math.speed_caps` is indexed by the shape's backing value.
    if (@backingInt(bullets.Shape.round) != 0 or @backingInt(bullets.Shape.needle) != 1 or
        @backingInt(bullets.Shape.pellet) != 2 or @backingInt(bullets.Shape.orb) != 3)
        @compileError("rank_math.speed_caps is out of step with bullets.Shape");
}

/// Mercy added by a hit that is rewound (or counted by the probe).
pub const mercy_per_hit: u16 = 80;
/// Mercy never exceeds this (three hits' worth), so a bad stretch buys a
/// short reprieve, not minutes at rank 0 that also cancel the loop bonus.
pub const mercy_cap: u16 = 240;
/// Mercy decays by 1 every this many game ticks (2 a second: a full 240
/// is gone in two minutes).
const mercy_decay_every: u32 = 30;

/// Revenge bullet: an aimed pellet at base speed 1.0, a 3-way fan 10/256
/// apart at high rank.
const revenge_speed: f32 = 1.0;
const revenge_step: u32 = 10;

pub fn value() u32 {
    const w = &world.w;
    return math.value(.{
        .stage = w.waves.stage,
        .loop = w.waves.loop,
        .t = w.waves.t,
        .level = w.player.level,
        .forks = w.player.forks,
        .mercy = w.mercy,
    });
}

/// value / 1000.
pub fn r() f32 {
    return math.r_of(value());
}

/// A fire interval at the current rank: round(base * (1 - 0.4 r)), at
/// least base / 2 and 1. Content writes `rank.interval(base)`.
pub fn interval(base: u32) u32 {
    return math.interval(base, r());
}

/// Extra bullets for a pattern of `n + k`: floor(r * (k + 1)), at most k.
pub fn extra(k: u32) u32 {
    return math.extra(k, r());
}

/// A regular enemy's HP at spawn: round(base * (1 + 0.6 r)), at least 1.
pub fn hp(base: u16) u16 {
    return math.hp(base, r());
}

/// An enemy bullet's speed at spawn: base * (1 + 0.5 r), capped per shape
/// (round 2.0, needle 2.6, pellet 2.2, orb 1.6). `bullets.spawn_shot`
/// applies it; content never multiplies by hand.
pub fn bullet_speed(base: f32, shape: bullets.Shape) f32 {
    return math.speed(base, r(), @backingInt(shape));
}

/// One tick of mercy decay; called once per simulated tick.
pub fn update() void {
    const w = &world.w;
    if (w.mercy > 0 and w.game_tick % mercy_decay_every == 0) w.mercy -= 1;
}

/// A bolt killed a (non-boss) enemy of `kind` centered at (cx, cy):
/// revenge bullets when the rank says so (`rank_math.revenge_count`).
pub fn revenge(kind: enemies.Kind, cx: f32, cy: f32) void {
    const hb = player.hitbox();
    const dx = cx - (hb[0] + hb[2] / 2);
    const dy = cy - (hb[1] + hb[3] / 2);
    const n = math.revenge_count(kind == .gnat, world.w.waves.loop, r(), dx * dx + dy * dy);
    if (n == 0) return;
    const shot: bullets.Shot = .{ .speed = revenge_speed, .shape = .pellet, .source = kind };
    if (n == 1) patterns.aimed(cx, cy, shot) else patterns.fan(cx, cy, n, revenge_step, shot);
}
