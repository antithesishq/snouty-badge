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
const pickups = @import("pickups.zig");
const formations = @import("formations.zig");
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
    /// Player shots (PLAN.md M6: 64, for the 5-way fuzzer and three forks).
    bolts: [64]bullets.Bolt = @splat(.{}),
    /// PLAN.md M7: pool of 128 (was 96).
    enemy_bullets: [bullets.enemy_pool_len]bullets.EnemyBullet = @splat(.{}),
    fx: [16]fx.Fx = @splat(.{}),
    /// Powerup crates (PLAN.md M6), and the drop sequence cursor.
    pickups: [4]pickups.Pickup = @splat(.{}),
    drops: pickups.Drops = .{},
    /// Enemy formations (PLAN.md M7, 1942's POW): `formations.zig`.
    formations: [formations.slots]formations.Formation = @splat(.{}),
    /// Next formation id to hand out (wraps, skips 0).
    next_formation_id: u8 = 1,
    /// Rank mercy (PLAN.md M7 "Rank"): +80 at each auto-rewind resume (and
    /// each probe hit), -1 every 120 ticks; subtracted from the rank.
    mercy: u16 = 0,
    waves: waves.State = .{},
    bg: draw.BgState = .{},
};

pub var w: World = .{};
