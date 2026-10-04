//! Boss ids and hit points (SPEC.md section 7, PLAN.md M7 "Bosses"). Pure,
//! no cart API, so `zig build test` runs it on the host. `Enemy.hp` is a
//! u16 since M7; the spawn and the HUD bar's denominator both come from
//! `max_hp`, so a fresh boss always shows a full bar (review 2026-10-01 G6).
//!
//! Every boss still uses the M3 Heisenbug numbers (60 + 20 per completed
//! loop); track B2 sets the real per-boss values (PLAN.md M7).

/// `Enemy.variant` of a `.boss`: which of the four bosses it is.
pub const BossId = enum(u8) { heisenbug, mandelbug, schrodinbug, bohrbug };

/// The boss of stage index `stage` (0 = UNIT TESTS .. 3 = PRODUCTION);
/// a later index wraps.
pub fn for_stage(stage: u8) BossId {
    return @fromBackingInt(@intCast(stage % 4));
}

const base: u32 = 60;
const per_loop: u32 = 20;

/// Boss HP for `boss` in loop `loop`: 60 + 20 per loop for now, at most
/// 65535.
pub fn max_hp(boss: BossId, loop: u8) u16 {
    _ = boss;
    return @intCast(@min(base + per_loop * @as(u32, loop), 0xFFFF));
}

const testing = @import("std").testing;

test "boss HP grows 20 per loop from 60" {
    try testing.expectEqual(@as(u16, 60), max_hp(.heisenbug, 0));
    try testing.expectEqual(@as(u16, 80), max_hp(.heisenbug, 1));
    try testing.expectEqual(@as(u16, 240), max_hp(.heisenbug, 9));
}

test "boss HP is no longer capped at the u8 limit" {
    try testing.expectEqual(@as(u16, 260), max_hp(.heisenbug, 10));
    try testing.expectEqual(@as(u16, 5160), max_hp(.bohrbug, 255));
}

test "each stage has its own boss" {
    try testing.expectEqual(BossId.heisenbug, for_stage(0));
    try testing.expectEqual(BossId.mandelbug, for_stage(1));
    try testing.expectEqual(BossId.schrodinbug, for_stage(2));
    try testing.expectEqual(BossId.bohrbug, for_stage(3));
    try testing.expectEqual(BossId.heisenbug, for_stage(4));
}
