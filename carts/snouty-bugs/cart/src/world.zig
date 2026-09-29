//! The World: every piece of mutable play state in one plain struct, and
//! the one global instance (SPEC.md section 13.1). No pointers, no slices,
//! no undefined bytes, so a snapshot is a struct copy; two worlds compare
//! field by field with `history.worlds_equal` (not by bytes: the pool
//! structs have padding). Every field has a default, so `.{}` is a fresh
//! game. Meta-state (state machine, rewind stock, tick_total, history)
//! lives outside, in `main.zig`, `input.zig` and `history.zig`, and is
//! never rewound.
const input = @import("input.zig");
const rng = @import("rng.zig");
const player = @import("player.zig");
const enemies = @import("enemies.zig");
const bullets = @import("bullets.zig");
const fx = @import("fx.zig");
const waves = @import("waves.zig");
const draw = @import("draw.zig");

/// How `simulate()` runs a tick: `.live` emits audio effects,
/// `.silent` (`history.restore` catch-up) runs the same world-side
/// simulation without them and without touching meta-state.
pub const Mode = enum { live, silent };

pub const World = struct {
    /// Ticks of simulated play (frozen while paused; drives animations).
    game_tick: u32 = 0,
    /// xorshift32 state, see `rng.zig`.
    rng: u32 = rng.fallback_seed,
    input: input.State = .{},
    player: player.State = .{},
    enemies: [24]enemies.Enemy = @splat(.{}),
    bolts: [24]bullets.Bolt = @splat(.{}),
    /// SPEC.md section 6: pool of 96.
    enemy_bullets: [96]bullets.EnemyBullet = @splat(.{}),
    fx: [16]fx.Fx = @splat(.{}),
    waves: waves.State = .{},
    bg: draw.BgState = .{},
};

pub var w: World = .{};
