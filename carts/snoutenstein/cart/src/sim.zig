//! step(state, level, buttons): the whole simulation for one tick.
//! Pure over GameState, 16.16 fixed point only, no cart-api import, so
//! `zig test cart/src/sim.zig` runs on the host and replays are
//! bit-identical between the simulator and the badge (SPEC.md 9.3).
//! Movement with sliding collision, doors, pickups, weapons, player damage
//! and the rewind meter live here; enemy behaviour is ai.zig and
//! projectiles are projectiles.zig, both called from `step`.
const std = @import("std");
const fixed = @import("fixed.zig");
const state = @import("state.zig");
const levels = @import("levels.zig");
const level_parse = @import("level_parse.zig");
const ai = @import("ai.zig");
const projectiles = @import("projectiles.zig");

pub const GameState = state.GameState;
const Fixed = fixed.Fixed;
const Level = levels.Level;

pub const turn_speed: fixed.Angle = 455; // 2.5 degrees per tick
pub const walk_speed: Fixed = fixed.from_float(0.045);
pub const back_speed: Fixed = fixed.from_float(0.03);
/// Player (and, for door occupancy, enemy) radius. Collision treats the
/// circle as its bounding square, which is what makes sliding cheap.
pub const radius: Fixed = fixed.from_float(0.25);

/// A door is walkable once it is three quarters open (Wolf3D does the same).
pub const door_passable: u8 = 192;
pub const door_speed: u8 = 9; // per tick, 0 -> 255 in 29 ticks
pub const door_hold: u8 = 180; // ticks fully open before it tries to close

pub const door_closed = 0;
pub const door_opening = 1;
pub const door_open = 2;
pub const door_closing = 3;

pub const max_hp = 100;
/// Ticks the view flashes red after the player is hurt.
pub const hurt_ticks: u8 = 4;
/// Enemies wake on gunfire within this many cells (SPEC.md section 8).
pub const gunfire_radius: Fixed = fixed.from_int(8);
pub const max_zapper = 99;
pub const max_spray = 30;
pub const max_debugger = 9;
pub const max_rewind = 600;
pub const rewind_regen_ticks = 6;

pub const EnemyStats = struct {
    hp: i16,
    /// Hit-test radius in cells (the sprite is drawn 1 cell wide).
    radius: Fixed,
};

/// Indexed by `@intFromEnum(EnemyKind)` (SPEC.md section 8).
pub const enemy_stats = [5]EnemyStats{
    .{ .hp = 3, .radius = fixed.from_float(0.3) }, // gnat
    .{ .hp = 6, .radius = fixed.from_float(0.3) }, // wasp
    .{ .hp = 20, .radius = fixed.from_float(0.3) }, // beetle
    .{ .hp = 8, .radius = fixed.from_float(0.3) }, // spider
    .{ .hp = 80, .radius = fixed.from_float(0.3) }, // boss
};

pub fn stats(kind: state.EnemyKind) EnemyStats {
    return enemy_stats[@backingInt(kind)];
}

/// Enemy sprite sheet cells (walk, walk, attack, pain, death x3).
pub const frame_idle: u8 = 0;
pub const frame_attack: u8 = 2;
pub const frame_pain: u8 = 3;
pub const frame_dying: u8 = 4; // 4, 5, 6
pub const frame_dead: u8 = 6;

pub const flash_ticks: u8 = 2;
pub const pain_ticks: u8 = 12;
pub const dying_frame_ticks: u8 = 8;
pub const dying_ticks: u8 = 3 * dying_frame_ticks;

/// Weapons (SPEC.md section 7).
pub const swatter_damage: i16 = 4;
pub const swatter_reach: Fixed = fixed.from_float(1.2);
pub const swatter_cone: fixed.Angle = fixed.deg(15); // half-angle
pub const zapper_damage: i16 = 3;
pub const spray_damage: i16 = 2;
pub const spray_pellets = 5;
pub const spray_reach: Fixed = fixed.from_int(6);
pub const spray_jitter: fixed.Angle = fixed.deg(10); // +- per pellet
/// Hitscan rays stop here even in open space.
pub const max_ray: Fixed = fixed.from_int(24);

/// Ticks between shots.
pub fn fire_rate(w: state.Weapon) u8 {
    return switch (w) {
        .swatter => 24,
        .zapper => 12,
        .spray => 36,
        .debugger => 48,
    };
}

/// Fresh state at the start of `level`.
pub fn init(s: *GameState, level: *const Level, level_index: u8, seed: u32) void {
    // Every field has a default and no struct has padding (state.zig
    // asserts it), so this assignment defines every byte `hash` reads.
    s.* = .{
        .player = .{
            .x = fixed.from_int(level.start_x) + fixed.half,
            .y = fixed.from_int(level.start_y) + fixed.half,
            .angle = level.start_angle,
        },
        .level = level_index,
        .rng = if (seed == 0) 0x2545F491 else seed,
    };
    for (level.enemies, 0..) |e, i| {
        s.enemies[i] = .{
            .x = fixed.from_int(e.x) + fixed.half,
            .y = fixed.from_int(e.y) + fixed.half,
            .kind = e.kind,
            .state = .idle,
            .hp = stats(e.kind).hp,
            .frame = frame_idle,
        };
    }
}

pub fn step(s: *GameState, level: *const Level, b: state.Buttons) void {
    s.last_locked = 0;
    if (s.hurt > 0) s.hurt -= 1;
    const p = &s.player;
    if (b.left) p.angle -%= turn_speed;
    if (b.right) p.angle +%= turn_speed;
    var move: Fixed = 0;
    if (b.up) move = walk_speed;
    if (b.down) move = -back_speed;
    // A spider web freezes movement, not turning (SPEC.md section 8).
    if (p.frozen > 0) {
        p.frozen -= 1;
        move = 0;
    }
    if (move != 0) {
        _ = move_circle(s, level, &p.x, &p.y, fixed.mul(fixed.cos(p.angle), move), fixed.mul(fixed.sin(p.angle), move), radius, .player);
    }
    update_doors(s, level);
    enter_cell(s, level);
    // Enemies first: a hit this tick shows its flash/pain/dying frame at
    // full length (dying lasts exactly `dying_ticks` steps after the hit).
    ai.update(s, level);
    projectiles.update(s, level);
    update_weapon(s, level, b);
    regen_rewind(s);
    p.prev = b;
    s.tick +%= 1;
}

/// True if the cell blocks movement right now.
pub fn is_solid(s: *const GameState, level: *const Level, cx: i32, cy: i32) bool {
    const c = level.cell(cx, cy);
    if (Level.is_wall(c)) return true;
    if (Level.is_door(c)) return s.doors[Level.door_index(c)].open < door_passable;
    return c != 0; // reserved values count as solid
}

/// Who is moving: the player opens any door it has the key for and flags
/// locked ones; enemies open plain doors only, never secret ones.
pub const Mover = enum { player, enemy };

