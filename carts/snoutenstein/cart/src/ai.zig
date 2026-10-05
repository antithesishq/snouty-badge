//! Enemy behaviour (SPEC.md section 8, PLAN.md "Contract: enemy AI"),
//! called once per tick from `sim.step` after doors and pickups and before
//! the player's weapon. Owns every field of `state.Enemy` (including
//! `frame`) once the level starts; `sim.damage_enemy` is the only outside
//! writer. Fixed point only, `sim.next_rand` for randomness, no cart-api.
//!
//! State machine: `dormant`/`idle` (not yet woken: one line-of-sight check
//! every 8 ticks, staggered by index, plus the gunfire wake) -> `alert`
//! (12-tick startle) -> `chase` <-> `attack` (windup with frame 2, then the
//! attack lands). `pain` and `dying` are set by `sim.damage_enemy`; pain
//! ends in `idle`, which for an awake enemy resumes the chase next tick.
//! `sim.init` spawns enemies in `idle`, so "idle and not awake" is the
//! dormant state; the awake bit in `aux[2]` tells them apart.
//!
//! Per-enemy scratch:
//! - `timer`: ticks left in `alert`, `attack` (windup / flicker), `pain`,
//!   `dying`, and a wasp's charge.
//! - `dir`: wasp: charge heading. Others: attack cooldowns, low byte melee,
//!   high byte shot (spit/web/fan).
//! - `aux[0]`: eight-direction fallback, `dir << 0 | ticks_left << 3`.
//! - `aux[1]`: boss: consecutive ticks the player has faced it. Wasp: 1
//!   once the current charge has hit.
//! - `aux[2]`: bit 7 awake, bits 0-1 the action a windup resolves into.
const std = @import("std");
const fixed = @import("fixed.zig");
const state = @import("state.zig");
const levels = @import("levels.zig");
const sim = @import("sim.zig");
const projectiles = @import("projectiles.zig");

const GameState = state.GameState;
const Level = levels.Level;
const Enemy = state.Enemy;
const Fixed = fixed.Fixed;
const Angle = fixed.Angle;

// ---------------------------------------------------------------- tuning

pub const KindTuning = struct {
    /// Cells per tick while chasing (wasp: while charging).
    speed: Fixed,
    /// Chasers stop closing in once the player is this near.
    stop: Fixed,
    /// Melee (0 range = none). Wasp: contact range during a charge.
    melee_range: Fixed,
    melee_damage: i16,
    melee_every: u8,
    melee_windup: u8,
    /// Ranged attack through `projectiles.spawn` (0 range = none); needs
    /// line of sight and the player farther than `shot_min` (the boss
    /// bites up close instead of spitting its fan point-blank, M5).
    shot_range: Fixed,
    shot_min: Fixed = 0,
    shot_every: u8,
    shot_windup: u8,
    shot_kind: u8,
};

/// Indexed by `@intFromEnum(EnemyKind)`; SPEC.md section 8 values.
pub const tuning = [5]KindTuning{
    // gnat: zig-zags in, bites. SPEC was 5 every 30 (windup 6); M5 tried 2
    // every 60 and Adrian found the game impossible to lose, so 4 every 40:
    // see the Build Farm opening tests below.
    .{ .speed = fixed.from_float(0.05), .stop = fixed.from_float(0.6), .melee_range = fixed.from_float(0.8), .melee_damage = 4, .melee_every = 40, .melee_windup = 8, .shot_range = 0, .shot_every = 0, .shot_windup = 0, .shot_kind = projectiles.kind_none },
    // wasp: straight charges, contact damage once per charge.
    .{ .speed = fixed.from_float(0.07), .stop = 0, .melee_range = fixed.from_float(0.5), .melee_damage = 10, .melee_every = 0, .melee_windup = 0, .shot_range = 0, .shot_every = 0, .shot_windup = 0, .shot_kind = projectiles.kind_none },
    // beetle: slow walker, spits.
    .{ .speed = fixed.from_float(0.02), .stop = fixed.from_float(1.0), .melee_range = 0, .melee_damage = 0, .melee_every = 0, .melee_windup = 0, .shot_range = fixed.from_int(8), .shot_every = 90, .shot_windup = 10, .shot_kind = projectiles.kind_spit },
    // spider: turret, webs.
    .{ .speed = 0, .stop = 0, .melee_range = 0, .melee_damage = 0, .melee_every = 0, .melee_windup = 0, .shot_range = fixed.from_int(6), .shot_every = 120, .shot_windup = 10, .shot_kind = projectiles.kind_web },
    // boss: chases, melee, spit fan (range = line of sight).
    .{ .speed = fixed.from_float(0.04), .stop = fixed.from_float(0.7), .melee_range = fixed.from_float(0.9), .melee_damage = 15, .melee_every = 45, .melee_windup = 10, .shot_range = sim.max_ray, .shot_min = fixed.from_float(2.5), .shot_every = 100, .shot_windup = 10, .shot_kind = projectiles.kind_spit },
};

pub fn tune(kind: state.EnemyKind) KindTuning {
    return tuning[@backingInt(kind)];
}

