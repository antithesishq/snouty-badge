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
//! Drops: a dying player's weapon in hand stays on the floor with its
//! ammo (`drop_weapon`) for anyone to walk over (`take_drops`).
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

/// FUZZER: 2 bug units (12 HP) per hit, 12 shots a second (M9 tuning: at
/// PLAN's 1 unit it did 1.2 HP a tick, less than the starting zapper's 1.5).
pub const fuzzer_damage: i16 = 2;
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

/// At match init (after the players exist): every pad's first weapon.
/// The empty pool and the zero arsenal ammo are the defaults of the fresh
/// Match that `match.init_n` builds first.
pub fn init(m: *Match, level: *const Level) void {
    var n: usize = 0;
    const np = @min(level.pickups.len, state.max_match_pickups);
    for (level.pickups[0..np], 0..) |pk, k| {
        if (pk.kind != .pad) continue;
        m.pad_item[k] = @backingInt(rotation[n % rotation.len]);
        n += 1;
    }
}

/// On respawn (slot `i`): arsenal weapons and ammo are lost (Quake rules).
pub fn reset_slot(m: *Match, i: usize) void {
    m.ammo_fuzzer[i] = 0;
    m.ammo_bomb[i] = 0;
    m.ammo_rocket[i] = 0;
    m.owned[i] = 0;
    m.gc_spin[i] = 0;
}

/// Ammo per pickup and the cap of the arsenal weapons (index weapon - 4;
/// the Garbage Collector has none).
const pickup_ammo = [4]u8{ fuzzer_pickup, bomb_pickup, rocket_pickup, 0 };
const max_ammo = [4]u8{ max_fuzzer, max_bomb, max_rocket, 0 };

/// Slot `i`'s ammo counter of arsenal weapon `wp` (fuzzer, fork bomb,
/// ship it; the GC has none and maps to the rocket's, never read for it).
fn ammo_ref(m: *Match, i: usize, wp: Weapon) *u8 {
    return switch (wp) {
        .fuzzer => &m.ammo_fuzzer[i],
        .fork_bomb => &m.ammo_bomb[i],
        else => &m.ammo_rocket[i],
    };
}

/// The weapon after `item` in `rotation` (the first for anything else).
fn rotate(item: u8) u8 {
    for (rotation, 0..) |r, k| {
        if (@backingInt(r) == item) return @backingInt(rotation[(k + 1) % rotation.len]);
    }
    return @backingInt(rotation[0]);
}

/// Slot `i` walked onto pickup `k`, a pad (`PickupKind.pad`) that is
/// present: gives `m.pad_item[k]` (spray: as `sim.apply_pickup(.spray_can)`;
/// an arsenal weapon: owned bit + its pickup ammo, selects it if newly
/// owned), advances `pad_item[k]` along `rotation`, and returns the pad's
/// respawn ticks. The caller takes the pickup and sets the timer.
/// Works on `m.players[i]` (match.zig calls it with the slot swapped out).
pub fn take_pad(w: *match.World, i: usize, k: usize) u16 {
    const m = &w.m;
    const p = &m.players[i];
    const item = m.pad_item[k];
    m.pad_item[k] = rotate(item);
    if (item < 4) {
        sim.apply_pickup(p, .spray_can);
    } else {
        give(m, i, @fromBackingInt(@intCast(item)), pickup_ammo[item - 4]);
    }
    return pad_respawn;
}

/// Slot `i` gets weapon `wp` with `a` ammo: added to its pool (up to the
/// cap) if it has the weapon already, else the weapon, selected. The
/// zapper everyone has; the Garbage Collector has no ammo.
fn give(m: *Match, i: usize, wp: Weapon, a: u8) void {
    const p = &m.players[i];
    switch (wp) {
        .swatter => {},
        .zapper => p.ammo_zapper = @min(sim.max_zapper, @as(u16, p.ammo_zapper) + a),
        .spray => {
            p.ammo_spray = @min(sim.max_spray, @as(u16, p.ammo_spray) + a);
            if (!p.has_spray) p.weapon = .spray;
            p.has_spray = true;
        },
        .debugger => {
            p.ammo_debugger = @min(sim.max_debugger, @as(u16, p.ammo_debugger) + a);
            if (!p.has_debugger) p.weapon = .debugger;
            p.has_debugger = true;
        },
        else => {
            const n = @backingInt(wp);
            const bit = owned_bit(wp);
            if (m.owned[i] & bit == 0) p.weapon = wp;
            m.owned[i] |= bit;
            const r = ammo_ref(m, i, wp);
            r.* = @min(max_ammo[n - 4], @as(u16, r.*) + a);
        },
    }
}