/// Move the circle at (x, y) of half-size `r` by (dx, dy) with sliding:
/// x first, then y, each axis pushing the box back out of a solid cell it
/// entered (|dx|, |dy| < r). Bumped doors are opened per `who`. Returns
/// true if either axis was blocked.
pub fn move_circle(s: *GameState, level: *const Level, x: *Fixed, y: *Fixed, dx: Fixed, dy: Fixed, r: Fixed, who: Mover) bool {
    var blocked = false;
    if (dx != 0) {
        var nx = x.* + dx;
        // Rows overlapped by the box [y - r, y + r) (the upper edge is exclusive).
        const r0 = fixed.to_int(y.* - r);
        const r1 = fixed.to_int(y.* + r - 1);
        const col = if (dx > 0) fixed.to_int(nx + r - 1) else fixed.to_int(nx - r);
        var hit = false;
        var row = r0;
        while (row <= r1) : (row += 1) {
            if (is_solid(s, level, col, row)) {
                hit = true;
                bump(s, level, col, row, who);
            }
        }
        if (hit) nx = if (dx > 0) fixed.from_int(col) - r else fixed.from_int(col + 1) + r;
        x.* = nx;
        blocked = blocked or hit;
    }
    if (dy != 0) {
        var ny = y.* + dy;
        const c0 = fixed.to_int(x.* - r);
        const c1 = fixed.to_int(x.* + r - 1);
        const row = if (dy > 0) fixed.to_int(ny + r - 1) else fixed.to_int(ny - r);
        var hit = false;
        var col = c0;
        while (col <= c1) : (col += 1) {
            if (is_solid(s, level, col, row)) {
                hit = true;
                bump(s, level, col, row, who);
            }
        }
        if (hit) ny = if (dy > 0) fixed.from_int(row) - r else fixed.from_int(row + 1) + r;
        y.* = ny;
        blocked = blocked or hit;
    }
    return blocked;
}

/// Something walked into a solid cell; if it is a door, try to open it.
fn bump(s: *GameState, level: *const Level, cx: i32, cy: i32, who: Mover) void {
    const c = level.cell(cx, cy);
    if (!Level.is_door(c)) return;
    const i = Level.door_index(c);
    const d = &s.doors[i];
    if (d.phase != door_closed and d.phase != door_closing) return;
    const kind = level.doors[i].kind;
    if (who == .enemy) {
        if (kind == .plain) d.phase = door_opening;
        return;
    }
    const need: u8 = switch (kind) {
        .coral => 1,
        .iris => 2,
        .gold => 4,
        .plain, .exit, .secret => 0,
    };
    if (s.player.keys & need != need) {
        s.last_locked = @backingInt(kind);
        return;
    }
    d.phase = door_opening;
}

/// Does a box of half-size `radius` centred on (x, y) overlap cell (cx, cy)?
fn box_overlaps(x: Fixed, y: Fixed, cx: i32, cy: i32) bool {
    const left = fixed.from_int(cx);
    const top = fixed.from_int(cy);
    return x - radius < left + fixed.one and x + radius > left and
        y - radius < top + fixed.one and y + radius > top;
}

fn door_occupied(s: *const GameState, cx: i32, cy: i32) bool {
    if (box_overlaps(s.player.x, s.player.y, cx, cy)) return true;
    for (s.enemies) |e| {
        if (e.state != .dead and box_overlaps(e.x, e.y, cx, cy)) return true;
    }
    return false;
}

fn update_doors(s: *GameState, level: *const Level) void {
    for (level.doors, 0..) |def, i| {
        const d = &s.doors[i];
        switch (d.phase) {
            door_opening => {
                d.open = @min(255, @as(u16, d.open) + door_speed);
                if (d.open == 255) {
                    d.phase = door_open;
                    d.timer = door_hold;
                }
            },
            door_open => {
                // Secret doors stay open for good once found.
                if (def.kind == .secret) continue;
                if (d.timer > 0) d.timer -= 1;
                if (d.timer == 0 and !door_occupied(s, def.x, def.y)) d.phase = door_closing;
            },
            door_closing => {
                if (door_occupied(s, def.x, def.y)) {
                    // Something stepped in while it was still passable: back open.
                    d.phase = door_opening;
                } else {
                    d.open -|= door_speed;
                    if (d.open == 0) d.phase = door_closed;
                }
            },
            else => {},
        }
    }
}

/// Pickups and the exit trigger on the cell under the player's centre.
fn enter_cell(s: *GameState, level: *const Level) void {
    const p = &s.player;
    const cx = fixed.to_int(p.x);
    const cy = fixed.to_int(p.y);
    const c = level.cell(cx, cy);
    if (Level.is_door(c) and level.doors[Level.door_index(c)].kind == .exit) s.finished = true;
    for (level.pickups, 0..) |pk, i| {
        if (pk.x != cx or pk.y != cy or !state.pickup_present(s, i)) continue;
        switch (pk.kind) {
            .key_coral => p.keys |= 1,
            .key_iris => p.keys |= 2,
            .key_gold => p.keys |= 4,
            .hotfix => p.hp = @min(max_hp, p.hp + 25),
            .charge => p.ammo_zapper = @min(max_zapper, @as(u16, p.ammo_zapper) + 8),
            .spray_can => {
                p.ammo_spray = @min(max_spray, @as(u16, p.ammo_spray) + 5);
                if (!p.has_spray) {
                    p.has_spray = true;
                    p.weapon = .spray;
                }
            },
            .battery => p.rewind_meter = @min(max_rewind, p.rewind_meter + 180),
            .debugger => {
                p.ammo_debugger = @min(max_debugger, @as(u16, p.ammo_debugger) + 3);
                if (!p.has_debugger) {
                    p.has_debugger = true;
                    p.weapon = .debugger;
                }
            },
        }
        state.take_pickup(s, i);
    }
}

fn regen_rewind(s: *GameState) void {
    const p = &s.player;
    p.rewind_regen += 1;
    if (p.rewind_regen >= rewind_regen_ticks) {
        p.rewind_regen = 0;
        if (p.rewind_meter < max_rewind) p.rewind_meter += 1;
    }
}

// ---------------------------------------------------------------- combat

pub fn living(e: *const state.Enemy) bool {
    return e.hp > 0 and switch (e.state) {
        .dying, .dead => false,
        else => true,
    };
}

/// Apply `d` damage to enemy `i`: flash, pain, or dying (counts the kill).
pub fn damage_enemy(s: *GameState, i: usize, d: i16) void {
    const e = &s.enemies[i];
    if (!living(e)) return;
    e.hp -= d;
    e.flash = flash_ticks;
    if (e.hp <= 0) {
        e.state = .dying;
        e.timer = dying_ticks;
        e.frame = frame_dying;
        s.kills +%= 1;
    } else if (e.kind == .boss) {
        // Bosses do not flinch (Wolf3D rule): a pain state as long as the
        // zapper cooldown would let a held A stunlock the Heisenbug (found
        // by the M5 duel test). The white flash still marks the hit.
    } else {
        e.state = .pain;
        e.timer = pain_ticks;
        e.frame = frame_pain;
    }
}

