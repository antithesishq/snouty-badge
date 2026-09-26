//! step(state, level, buttons): the whole simulation for one tick.
//! Pure over GameState, 16.16 fixed point only, no cart-api import, so
//! `zig test cart/src/sim.zig` runs on the host and replays are
//! bit-identical between the simulator and the badge (SPEC.md 9.3).
//! M1: turning, walking with sliding collision, doors, pickups, rewind
//! meter regeneration. Enemies, projectiles and weapons are M2/M3.
const std = @import("std");
const fixed = @import("fixed.zig");
const state = @import("state.zig");
const levels = @import("levels.zig");

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
pub const max_zapper = 99;
pub const max_spray = 30;
pub const max_rewind = 600;
pub const rewind_regen_ticks = 6;

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
            .state = .dormant,
            .hp = 1,
        };
    }
}

pub fn step(s: *GameState, level: *const Level, b: state.Buttons) void {
    s.last_locked = 0;
    const p = &s.player;
    if (b.left) p.angle -%= turn_speed;
    if (b.right) p.angle +%= turn_speed;
    var move: Fixed = 0;
    if (b.up) move = walk_speed;
    if (b.down) move = -back_speed;
    if (move != 0) {
        move_x(s, level, fixed.mul(fixed.cos(p.angle), move));
        move_y(s, level, fixed.mul(fixed.sin(p.angle), move));
    }
    update_doors(s, level);
    enter_cell(s, level);
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

/// Move along x by `dx` (|dx| < radius), then push the player's box back
/// out of the column it entered if any overlapped cell there is solid.
fn move_x(s: *GameState, level: *const Level, dx: Fixed) void {
    if (dx == 0) return;
    const p = &s.player;
    var nx = p.x + dx;
    // Rows overlapped by the box [y - r, y + r) (the upper edge is exclusive).
    const r0 = fixed.to_int(p.y - radius);
    const r1 = fixed.to_int(p.y + radius - 1);
    const col = if (dx > 0) fixed.to_int(nx + radius - 1) else fixed.to_int(nx - radius);
    var blocked = false;
    var row = r0;
    while (row <= r1) : (row += 1) {
        if (is_solid(s, level, col, row)) {
            blocked = true;
            bump(s, level, col, row);
        }
    }
    if (blocked) nx = if (dx > 0) fixed.from_int(col) - radius else fixed.from_int(col + 1) + radius;
    p.x = nx;
}

fn move_y(s: *GameState, level: *const Level, dy: Fixed) void {
    if (dy == 0) return;
    const p = &s.player;
    var ny = p.y + dy;
    const c0 = fixed.to_int(p.x - radius);
    const c1 = fixed.to_int(p.x + radius - 1);
    const row = if (dy > 0) fixed.to_int(ny + radius - 1) else fixed.to_int(ny - radius);
    var blocked = false;
    var col = c0;
    while (col <= c1) : (col += 1) {
        if (is_solid(s, level, col, row)) {
            blocked = true;
            bump(s, level, col, row);
        }
    }
    if (blocked) ny = if (dy > 0) fixed.from_int(row) - radius else fixed.from_int(row + 1) + radius;
    p.y = ny;
}

/// The player walked into a solid cell; if it is a door, try to open it.
fn bump(s: *GameState, level: *const Level, cx: i32, cy: i32) void {
    const c = level.cell(cx, cy);
    if (!Level.is_door(c)) return;
    const i = Level.door_index(c);
    const d = &s.doors[i];
    if (d.phase != door_closed and d.phase != door_closing) return;
    const kind = level.doors[i].kind;
    const need: u8 = switch (kind) {
        .coral => 1,
        .iris => 2,
        .gold => 4,
        .plain, .exit => 0,
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

/// FNV-1a over the raw bytes of the state, for determinism checks.
pub fn hash(s: *const GameState) u32 {
    var h: u32 = 2166136261;
    for (std.mem.asBytes(s)) |byte| {
        h ^= byte;
        h *%= 16777619;
    }
    return h;
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

const room = levels.parse("room",
    \\1111111
    \\1S>...1
    \\1.....1
    \\1.....1
    \\1.....1
    \\1.....1
    \\1111111
, 0);

test "walking into a wall stops at the radius" {
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

const door_level = levels.parse("door",
    \\11111111
    \\1S>.D..1
    \\11111111
, 0);

test "a door opens over 30 ticks, is passable at 192, then closes" {
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

const locked_level = levels.parse("locked",
    \\11111111
    \\1S>.C..1
    \\11111111
, 0);

test "a locked door stays shut without the key and opens with it" {
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

const exit_level = levels.parse("exit",
    \\111111
    \\1S>.E1
    \\111111
, 0);

test "the exit door opens and finishes the level when entered" {
    const L = &exit_level;
    var s: GameState = undefined;
    init(&s, L, 0, 1);
    var n: usize = 0;
    while (!s.finished and n < 200) : (n += 1) step(&s, L, .{ .up = true });
    try testing.expect(s.finished);
    try testing.expectEqual(@as(i32, 4), fixed.to_int(s.player.x));
}

const pickup_level = levels.parse("pickups",
    \\111111111111
    \\1S>cig+%$*$1
    \\111111111111
, 0);

test "pickups clear their bit and clamp" {
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

test "rewind meter regenerates 1 per 6 ticks up to 600" {
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
    // The script actually moved the player somewhere.
    try testing.expect(a.player.x != fixed.from_int(3) + fixed.half or a.player.y != fixed.from_int(3) + fixed.half);
}
