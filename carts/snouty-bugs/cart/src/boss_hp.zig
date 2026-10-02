//! Boss hit points per stage (SPEC.md section 7, PLAN.md "Gameplay numbers
//! for M3"). Pure, no cart API, so `zig build test` runs it on the host.
//! `Enemy.hp` is a u8, so the maximum is capped at 255: the spawn and the
//! HUD bar's denominator both come from `max_hp`, and a fresh boss always
//! shows a full bar (review 2026-10-01 G6).

const base: u32 = 60;
const per_loop: u32 = 20;

/// Boss HP for `loop` completed stages: 60 + 20 per stage, at most 255
/// (reached at loop 10, stage 11).
pub fn max_hp(loop: u8) u8 {
    return @intCast(@min(base + per_loop * @as(u32, loop), 255));
}

const testing = @import("std").testing;

test "boss HP grows 20 per stage from 60" {
    try testing.expectEqual(@as(u8, 60), max_hp(0));
    try testing.expectEqual(@as(u8, 80), max_hp(1));
    try testing.expectEqual(@as(u8, 240), max_hp(9));
}

test "boss HP caps at the u8 limit from stage 11 on" {
    try testing.expectEqual(@as(u8, 255), max_hp(10));
    try testing.expectEqual(@as(u8, 255), max_hp(20));
    try testing.expectEqual(@as(u8, 255), max_hp(255));
}