/// Hurt the player: HP floors at 0 (death is the caller's business: main
/// freezes time at hp 0) and the view flashes red for `hurt_ticks`.
pub fn damage_player(s: *GameState, amount: i16) void {
    const p = &s.player;
    if (p.hp <= 0) return;
    p.hp = @max(0, p.hp - amount);
    s.hurt = hurt_ticks;
}

/// Straight-line visibility between two points: no wall or shut door on
/// the segment and the segment shorter than `max_ray`.
pub fn line_of_sight(s: *const GameState, level: *const Level, x0: Fixed, y0: Fixed, x1: Fixed, y1: Fixed) bool {
    const rx = x1 - x0;
    const ry = y1 - y0;
    const d2 = @as(i64, rx) * rx + @as(i64, ry) * ry;
    const w = @as(i64, wall_distance(s, level, x0, y0, fixed.atan2(ry, rx)));
    if (w >= max_ray) return d2 < w * w;
    return d2 < w * w;
}

/// The simulation's xorshift32 (SPEC.md 9.3: never cart.rand).
pub fn next_rand(s: *GameState) u32 {
    var x = s.rng;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    s.rng = x;
    return x;
}

fn has_ammo(p: *const state.Player, w: state.Weapon) bool {
    return switch (w) {
        .swatter => true,
        .zapper => p.ammo_zapper > 0,
        .spray => p.has_spray and p.ammo_spray > 0,
        .debugger => p.has_debugger and p.ammo_debugger > 0,
    };
}

/// Select cycles swatter -> zapper -> spray -> swatter, skipping empty ones.
fn next_weapon(p: *const state.Player) state.Weapon {
    var w = p.weapon;
    for (0..4) |_| {
        w = switch (w) {
            .swatter => .zapper,
            .zapper => .spray,
            .spray => .debugger,
            .debugger => .swatter,
        };
        if (has_ammo(p, w)) return w;
    }
    return p.weapon;
}

fn update_weapon(s: *GameState, level: *const Level, b: state.Buttons) void {
    const p = &s.player;
    if (b.select and !p.prev.select) p.weapon = next_weapon(p);
    if (p.fire_cooldown > 0) p.fire_cooldown -= 1;
    if (!b.a or p.fire_cooldown != 0) return;
    switch (p.weapon) {
        .swatter => swat(s, level),
        .zapper => {
            if (p.ammo_zapper == 0) return;
            p.ammo_zapper -= 1;
            s.last_shot = s.tick;
            const ray = cast(s, level, p.angle, max_ray);
            if (ray) |i| damage_enemy(s, i, zapper_damage);
        },
        .spray => {
            if (p.ammo_spray == 0) return;
            p.ammo_spray -= 1;
            s.last_shot = s.tick;
            const span: u32 = 2 * @as(u32, spray_jitter) + 1;
            for (0..spray_pellets) |_| {
                const j: i32 = @as(i32, @intCast(next_rand(s) % span)) - spray_jitter;
                const a: fixed.Angle = p.angle +% @as(u16, @bitCast(@as(i16, @intCast(j))));
                if (cast(s, level, a, spray_reach)) |i| damage_enemy(s, i, spray_damage);
            }
        },
        .debugger => {
            // M6 track A: fire the bolt (projectiles.kind_debug).
            if (p.ammo_debugger == 0) return;
            p.ammo_debugger -= 1;
            s.last_shot = s.tick;
        },
    }
    p.fire_cooldown = fire_rate(p.weapon);
}

/// Hitscan from the player along `angle`: the living enemy with the
/// smallest along-ray distance `t` such that `0 < t < reach`, `t` short of
/// the first wall, and the enemy centre within its radius of the ray.
fn cast(s: *const GameState, level: *const Level, angle: fixed.Angle, reach: Fixed) ?usize {
    const p = &s.player;
    const dx = fixed.cos(angle);
    const dy = fixed.sin(angle);
    const limit = @min(reach, wall_distance(s, level, p.x, p.y, angle));
    var best: ?usize = null;
    var best_t: Fixed = limit;
    for (&s.enemies, 0..) |*e, i| {
        if (!living(e)) continue;
        const rx = e.x - p.x;
        const ry = e.y - p.y;
        const t = fixed.mul(rx, dx) + fixed.mul(ry, dy);
        if (t <= 0 or t >= best_t) continue;
        const lat = fixed.mul(rx, dy) - fixed.mul(ry, dx);
        if (fixed.abs(lat) >= stats(e.kind).radius) continue;
        best = i;
        best_t = t;
    }
    return best;
}

/// Swatter: nearest living enemy within reach and the facing cone, in sight.
fn swat(s: *GameState, level: *const Level) void {
    const p = &s.player;
    const reach_sq = @as(i64, swatter_reach) * swatter_reach;
    var best: ?usize = null;
    var best_d: i64 = reach_sq + 1;
    for (&s.enemies, 0..) |*e, i| {
        if (!living(e)) continue;
        const rx = e.x - p.x;
        const ry = e.y - p.y;
        const d = @as(i64, rx) * rx + @as(i64, ry) * ry;
        if (d >= best_d) continue;
        const a = fixed.atan2(ry, rx);
        const off = fixed.angle_diff(a, p.angle);
        if (off > @as(i32, swatter_cone) or off < -@as(i32, swatter_cone)) continue;
        const w = @as(i64, wall_distance(s, level, p.x, p.y, a));
        if (d >= w * w) continue;
        best = i;
        best_d = d;
    }
    if (best) |i| damage_enemy(s, i, swatter_damage);
}

/// Distance from (x, y) along `angle` to the first solid cell (walls, and
/// doors while less than `door_passable` open), capped at `max_ray`.
/// Fixed-point DDA over grid lines; 0 if (x, y) is itself inside a solid cell.
pub fn wall_distance(s: *const GameState, level: *const Level, x: Fixed, y: Fixed, angle: fixed.Angle) Fixed {
    var cx = fixed.to_int(x);
    var cy = fixed.to_int(y);
    if (is_solid(s, level, cx, cy)) return 0;
    const dx: i64 = fixed.cos(angle);
    const dy: i64 = fixed.sin(angle);
    const cap: i64 = max_ray;
    // Ray length per cell crossed on each axis (16.16), "infinite" if parallel.
    const never: i64 = cap * 4;
    const delta_x: i64 = if (dx == 0) never else @min(never, @divTrunc(@as(i64, fixed.one) << 16, @as(i64, @intCast(@abs(dx)))));
    const delta_y: i64 = if (dy == 0) never else @min(never, @divTrunc(@as(i64, fixed.one) << 16, @as(i64, @intCast(@abs(dy)))));
    const step_x: i32 = if (dx < 0) -1 else 1;
    const step_y: i32 = if (dy < 0) -1 else 1;
    const fx: i64 = fixed.frac(x);
    const fy: i64 = fixed.frac(y);
    var side_x: i64 = ((if (dx < 0) fx else fixed.one - fx) * delta_x) >> 16;
    var side_y: i64 = ((if (dy < 0) fy else fixed.one - fy) * delta_y) >> 16;
    while (true) {
        var t: i64 = undefined;
        if (side_x < side_y) {
            t = side_x;
            side_x += delta_x;
            cx += step_x;
        } else {
            t = side_y;
            side_y += delta_y;
            cy += step_y;
        }
        if (t >= cap) return max_ray;
        if (is_solid(s, level, cx, cy)) return @intCast(t);
    }
}

