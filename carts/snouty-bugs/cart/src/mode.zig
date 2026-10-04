//! The game mode, picked on the title with up / down (A or Start plays):
//! NORMAL (rewind stock), HARDCORE (no stock, hits paid from the fuel bar,
//! every powerup lost) and SUPER-HARDCORE (hardcore rules at the pace of
//! the 2026-10-04 catch-up clock). Meta-state like `main.zig`'s: set by
//! `main.new_game` and constant through a game, so the simulation may read
//! it in both simulate modes without breaking the identity check.
pub const Mode = enum(u8) { normal = 0, hardcore = 1, super_hardcore = 2 };
pub const count: u8 = 3;

pub var current: Mode = .normal;

/// Hardcore rules (SPEC.md 5.3): no rewind stock, fuel-paid hits.
pub fn hardcore() bool {
    return current != .normal;
}

/// How `waves.zig` runs the table clock on a thin field (PLAN.md M7
/// "Catch-up"): while fewer than `field_floor` enemies are on the field it
/// runs `catchup` ticks a tick. `rush` also runs the difficulty clock (the
/// fire ramp and rank's stage seconds) with it; otherwise those count real
/// ticks, so a fast player meets the next wave sooner but no harder.
pub const Pace = struct {
    field_floor: u32,
    catchup: u32,
    rush: bool,
};

/// NORMAL and HARDCORE hurry the next wave in only on an empty field (so
/// a wave never lands on top of a live one) and keep the difficulty on
/// real ticks; SUPER-HARDCORE is the catch-up of c65730d unchanged.
pub fn pace() Pace {
    return switch (current) {
        .normal, .hardcore => .{ .field_floor = 1, .catchup = 3, .rush = false },
        .super_hardcore => .{ .field_floor = 3, .catchup = 4, .rush = true },
    };
}
