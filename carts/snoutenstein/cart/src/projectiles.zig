//! Projectiles: enemy spit and web (movement, wall collision, player
//! hits) and the player's Debugger bolt (M6: bursts on a wall or near an
//! enemy, splash damage to enemies, never hurts the player) with its
//! display-only burst. Called once per tick from `sim.step` after
//! `ai.update`. Fixed point only, no cart-api. Values from SPEC.md
//! sections 7 and 8, PLAN.md M3 "Contract: projectiles (track B)" and M6.
const std = @import("std");
const fixed = @import("fixed.zig");
const state = @import("state.zig");
const levels = @import("levels.zig");
const sim = @import("sim.zig");

const GameState = state.GameState;
const Level = levels.Level;
const Fixed = fixed.Fixed;

pub const kind_none: u8 = 0;
pub const kind_spit: u8 = 1;
pub const kind_web: u8 = 2;
/// The Debugger's bolt (player-owned: hurts enemies, never the player).
pub const kind_debug: u8 = 3;
/// A bolt's burst: display only (no movement, no damage), `burst_ticks` long.
pub const kind_burst: u8 = 4;

/// Cells per tick.
pub const spit_speed: Fixed = fixed.from_float(0.08);
pub const web_speed: Fixed = fixed.from_float(0.06);
pub const debug_speed: Fixed = fixed.from_float(0.10);
/// Ticks a spit or web lives (it moves at most this many times).
pub const ttl_ticks: u8 = 180;
/// Ticks a Debugger bolt lives (12 cells at `debug_speed`).
pub const debug_ttl: u8 = 120;
/// A bolt bursts when its centre comes within this of a living enemy centre.
pub const debug_trigger: Fixed = fixed.from_float(0.4);
const debug_trigger_sq: i64 = @as(i64, debug_trigger) * debug_trigger;
/// Every living enemy centre within this of the burst point takes
/// `burst_damage` (no line-of-sight test).
pub const burst_radius: Fixed = fixed.from_float(1.5);
const burst_radius_sq: i64 = @as(i64, burst_radius) * burst_radius;
pub const burst_damage: i16 = 12;
/// White flash ticks on each enemy a burst hits (overrides `sim.flash_ticks`).
pub const burst_flash: u8 = 6;
/// Display lifetime of a `kind_burst` entry.
pub const burst_ticks: u8 = 6;
/// Spawn offset along the angle, so a shot does not start in the
/// spawner's own cell.
pub const spawn_offset: Fixed = fixed.from_float(0.4);
/// Hit radius around the player centre.
pub const hit_radius: Fixed = fixed.from_float(0.35);
const hit_radius_sq: i64 = @as(i64, hit_radius) * hit_radius;
pub const spit_damage: i16 = 10;
pub const web_damage: i16 = 6;
/// Ticks of movement freeze a web hit applies (`sim.step` counts it down).
pub const web_freeze_ticks: u8 = 45;

fn speed(kind: u8) Fixed {
    return switch (kind) {
        kind_web => web_speed,
        kind_debug => debug_speed,
        else => spit_speed,
    };
}

fn ttl_for(kind: u8) u8 {
    return switch (kind) {
        kind_debug => debug_ttl,
        kind_burst => burst_ticks,
        else => ttl_ticks,
    };
}

/// Launch a projectile of `kind` from (x, y) along `angle`. Returns false
/// when the pool is full. Takes the lowest free slot (deterministic).
pub fn spawn(s: *GameState, x: Fixed, y: Fixed, angle: fixed.Angle, kind: u8) bool {
    return spawn_tagged(s, x, y, angle, kind, 0);
}

/// `spawn` with `aux[0] = tag`: a deathmatch Debugger bolt's owner
/// (slot + 1; the campaign's bolts are 0).
pub fn spawn_tagged(s: *GameState, x: Fixed, y: Fixed, angle: fixed.Angle, kind: u8, tag: u8) bool {
    std.debug.assert(kind != kind_none);
    const c = fixed.cos(angle);
    const sn = fixed.sin(angle);
    const v = speed(kind);
    for (&s.projectiles) |*p| {
        if (p.kind != kind_none) continue;
        p.* = .{
            .x = x + fixed.mul(c, spawn_offset),
            .y = y + fixed.mul(sn, spawn_offset),
            .vx = fixed.mul(c, v),
            .vy = fixed.mul(sn, v),
            .kind = kind,
            .ttl = ttl_for(kind),
            .aux = .{ tag, 0 },
        };
        return true;
    }
    return false;
}