// ---------------------------------------------------------------- drops

/// A dropped weapon lies there 30 s, blinking for the last `drop_blink`.
pub const drop_ticks: u16 = 1800;
pub const drop_blink: u16 = 180;
/// A living player this close to a drop's centre takes it.
pub const drop_reach: Fixed = fixed.from_float(0.5);

/// At slot `i`'s death (before the respawn resets the loadout): the
/// weapon in hand falls where the player stood, with the ammo it had, for
/// the others to take (the swatter, and a weapon with no ammo left, fall
/// as nothing; the Garbage Collector needs none). It takes a free `Match.drops` entry, or
/// the one closest to vanishing.
pub fn drop_weapon(m: *Match, i: usize) void {
    const p = &m.players[i];
    const wp = p.weapon;
    if (wp == .swatter) return;
    const a: u8 = ammo(m, i) orelse 0;
    if (a == 0 and wp != .gc) return;
    var k: usize = 0;
    for (m.drops, 0..) |d, j| {
        if (d.timer < m.drops[k].timer) k = j;
    }
    m.drops[k] = .{ .x = p.x, .y = p.y, .timer = drop_ticks, .weapon = @backingInt(wp), .ammo = a, .owner = @intCast(i) };
}

/// Slot `i` (alive, after its move) takes every drop within `drop_reach`
/// but its own.
pub fn take_drops(m: *Match, i: usize) void {
    const p = &m.players[i];
    for (&m.drops) |*d| {
        if (d.timer == 0 or d.owner == i or !near(p.x, p.y, d.x, d.y, drop_reach)) continue;
        give(m, i, @fromBackingInt(@intCast(d.weapon)), d.ammo);
        d.* = .{};
    }
}

/// Once a tick: drops age and vanish.
pub fn tick_drops(m: *Match) void {
    for (&m.drops) |*d| d.timer -|= 1;
}

/// Respawn ticks of an arena pickup of `kind` (pad, Debugger, the rest).
pub fn respawn_ticks(kind: levels.PickupKind) u16 {
    return switch (kind) {
        .pad => pad_respawn,
        .debugger => debugger_respawn,
        else => match.pickup_respawn,
    };
}

/// `has_ammo` for player record `p` of slot `i` (which may be the
/// swapped-in scratch copy).
fn can_fire(m: *const Match, p: *const state.Player, i: usize, wp: Weapon) bool {
    return switch (wp) {
        .swatter => true,
        .zapper => p.ammo_zapper > 0,
        .spray => p.has_spray and p.ammo_spray > 0,
        .debugger => p.has_debugger and p.ammo_debugger > 0,
        else => m.owned[i] & owned_bit(wp) != 0 and (wp == .gc or ammo_ref(@constCast(m), i, wp).* > 0),
    };
}

/// Can slot `i` fire weapon `wp` (owned, with ammo; swatter and GC always
/// once owned)? Campaign weapons read the Player as `sim` does.
pub fn has_ammo(m: *const Match, i: usize, wp: Weapon) bool {
    return can_fire(m, &m.players[i], i, wp);
}

/// The HUD's ammo count for slot `i`'s current weapon (null = no ammo
/// counter: swatter, GC).
pub fn ammo(m: *const Match, i: usize) ?u8 {
    const p = &m.players[i];
    return switch (p.weapon) {
        .swatter, .gc => null,
        .zapper => p.ammo_zapper,
        .spray => p.ammo_spray,
        .debugger => p.ammo_debugger,
        else => ammo_ref(@constCast(m), i, p.weapon).*,
    };
}

/// Ticks a rocket flies before it is dropped unexploded (24 cells; every
/// arena is walled in, so it meets a wall long before).
pub const rocket_ttl: u8 = 96;
/// Rocket movement sub-steps per tick (0.0625 cells each), so it never
/// skips a wall corner or a player's hit radius.
const rocket_substeps = 4;