/// Enemy collision half-size for `sim.move_circle`.
pub const move_radius: Fixed = fixed.from_float(0.3);
/// Dormant enemies look for the player once per this many ticks.
pub const dormant_period: u32 = 8;
/// A shot this recent (ticks) wakes dormant enemies within `wake_radius`.
pub const gunfire_window: u32 = 8;
pub const wake_radius: Fixed = sim.gunfire_radius;
pub const alert_ticks: u8 = 12;
/// Ticks a blocked chaser keeps its eight-direction fallback.
pub const fallback_ticks: u8 = 16;
pub const walk_frame_ticks: u32 = 8;
pub const gnat_zig: Angle = fixed.deg(30);
pub const gnat_zig_ticks: u32 = 20;
/// Centre-to-centre distance a chasing or charging enemy keeps from every
/// other enemy that blocks (`blocks`); a move that would end closer (and
/// closer than it started) counts as a wall hit.
pub const separation: Fixed = fixed.from_float(0.5);
pub const wasp_charge_ticks: u8 = 40;
pub const wasp_overshoot: Fixed = fixed.from_float(1.5);
pub const wasp_turn_ticks: u8 = 12;
pub const boss_fan: Angle = fixed.deg(12);
pub const boss_stare_cone: Angle = fixed.deg(20);
pub const boss_stare_ticks: u8 = 90;
pub const boss_flicker_ticks: u8 = 8;
/// Teleport target: the cell ring around the point this far behind the
/// player, searched out to `teleport_search` cells, accepting floor cells
/// whose centre is `teleport_min`..`teleport_max` from the player.
pub const teleport_behind: Fixed = fixed.from_int(4);
pub const teleport_search: i32 = 2;
pub const teleport_min: Fixed = fixed.from_int(3);
pub const teleport_max: Fixed = fixed.from_int(5);

pub const frame_walk2: u8 = 1;
pub const frame_flicker: u8 = 7;

const awake_bit: u8 = 0x80;
const act_mask: u8 = 0x03;
const act_melee: u8 = 1;
const act_shot: u8 = 2;
const act_teleport: u8 = 3;

// ---------------------------------------------------------------- update

pub fn update(s: *GameState, level: *const Level) void {
    for (0..s.enemies.len) |i| update_enemy(s, level, i);
}

/// One enemy's tick against `s.player`. Deathmatch (`match.zig`) calls it
/// per enemy with the player it targets swapped into `s.player`.
pub fn update_enemy(s: *GameState, level: *const Level, i: usize) void {
    const e = &s.enemies[i];
    if (e.flash > 0) e.flash -= 1;
    switch (e.state) {
        .dead => {},
        .dying => {
            if (e.timer > 0) e.timer -= 1;
            if (e.timer == 0) {
                e.state = .dead;
                e.frame = sim.frame_dead;
            } else {
                e.frame = sim.frame_dying + (sim.dying_ticks - e.timer) / sim.dying_frame_ticks;
            }
        },
        else => {
            const asleep = e.aux[2] & awake_bit == 0;
            if (asleep and (e.state == .dormant or e.state == .idle)) {
                sleep(s, level, e, i);
                return;
            }
            // Any other state (pain, or a test placing a chaser) is awake.
            e.aux[2] |= awake_bit;
            awake(s, level, e, i);
        },
    }
}

fn sleep(s: *GameState, level: *const Level, e: *Enemy, i: usize) void {
    e.frame = sim.frame_idle;
    const p = &s.player;
    var wake = false;
    if (s.last_shot != state.no_shot and s.tick -% s.last_shot < gunfire_window) {
        wake = dist2(p.x - e.x, p.y - e.y) < sq(wake_radius);
    }
    if (!wake and s.tick % dormant_period == i % dormant_period) {
        wake = sim.line_of_sight(s, level, e.x, e.y, p.x, p.y);
    }
    if (!wake) return;
    e.aux[2] |= awake_bit;
    e.state = .alert;
    e.timer = alert_ticks;
}

fn awake(s: *GameState, level: *const Level, e: *Enemy, i: usize) void {
    if (e.kind != .wasp) {
        // Cooldowns run in every awake state, pain included.
        var melee_cd: u8 = @truncate(e.dir);
        var shot_cd: u8 = @truncate(e.dir >> 8);
        melee_cd -|= 1;
        shot_cd -|= 1;
        e.dir = @as(u16, shot_cd) << 8 | melee_cd;
    }
    if (e.kind == .boss) stare(s, level, e);
    switch (e.state) {
        .pain => {
            if (e.timer > 0) e.timer -= 1;
            if (e.timer == 0) {
                e.state = .idle;
                e.frame = sim.frame_idle;
            } else e.frame = sim.frame_pain;
        },
        .dormant, .idle => {
            // Awake again after pain.
            if (e.kind == .wasp) {
                turn(e);
            } else {
                e.state = .chase;
                chase(s, level, e, i);
            }
        },
        .alert => {
            e.frame = sim.frame_idle;
            if (e.timer > 0) e.timer -= 1;
            if (e.timer == 0) {
                if (e.kind == .wasp) start_charge(s, e) else e.state = .chase;
            }
        },
        .chase => if (e.kind == .wasp) charge(s, level, e) else chase(s, level, e, i),
        .attack => {
            const act = e.aux[2] & act_mask;
            e.frame = if (act == act_teleport) frame_flicker else sim.frame_attack;
            if (e.timer > 0) e.timer -= 1;
            if (e.timer == 0) {
                resolve(s, level, e, act);
                e.aux[2] &= ~act_mask;
                e.state = .chase;
                e.frame = sim.frame_idle;
            }
        },
        .dying, .dead => {},
    }
}