/// FNV-1a over the raw bytes of the state, for determinism checks.
pub fn hash(s: *const GameState) u32 {
    var h: u32 = 2166136261;
    for (std.mem.asBytes(s)) |byte| {
        h ^= byte;
        h *%= 16777619;
    }
    return h;
}

/// `hash` with the rewind bookkeeping zeroed (`player.rewind_meter`,
/// `player.rewind_regen`, `rewinds`). A state committed by a rewind
/// differs from the state that was live at that tick only in those
/// fields (the meter was drained, the counter bumped), so this is what
/// `check_determinism.mjs --rewind-at` compares (PLAN.md M4).
pub fn hash_gameplay(s: *const GameState) u32 {
    var c = s.*;
    c.player.rewind_meter = 0;
    c.player.rewind_regen = 0;
    c.rewinds = 0;
    return hash(&c);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn run(s: *GameState, level: *const Level, b: state.Buttons, n: usize) void {
    for (0..n) |_| step(s, level, b);
}

test "init places the player at the start cell centre" {
    var s: GameState = undefined;
    init(&s, &levels.all[0], 0, 1);
    try testing.expectEqual(fixed.from_int(3) + fixed.half, s.player.x);
    step(&s, &levels.all[0], .{ .up = true });
    try testing.expect(s.player.x > fixed.from_int(3) + fixed.half);
}

const room_src =
    \\1111111
    \\1S>...1
    \\1.....1
    \\1.....1
    \\1.....1
    \\1.....1
    \\1111111
;

test "walking into a wall stops at the radius" {
    var room_st: level_parse.Parsed = undefined;
    const room = try level_parse.parse_level(&room_st, "room", room_src, 0);
    var s: GameState = undefined;
    init(&s, &room, 0, 1);
    run(&s, &room, .{ .up = true }, 200);
    try testing.expectEqual(fixed.from_int(6) - radius, s.player.x);
    try testing.expectEqual(fixed.from_int(1) + fixed.half, s.player.y);
    // Backing into the west wall stops at its radius too.
    run(&s, &room, .{ .down = true }, 300);
    try testing.expectEqual(fixed.from_int(1) + radius, s.player.x);
}

test "sliding along a wall keeps the tangential movement" {
    var room_st: level_parse.Parsed = undefined;
    const room = try level_parse.parse_level(&room_st, "room", room_src, 0);
    var s: GameState = undefined;
    init(&s, &room, 0, 1);
    s.player.angle = fixed.deg(20); // mostly east, a little south
    run(&s, &room, .{ .up = true }, 120); // well past contact with x = 6
    try testing.expectEqual(fixed.from_int(6) - radius, s.player.x);
    const dy = fixed.mul(fixed.sin(s.player.angle), walk_speed);
    for (0..10) |_| {
        const y0 = s.player.y;
        step(&s, &room, .{ .up = true });
        try testing.expectEqual(fixed.from_int(6) - radius, s.player.x);
        try testing.expectEqual(y0 + dy, s.player.y);
    }
    // And it stops again in the south-east corner.
    run(&s, &room, .{ .up = true }, 400);
    try testing.expectEqual(fixed.from_int(6) - radius, s.player.x);
    try testing.expectEqual(fixed.from_int(6) - radius, s.player.y);
}

const door_level_src =
    \\11111111
    \\1S>.D..1
    \\11111111
;

test "a door opens over 30 ticks, is passable at 192, then closes" {
    var door_level_st: level_parse.Parsed = undefined;
    const door_level = try level_parse.parse_level(&door_level_st, "door", door_level_src, 0);
    const L = &door_level;
    var s: GameState = undefined;
    init(&s, L, 0, 1);
    try testing.expect(L.doors[0].vertical);
    // Stand flush against the door (x + r == 4).
    s.player.x = fixed.from_int(4) - radius;
    try testing.expect(is_solid(&s, L, 4, 1));
    step(&s, L, .{ .up = true }); // bump: opening starts this tick
    try testing.expectEqual(@as(u8, door_opening), s.doors[0].phase);
    try testing.expectEqual(@as(u8, 9), s.doors[0].open);
    try testing.expectEqual(fixed.from_int(4) - radius, s.player.x);
    var ticks: usize = 1;
    while (s.doors[0].open < door_passable) : (ticks += 1) {
        try testing.expect(is_solid(&s, L, 4, 1));
        step(&s, L, .{ .up = true });
        if (s.doors[0].open < door_passable) try testing.expectEqual(fixed.from_int(4) - radius, s.player.x);
    }
    try testing.expectEqual(@as(usize, 22), ticks); // 22 * 9 = 198
    try testing.expect(!is_solid(&s, L, 4, 1));
    // The player moves in on the next tick.
    step(&s, L, .{});
    step(&s, L, .{ .up = true });
    try testing.expect(s.player.x > fixed.from_int(4) - radius);
    ticks += 2;
    while (s.doors[0].phase == door_opening) : (ticks += 1) step(&s, L, .{});
    try testing.expectEqual(@as(usize, 29), ticks); // fully open within 30 ticks
    try testing.expectEqual(@as(u8, 255), s.doors[0].open);
    try testing.expectEqual(door_hold, s.doors[0].timer);
    // Stand in the doorway past the hold time: it stays open.
    s.player.x = fixed.from_int(4) + fixed.half;
    run(&s, L, .{}, 300);
    try testing.expectEqual(@as(u8, door_open), s.doors[0].phase);
    try testing.expectEqual(@as(u8, 255), s.doors[0].open);
    // Step out east: it closes at the same rate, back to 0.
    s.player.x = fixed.from_int(5) + fixed.half;
    step(&s, L, .{});
    try testing.expectEqual(@as(u8, door_closing), s.doors[0].phase);
    run(&s, L, .{}, 29);
    try testing.expectEqual(@as(u8, 0), s.doors[0].open);
    try testing.expectEqual(@as(u8, door_closed), s.doors[0].phase);
    try testing.expect(is_solid(&s, L, 4, 1));
}

test "a door holds open for 180 ticks and reopens if entered while closing" {
    var door_level_st: level_parse.Parsed = undefined;
    const door_level = try level_parse.parse_level(&door_level_st, "door", door_level_src, 0);
    const L = &door_level;
    var s: GameState = undefined;
    init(&s, L, 0, 1);
    s.player.x = fixed.from_int(4) - radius;
    step(&s, L, .{ .up = true });
    run(&s, L, .{}, 28);
    try testing.expectEqual(@as(u8, door_open), s.doors[0].phase);
    run(&s, L, .{}, door_hold - 1);
    try testing.expectEqual(@as(u8, door_open), s.doors[0].phase);
    step(&s, L, .{});
    try testing.expectEqual(@as(u8, door_closing), s.doors[0].phase);
    step(&s, L, .{});
    try testing.expectEqual(@as(u8, 246), s.doors[0].open);
    step(&s, L, .{ .up = true }); // passable (246 >= 192): walk into the doorway
    try testing.expect(s.player.x > fixed.from_int(4) - radius);
    try testing.expectEqual(@as(u8, door_opening), s.doors[0].phase);
    try testing.expectEqual(@as(u8, 246), s.doors[0].open);
}

const locked_level_src =
    \\11111111
    \\1S>.C..1
    \\11111111
;

test "a locked door stays shut without the key and opens with it" {
    var locked_level_st: level_parse.Parsed = undefined;
    const locked_level = try level_parse.parse_level(&locked_level_st, "locked", locked_level_src, 0);
    const L = &locked_level;
    var s: GameState = undefined;
    init(&s, L, 0, 1);
    s.player.x = fixed.from_int(4) - radius;
    s.player.keys = 2 | 4; // iris and gold, but not coral
    for (0..60) |_| {
        step(&s, L, .{ .up = true });
        try testing.expectEqual(@as(u8, @backingInt(levels.DoorKind.coral)), s.last_locked);
        try testing.expectEqual(@as(u8, door_closed), s.doors[0].phase);
        try testing.expectEqual(@as(u8, 0), s.doors[0].open);
        try testing.expectEqual(fixed.from_int(4) - radius, s.player.x);
    }
    step(&s, L, .{});
    try testing.expectEqual(@as(u8, 0), s.last_locked); // cleared every tick
    s.player.keys |= 1;
    step(&s, L, .{ .up = true });
    try testing.expectEqual(@as(u8, 0), s.last_locked);
    try testing.expectEqual(@as(u8, door_opening), s.doors[0].phase);
    run(&s, L, .{ .up = true }, 60);
    try testing.expect(s.player.x > fixed.from_int(5));
}

const exit_level_src =
    \\111111
    \\1S>.E1
    \\111111
;

test "the exit door opens and finishes the level when entered" {
    var exit_level_st: level_parse.Parsed = undefined;
    const exit_level = try level_parse.parse_level(&exit_level_st, "exit", exit_level_src, 0);
    const L = &exit_level;
    var s: GameState = undefined;
    init(&s, L, 0, 1);
    var n: usize = 0;
    while (!s.finished and n < 200) : (n += 1) step(&s, L, .{ .up = true });
    try testing.expect(s.finished);
    try testing.expectEqual(@as(i32, 4), fixed.to_int(s.player.x));
}

const secret_level_src =
    \\1111111111
    \\1....5...1
    \\1S>..X$..1
    \\1....5...1
    \\1........1
    \\1.a......1
    \\1111111111
;

test "a secret door opens for the player, never closes, and enemies cannot open it" {
    var st: level_parse.Parsed = undefined;
    const L = try level_parse.parse_level(&st, "secret", secret_level_src, 0);
    try testing.expectEqual(levels.DoorKind.secret, L.doors[0].kind);
    try testing.expectEqual(@as(u8, 4), L.doors[0].tex);
    try testing.expect(L.doors[0].vertical); // walls above and below: the panel runs north-south
    var s: GameState = undefined;
    init(&s, &L, 0, 1);
    // An enemy walking into it does nothing.
    bump(&s, &L, 5, 2, .enemy);
    try testing.expectEqual(@as(u8, door_closed), s.doors[0].phase);
    // The player walks east into the panel: it opens.
    var n: usize = 0;
    while (s.doors[0].phase == door_closed and n < 200) : (n += 1) step(&s, &L, .{ .up = true });
    try testing.expectEqual(@as(u8, door_opening), s.doors[0].phase);
    while (s.doors[0].phase == door_opening) step(&s, &L, .{});
    try testing.expectEqual(@as(u8, door_open), s.doors[0].phase);
    // Long after the plain-door hold time, still open, nobody inside it.
    for (0..3 * @as(usize, door_hold)) |_| step(&s, &L, .{ .down = true });
    try testing.expectEqual(@as(u8, door_open), s.doors[0].phase);
    try testing.expectEqual(@as(u8, 255), s.doors[0].open);
}

const pickup_level_src =
    \\111111111111
    \\1S>cig+%$*$1
    \\111111111111
;

test "pickups clear their bit and clamp" {
    var pickup_level_st: level_parse.Parsed = undefined;
    const pickup_level = try level_parse.parse_level(&pickup_level_st, "pickups", pickup_level_src, 0);
    const L = &pickup_level;
    var s: GameState = undefined;
    init(&s, L, 0, 1);
    s.player.hp = 90;
    s.player.ammo_zapper = 95;
    s.player.ammo_spray = 27;
    s.player.rewind_meter = 500;
    s.player.weapon = .zapper;
    run(&s, L, .{ .up = true }, 400);
    try testing.expectEqual(fixed.from_int(11) - radius, s.player.x);
    for (0..L.pickups.len) |i| try testing.expect(!state.pickup_present(&s, i));
    try testing.expect(state.pickup_present(&s, L.pickups.len)); // unused bits untouched
    try testing.expectEqual(@as(u8, 7), s.player.keys);
    try testing.expectEqual(@as(i16, 100), s.player.hp);
    try testing.expectEqual(@as(u8, 99), s.player.ammo_zapper);
    try testing.expectEqual(@as(u8, 30), s.player.ammo_spray);
    try testing.expectEqual(@as(u16, 600), s.player.rewind_meter);
    try testing.expect(s.player.has_spray);
    try testing.expectEqual(state.Weapon.spray, s.player.weapon);

    // Unclamped amounts, one pickup at a time, and no double pickup.
    init(&s, L, 0, 1);
    s.player.hp = 50;
    s.player.ammo_zapper = 10;
    s.player.rewind_meter = 100;
    s.player.weapon = .swatter;
    run(&s, L, .{ .up = true }, 400);
    try testing.expectEqual(@as(i16, 75), s.player.hp);
    try testing.expectEqual(@as(u8, 18), s.player.ammo_zapper);
    try testing.expectEqual(@as(u8, 10), s.player.ammo_spray); // two cans
    // 180 from the battery plus 400 / 6 = 66 regen ticks.
    try testing.expectEqual(@as(u16, 100 + 180 + 66), s.player.rewind_meter);
    run(&s, L, .{ .down = true }, 400);
    try testing.expectEqual(@as(i16, 75), s.player.hp);
    try testing.expectEqual(@as(u8, 10), s.player.ammo_spray);
}

test "hash_gameplay ignores the rewind meter and counter" {
    var room_st: level_parse.Parsed = undefined;
    const room = try level_parse.parse_level(&room_st, "room", room_src, 0);
    var a: GameState = undefined;
    init(&a, &room, 0, 7);
    var b = a;
    b.player.rewind_meter = 12;
    b.player.rewind_regen = 3;
    b.rewinds = 2;
    try testing.expect(hash(&a) != hash(&b));
    try testing.expectEqual(hash_gameplay(&a), hash_gameplay(&b));
    b.player.hp -= 1;
    try testing.expect(hash_gameplay(&a) != hash_gameplay(&b));
}

test "rewind meter regenerates 1 per 6 ticks up to 600" {
    var room_st: level_parse.Parsed = undefined;
    const room = try level_parse.parse_level(&room_st, "room", room_src, 0);
    var s: GameState = undefined;
    init(&s, &room, 0, 1);
    s.player.rewind_meter = 590;
    run(&s, &room, .{}, 6);
    try testing.expectEqual(@as(u16, 591), s.player.rewind_meter);
    run(&s, &room, .{}, 5);
    try testing.expectEqual(@as(u16, 591), s.player.rewind_meter);
    run(&s, &room, .{}, 1000);
    try testing.expectEqual(@as(u16, 600), s.player.rewind_meter);
}

/// Deterministic pseudo-random input script (xorshift over the tick).
fn script(seed: u32, tick: u32) state.Buttons {
    var x = seed ^ (tick / 20 *% 0x9E3779B9);
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return .{
        .up = x & 3 != 0,
        .down = x & 3 == 0 and x & 4 != 0,
        .left = x & 0x30 == 0x10,
        .right = x & 0x30 == 0x20,
        .a = x & 0x40 != 0,
        .select = x & 0x380 == 0x380,
    };
}

fn run_script(buf: *GameState, fill: u8, seed: u32) u32 {
    @memset(std.mem.asBytes(buf), fill); // garbage underneath must not matter
    const L = &levels.all[0];
    init(buf, L, 0, 1234);
    var t: u32 = 0;
    while (t < 600) : (t += 1) step(buf, L, script(seed, t));
    return hash(buf);
}

test "same 600-tick script gives the same hash, a different one does not" {
    var a: GameState = undefined;
    var b: GameState = undefined;
    const h1 = run_script(&a, 0xAA, 1);
    const h2 = run_script(&b, 0x55, 1);
    try testing.expectEqual(h1, h2);
    try testing.expect(std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b)));
    const h3 = run_script(&b, 0x00, 2);
    try testing.expect(h1 != h3);
    // The script fired: the zapper spent charge.
    try testing.expect(a.player.ammo_zapper < 40 or a.player.weapon != .zapper);
    // The script actually moved the player somewhere.
    try testing.expect(a.player.x != fixed.from_int(3) + fixed.half or a.player.y != fixed.from_int(3) + fixed.half);
}