/// Replaces `sim.update_weapon` in a match for slot `i` (swapped into
/// `w.gs.player`): Select cycles every owned weapon with ammo, campaign
/// and arsenal, in enum order; weapons 0-3 then go to `sim.update_weapon`
/// (with Select masked); 4-7 fire here. Hitscan damage goes into
/// `shot.rivals[k].damage` like the campaign weapons; projectiles go to
/// the pool with `owner = i`. `shot.fired` (accuracy) is set per fuzzer
/// shot, throw and rocket, and per Garbage Collector shred that met
/// something (holding it in the air is no shot).
pub fn update(w: *match.World, level: *const Level, i: usize, b: Buttons, shot: *sim.Shot) void {
    const s = &w.gs;
    const m = &w.m;
    const p = &s.player;
    if (b.select and !p.prev.select) {
        var n = @backingInt(p.weapon);
        for (0..7) |_| {
            n = (n + 1) & 7;
            if (can_fire(m, p, i, @fromBackingInt(@intCast(n)))) {
                p.weapon = @fromBackingInt(@intCast(n));
                break;
            }
        }
    }
    const wp = p.weapon;
    if (wp != .gc or !b.a) m.gc_spin[i] = 0;
    if (@backingInt(wp) < 4) {
        var b2 = b;
        b2.select = false;
        sim.update_weapon(s, level, b2, shot);
        return;
    }
    if (p.fire_cooldown > 0) p.fire_cooldown -= 1;
    if (!b.a) return;
    // The GC spins up while A is held, whatever the cooldown.
    if (wp == .gc and m.gc_spin[i] < gc_spinup) {
        m.gc_spin[i] += 1;
        return;
    }
    if (p.fire_cooldown != 0) return;
    switch (wp) {
        .gc => {
            p.fire_cooldown = gc_rate;
            if (!sim.melee(s, level, shot, gc_reach, gc_cone, gc_damage)) return;
        },
        else => {
            const a = ammo_ref(m, i, wp);
            if (a.* == 0) return;
            a.* -= 1;
            if (wp == .fuzzer) {
                const t = sim.cast(s, level, sim.jittered(s, p.angle, fuzzer_jitter), sim.max_ray, shot);
                sim.apply_hit(s, t, fuzzer_damage, shot);
            } else {
                launch(m, p, i, wp);
            }
            p.fire_cooldown = sim.fire_rate(wp);
        },
    }
    s.last_shot = s.tick;
    shot.fired = true;
}

/// A fork bomb or a rocket from the player's centre along its facing into
/// the lowest free pool entry; a full pool drops it (the ammo is spent).
fn launch(m: *Match, p: *const state.Player, i: usize, wp: Weapon) void {
    const rocket = wp == .ship_it;
    const v = if (rocket) rocket_speed else bomb_speed;
    for (&m.dm_shots) |*sh| {
        if (sh.kind != kind_none) continue;
        sh.* = .{
            .x = p.x,
            .y = p.y,
            .vx = fixed.mul(fixed.cos(p.angle), v),
            .vy = fixed.mul(fixed.sin(p.angle), v),
            .kind = if (rocket) kind_rocket else kind_bomb,
            .ttl = if (rocket) rocket_ttl else bomb_fuse,
            .owner = @intCast(i),
        };
        return;
    }
}

/// Once a tick after the players moved: move fork bombs and rockets,
/// explode them (splash via `sim.damage_slot` with the owner's credit,
/// self-damage included), age the blasts.
pub fn step_shots(w: *match.World, level: *const Level) void {
    const s = &w.gs;
    for (&w.m.dm_shots) |*sh| {
        switch (sh.kind) {
            kind_bomb => {
                // Friction, then each axis on its own: a step into a solid
                // cell (wall, closed door) reflects that axis instead.
                sh.vx = fixed.mul(sh.vx, bomb_friction);
                sh.vy = fixed.mul(sh.vy, bomb_friction);
                if (sim.is_solid(s, level, fixed.to_int(sh.x + sh.vx), fixed.to_int(sh.y))) sh.vx = -sh.vx else sh.x += sh.vx;
                if (sim.is_solid(s, level, fixed.to_int(sh.x), fixed.to_int(sh.y + sh.vy))) sh.vy = -sh.vy else sh.y += sh.vy;
                sh.ttl -= 1;
                if (sh.ttl == 0) explode(w, level, sh, sh.x, sh.y, state.no_one);
                continue;
            },
            kind_rocket => if (fly(w, level, sh)) continue,
            kind_blast => {},
            else => continue,
        }
        sh.ttl -= 1;
        if (sh.ttl == 0) sh.* = .{};
    }
}