/// Boss: count consecutive ticks the player faces it with line of sight
/// (saturating), except while it is already flickering.
fn stare(s: *GameState, level: *const Level, e: *Enemy) void {
    if (e.state == .attack and e.aux[2] & act_mask == act_teleport) return;
    const p = &s.player;
    const off = fixed.angle_diff(fixed.atan2(e.y - p.y, e.x - p.x), p.angle);
    const faced = off < @as(i32, boss_stare_cone) and off > -@as(i32, boss_stare_cone) and
        sim.line_of_sight(s, level, p.x, p.y, e.x, e.y);
    e.aux[1] = if (faced) @min(boss_stare_ticks, e.aux[1] + 1) else 0;
}

fn begin(e: *Enemy, act: u8, ticks: u8) void {
    e.state = .attack;
    e.timer = ticks;
    e.aux[2] = (e.aux[2] & ~act_mask) | act;
    e.frame = if (act == act_teleport) frame_flicker else sim.frame_attack;
}

fn chase(s: *GameState, level: *const Level, e: *Enemy, i: usize) void {
    const t = tune(e.kind);
    if (e.kind == .boss and e.aux[1] >= boss_stare_ticks) {
        begin(e, act_teleport, boss_flicker_ticks);
        return;
    }
    const p = &s.player;
    const rx = p.x - e.x;
    const ry = p.y - e.y;
    const d2 = dist2(rx, ry);
    const melee_cd: u8 = @truncate(e.dir);
    const shot_cd: u8 = @truncate(e.dir >> 8);
    if (t.melee_range > 0 and melee_cd == 0 and d2 < sq(t.melee_range) and
        sim.line_of_sight(s, level, e.x, e.y, p.x, p.y))
    {
        e.dir = (e.dir & 0xFF00) | t.melee_every;
        begin(e, act_melee, t.melee_windup);
        return;
    }
    if (t.shot_range > 0 and shot_cd == 0 and d2 < sq(t.shot_range) and d2 >= sq(t.shot_min) and
        sim.line_of_sight(s, level, e.x, e.y, p.x, p.y))
    {
        e.dir = (e.dir & 0x00FF) | @as(u16, t.shot_every) << 8;
        begin(e, act_shot, t.shot_windup);
        return;
    }
    var moved = false;
    if (t.speed > 0 and d2 > sq(t.stop)) {
        var h = fixed.atan2(ry, rx);
        if (e.kind == .gnat) {
            h = if ((s.tick / gnat_zig_ticks + i) & 1 == 0) h +% gnat_zig else h -% gnat_zig;
        }
        moved = walk(s, level, e, h, t.speed);
    }
    e.frame = walk_frame(s, moved);
}

fn walk_frame(s: *const GameState, moved: bool) u8 {
    if (!moved) return sim.frame_idle;
    return if ((s.tick / walk_frame_ticks) & 1 == 0) sim.frame_idle else frame_walk2;
}

/// Move along `desired` (or the active fallback direction) with sliding;
/// when blocked, pick a new eight-direction fallback for the next ticks.
/// Returns true if the enemy moved.
fn walk(s: *GameState, level: *const Level, e: *Enemy, desired: Angle, speed: Fixed) bool {
    var h = desired;
    if (e.aux[0] >> 3 > 0) {
        h = compass(e.aux[0] & 7);
        e.aux[0] -= 1 << 3;
    }
    const x0 = e.x;
    const y0 = e.y;
    var blocked = sim.move_circle(s, level, &e.x, &e.y, fixed.mul(fixed.cos(h), speed), fixed.mul(fixed.sin(h), speed), move_radius, .enemy);
    if (crowds(s, level, e, x0, y0, e.x, e.y)) {
        e.x = x0;
        e.y = y0;
        blocked = true;
    }
    if (blocked) pick_fallback(s, level, e, desired, speed);
    return e.x != x0 or e.y != y0;
}

fn compass(d: u8) Angle {
    return @as(Angle, d & 7) << 13;
}

/// Compass directions nearest `desired` first: 0, +1, -1, +2, -2, +3, -3, 4.
const fallback_order = [8]u8{ 0, 1, 7, 2, 6, 3, 5, 4 };

fn pick_fallback(s: *const GameState, level: *const Level, e: *Enemy, desired: Angle, speed: Fixed) void {
    const o: u8 = @intCast((desired +% 4096) >> 13);
    for (fallback_order) |off| {
        const d = (o + off) & 7;
        const a = compass(d);
        const nx = e.x + fixed.mul(fixed.cos(a), speed);
        const ny = e.y + fixed.mul(fixed.sin(a), speed);
        if (box_free(s, level, nx, ny, move_radius) and !crowds(s, level, e, e.x, e.y, nx, ny)) {
            e.aux[0] = fallback_ticks << 3 | d;
            return;
        }
    }
    e.aux[0] = 0;
}