// ---------------------------------------------------------------- combat tests

const arena_src =
    \\111111111111
    \\1S>........1
    \\1..........1
    \\1..........1
    \\1.....a....1
    \\111111111111
;

/// Fresh arena with enemy 0 turned into `kind` at (x, y) and the player
/// at the start (1.5, 1.5) facing east.
fn arena_with(s: *GameState, L: *const Level, kind: state.EnemyKind, x: Fixed, y: Fixed) void {
    init(s, L, 0, 1);
    s.enemies[0].kind = kind;
    s.enemies[0].hp = stats(kind).hp;
    s.enemies[0].x = x;
    s.enemies[0].y = y;
}

const px0 = fixed.from_int(1) + fixed.half;

test "init gives enemies their real hp, idle, frame 0" {
    var arena_st: level_parse.Parsed = undefined;
    const arena = try level_parse.parse_level(&arena_st, "arena", arena_src, 0);
    var s: GameState = undefined;
    init(&s, &arena, 0, 1);
    try testing.expectEqual(state.EnemyState.idle, s.enemies[0].state);
    try testing.expectEqual(@as(i16, 3), s.enemies[0].hp);
    try testing.expectEqual(@as(u8, 0), s.enemies[0].frame);
    try testing.expectEqual(state.EnemyState.dead, s.enemies[1].state); // unused slot
    try testing.expectEqual(@as(i16, 20), stats(.beetle).hp);
    try testing.expectEqual(@as(i16, 80), stats(.boss).hp);
}