/// One tick of a rocket in `rocket_substeps` steps; true when it exploded:
/// on a wall or shut door (at its last open position, so the blast is not
/// inside the wall), on any living player but its owner (a direct hit), or
/// on a living bug.
fn fly(w: *match.World, level: *const Level, sh: *state.DmShot) bool {
    const s = &w.gs;
    const m = &w.m;
    for (0..rocket_substeps) |_| {
        const ox = sh.x;
        const oy = sh.y;
        sh.x += sh.vx >> 2;
        sh.y += sh.vy >> 2;
        if (sim.is_solid(s, level, fixed.to_int(sh.x), fixed.to_int(sh.y))) {
            explode(w, level, sh, ox, oy, state.no_one);
            return true;
        }
        for (0..state.max_players) |j| {
            if (j == sh.owner or !m.alive(j) or !near(sh.x, sh.y, m.players[j].x, m.players[j].y, hit_radius)) continue;
            explode(w, level, sh, sh.x, sh.y, @intCast(j));
            return true;
        }
        for (&s.enemies) |*e| {
            if (!sim.living(e) or !near(sh.x, sh.y, e.x, e.y, bug_radius)) continue;
            explode(w, level, sh, sh.x, sh.y, state.no_one);
            return true;
        }
    }
    return false;
}

/// A rocket's hit radius around a player's centre (as enemy shots) and
/// around a bug's (every kind's `sim.stats` radius).
const hit_radius: Fixed = fixed.from_float(0.35);
const bug_radius: Fixed = fixed.from_float(0.3);

fn near(x: Fixed, y: Fixed, tx: Fixed, ty: Fixed, r: Fixed) bool {
    const dx: i64 = tx - x;
    const dy: i64 = ty - y;
    return dx * dx + dy * dy < @as(i64, r) * r;
}

/// The blast of `sh` at (x, y): bugs and players within the radius and in
/// sight of the centre take the damage falling off linearly to 0 at the
/// radius (players times `match.pvp_scale`, credited to the owner, who is
/// hurt too; the owner's teammates are spared); `direct` (a slot or
/// `no_one`) takes the full centre damage. One hit for the owner's
/// accuracy however many foes it hurt. The entry becomes a `kind_blast`.
fn explode(w: *match.World, level: *const Level, sh: *state.DmShot, x: Fixed, y: Fixed, direct: u8) void {
    const s = &w.gs;
    const m = &w.m;
    const rocket = sh.kind == kind_rocket;
    const top: i16 = if (rocket) rocket_damage else bomb_damage;
    const r: Fixed = if (rocket) rocket_radius else bomb_radius;
    const owner = sh.owner;
    for (&s.enemies, 0..) |*e, k| {
        if (!sim.living(e)) continue;
        const d = falloff(s, level, x, y, e.x, e.y, top, r);
        if (d > 0) sim.damage_enemy(s, k, d);
    }
    var hit = false;
    for (0..state.max_players) |j| {
        if (!m.alive(j) or (j != owner and !m.foes(owner, j))) continue;
        const pl = &m.players[j];
        const d = if (j == direct) top * match.pvp_scale else falloff(s, level, x, y, pl.x, pl.y, top * match.pvp_scale, r);
        if (d > 0 and sim.damage_slot(m, j, d, owner) and j != owner) hit = true;
    }
    if (hit) m.hits[owner] +%= 1;
    sh.* = .{ .x = x, .y = y, .kind = kind_blast, .ttl = blast_ticks, .owner = owner, .aux = @intFromBool(rocket) };
}

/// `top` at (x, y) falling off linearly to 0 at distance `r`; 0 beyond it
/// or out of sight.
fn falloff(s: *const state.GameState, level: *const Level, x: Fixed, y: Fixed, tx: Fixed, ty: Fixed, top: i16, r: Fixed) i16 {
    const dx: i64 = tx - x;
    const dy: i64 = ty - y;
    const d2 = dx * dx + dy * dy;
    if (d2 >= @as(i64, r) * r or !sim.line_of_sight(s, level, x, y, tx, ty)) return 0;
    // r <= 2 cells, so d2 / 4 fits a u32 (32-bit sqrt and divide only).
    const d: i32 = @as(i32, std.math.sqrt(@as(u32, @intCast(d2 >> 2)))) * 2;
    return @intCast(@divTrunc(@as(i32, top) * (r - d), r));
}

/// Walking speed factor for slot `i` (GC spinning: `gc_slow`, else 1.0).
pub fn walk_scale(m: *const Match, i: usize) Fixed {
    return if (m.gc_spin[i] > 0) gc_slow else fixed.one;
}

comptime {
    // The cooldowns sim.fire_rate gives must be the tuning above.
    if (sim.fire_rate(.fuzzer) != fuzzer_rate or sim.fire_rate(.gc) != gc_rate) @compileError("sim.fire_rate disagrees with arsenal tuning");
    // `falloff`'s 32-bit math.
    if (@max(bomb_radius, rocket_radius) > fixed.from_int(2)) @compileError("blast radius over 2 cells");
}