/// Does another enemy stand in the way of this one's move? True if some
/// blocking enemy is closer than `separation` to (nx, ny) and the move
/// from (x0, y0) brings the two closer, so overlapping enemies can still
/// step apart. One pass over the level's enemies.
fn crowds(s: *const GameState, level: *const Level, e: *const Enemy, x0: Fixed, y0: Fixed, nx: Fixed, ny: Fixed) bool {
    for (s.enemies[0..level.enemies.len]) |*o| {
        if (o == e or !blocks(o)) continue;
        const d = dist2(nx - o.x, ny - o.y);
        if (d < sq(separation) and d < dist2(x0 - o.x, y0 - o.y)) return true;
    }
    return false;
}

/// Enemies that others keep their distance from: alive, woken, not a
/// spider (a ceiling turret).
fn blocks(o: *const Enemy) bool {
    const dormant = o.aux[2] & awake_bit == 0 and (o.state == .dormant or o.state == .idle);
    return o.kind != .spider and !dormant and sim.living(o);
}

/// True if a box of half-size `r` at (x, y) overlaps no solid cell.
fn box_free(s: *const GameState, level: *const Level, x: Fixed, y: Fixed, r: Fixed) bool {
    var cy = fixed.to_int(y - r);
    while (cy <= fixed.to_int(y + r - 1)) : (cy += 1) {
        var cx = fixed.to_int(x - r);
        while (cx <= fixed.to_int(x + r - 1)) : (cx += 1) {
            if (sim.is_solid(s, level, cx, cy)) return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------- wasp

fn start_charge(s: *const GameState, e: *Enemy) void {
    e.dir = fixed.atan2(s.player.y - e.y, s.player.x - e.x);
    e.timer = wasp_charge_ticks;
    e.aux[1] = 0;
    e.state = .chase;
}

fn turn(e: *Enemy) void {
    e.state = .alert;
    e.timer = wasp_turn_ticks;
    e.frame = sim.frame_idle;
}

fn charge(s: *GameState, level: *const Level, e: *Enemy) void {
    const t = tune(.wasp);
    const h = e.dir;
    const x0 = e.x;
    const y0 = e.y;
    _ = sim.move_circle(s, level, &e.x, &e.y, fixed.mul(fixed.cos(h), t.speed), fixed.mul(fixed.sin(h), t.speed), move_radius, .enemy);
    // Running into another enemy ends the charge like a wall.
    if (crowds(s, level, e, x0, y0, e.x, e.y)) {
        e.x = x0;
        e.y = y0;
    }
    // Sliding along a wall still counts as progress; a wall hit is when
    // less than half the step was made.
    const hit_wall = dist2(e.x - x0, e.y - y0) < sq(t.speed >> 1);
    e.frame = walk_frame(s, !hit_wall);
    const p = &s.player;
    const rx = p.x - e.x;
    const ry = p.y - e.y;
    if (e.aux[1] == 0 and dist2(rx, ry) < sq(t.melee_range)) {
        sim.damage_player(s, t.melee_damage);
        e.aux[1] = 1;
    }
    const along = fixed.mul(rx, fixed.cos(h)) + fixed.mul(ry, fixed.sin(h));
    if (e.timer > 0) e.timer -= 1;
    if (e.timer == 0 or hit_wall or along < -wasp_overshoot) turn(e);
}

// ---------------------------------------------------------------- attacks

fn resolve(s: *GameState, level: *const Level, e: *Enemy, act: u8) void {
    const t = tune(e.kind);
    const p = &s.player;
    switch (act) {
        act_melee => if (dist2(p.x - e.x, p.y - e.y) < sq(t.melee_range)) sim.damage_player(s, t.melee_damage),
        act_shot => {
            const a = fixed.atan2(p.y - e.y, p.x - e.x);
            if (e.kind == .boss) {
                _ = projectiles.spawn(s, e.x, e.y, a -% boss_fan, t.shot_kind);
                _ = projectiles.spawn(s, e.x, e.y, a, t.shot_kind);
                _ = projectiles.spawn(s, e.x, e.y, a +% boss_fan, t.shot_kind);
            } else _ = projectiles.spawn(s, e.x, e.y, a, t.shot_kind);
        },
        act_teleport => {
            if (teleport_target(s, level)) |c| {
                e.x = fixed.from_int(c[0]) + fixed.half;
                e.y = fixed.from_int(c[1]) + fixed.half;
            }
            e.aux[0] = 0;
            e.aux[1] = 0;
        },
        else => {},
    }
}

/// First floor cell in a clockwise spiral (ring 0, 1, 2; each ring from
/// its north-west corner) around the point `teleport_behind` behind the
/// player whose centre is `teleport_min`..`teleport_max` from the player
/// and in the player's line of sight (so the boss lands in the same room).
pub fn teleport_target(s: *const GameState, level: *const Level) ?[2]i32 {
    const p = &s.player;
    const bx = fixed.to_int(p.x - fixed.mul(fixed.cos(p.angle), teleport_behind));
    const by = fixed.to_int(p.y - fixed.mul(fixed.sin(p.angle), teleport_behind));
    var r: i32 = 0;
    while (r <= teleport_search) : (r += 1) {
        const n: i32 = if (r == 0) 1 else 8 * r;
        var k: i32 = 0;
        while (k < n) : (k += 1) {
            const c = ring_cell(r, k);
            const cx = bx + c[0];
            const cy = by + c[1];
            if (teleport_ok(s, level, cx, cy)) return .{ cx, cy };
        }
    }
    return null;
}

/// Offset of the k-th cell of the square ring of radius r (r > 0: 8r
/// cells), clockwise from the north-west corner.
fn ring_cell(r: i32, k: i32) [2]i32 {
    if (r == 0) return .{ 0, 0 };
    const side = 2 * r;
    if (k < side) return .{ -r + k, -r }; // north edge, west to east
    if (k < 2 * side) return .{ r, -r + (k - side) }; // east edge, north to south
    if (k < 3 * side) return .{ r - (k - 2 * side), r }; // south edge, east to west
    return .{ -r, r - (k - 3 * side) }; // west edge, south to north
}

fn teleport_ok(s: *const GameState, level: *const Level, cx: i32, cy: i32) bool {
    if (level.cell(cx, cy) != 0) return false;
    const p = &s.player;
    const x = fixed.from_int(cx) + fixed.half;
    const y = fixed.from_int(cy) + fixed.half;
    const d2 = dist2(x - p.x, y - p.y);
    if (d2 < sq(teleport_min) or d2 > sq(teleport_max)) return false;
    return sim.line_of_sight(s, level, p.x, p.y, x, y);
}

fn sq(a: Fixed) i64 {
    return @as(i64, a) * a;
}
fn dist2(dx: Fixed, dy: Fixed) i64 {
    return sq(dx) + sq(dy);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const level_parse = @import("level_parse.zig");

fn run(s: *GameState, level: *const Level, b: state.Buttons, n: usize) void {
    for (0..n) |_| sim.step(s, level, b);
}

fn is_awake(e: *const Enemy) bool {
    return e.aux[2] & awake_bit != 0;
}

/// True once track B's projectiles.spawn is real (the M3 stub returns false).
fn projectiles_real() bool {
    var t: GameState = .{ .player = .{ .x = 0, .y = 0, .angle = 0 } };
    return projectiles.spawn(&t, fixed.from_int(2), fixed.from_int(2), 0, projectiles.kind_spit);
}

fn live_projectiles(s: *const GameState) usize {
    var n: usize = 0;
    for (s.projectiles) |pr| {
        if (pr.kind != projectiles.kind_none) n += 1;
    }
    return n;
}

const open_src =
    \\1111111111111111
    \\1..............1
    \\1..............1
    \\1S>...a........1
    \\1..............1
    \\1..............1
    \\1111111111111111
;

test "a gnat 5 cells away wakes, closes in and bites on its cooldown" {
    const g = tune(.gnat);
    var st: level_parse.Parsed = undefined;
    const L = try level_parse.parse_level(&st, "open", open_src, 0);
    var s: GameState = undefined;
    sim.init(&s, &L, 0, 1);
    try testing.expectEqual(fixed.from_int(5), s.enemies[0].x - s.player.x);
    var t: usize = 0;
    while (!is_awake(&s.enemies[0])) : (t += 1) {
        try testing.expect(t < 8);
        sim.step(&s, &L, .{});
    }
    const reach = sq(g.melee_range);
    while (dist2(s.player.x - s.enemies[0].x, s.player.y - s.enemies[0].y) >= reach) : (t += 1) {
        try testing.expect(t < 150);
        sim.step(&s, &L, .{});
    }
    try testing.expectEqual(@as(i16, 100), s.player.hp);
    while (s.player.hp == 100) : (t += 1) {
        try testing.expect(t < 250);
        sim.step(&s, &L, .{});
    }
    try testing.expectEqual(100 - g.melee_damage, s.player.hp);
    for (0..g.melee_every - 1) |_| {
        sim.step(&s, &L, .{});
        try testing.expectEqual(100 - g.melee_damage, s.player.hp);
    }
    sim.step(&s, &L, .{});
    try testing.expectEqual(100 - 2 * g.melee_damage, s.player.hp);
}

const walled_src =
    \\1111111111111
    \\1S>..1.a....1
    \\1111111111111
;

test "a gnat behind a wall stays dormant for 300 ticks" {
    var st: level_parse.Parsed = undefined;
    const L = try level_parse.parse_level(&st, "walled", walled_src, 0);
    var s: GameState = undefined;
    sim.init(&s, &L, 0, 1);
    const x0 = s.enemies[0].x;
    for (0..300) |_| {
        sim.step(&s, &L, .{});
        try testing.expect(!is_awake(&s.enemies[0]));
        try testing.expectEqual(state.EnemyState.idle, s.enemies[0].state);
        try testing.expectEqual(x0, s.enemies[0].x);
    }
}

test "a shot within 8 cells wakes a gnat with no line of sight, beyond 8 it does not" {
    var st: level_parse.Parsed = undefined;
    const L = try level_parse.parse_level(&st, "walled", walled_src, 0);
    var s: GameState = undefined;
    sim.init(&s, &L, 0, 1);
    sim.step(&s, &L, .{ .a = true }); // hits the wall at x = 5
    try testing.expectEqual(@as(u8, 39), s.player.ammo_zapper);
    try testing.expect(!is_awake(&s.enemies[0]));
    run(&s, &L, .{}, 7);
    try testing.expect(is_awake(&s.enemies[0]));
    try testing.expectEqual(state.EnemyState.alert, s.enemies[0].state);
    // 9 cells away: not woken.
    sim.init(&s, &L, 0, 1);
    s.enemies[0].x = fixed.from_int(10) + fixed.half;
    sim.step(&s, &L, .{ .a = true });
    run(&s, &L, .{}, 40);
    try testing.expect(!is_awake(&s.enemies[0]));
}

const corridor_src =
    \\1111111111111111
    \\1S>...w........1
    \\1111111111111111
;

test "a wasp charge covers 0.07 per tick and deals 10 once per charge" {
    var st: level_parse.Parsed = undefined;
    const L = try level_parse.parse_level(&st, "corridor", corridor_src, 0);
    var s: GameState = undefined;
    sim.init(&s, &L, 0, 1);
    // Room to overshoot: the west wall is 3.5 cells behind the player.
    s.player.x = fixed.from_int(4) + fixed.half;
    s.enemies[0].x = s.player.x + fixed.from_int(2);
    const e = &s.enemies[0];
    var t: usize = 0;
    while (e.state != .chase) : (t += 1) {
        try testing.expect(t < 30);
        sim.step(&s, &L, .{});
    }
    try testing.expectEqual(@as(i16, 100), s.player.hp);
    // Charging west along the corridor, straight at the player.
    var ticks: usize = 0;
    while (e.state == .chase) : (ticks += 1) {
        const x0 = e.x;
        sim.step(&s, &L, .{});
        try testing.expectEqual(x0 - tune(.wasp).speed, e.x);
        try testing.expectEqual(s.player.y, e.y);
    }
    try testing.expect(ticks <= wasp_charge_ticks);
    try testing.expect(e.x < s.player.x); // went through and past
    try testing.expectEqual(@as(i16, 90), s.player.hp);
    // It turns for 12 ticks, then the next charge can hit again.
    try testing.expectEqual(state.EnemyState.alert, e.state);
    run(&s, &L, .{}, 12);
    try testing.expectEqual(state.EnemyState.chase, e.state);
    ticks = 0;
    while (e.state == .chase) : (ticks += 1) {
        try testing.expect(ticks < wasp_charge_ticks);
        sim.step(&s, &L, .{});
    }
    try testing.expectEqual(@as(i16, 80), s.player.hp);
}

test "a beetle walks in and spits" {
    var st: level_parse.Parsed = undefined;
    const L = try level_parse.parse_level(&st, "open", open_src, 0);
    var s: GameState = undefined;
    sim.init(&s, &L, 0, 1);
    s.enemies[0].kind = .beetle;
    s.enemies[0].hp = sim.stats(.beetle).hp;
    s.enemies[0].x = s.player.x + fixed.from_int(4);
    const real = projectiles_real();
    var attacked = false;
    var spat = false;
    for (0..60) |_| {
        sim.step(&s, &L, .{});
        if (s.enemies[0].state == .attack) {
            attacked = true;
            try testing.expectEqual(sim.frame_attack, s.enemies[0].frame);
        }
        if (live_projectiles(&s) > 0) spat = true;
    }
    try testing.expect(attacked);
    // Only once track B's real projectiles.spawn has landed.
    if (real) try testing.expect(spat);
    try testing.expect(s.enemies[0].x < s.player.x + fixed.from_int(4)); // it walked in
}

test "a spider at 4 cells webs, at 7 it does not" {
    var st: level_parse.Parsed = undefined;
    const L = try level_parse.parse_level(&st, "open", open_src, 0);
    var s: GameState = undefined;
    const real = projectiles_real();
    for ([_]i32{ 4, 7 }) |d| {
        sim.init(&s, &L, 0, 1);
        s.enemies[0].kind = .spider;
        s.enemies[0].hp = sim.stats(.spider).hp;
        s.enemies[0].x = s.player.x + fixed.from_int(d);
        const x0 = s.enemies[0].x;
        var attacked = false;
        var webbed = false;
        for (0..300) |_| {
            sim.step(&s, &L, .{});
            if (s.enemies[0].state == .attack) attacked = true;
            if (live_projectiles(&s) > 0) webbed = true;
            try testing.expectEqual(x0, s.enemies[0].x); // never moves
        }
        try testing.expect(is_awake(&s.enemies[0]));
        try testing.expectEqual(d == 4, attacked);
        // Only once track B's real projectiles.spawn has landed.
        if (real) try testing.expectEqual(d == 4, webbed);
    }
}

const hall_src =
    \\11111111111111111
    \\1...............1
    \\1...............1
    \\1...............1
    \\1...............1
    \\1.......S>....H.1
    \\1...............1
    \\1...............1
    \\1...............1
    \\1...............1
    \\11111111111111111
;

/// Steps until the boss jumps more than a cell in one tick; returns the
/// tick count, or null after `limit`. `look_away_at` turns the player away
/// for one tick at that step.
fn boss_run(s: *GameState, L: *const Level, limit: usize, look_away_at: ?usize) !?usize {
    const e = &s.enemies[0];
    var saw_flicker = false;
    for (0..limit) |t| {
        const x0 = e.x;
        const y0 = e.y;
        const facing = s.player.angle;
        if (look_away_at == t) s.player.angle = fixed.deg(180);
        sim.step(s, L, .{});
        s.player.angle = facing;
        if (e.frame == frame_flicker) saw_flicker = true;
        if (dist2(e.x - x0, e.y - y0) > sq(fixed.one)) {
            try testing.expect(saw_flicker);
            return t + 1;
        }
    }
    return null;
}

test "the boss teleports behind the player after 90 ticks of being faced, not before" {
    var st: level_parse.Parsed = undefined;
    const L = try level_parse.parse_level(&st, "hall", hall_src, 0);
    var s: GameState = undefined;
    sim.init(&s, &L, 0, 1);
    s.player.hp = 30000;
    const t = (try boss_run(&s, &L, 300, null)).?;
    // Woken on tick 0, counted from tick 1: 90 faced ticks, 8 of flicker.
    try testing.expectEqual(@as(usize, 1 + boss_stare_ticks + boss_flicker_ticks), t);
    const e = &s.enemies[0];
    const rx = e.x - s.player.x;
    const ry = e.y - s.player.y;
    try testing.expect(dist2(rx, ry) >= sq(teleport_min) and dist2(rx, ry) <= sq(teleport_max));
    try testing.expect(rx < 0); // behind: the player faces east
    try testing.expectEqual(@as(u8, 0), e.aux[1]);

    // Looking away for one tick at 60 restarts the count.
    sim.init(&s, &L, 0, 1);
    s.player.hp = 30000;
    const t2 = (try boss_run(&s, &L, 400, 60)).?;
    try testing.expectEqual(@as(usize, 61 + boss_stare_ticks + boss_flicker_ticks), t2);

    // Never faced: no teleport.
    sim.init(&s, &L, 0, 1);
    s.player.hp = 30000;
    s.player.angle = fixed.deg(180);
    try testing.expectEqual(@as(?usize, null), try boss_run(&s, &L, 400, null));
}

test "teleport search: ring order and no target in a closet" {
    try testing.expectEqual([2]i32{ -1, -1 }, ring_cell(1, 0));
    try testing.expectEqual([2]i32{ 1, -1 }, ring_cell(1, 2));
    try testing.expectEqual([2]i32{ 1, 1 }, ring_cell(1, 4));
    try testing.expectEqual([2]i32{ -1, 1 }, ring_cell(1, 6));
    try testing.expectEqual([2]i32{ -1, 0 }, ring_cell(1, 7));
    var st: level_parse.Parsed = undefined;
    const L = try level_parse.parse_level(&st, "corridor", corridor_src, 0);
    var s: GameState = undefined;
    sim.init(&s, &L, 0, 1);
    // Facing east at x 1.5: behind is solid wall, nothing qualifies.
    try testing.expectEqual(@as(?[2]i32, null), teleport_target(&s, &L));
    // Facing west: the corridor cells 3 to 5 east of the player.
    s.player.angle = fixed.deg(180);
    const c = teleport_target(&s, &L).?;
    try testing.expectEqual(@as(i32, 1), c[1]);
    try testing.expect(c[0] >= 4 and c[0] <= 6);
}

const zoo_src =
    \\1111111111111111
    \\1....a....1....1
    \\1..w......D..b.1
    \\1S>.......1....1
    \\111D111111111D11
    \\1..s.......a...1
    \\1.........H....1
    \\1111111111111111
;

fn zoo_script(tick: u32) state.Buttons {
    var x = 0x1234567 ^ (tick / 16 *% 0x9E3779B9);
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return .{
        .up = x & 3 != 0,
        .down = x & 3 == 0 and x & 4 != 0,
        .left = x & 0x30 == 0x10,
        .right = x & 0x30 == 0x20,
        .a = x & 0x40 != 0,
    };
}

fn zoo_run(s: *GameState, L: *const Level, fill: u8) u32 {
    @memset(std.mem.asBytes(s), fill);
    sim.init(s, L, 0, 777);
    s.player.hp = 30000;
    var t: u32 = 0;
    while (t < 600) : (t += 1) sim.step(s, L, zoo_script(t));
    return sim.hash(s);
}

test "600 scripted ticks with 6 enemies hash the same twice" {
    var st: level_parse.Parsed = undefined;
    const L = try level_parse.parse_level(&st, "zoo", zoo_src, 0);
    try testing.expectEqual(@as(usize, 6), L.enemies.len);
    var a: GameState = undefined;
    var b: GameState = undefined;
    const h1 = zoo_run(&a, &L, 0xAA);
    const h2 = zoo_run(&b, &L, 0x55);
    try testing.expectEqual(h1, h2);
    try testing.expect(std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b)));
    // Something happened: the bugs woke up and the player got hurt.
    var woke: usize = 0;
    for (a.enemies[0..6]) |e| {
        if (is_awake(&e) or e.state == .dying or e.state == .dead) woke += 1;
    }
    try testing.expect(woke >= 3);
    try testing.expect(a.player.hp < 30000);
}

// ---------------------------------------------------------------- M5 balance

/// The Build Farm opening: the real level from `sim.init`, the player
/// standing in the first cell of the cable-tray room (just past the plain
/// door at x = 11, which a player standing at `S` never opens) facing east,
/// so its three gnats see them. Returns HP after 420 ticks.
fn farm_opening_hp(fire: bool) !i16 {
    var st: level_parse.Parsed = undefined;
    const L = try level_parse.parse_level(&st, "build_farm", @embedFile("levels/build_farm.txt"), 0);
    var s: GameState = undefined;
    sim.init(&s, &L, 0, 1);
    try testing.expectEqual(@as(u8, 0), s.player.angle >> 8); // facing east
    s.player.x = fixed.from_int(12) + fixed.half;
    for (0..420) |_| sim.step(&s, &L, .{ .a = fire });
    return s.player.hp;
}

// Measured with 4 every 40 at speed 0.05: standing still 4 HP (ignoring
// three gnats for 7 s nearly kills you), holding A without turning 60 HP.
test "Build Farm opening: three gnats nearly kill a player standing still for 420 ticks" {
    const hp = try farm_opening_hp(false);
    try testing.expect(hp > 0 and hp <= 25);
}

test "Build Farm opening: holding A with the zapper facing east ends at 45..75 HP" {
    const hp = try farm_opening_hp(true);
    try testing.expect(hp >= 45 and hp <= 75);
}

const arena_src =
    \\11111111111111
    \\1............1
    \\1............1
    \\1............1
    \\1............1
    \\1............1
    \\1.S>..H......1
    \\1............1
    \\1............1
    \\1............1
    \\1............1
    \\1............1
    \\1............1
    \\11111111111111
;

/// Heisenbug duel: 12x12 open room, boss 4 cells east, 99 charges, the
/// player holds A and turns to face the boss every tick. Returns
/// .{ ticks to kill (the tick the boss starts dying), player HP left };
/// ticks is null if the player died first or 3000 ticks ran out.
fn boss_duel() !struct { ?usize, i16 } {
    var st: level_parse.Parsed = undefined;
    const L = try level_parse.parse_level(&st, "arena", arena_src, 0);
    var s: GameState = undefined;
    sim.init(&s, &L, 0, 1);
    try testing.expectEqual(fixed.from_int(4), s.enemies[0].x - s.player.x);
    s.player.ammo_zapper = 99;
    const e = &s.enemies[0];
    for (0..3000) |t| {
        s.player.angle = fixed.atan2(e.y - s.player.y, e.x - s.player.x);
        sim.step(&s, &L, .{ .a = true });
        if (!sim.living(e)) return .{ t + 1, s.player.hp };
        if (s.player.hp <= 0) return .{ null, 0 };
    }
    return .{ null, s.player.hp };
}

// Measured M5: the boss dies on tick 313 (27 shots, one per 12-tick zapper
// cooldown). With the SPEC numbers it never fought back: each hit's 12-tick
// pain outlasted the cooldown gap (stunlock). Bosses therefore take no pain
// state (sim.damage_enemy), spit only beyond `shot_min` (2.5 cells; the
// point-blank fan did 24 a volley). Melee stays at the SPEC 15 every 45:
// the stand-and-shoot player wins with 15 HP left (10/60 gave 52, which
// Adrian judged impossible to lose). Hardware feel pass deferred; the
// `tuning` row is the knob.
test "Heisenbug duel: facing and zapping the boss wins, barely" {
    const r = try boss_duel();
    try testing.expect(r[0] != null);
    try testing.expect(r[1] > 0 and r[1] <= 40);
}

const pair_src =
    \\1111111111111111
    \\1..............1
    \\1..............1
    \\1S>.......a....1
    \\1.........a....1
    \\1..............1
    \\1111111111111111
;

const file_src =
    \\1111111111111111
    \\1..............1
    \\1..............1
    \\1S>.......aa...1
    \\1..............1
    \\1..............1
    \\1111111111111111
;

test "two gnats from adjacent cells never end a tick closer than the separation" {
    for ([_][]const u8{ pair_src, file_src }) |src| {
        var st: level_parse.Parsed = undefined;
        const L = try level_parse.parse_level(&st, "pair", src, 0);
        var s: GameState = undefined;
        sim.init(&s, &L, 0, 1);
        s.player.hp = 30000;
        for (s.enemies[0..2]) |*e| {
            e.aux[2] |= awake_bit;
            e.state = .chase;
        }
        var closest: i64 = std.math.maxInt(i64);
        for (0..300) |_| {
            sim.step(&s, &L, .{});
            const a = &s.enemies[0];
            const b = &s.enemies[1];
            const d = dist2(a.x - b.x, a.y - b.y);
            closest = @min(closest, d);
            try testing.expect(d >= sq(separation));
        }
        // They did close in on the player (and bit).
        try testing.expect(s.player.hp < 30000);
        try testing.expect(closest < sq(fixed.from_float(0.75)));
    }
}

test "a dormant or dying enemy does not block, a spider neither" {
    var st: level_parse.Parsed = undefined;
    const L = try level_parse.parse_level(&st, "file", file_src, 0);
    var s: GameState = undefined;
    sim.init(&s, &L, 0, 1);
    const a = &s.enemies[0];
    const b = &s.enemies[1];
    try testing.expect(!blocks(a)); // dormant
    b.aux[2] |= awake_bit;
    b.state = .chase;
    try testing.expect(blocks(b));
    try testing.expect(crowds(&s, &L, a, a.x + fixed.from_float(0.6), a.y, a.x + fixed.from_float(0.7), a.y));
    // Moving apart while already too close is allowed.
    try testing.expect(!crowds(&s, &L, a, b.x - fixed.from_float(0.2), a.y, b.x - fixed.from_float(0.3), a.y));
    b.state = .dying;
    try testing.expect(!blocks(b));
    b.state = .chase;
    b.kind = .spider;
    try testing.expect(!blocks(b));
}