test "zapper kills a gnat in one shot and spends a charge" {
    var arena_st: level_parse.Parsed = undefined;
    const arena = try level_parse.parse_level(&arena_st, "arena", arena_src, 0);
    var s: GameState = undefined;
    arena_with(&s, &arena, .gnat, fixed.from_int(5) + fixed.half, px0);
    step(&s, &arena, .{ .a = true });
    try testing.expectEqual(state.EnemyState.dying, s.enemies[0].state);
    try testing.expectEqual(@as(i16, 0), s.enemies[0].hp);
    try testing.expectEqual(@as(u8, 39), s.player.ammo_zapper);
    try testing.expectEqual(@as(u16, 1), s.kills);
    try testing.expectEqual(@as(u8, 12), s.player.fire_cooldown);
    // A ray that passes beside the gnat (lateral 0.35 > radius 0.3) misses.
    arena_with(&s, &arena, .gnat, fixed.from_int(5) + fixed.half, px0 + fixed.from_float(0.35));
    step(&s, &arena, .{ .a = true });
    try testing.expectEqual(@as(i16, 3), s.enemies[0].hp);
    try testing.expectEqual(@as(u8, 39), s.player.ammo_zapper);
    // Behind the player: no hit either.
    arena_with(&s, &arena, .gnat, px0, px0);
    s.player.x = fixed.from_int(3) + fixed.half;
    step(&s, &arena, .{ .a = true });
    try testing.expectEqual(@as(i16, 3), s.enemies[0].hp);
}

test "zapper cooldown blocks the next shot for 12 ticks" {
    var arena_st: level_parse.Parsed = undefined;
    const arena = try level_parse.parse_level(&arena_st, "arena", arena_src, 0);
    var s: GameState = undefined;
    arena_with(&s, &arena, .wasp, fixed.from_int(5) + fixed.half, px0);
    step(&s, &arena, .{ .a = true });
    try testing.expectEqual(@as(i16, 3), s.enemies[0].hp);
    try testing.expectEqual(state.EnemyState.pain, s.enemies[0].state);
    for (0..11) |_| {
        step(&s, &arena, .{ .a = true });
        try testing.expectEqual(@as(i16, 3), s.enemies[0].hp);
    }
    try testing.expectEqual(@as(u8, 39), s.player.ammo_zapper);
    step(&s, &arena, .{ .a = true }); // 12 ticks after the first shot
    try testing.expectEqual(@as(i16, 0), s.enemies[0].hp);
    try testing.expectEqual(state.EnemyState.dying, s.enemies[0].state);
    try testing.expectEqual(@as(u8, 38), s.player.ammo_zapper);
}

