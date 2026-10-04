//! The rank formula and its effects table (PLAN.md M7 "Rank"), as pure
//! functions of their inputs: no cart API, no World, so `zig build test`
//! runs them on the host. `rank.zig` feeds them from the World.
//!
//! value = clamp(stage_base[stage] + 400 * loop + stage_seconds
//!               + 25 * (level - 1) + 30 * forks - mercy, 0, 1000)
//! r = value / 1000

pub const max_value: u32 = 1000;
pub const stage_base = [4]u32{ 0, 150, 300, 450 };
const per_loop: u32 = 400;
/// stage_seconds = min(waves.t / 60, 120).
const max_stage_seconds: u32 = 120;
const per_level: u32 = 25;
const per_fork: u32 = 30;

/// Everything the rank is computed from (all World state).
pub const Inputs = struct {
    /// 0..3; a later stage index uses the last base.
    stage: u8 = 0,
    loop: u8 = 0,
    /// Ticks since the stage started (`waves.State.t`).
    t: u32 = 0,
    /// Weapon level 1..5 (0 reads as 1).
    level: u8 = 1,
    forks: u8 = 0,
    mercy: u16 = 0,
};

pub fn value(in: Inputs) u32 {
    const secs = @min(in.t / 60, max_stage_seconds);
    const plus: u32 = stage_base[@min(in.stage, stage_base.len - 1)] +
        per_loop * @as(u32, in.loop) + secs +
        per_level * (@as(u32, @max(in.level, 1)) - 1) + per_fork * @as(u32, in.forks);
    if (plus <= in.mercy) return 0;
    return @min(plus - in.mercy, max_value);
}

/// r = value / 1000, in 0..1.
pub fn r_of(v: u32) f32 {
    return @as(f32, @floatFromInt(@min(v, max_value))) / @as(f32, @floatFromInt(max_value));
}

/// round(x) for x >= 0, without libm.
fn round_pos(x: f32) u32 {
    return @intFromFloat(@floor(x + 0.5));
}

/// Fire interval: round(base * (1 - 0.4 r)), at least base / 2 and 1.
pub fn interval(base: u32, r: f32) u32 {
    const scaled = round_pos(@as(f32, @floatFromInt(base)) * (1.0 - 0.4 * r));
    return @max(scaled, base / 2, 1);
}

/// Extra bullets for a pattern: floor(r * (k + 1)), at most k.
pub fn extra(k: u32, r: f32) u32 {
    const e: u32 = @intFromFloat(@floor(r * @as(f32, @floatFromInt(k + 1))));
    return @min(e, k);
}

/// Regular enemy HP: round(base * (1 + 0.6 r)), at least 1.
pub fn hp(base: u16, r: f32) u16 {
    const scaled = round_pos(@as(f32, @floatFromInt(base)) * (1.0 + 0.6 * r));
    return @intCast(@min(@max(scaled, 1), 0xFFFF));
}

/// Per-shape speed caps in px per tick, indexed by `bullets.Shape`'s
/// backing value: round, needle, pellet, orb.
pub const speed_caps = [4]f32{ 2.0, 2.6, 2.2, 1.6 };

/// Enemy bullet speed: base * (1 + 0.5 r), capped by the shape. At r = 0
/// the result is `base` exactly (when base is under the cap).
pub fn speed(base: f32, r: f32, shape: u8) f32 {
    return @min(base * (1.0 + 0.5 * r), speed_caps[@min(shape, speed_caps.len - 1)]);
}

/// Revenge bullets for a bolt kill: 0 (none), 1 (one aimed pellet) or 3
/// (a 3-way fan). A non-gnat revenges when loop >= 1 or r >= 0.6, a gnat
/// only when loop >= 1; never when the kill is 40 px or less from the
/// ship's hitbox center (`dist2` is the squared distance); 3 when
/// r >= 0.85.
pub fn revenge_count(is_gnat: bool, loop: u8, r: f32, dist2: f32) u32 {
    const on = if (is_gnat) loop >= 1 else (loop >= 1 or r >= 0.6);
    if (!on or dist2 <= revenge_min_dist * revenge_min_dist) return 0;
    return if (r >= 0.85) 3 else 1;
}
pub const revenge_min_dist: f32 = 40;

const testing = @import("std").testing;

test "a fresh game has rank 0" {
    try testing.expectEqual(@as(u32, 0), value(.{}));
    try testing.expectEqual(@as(f32, 0), r_of(0));
}

