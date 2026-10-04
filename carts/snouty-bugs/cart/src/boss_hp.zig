//! Boss ids and hit points (SPEC.md section 7, PLAN.md M7 "Bosses"). Pure,
//! no cart API, so `zig build test` runs it on the host. `Enemy.hp` is a
//! u16 since M7; the spawn and the HUD bar's denominator both come from
//! `max_hp`, so a fresh boss always shows a full bar (review 2026-10-01 G6).
//!
//! Boss HP is not ranked: base x (1 + 0.3 x loop), rounded down, at most
//! 65535 (PLAN.md M7 "Bosses", track B2).

/// `Enemy.variant` of a `.boss`: which of the four bosses it is.
pub const BossId = enum(u8) { heisenbug, mandelbug, schrodinbug, bohrbug };

/// The boss of stage index `stage` (0 = UNIT TESTS .. 3 = PRODUCTION);
/// a later index wraps.
pub fn for_stage(stage: u8) BossId {
    return @fromBackingInt(@intCast(stage % 4));
}

/// Loop-0 HP per boss (PLAN.md M7 "Deviations (B2)" has the tuning).
pub fn base(boss: BossId) u32 {
    return switch (boss) {
        .heisenbug => 320,
        .mandelbug => 480,
        .schrodinbug => 240,
        .bohrbug => 420,
    };
}

/// Boss HP for `boss` in loop `loop`: base x (1 + 0.3 loop), rounded
/// down, at most 65535.
pub fn max_hp(boss: BossId, loop: u8) u16 {
    const hp = base(boss) * (10 + 3 * @as(u32, loop)) / 10;
    return @intCast(@min(hp, 0xFFFF));
}

const testing = @import("std").testing;

test "loop-0 boss HP is the base" {
    try testing.expectEqual(@as(u16, 320), max_hp(.heisenbug, 0));
    try testing.expectEqual(@as(u16, 480), max_hp(.mandelbug, 0));
    try testing.expectEqual(@as(u16, 240), max_hp(.schrodinbug, 0));
    try testing.expectEqual(@as(u16, 420), max_hp(.bohrbug, 0));
}

test "boss HP grows 30 percent of the base per loop" {
    try testing.expectEqual(@as(u16, 416), max_hp(.heisenbug, 1));
    try testing.expectEqual(@as(u16, 624), max_hp(.mandelbug, 1));
    try testing.expectEqual(@as(u16, 768), max_hp(.mandelbug, 2));
    try testing.expectEqual(@as(u16, 546), max_hp(.bohrbug, 1));
    try testing.expectEqual(@as(u16, 312), max_hp(.schrodinbug, 1));
}

test "the last loop still fits in a u16" {
    try testing.expectEqual(@as(u16, 37200), max_hp(.mandelbug, 255));
    try testing.expectEqual(@as(u16, 24800), max_hp(.heisenbug, 255));
}

test "each stage has its own boss" {
    try testing.expectEqual(BossId.heisenbug, for_stage(0));
    try testing.expectEqual(BossId.mandelbug, for_stage(1));
    try testing.expectEqual(BossId.schrodinbug, for_stage(2));
    try testing.expectEqual(BossId.bohrbug, for_stage(3));
    try testing.expectEqual(BossId.heisenbug, for_stage(4));
}