pub fn update(s: *GameState, level: *const Level) void {
    for (&s.projectiles) |*p| {
        switch (p.kind) {
            kind_none => continue,
            kind_burst => {},
            kind_debug => if (update_debug(s, level, p)) continue,
            else => if (update_enemy_shot(s, level, p)) continue,
        }
        p.ttl -= 1;
        if (p.ttl == 0) p.* = .{};
    }
}

/// Move a spit or web; true when it ended this tick (wall or player hit).
fn update_enemy_shot(s: *GameState, level: *const Level, p: *state.Projectile) bool {
    p.x += p.vx;
    p.y += p.vy;
    if (sim.is_solid(s, level, fixed.to_int(p.x), fixed.to_int(p.y))) {
        p.* = .{};
        return true;
    }
    const dx: i64 = p.x - s.player.x;
    const dy: i64 = p.y - s.player.y;
    if (dx * dx + dy * dy < hit_radius_sq) {
        if (p.kind == kind_web) {
            sim.damage_player(s, web_damage);
            if (s.player.grace == 0) s.player.frozen = web_freeze_ticks;
        } else {
            sim.damage_player(s, spit_damage);
        }
        p.* = .{};
        return true;
    }
    return false;
}

/// Move a Debugger bolt; true when it burst this tick. A wall bursts it
/// at its position before the move (so the burst is not drawn inside the
/// wall), a living enemy within `debug_trigger` at its new position.
/// Never tests against the player.
fn update_debug(s: *GameState, level: *const Level, p: *state.Projectile) bool {
    const ox = p.x;
    const oy = p.y;
    p.x += p.vx;
    p.y += p.vy;
    if (sim.is_solid(s, level, fixed.to_int(p.x), fixed.to_int(p.y))) {
        burst(s, p, ox, oy);
        return true;
    }
    for (&s.enemies) |*e| {
        if (!sim.living(e)) continue;
        const dx: i64 = e.x - p.x;
        const dy: i64 = e.y - p.y;
        if (dx * dx + dy * dy < debug_trigger_sq) {
            burst(s, p, p.x, p.y);
            return true;
        }
    }
    return false;
}

/// `burst_damage` to every living enemy within `burst_radius` of (x, y),
/// a `burst_flash` on each, then the slot becomes a `kind_burst` there.
fn burst(s: *GameState, p: *state.Projectile, x: Fixed, y: Fixed) void {
    burst_enemies(s, x, y);
    p.* = .{ .x = x, .y = y, .kind = kind_burst, .ttl = burst_ticks };
}

fn burst_enemies(s: *GameState, x: Fixed, y: Fixed) void {
    for (&s.enemies, 0..) |*e, i| {
        if (!sim.living(e)) continue;
        const dx: i64 = e.x - x;
        const dy: i64 = e.y - y;
        if (dx * dx + dy * dy >= burst_radius_sq) continue;
        sim.damage_enemy(s, i, burst_damage);
        e.flash = burst_flash;
    }
}

// ---------------------------------------------------------------- deathmatch

/// Deathmatch (M7, M8): `update` for a match (`match.step`), where the
/// players live in `m`, not in `s.player`. Enemy shots hit any living
/// player (the first in slot order within `hit_radius`). A Debugger bolt
/// (owner `aux[0] - 1`) also bursts on a living foe of its owner, and its
/// burst hurts every living player within `burst_radius` but the owner's
/// teammates, the owner too (a self-frag counts), by `burst_damage *
/// pvp_scale`, credited to the owner; one hit for the owner's accuracy
/// however many foes it hurt.
pub fn update_match(s: *GameState, level: *const Level, m: *state.Match, pvp_scale: i16) void {
    for (&s.projectiles) |*p| {
        switch (p.kind) {
            kind_none => continue,
            kind_burst => {},
            kind_debug => if (update_debug_match(s, level, m, p, pvp_scale)) continue,
            else => if (update_enemy_shot_match(s, level, m, p)) continue,
        }
        p.ttl -= 1;
        if (p.ttl == 0) p.* = .{};
    }
}