test "zapper with no charge does nothing" {
    var arena_st: level_parse.Parsed = undefined;
    const arena = try level_parse.parse_level(&arena_st, "arena", arena_src, 0);
    var s: GameState = undefined;
    arena_with(&s, &arena, .gnat, fixed.from_int(5) + fixed.half, px0);
    s.player.ammo_zapper = 0;
    run(&s, &arena, .{ .a = true }, 30);
    try testing.expectEqual(@as(i16, 3), s.enemies[0].hp);
    try testing.expectEqual(@as(u8, 0), s.player.fire_cooldown);
}

test "pain flashes 2 ticks, shows frame 3 for 12 ticks, then idles" {
    var arena_st: level_parse.Parsed = undefined;
    const arena = try level_parse.parse_level(&arena_st, "arena", arena_src, 0);
    var s: GameState = undefined;
    arena_with(&s, &arena, .beetle, fixed.from_int(5) + fixed.half, px0);
    step(&s, &arena, .{ .a = true });
    try testing.expectEqual(@as(u8, 2), s.enemies[0].flash);
    try testing.expectEqual(@as(u8, 3), s.enemies[0].frame);
    step(&s, &arena, .{});
    try testing.expectEqual(@as(u8, 1), s.enemies[0].flash);
    step(&s, &arena, .{});
    try testing.expectEqual(@as(u8, 0), s.enemies[0].flash);
    run(&s, &arena, .{}, 9);
    try testing.expectEqual(state.EnemyState.pain, s.enemies[0].state);
    try testing.expectEqual(@as(u8, 3), s.enemies[0].frame);
    step(&s, &arena, .{});
    try testing.expectEqual(state.EnemyState.idle, s.enemies[0].state);
    try testing.expectEqual(@as(u8, 0), s.enemies[0].frame);
    try testing.expectEqual(@as(i16, 17), s.enemies[0].hp);
}

const wall_level_src =
    \\1111111111
    \\1S>..1.a.1
    \\1111111111
;

test "a wall between blocks the shot" {
    var wall_level_st: level_parse.Parsed = undefined;
    const wall_level = try level_parse.parse_level(&wall_level_st, "wall", wall_level_src, 0);
    var s: GameState = undefined;
    init(&s, &wall_level, 0, 1);
    try testing.expectEqual(fixed.from_float(3.5), wall_distance(&s, &wall_level, s.player.x, s.player.y, 0));
    step(&s, &wall_level, .{ .a = true });
    try testing.expectEqual(@as(i16, 3), s.enemies[0].hp);
    try testing.expectEqual(@as(u8, 39), s.player.ammo_zapper); // the shot still costs
}

const long_src =
    \\1111111111111111111111111111111111
    \\1S>..............................1
    \\1111111111111111111111111111111111
;

test "wall_distance: doors, cap, directions" {
    var door_level_st: level_parse.Parsed = undefined;
    const door_level = try level_parse.parse_level(&door_level_st, "door", door_level_src, 0);
    var long_st: level_parse.Parsed = undefined;
    const long = try level_parse.parse_level(&long_st, "long", long_src, 0);
    var room_st: level_parse.Parsed = undefined;
    const room = try level_parse.parse_level(&room_st, "room", room_src, 0);
    var s: GameState = undefined;
    const L = &door_level;
    init(&s, L, 0, 1);
    const x = s.player.x;
    const y = s.player.y;
    try testing.expectEqual(fixed.from_float(2.5), wall_distance(&s, L, x, y, 0));
    s.doors[0].open = door_passable - 1;
    try testing.expectEqual(fixed.from_float(2.5), wall_distance(&s, L, x, y, 0));
    s.doors[0].open = door_passable;
    try testing.expectEqual(fixed.from_float(5.5), wall_distance(&s, L, x, y, 0));
    try testing.expectEqual(fixed.half, wall_distance(&s, L, x, y, fixed.deg(180)));
    try testing.expectEqual(fixed.half, wall_distance(&s, L, x, y, fixed.angle_quarter));
    try testing.expectEqual(fixed.half, wall_distance(&s, L, x, y, 3 * fixed.angle_quarter));
    // Inside a wall: 0. Long open line: capped.
    try testing.expectEqual(@as(Fixed, 0), wall_distance(&s, L, fixed.half, y, 0));
    init(&s, &long, 0, 1);
    try testing.expectEqual(max_ray, wall_distance(&s, &long, s.player.x, s.player.y, 0));
    // A diagonal in the 5x5 room: from (1.5, 1.5) at 45 degrees the ray
    // reaches the far corner region, about 4.5 * sqrt(2) = 6.36 cells.
    init(&s, &room, 0, 1);
    const d = wall_distance(&s, &room, s.player.x, s.player.y, fixed.deg(45));
    try testing.expect(d > fixed.from_float(6.2) and d < fixed.from_float(6.5));
}

test "swatter hits at 1.0 cells, misses at 1.5 or 30 degrees off" {
    var arena_st: level_parse.Parsed = undefined;
    const arena = try level_parse.parse_level(&arena_st, "arena", arena_src, 0);
    var s: GameState = undefined;
    const cx = fixed.from_int(3) + fixed.half;
    const cy = fixed.from_int(2) + fixed.half;
    const cases = [_]struct { dist: Fixed, deg: fixed.Angle, hit: bool }{
        .{ .dist = fixed.one, .deg = 0, .hit = true },
        .{ .dist = fixed.from_float(1.15), .deg = 0, .hit = true },
        .{ .dist = fixed.one, .deg = fixed.deg(10), .hit = true },
        .{ .dist = fixed.one, .deg = 0 -% fixed.deg(10), .hit = true },
        .{ .dist = fixed.from_float(1.5), .deg = 0, .hit = false },
        .{ .dist = fixed.one, .deg = fixed.deg(30), .hit = false },
        .{ .dist = fixed.one, .deg = 0 -% fixed.deg(30), .hit = false },
        .{ .dist = fixed.one, .deg = fixed.deg(180), .hit = false },
    };
    for (cases) |c| {
        // Facing north-west-ish too, so the cone test crosses angle 0 wrap.
        for ([_]fixed.Angle{ 0, fixed.deg(5) }) |facing| {
            const a = facing +% c.deg;
            arena_with(&s, &arena, .wasp, cx + fixed.mul(fixed.cos(a), c.dist), cy + fixed.mul(fixed.sin(a), c.dist));
            s.player.x = cx;
            s.player.y = cy;
            s.player.angle = facing;
            s.player.weapon = .swatter;
            step(&s, &arena, .{ .a = true });
            try testing.expectEqual(@as(i16, if (c.hit) 2 else 6), s.enemies[0].hp);
            try testing.expectEqual(@as(u8, 24), s.player.fire_cooldown);
            try testing.expectEqual(@as(u8, 40), s.player.ammo_zapper);
        }
    }
}

