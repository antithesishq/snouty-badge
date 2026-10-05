//! The deathmatch arsenal (M9, PLAN.md "M9 Deathmatch arsenal"): the four
//! deathmatch-only weapons, the weapon pads and the deathmatch projectile
//! pool. Pure (no cart-api), fixed point only, reads and writes only the
//! `match.World`, so every badge in a lockstep match computes the same.
//!
//! The campaign never reaches this file: its GameState and Player are
//! unchanged; the arsenal's per-player state is the per-slot arrays in
//! `state.Match` (ammo_fuzzer, ammo_bomb, ammo_rocket, owned, gc_spin,
//! pad_item, dm_shots).
//!
//! Weapons (`state.Weapon` 4-7; damage in bug units, times
//! `match.pvp_scale` against players):
//! - FUZZER (automatic): hold A, a hitscan shot every `fuzzer_rate` ticks
//!   with +-`fuzzer_jitter` from the World PRNG.
//! - FORK BOMB (thrown grenade): slides, slows, bounces off walls and
//!   closed doors, explodes after `bomb_fuse` ticks (splash, hurts the
//!   thrower too).
//! - SHIP IT (rocket launcher): explodes on a wall, door or body (direct +
//!   splash, hurts the shooter too).
//! - GARBAGE COLLECTOR (hold melee): hold A to spin up, then shreds the
//!   nearest foe in front every `gc_rate` ticks; slows walking while spinning.
//!
//! Pads: legend `@` (`PickupKind.pad`) shows `Match.pad_item[k]`; taking it
//! gives the weapon (or its ammo), the pad comes back after `pad_respawn`
//! with the next weapon of `rotation`. The Debugger `&` in an arena is
//! fixed (never rotates) and comes back after `debugger_respawn`.

const std = @import("std");
const fixed = @import("fixed.zig");
const state = @import("state.zig");
const levels = @import("levels.zig");
const sim = @import("sim.zig");
const match = @import("match.zig");

const Fixed = fixed.Fixed;
const Buttons = state.Buttons;
const Weapon = state.Weapon;
const Match = state.Match;
const Level = levels.Level;

// ---------------------------------------------------------------- tuning

/// Pads: 15 s empty after a pickup; the Debugger (`&`) 60 s.
pub const pad_respawn: u16 = 900;
pub const debugger_respawn: u16 = 3600;
/// What a pad shows, in order; pad n (in level pickup order among the
/// pads) starts at `rotation[n % rotation.len]`.
pub const rotation = [_]Weapon{ .fuzzer, .fork_bomb, .ship_it, .gc, .spray };

/// FUZZER: 1 bug unit (6 HP) per hit, 12 shots a second.
pub const fuzzer_damage: i16 = 1;
pub const fuzzer_rate: u8 = 5;
pub const fuzzer_jitter: fixed.Angle = fixed.deg(4);
pub const fuzzer_pickup: u8 = 50;
pub const max_fuzzer: u8 = 150;

/// FORK BOMB: thrown at `bomb_speed`, each tick the speed is multiplied by
/// `bomb_friction`; up to `bomb_damage` at the centre, 0 at `bomb_radius`.
pub const bomb_speed: Fixed = fixed.from_float(0.12);
pub const bomb_friction: Fixed = fixed.from_float(0.96);
pub const bomb_fuse: u8 = 90;
pub const bomb_damage: i16 = 15;
pub const bomb_radius: Fixed = fixed.from_int(2);
pub const bomb_pickup: u8 = 2;
pub const max_bomb: u8 = 6;

/// SHIP IT: `rocket_damage` on a direct hit (the body hit takes the full
/// splash centre), falling to 0 at `rocket_radius`.
pub const rocket_speed: Fixed = fixed.from_float(0.25);
pub const rocket_damage: i16 = 16;
pub const rocket_radius: Fixed = fixed.from_float(1.75);
pub const rocket_pickup: u8 = 5;
pub const max_rocket: u8 = 20;