fn player_alive(m: *const state.Match, slot: usize) bool {
    return m.alive(slot);
}

fn near(x: Fixed, y: Fixed, px: Fixed, py: Fixed, r_sq: i64) bool {
    const dx: i64 = x - px;
    const dy: i64 = y - py;
    return dx * dx + dy * dy < r_sq;
}

fn update_enemy_shot_match(s: *GameState, level: *const Level, m: *state.Match, p: *state.Projectile) bool {
    p.x += p.vx;
    p.y += p.vy;
    if (sim.is_solid(s, level, fixed.to_int(p.x), fixed.to_int(p.y))) {
        p.* = .{};
        return true;
    }
    for (0..state.max_players) |slot| {
        const pl = &m.players[slot];
        if (!player_alive(m, slot) or !near(p.x, p.y, pl.x, pl.y, hit_radius_sq)) continue;
        const sl = slot;
        if (p.kind == kind_web) {
            _ = sim.damage_slot(m, sl, web_damage, state.by_bug);
            if (pl.grace == 0) pl.frozen = web_freeze_ticks;
        } else {
            _ = sim.damage_slot(m, sl, spit_damage, state.by_bug);
        }
        p.* = .{};
        return true;
    }
    return false;
}

fn update_debug_match(s: *GameState, level: *const Level, m: *state.Match, p: *state.Projectile, pvp_scale: i16) bool {
    const ox = p.x;
    const oy = p.y;
    p.x += p.vx;
    p.y += p.vy;
    if (sim.is_solid(s, level, fixed.to_int(p.x), fixed.to_int(p.y))) {
        burst_match(s, m, p, ox, oy, pvp_scale);
        return true;
    }
    var trigger = false;
    for (&s.enemies) |*e| {
        if (sim.living(e) and near(e.x, e.y, p.x, p.y, debug_trigger_sq)) trigger = true;
    }
    const owner = p.aux[0] -% 1;
    for (0..state.max_players) |slot| {
        const pl = &m.players[slot];
        const foe = owner >= state.max_players or m.foes(owner, slot);
        if (foe and slot != owner and player_alive(m, slot) and near(pl.x, pl.y, p.x, p.y, debug_trigger_sq)) trigger = true;
    }
    if (!trigger) return false;
    burst_match(s, m, p, p.x, p.y, pvp_scale);
    return true;
}

fn burst_match(s: *GameState, m: *state.Match, p: *state.Projectile, x: Fixed, y: Fixed, pvp_scale: i16) void {
    burst_enemies(s, x, y);
    const owner = p.aux[0] -% 1;
    const by: u8 = if (owner < state.max_players) owner else state.by_bug;
    var hit = false;
    for (0..state.max_players) |slot| {
        const pl = &m.players[slot];
        if (!player_alive(m, slot) or !near(pl.x, pl.y, x, y, burst_radius_sq)) continue;
        // No friendly fire: the owner's teammates are spared (the owner is not).
        if (owner < state.max_players and slot != owner and !m.foes(owner, slot)) continue;
        if (sim.damage_slot(m, slot, burst_damage * pvp_scale, by) and owner < state.max_players and slot != owner) hit = true;
    }
    if (hit) m.hits[owner] +%= 1;
    p.* = .{ .x = x, .y = y, .kind = kind_burst, .ttl = burst_ticks };
}