test "Select cycles weapons and skips empty ones" {
    var arena_st: level_parse.Parsed = undefined;
    const arena = try level_parse.parse_level(&arena_st, "arena", arena_src, 0);
    var s: GameState = undefined;
    init(&s, &arena, 0, 1);
    const sel: state.Buttons = .{ .select = true };
    try testing.expectEqual(state.Weapon.zapper, s.player.weapon);
    step(&s, &arena, sel); // no spray yet: skip to swatter
    try testing.expectEqual(state.Weapon.swatter, s.player.weapon);
    run(&s, &arena, sel, 10); // held: one cycle per press
    try testing.expectEqual(state.Weapon.swatter, s.player.weapon);
    step(&s, &arena, .{});
    step(&s, &arena, sel);
    try testing.expectEqual(state.Weapon.zapper, s.player.weapon);
    // With the spray and cans: zapper -> spray -> swatter.
    s.player.has_spray = true;
    s.player.ammo_spray = 5;
    step(&s, &arena, .{});
    step(&s, &arena, sel);
    try testing.expectEqual(state.Weapon.spray, s.player.weapon);
    step(&s, &arena, .{});
    step(&s, &arena, sel);
    try testing.expectEqual(state.Weapon.swatter, s.player.weapon);
    // Zapper empty: swatter -> spray.
    s.player.ammo_zapper = 0;
    step(&s, &arena, .{});
    step(&s, &arena, sel);
    try testing.expectEqual(state.Weapon.spray, s.player.weapon);
    // Everything empty: the swatter is never skipped.
    s.player.ammo_spray = 0;
    step(&s, &arena, .{});
    step(&s, &arena, sel);
    try testing.expectEqual(state.Weapon.swatter, s.player.weapon);
    step(&s, &arena, .{});
    step(&s, &arena, sel);
    try testing.expectEqual(state.Weapon.swatter, s.player.weapon);
}

test "spray spends one can and hits a beetle at 3 cells" {
    var arena_st: level_parse.Parsed = undefined;
    const arena = try level_parse.parse_level(&arena_st, "arena", arena_src, 0);
    var s: GameState = undefined;
    for ([_]u32{ 1, 2, 3, 99, 0xDEADBEEF }) |seed| {
        arena_with(&s, &arena, .beetle, fixed.from_int(4) + fixed.half, fixed.from_int(2) + fixed.half);
        s.rng = seed;
        s.player.y = fixed.from_int(2) + fixed.half;
        s.player.has_spray = true;
        s.player.ammo_spray = 5;
        s.player.weapon = .spray;
        step(&s, &arena, .{ .a = true });
        try testing.expectEqual(@as(u8, 4), s.player.ammo_spray);
        try testing.expectEqual(@as(u8, 36), s.player.fire_cooldown);
        try testing.expect(s.rng != seed);
        try testing.expect(s.enemies[0].hp <= 18);
        try testing.expect(@rem(s.enemies[0].hp, 2) == 0);
    }
    // Out of reach (7 cells): nothing.
    arena_with(&s, &arena, .beetle, fixed.from_int(8) + fixed.half, px0);
    s.player.has_spray = true;
    s.player.ammo_spray = 1;
    s.player.weapon = .spray;
    step(&s, &arena, .{ .a = true });
    try testing.expectEqual(@as(i16, 20), s.enemies[0].hp);
    try testing.expectEqual(@as(u8, 0), s.player.ammo_spray);
    // No cans: A does nothing.
    run(&s, &arena, .{ .a = true }, 60);
    try testing.expectEqual(@as(u8, 0), s.player.ammo_spray);
}

test "dying takes 24 ticks, increments kills, frames 4 5 6, corpse is no target" {
    var arena_st: level_parse.Parsed = undefined;
    const arena = try level_parse.parse_level(&arena_st, "arena", arena_src, 0);
    var s: GameState = undefined;
    arena_with(&s, &arena, .gnat, fixed.from_int(4) + fixed.half, px0);
    // A second gnat right behind the first, on the same ray.
    s.enemies[1] = .{ .x = fixed.from_int(6) + fixed.half, .y = px0, .kind = .gnat, .state = .idle, .hp = 3 };
    step(&s, &arena, .{ .a = true });
    try testing.expectEqual(@as(u16, 1), s.kills);
    try testing.expectEqual(@as(i16, 3), s.enemies[1].hp); // nearest took it
    // The hit tick plus 23 more show dying frames, 8 ticks each ...
    for (0..24) |i| {
        if (i > 0) step(&s, &arena, .{});
        try testing.expectEqual(state.EnemyState.dying, s.enemies[0].state);
        try testing.expectEqual(@as(u8, 4 + @as(u8, @intCast(i / 8))), s.enemies[0].frame);
    }
    // ... and the 24th step after the hit lands on dead.
    step(&s, &arena, .{});
    try testing.expectEqual(state.EnemyState.dead, s.enemies[0].state);
    try testing.expectEqual(@as(u8, 6), s.enemies[0].frame);
    try testing.expectEqual(@as(u16, 1), s.kills);
    // Dying and dead gnats are no longer targets: the next shot passes through.
    step(&s, &arena, .{ .a = true });
    try testing.expectEqual(@as(i16, 0), s.enemies[1].hp);
    try testing.expectEqual(@as(u16, 2), s.kills);
    run(&s, &arena, .{ .a = true }, 100);
    try testing.expectEqual(@as(u16, 2), s.kills);
    try testing.expectEqual(@as(u8, 6), s.enemies[0].frame);
}

test "a dead enemy in a doorway does not hold the door open" {
    var door_level_st: level_parse.Parsed = undefined;
    const door_level = try level_parse.parse_level(&door_level_st, "door", door_level_src, 0);
    const L = &door_level;
    var s: GameState = undefined;
    init(&s, L, 0, 1);
    s.enemies[0] = .{ .x = fixed.from_int(4) + fixed.half, .y = fixed.from_int(1) + fixed.half, .kind = .gnat, .state = .idle, .hp = 3 };
    s.doors[0] = .{ .open = 255, .timer = 1, .phase = door_open };
    run(&s, L, .{}, 5);
    try testing.expectEqual(@as(u8, door_open), s.doors[0].phase); // living: held
    s.enemies[0].state = .dead;
    s.enemies[0].hp = 0;
    run(&s, L, .{}, 40);
    try testing.expectEqual(@as(u8, door_closed), s.doors[0].phase);
}