test "rank adds stage, loop, seconds, level and forks" {
    try testing.expectEqual(@as(u32, 150), value(.{ .stage = 1 }));
    try testing.expectEqual(@as(u32, 450), value(.{ .stage = 3 }));
    try testing.expectEqual(@as(u32, 450), value(.{ .stage = 9 }));
    try testing.expectEqual(@as(u32, 400), value(.{ .loop = 1 }));
    try testing.expectEqual(@as(u32, 1), value(.{ .t = 119 }));
    try testing.expectEqual(@as(u32, 120), value(.{ .t = 60 * 500 }));
    try testing.expectEqual(@as(u32, 100), value(.{ .level = 5 }));
    try testing.expectEqual(@as(u32, 0), value(.{ .level = 0 }));
    try testing.expectEqual(@as(u32, 90), value(.{ .forks = 3 }));
    try testing.expectEqual(@as(u32, 300 + 30 + 75 + 60), value(.{ .stage = 2, .t = 1800, .level = 4, .forks = 2 }));
}

test "mercy subtracts and the value clamps to 0..1000" {
    try testing.expectEqual(@as(u32, 70), value(.{ .stage = 1, .mercy = 80 }));
    try testing.expectEqual(@as(u32, 0), value(.{ .mercy = 80 }));
    try testing.expectEqual(@as(u32, 1000), value(.{ .stage = 3, .loop = 2, .t = 99999, .level = 5, .forks = 3 }));
    try testing.expectEqual(@as(u32, 1000), value(.{ .loop = 255 }));
    try testing.expectEqual(@as(f32, 1), r_of(1000));
    try testing.expectEqual(@as(f32, 0.5), r_of(500));
}

test "fire interval shrinks to at most 40 percent off, floored at base / 2 and 1" {
    try testing.expectEqual(@as(u32, 45), interval(45, 0));
    try testing.expectEqual(@as(u32, 27), interval(45, 1));
    try testing.expectEqual(@as(u32, 36), interval(45, 0.5));
    try testing.expectEqual(@as(u32, 2), interval(4, 1));
    try testing.expectEqual(@as(u32, 1), interval(1, 1));
    try testing.expectEqual(@as(u32, 1), interval(0, 0));
    try testing.expectEqual(@as(u32, 2), interval(3, 1));
    try testing.expectEqual(@as(u32, 6), interval(10, 1));
}

test "extra bullets are floor(r (k + 1)) up to k" {
    try testing.expectEqual(@as(u32, 0), extra(3, 0));
    try testing.expectEqual(@as(u32, 1), extra(3, 0.25));
    try testing.expectEqual(@as(u32, 3), extra(3, 0.99));
    try testing.expectEqual(@as(u32, 3), extra(3, 1));
    try testing.expectEqual(@as(u32, 0), extra(0, 1));
}

test "enemy HP grows up to 60 percent, at least 1" {
    try testing.expectEqual(@as(u16, 12), hp(12, 0));
    try testing.expectEqual(@as(u16, 19), hp(12, 1));
    try testing.expectEqual(@as(u16, 1), hp(1, 0.8));
    try testing.expectEqual(@as(u16, 2), hp(1, 0.84));
    try testing.expectEqual(@as(u16, 1), hp(0, 0));
}

test "bullet speed scales by half and is capped per shape" {
    try testing.expectEqual(@as(f32, 1.0), speed(1.0, 0, 0));
    try testing.expectEqual(@as(f32, 1.5), speed(1.0, 1, 0));
    try testing.expectEqual(@as(f32, 2.0), speed(1.5, 1, 0));
    try testing.expectEqual(@as(f32, 2.25), speed(1.5, 1, 1));
    try testing.expectEqual(@as(f32, 2.6), speed(2.0, 1, 1));
    try testing.expectEqual(@as(f32, 2.2), speed(2.0, 1, 2));
    try testing.expectEqual(@as(f32, 1.6), speed(1.2, 1, 3));
}

test "revenge bullets by loop, rank and distance" {
    const far: f32 = 41 * 41;
    try testing.expectEqual(@as(u32, 0), revenge_count(false, 0, 0.59, far));
    try testing.expectEqual(@as(u32, 1), revenge_count(false, 0, 0.6, far));
    try testing.expectEqual(@as(u32, 0), revenge_count(true, 0, 0.9, far));
    try testing.expectEqual(@as(u32, 1), revenge_count(true, 1, 0, far));
    try testing.expectEqual(@as(u32, 3), revenge_count(true, 1, 0.85, far));
    try testing.expectEqual(@as(u32, 0), revenge_count(false, 1, 1, 40 * 40));
}
