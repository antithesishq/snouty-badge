//! Enemy projectiles (spit, web): movement, wall collision, player hits.
//! Called once per tick from `sim.step` after `ai.update`. Fixed point
//! only, no cart-api. Values from SPEC.md section 8 and PLAN.md M3
//! "Contract: projectiles (track B)".
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

/// Cells per tick.
pub const spit_speed: Fixed = fixed.from_float(0.08);
pub const web_speed: Fixed = fixed.from_float(0.06);
/// Ticks a projectile lives (it moves at most this many times).
pub const ttl_ticks: u8 = 180;
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
    return if (kind == kind_web) web_speed else spit_speed;
}

/// Launch a projectile of `kind` from (x, y) along `angle`. Returns false
/// when the pool is full. Takes the lowest free slot (deterministic).
pub fn spawn(s: *GameState, x: Fixed, y: Fixed, angle: fixed.Angle, kind: u8) bool {
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
            .ttl = ttl_ticks,
        };
        return true;
    }
    return false;
}

pub fn update(s: *GameState, level: *const Level) void {
    for (&s.projectiles) |*p| {
        if (p.kind == kind_none) continue;
        p.x += p.vx;
        p.y += p.vy;
        if (sim.is_solid(s, level, fixed.to_int(p.x), fixed.to_int(p.y))) {
            p.* = .{};
            continue;
        }
        const dx: i64 = p.x - s.player.x;
        const dy: i64 = p.y - s.player.y;
        if (dx * dx + dy * dy < hit_radius_sq) {
            if (p.kind == kind_web) {
                sim.damage_player(s, web_damage);
                s.player.frozen = web_freeze_ticks;
            } else {
                sim.damage_player(s, spit_damage);
            }
            p.* = .{};
            continue;
        }
        p.ttl -= 1;
        if (p.ttl == 0) p.* = .{};
    }
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