/// GARBAGE COLLECTOR: `gc_spinup` ticks of held A, then `gc_damage` every
/// `gc_rate` ticks to the nearest foe within `gc_reach` and `gc_cone`;
/// walking speed times `gc_slow` while it spins.
pub const gc_spinup: u8 = 15;
pub const gc_rate: u8 = 4;
pub const gc_damage: i16 = 2;
pub const gc_reach: Fixed = fixed.from_float(1.0);
pub const gc_cone: fixed.Angle = fixed.deg(30);
pub const gc_slow: Fixed = fixed.from_float(0.7);

/// Explosions stay in the pool this long for the renderer.
pub const blast_ticks: u8 = 12;

/// `state.DmShot.kind`.
pub const kind_none: u8 = 0;
pub const kind_bomb: u8 = 1;
pub const kind_rocket: u8 = 2;
/// Display only: `aux` = 0 bomb blast, 1 rocket blast; `ttl` counts down.
pub const kind_blast: u8 = 3;

/// `Match.owned` bit of an arsenal weapon.
pub fn owned_bit(w: Weapon) u8 {
    const n = @backingInt(w);
    std.debug.assert(n >= 4);
    return @as(u8, 1) << @intCast(n - 4);
}

// ---------------------------------------------------------------- API
// Lead pre-work: signatures fixed, bodies are Track A's.

/// At match init (after the players exist): every pad's first weapon,
/// empty pool, no arsenal ammo.
pub fn init(m: *Match, level: *const Level) void {
    _ = m;
    _ = level;
}

/// On respawn (slot `i`): arsenal weapons and ammo are lost (Quake rules).
pub fn reset_slot(m: *Match, i: usize) void {
    _ = m;
    _ = i;
}

/// Slot `i` walked onto pickup `k`, a pad (`PickupKind.pad`) that is
/// present: gives `m.pad_item[k]` (spray: as `sim.apply_pickup(.spray_can)`;
/// an arsenal weapon: owned bit + its pickup ammo, selects it if newly
/// owned), advances `pad_item[k]` along `rotation`, and returns the pad's
/// respawn ticks. The caller takes the pickup and sets the timer.
pub fn take_pad(w: *match.World, i: usize, k: usize) u16 {
    _ = w;
    _ = i;
    _ = k;
    return pad_respawn;
}

/// Respawn ticks of an arena pickup of `kind` (pad, Debugger, the rest).
pub fn respawn_ticks(kind: levels.PickupKind) u16 {
    return switch (kind) {
        .pad => pad_respawn,
        .debugger => debugger_respawn,
        else => match.pickup_respawn,
    };
}

/// Can slot `i` fire weapon `wp` (owned, with ammo; swatter and GC always
/// once owned)? Campaign weapons read the Player as `sim` does.
pub fn has_ammo(m: *const Match, i: usize, wp: Weapon) bool {
    _ = m;
    _ = i;
    _ = wp;
    return false;
}

/// The HUD's ammo count for slot `i`'s current weapon (null = no ammo
/// counter: swatter, GC).
pub fn ammo(m: *const Match, i: usize) ?u8 {
    _ = m;
    _ = i;
    return null;
}

/// Replaces `sim.update_weapon` in a match for slot `i` (swapped into
/// `w.gs.player`): Select cycles every owned weapon with ammo, campaign
/// and arsenal, in enum order; weapons 0-3 then go to `sim.update_weapon`
/// (with Select masked); 4-7 fire here. Hitscan damage goes into
/// `shot.rivals[k].damage` like the campaign weapons; projectiles go to
/// the pool with `owner = i`.
pub fn update(w: *match.World, level: *const Level, i: usize, b: Buttons, shot: *sim.Shot) void {
    sim.update_weapon(&w.gs, level, b, shot);
    _ = i;
}

/// Once a tick after the players moved: move fork bombs and rockets,
/// explode them (splash via `sim.damage_slot` with the owner's credit,
/// self-damage included), age the blasts.
pub fn step_shots(w: *match.World, level: *const Level) void {
    _ = w;
    _ = level;
}

/// Walking speed factor for slot `i` (GC spinning: `gc_slow`, else 1.0).
pub fn walk_scale(m: *const Match, i: usize) Fixed {
    _ = m;
    _ = i;
    return fixed.one;
}