pub fn live_count(s: *const GameState) usize {
    var n: usize = 0;
    for (s.projectiles) |p| {
        if (p.kind != kind_none) n += 1;
    }
    return n;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const level_parse = @import("level_parse.zig");

// Player at (1.5, 1.5) facing east; open floor to x = 9, wall at x = 10.
const hall_src =
    \\11111111111
    \\1S>.......1
    \\1.........1
    \\1.........1
    \\11111111111
;

const east: fixed.Angle = 0;
const west: fixed.Angle = 32768;
const cell_centre = fixed.half;

fn hall(st: *level_parse.Parsed) !Level {
    return level_parse.parse_level(st, "hall", hall_src, 0);
}

test "spawn fills slots, offsets 0.4 ahead, and fails when 12 are live" {
    var st: level_parse.Parsed = undefined;
    const lv = try hall(&st);
    var s: GameState = undefined;
    sim.init(&s, &lv, 0, 1);
    const x0 = fixed.from_int(5) + cell_centre;
    const y0 = fixed.from_int(3) + cell_centre;
    try testing.expect(spawn(&s, x0, y0, east, kind_spit));
    const p = s.projectiles[0];
    try testing.expectEqual(kind_spit, p.kind);
    try testing.expectEqual(x0 + spawn_offset, p.x);
    try testing.expectEqual(y0, p.y);
    try testing.expectEqual(spit_speed, p.vx);
    try testing.expectEqual(@as(Fixed, 0), p.vy);
    try testing.expectEqual(ttl_ticks, p.ttl);
    for (1..state.max_projectiles) |_| try testing.expect(spawn(&s, x0, y0, west, kind_web));
    try testing.expectEqual(@as(usize, state.max_projectiles), live_count(&s));
    try testing.expectEqual(-web_speed, s.projectiles[1].vx);
    try testing.expect(!spawn(&s, x0, y0, east, kind_spit));
    // Freeing one slot makes room again, and it is the one reused.
    s.projectiles[4] = .{};
    try testing.expect(spawn(&s, x0, y0, east, kind_spit));
    try testing.expectEqual(kind_spit, s.projectiles[4].kind);
}

test "a spit flying at a wall dies on the wall cell" {
    var st: level_parse.Parsed = undefined;
    const lv = try hall(&st);
    var s: GameState = undefined;
    sim.init(&s, &lv, 0, 1);
    // Row 3, well away from the player on row 1.
    try testing.expect(spawn(&s, fixed.from_int(2) + cell_centre, fixed.from_int(3) + cell_centre, east, kind_spit));
    var ticks: usize = 0;
    var last_x: Fixed = 0;
    while (s.projectiles[0].kind != kind_none) : (ticks += 1) {
        try testing.expect(ticks < ttl_ticks);
        last_x = s.projectiles[0].x;
        try testing.expect(fixed.to_int(last_x) <= 9);
        update(&s, &lv);
    }
    // It died on the move that took it into x = 10, the wall.
    try testing.expectEqual(@as(i32, 10), fixed.to_int(last_x + spit_speed));
    try testing.expectEqual(@as(i32, 9), fixed.to_int(last_x));
    try testing.expectEqual(@as(i16, 100), s.player.hp);
}

test "a spit aimed at the player from 3 cells hits on tick 29 for 8 HP" {
    var st: level_parse.Parsed = undefined;
    const lv = try hall(&st);
    var s: GameState = undefined;
    sim.init(&s, &lv, 0, 1);
    try testing.expect(spawn(&s, s.player.x + fixed.from_int(3), s.player.y, west, kind_spit));
    // Start 2.6 cells out; inside 0.35 after travelling > 2.25 cells:
    // ceil(2.25 / 0.08) = 29 moves.
    const expected: usize = @intCast(@divTrunc(fixed.from_int(3) - spawn_offset - hit_radius, spit_speed) + 1);
    try testing.expectEqual(@as(usize, 29), expected);
    for (0..expected - 1) |_| sim.step(&s, &lv, .{});
    try testing.expectEqual(kind_spit, s.projectiles[0].kind);
    try testing.expectEqual(@as(i16, 100), s.player.hp);
    sim.step(&s, &lv, .{});
    try testing.expectEqual(kind_none, s.projectiles[0].kind);
    try testing.expectEqual(@as(i16, 100 - spit_damage), s.player.hp);
    try testing.expect(s.hurt > 0);
    try testing.expectEqual(@as(u8, 0), s.player.frozen);
}

test "a web freezes movement for 45 ticks, turning still works" {
    var st: level_parse.Parsed = undefined;
    const lv = try hall(&st);
    var s: GameState = undefined;
    sim.init(&s, &lv, 0, 1);
    try testing.expect(spawn(&s, s.player.x + fixed.from_int(2), s.player.y, west, kind_web));
    var ticks: usize = 0;
    while (s.projectiles[0].kind != kind_none) : (ticks += 1) {
        try testing.expect(ticks < 60);
        sim.step(&s, &lv, .{});
    }
    try testing.expectEqual(@as(i16, 100 - web_damage), s.player.hp);
    try testing.expectEqual(web_freeze_ticks, s.player.frozen);
    const x = s.player.x;
    const y = s.player.y;
    // Hold forward and turn: 45 steps of no movement while the angle turns.
    for (0..web_freeze_ticks) |i| {
        const a = s.player.angle;
        sim.step(&s, &lv, .{ .up = true, .right = true });
        try testing.expectEqual(x, s.player.x);
        try testing.expectEqual(y, s.player.y);
        try testing.expectEqual(a +% sim.turn_speed, s.player.angle);
        try testing.expectEqual(@as(u8, @intCast(web_freeze_ticks - 1 - i)), s.player.frozen);
    }
    sim.step(&s, &lv, .{ .up = true });
    try testing.expect(s.player.x != x or s.player.y != y);
}

test "ttl expiry frees the slot after 180 ticks" {
    var st: level_parse.Parsed = undefined;
    const lv = try hall(&st);
    var s: GameState = undefined;
    sim.init(&s, &lv, 0, 1);
    try testing.expect(spawn(&s, fixed.from_int(5) + cell_centre, fixed.from_int(3) + cell_centre, east, kind_web));
    // Park it so only the ttl can end it.
    s.projectiles[0].vx = 0;
    s.projectiles[0].vy = 0;
    for (0..ttl_ticks - 1) |_| update(&s, &lv);
    try testing.expectEqual(kind_web, s.projectiles[0].kind);
    try testing.expectEqual(@as(u8, 1), s.projectiles[0].ttl);
    update(&s, &lv);
    try testing.expectEqual(kind_none, s.projectiles[0].kind);
    try testing.expectEqual(@as(usize, 0), live_count(&s));
    try testing.expect(spawn(&s, fixed.from_int(5) + cell_centre, fixed.from_int(3) + cell_centre, east, kind_web));
}

// ------------------------------------------------------- Debugger tests

/// Put a living gnat (or `kind`) in enemy slot `i` at (x, y), idle.
fn place(s: *GameState, i: usize, kind: state.EnemyKind, x: Fixed, y: Fixed) void {
    s.enemies[i] = .{ .x = x, .y = y, .kind = kind, .state = .idle, .hp = sim.stats(kind).hp };
}

fn dist_sq(x0: Fixed, y0: Fixed, x1: Fixed, y1: Fixed) i64 {
    const dx: i64 = x1 - x0;
    const dy: i64 = y1 - y0;
    return dx * dx + dy * dy;
}

test "a Debugger bolt spawns 0.4 ahead at 0.10 cells/tick with ttl 120" {
    var st: level_parse.Parsed = undefined;
    const lv = try hall(&st);
    var s: GameState = undefined;
    sim.init(&s, &lv, 0, 1);
    try testing.expect(spawn(&s, s.player.x, s.player.y, east, kind_debug));
    const p = s.projectiles[0];
    try testing.expectEqual(kind_debug, p.kind);
    try testing.expectEqual(s.player.x + spawn_offset, p.x);
    try testing.expectEqual(debug_speed, p.vx);
    try testing.expectEqual(@as(Fixed, 0), p.vy);
    try testing.expectEqual(debug_ttl, p.ttl);
}

test "a Debugger bolt fired at a wall bursts in the last floor cell, burst lasts 6 updates" {
    var st: level_parse.Parsed = undefined;
    const lv = try hall(&st);
    var s: GameState = undefined;
    sim.init(&s, &lv, 0, 1);
    const y0 = fixed.from_int(3) + cell_centre;
    try testing.expect(spawn(&s, fixed.from_int(2) + cell_centre, y0, east, kind_debug));
    var ticks: usize = 0;
    var last_x: Fixed = 0;
    while (s.projectiles[0].kind == kind_debug) : (ticks += 1) {
        try testing.expect(ticks < debug_ttl);
        last_x = s.projectiles[0].x;
        update(&s, &lv);
    }
    // It burst on the move into x = 10 (the wall), at the pre-move point.
    try testing.expectEqual(@as(i32, 10), fixed.to_int(last_x + debug_speed));
    const b = s.projectiles[0];
    try testing.expectEqual(kind_burst, b.kind);
    try testing.expectEqual(last_x, b.x);
    try testing.expectEqual(y0, b.y);
    try testing.expectEqual(@as(i32, 9), fixed.to_int(b.x));
    try testing.expectEqual(@as(Fixed, 0), b.vx);
    try testing.expectEqual(@as(Fixed, 0), b.vy);
    try testing.expectEqual(burst_ticks, b.ttl);
    // Display only: it stays put for 5 updates and is gone after the 6th.
    for (0..burst_ticks - 1) |_| {
        update(&s, &lv);
        try testing.expectEqual(kind_burst, s.projectiles[0].kind);
        try testing.expectEqual(last_x, s.projectiles[0].x);
    }
    update(&s, &lv);
    try testing.expectEqual(kind_none, s.projectiles[0].kind);
    try testing.expectEqual(@as(usize, 0), live_count(&s));
    try testing.expectEqual(@as(i16, 100), s.player.hp);
}

test "a burst 3 cells out kills two adjacent gnats, a third 2 cells away is untouched" {
    var st: level_parse.Parsed = undefined;
    const lv = try hall(&st);
    var s: GameState = undefined;
    sim.init(&s, &lv, 0, 1);
    // Player at (1.5, 1.5) facing east. Gnat 0 on the bolt's path at
    // x = 4.9: the bolt bursts once within 0.4 of it, near x = 4.5,
    // 3 cells from the player. Gnat 1 one row down (about 1.08 cells from
    // the burst), gnat 2 two rows down (about 2.04 cells).
    const gx = fixed.from_float(4.9);
    place(&s, 0, .gnat, gx, fixed.from_int(1) + cell_centre);
    place(&s, 1, .gnat, gx, fixed.from_int(2) + cell_centre);
    place(&s, 2, .gnat, gx, fixed.from_int(3) + cell_centre);
    try testing.expect(spawn(&s, s.player.x, s.player.y, east, kind_debug));
    var ticks: usize = 0;
    while (s.projectiles[0].kind == kind_debug) : (ticks += 1) {
        try testing.expect(ticks < debug_ttl);
        update(&s, &lv);
    }
    const b = s.projectiles[0];
    try testing.expectEqual(kind_burst, b.kind);
    // Burst point: first position within 0.4 of gnat 0, about 3 cells out.
    try testing.expect(gx - b.x < debug_trigger);
    try testing.expect(gx - b.x > debug_trigger - debug_speed);
    const out = b.x - s.player.x;
    try testing.expect(out > fixed.from_float(2.9) and out < fixed.from_float(3.1));
    try testing.expect(dist_sq(b.x, b.y, s.enemies[1].x, s.enemies[1].y) < burst_radius_sq);
    try testing.expect(dist_sq(b.x, b.y, s.enemies[2].x, s.enemies[2].y) > @as(i64, fixed.from_int(2)) * fixed.from_int(2));
    // Gnat hp 3 - 12 <= 0: both dying, flashing 6 ticks, two kills.
    try testing.expectEqual(@as(i16, 3), sim.stats(.gnat).hp);
    for (0..2) |i| {
        try testing.expectEqual(state.EnemyState.dying, s.enemies[i].state);
        try testing.expectEqual(@as(i16, 3 - burst_damage), s.enemies[i].hp);
        try testing.expectEqual(burst_flash, s.enemies[i].flash);
    }
    try testing.expectEqual(@as(u32, 2), @as(u32, s.kills));
    try testing.expectEqual(state.EnemyState.idle, s.enemies[2].state);
    try testing.expectEqual(@as(i16, 3), s.enemies[2].hp);
    try testing.expectEqual(@as(u8, 0), s.enemies[2].flash);
    try testing.expectEqual(@as(i16, 100), s.player.hp);
}

test "a burst takes exactly 12 from a beetle and flashes it 6 ticks, not 2" {
    var st: level_parse.Parsed = undefined;
    const lv = try hall(&st);
    var s: GameState = undefined;
    sim.init(&s, &lv, 0, 1);
    place(&s, 0, .beetle, fixed.from_int(5) + cell_centre, fixed.from_int(3) + cell_centre);
    try testing.expect(spawn(&s, fixed.from_int(2) + cell_centre, fixed.from_int(3) + cell_centre, east, kind_debug));
    for (0..debug_ttl) |_| {
        if (s.projectiles[0].kind != kind_debug) break;
        update(&s, &lv);
    }
    try testing.expectEqual(kind_burst, s.projectiles[0].kind);
    try testing.expectEqual(@as(i16, 20 - 12), s.enemies[0].hp);
    try testing.expectEqual(state.EnemyState.pain, s.enemies[0].state);
    try testing.expectEqual(burst_flash, s.enemies[0].flash);
    try testing.expectEqual(@as(u32, 0), @as(u32, s.kills));
}

test "the player takes no damage from a burst 0.5 cells away or a bolt passing through" {
    var st: level_parse.Parsed = undefined;
    const lv = try hall(&st);
    var s: GameState = undefined;
    sim.init(&s, &lv, 0, 1);
    // Gnat 0.85 ahead: the bolt starts 0.4 out, its first move to 0.5
    // puts it 0.35 from the gnat, so it bursts 0.5 cells from the player.
    place(&s, 0, .gnat, s.player.x + fixed.from_float(0.85), s.player.y);
    try testing.expect(spawn(&s, s.player.x, s.player.y, east, kind_debug));
    update(&s, &lv);
    const b = s.projectiles[0];
    try testing.expectEqual(kind_burst, b.kind);
    try testing.expectEqual(s.player.x + spawn_offset + debug_speed, b.x);
    try testing.expectEqual(state.EnemyState.dying, s.enemies[0].state);
    try testing.expectEqual(@as(i16, 100), s.player.hp);
    try testing.expectEqual(@as(u8, 0), s.hurt);
    // A bolt fired from behind flies straight through the player.
    s.projectiles[0] = .{};
    try testing.expect(spawn(&s, s.player.x - fixed.from_float(0.45), s.player.y, east, kind_debug));
    for (0..20) |_| update(&s, &lv);
    try testing.expectEqual(kind_debug, s.projectiles[0].kind);
    try testing.expect(s.projectiles[0].x > s.player.x + fixed.one);
    try testing.expectEqual(@as(i16, 100), s.player.hp);
    try testing.expectEqual(@as(u8, 0), s.hurt);
}

test "a Debugger bolt's ttl expiry frees the slot without a burst" {
    var st: level_parse.Parsed = undefined;
    const lv = try hall(&st);
    var s: GameState = undefined;
    sim.init(&s, &lv, 0, 1);
    try testing.expect(spawn(&s, fixed.from_int(5) + cell_centre, fixed.from_int(3) + cell_centre, east, kind_debug));
    s.projectiles[0].vx = 0;
    s.projectiles[0].vy = 0;
    // A gnat 1.0 away: inside the burst radius, outside the trigger.
    place(&s, 0, .gnat, fixed.from_int(6) + cell_centre, fixed.from_int(3) + cell_centre);
    for (0..debug_ttl - 1) |_| update(&s, &lv);
    try testing.expectEqual(kind_debug, s.projectiles[0].kind);
    update(&s, &lv);
    try testing.expectEqual(kind_none, s.projectiles[0].kind);
    try testing.expectEqual(@as(i16, 3), s.enemies[0].hp);
}
