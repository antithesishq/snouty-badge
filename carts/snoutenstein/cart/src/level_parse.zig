//! Runtime ASCII level parser (no comptime, no @embedFile in the parser).
//!
//! Used by `gen_levels.zig` (host tool that writes `levels/gen.zig`) and by
//! tests that build mini-levels. The cart itself only uses the generated
//! literal data in `levels.all`; see `levels.zig` for the cell encoding.
//!
//! Format: one row per line; lines that are empty or start with '#' are
//! comments. Rows shorter than the widest are padded with wall, and every
//! cell outside the drawn map is wall.
const std = @import("std");
const fixed = @import("fixed.zig");
const state = @import("state.zig");
const levels = @import("levels.zig"); // types only

const size = levels.size;
const DoorDef = levels.DoorDef;
const DoorKind = levels.DoorKind;
const PickupDef = levels.PickupDef;
const PickupKind = levels.PickupKind;
const EnemyDef = levels.EnemyDef;

pub const Error = error{ TooManyRows, RowTooWide, TooManyDoors, TooManyPickups, TooManyEnemies, TwoStarts, BadStartArrow, NoStart, UnknownChar };

pub const Parsed = struct {
    cells: [size][size]u8,
    width: u8,
    height: u8,
    start_x: u8,
    start_y: u8,
    start_angle: fixed.Angle,
    default_wall: u8,
    doors: [state.max_doors]DoorDef,
    door_count: u8,
    pickups: [state.max_pickups]PickupDef,
    pickup_count: u16,
    enemies: [state.max_enemies]EnemyDef,
    enemy_count: u8,
};

fn is_wall_char(ch: u8) bool {
    return ch == '#' or (ch >= '1' and ch <= '8');
}

/// Parses `src` into `out`. Same semantics as the old comptime parse, errors
/// instead of @compileError. On error `out` is partially written.
pub fn parse(out: *Parsed, src: []const u8, default_wall: u8) Error!void {
    var raw: [size][size]u8 = @splat(@splat(' '));
    var width: usize = 0;
    var height: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, "\r ");
        if (line.len == 0 or line[0] == '#') continue;
        if (height >= size) return error.TooManyRows;
        if (line.len > size) return error.RowTooWide;
        for (line, 0..) |ch, x| raw[height][x] = ch;
        if (line.len > width) width = line.len;
        height += 1;
    }
    // Rows shorter than the widest are padded with wall so the map is closed.
    for (0..height) |y| {
        for (0..width) |x| {
            if (raw[y][x] == ' ') raw[y][x] = '#';
        }
    }

    out.cells = @splat(@splat(0));
    out.door_count = 0;
    out.pickup_count = 0;
    out.enemy_count = 0;
    out.default_wall = default_wall;
    var start_x: ?u8 = null;
    var start_y: u8 = 0;
    var start_angle: fixed.Angle = 0;

    for (0..height) |y| {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const ch = raw[y][x];
            const xb: u8 = @intCast(x);
            const yb: u8 = @intCast(y);
            switch (ch) {
                '.' => {},
                '#' => out.cells[y][x] = default_wall + 1,
                '1'...'8' => out.cells[y][x] = ch - '0',
                'D', 'C', 'I', 'G', 'E' => {
                    if (out.door_count >= state.max_doors) return error.TooManyDoors;
                    const kind: DoorKind = switch (ch) {
                        'D' => .plain,
                        'C' => .coral,
                        'I' => .iris,
                        'G' => .gold,
                        else => .exit,
                    };
                    // Walls to the left and right: the passage runs
                    // north-south, so the panel runs east-west.
                    const left = if (x == 0) '#' else raw[y][x - 1];
                    const right = if (x + 1 >= width) '#' else raw[y][x + 1];
                    const vertical = !(is_wall_char(left) and is_wall_char(right));
                    out.cells[y][x] = levels.door_base + out.door_count;
                    out.doors[out.door_count] = .{ .x = xb, .y = yb, .kind = kind, .vertical = vertical };
                    out.door_count += 1;
                },
                'S' => {
                    if (start_x != null) return error.TwoStarts;
                    start_x = xb;
                    start_y = yb;
                    const dir = if (x + 1 < width) raw[y][x + 1] else '>';
                    start_angle = switch (dir) {
                        '>' => 0,
                        'v' => fixed.deg(90),
                        '<' => fixed.deg(180),
                        '^' => fixed.deg(270),
                        else => return error.BadStartArrow,
                    };
                    if (x + 1 < width) x += 1; // the arrow cell is floor
                },
                'c', 'i', 'g', '+', '%', '$', '*' => {
                    if (out.pickup_count >= state.max_pickups) return error.TooManyPickups;
                    const kind: PickupKind = switch (ch) {
                        'c' => .key_coral,
                        'i' => .key_iris,
                        'g' => .key_gold,
                        '+' => .hotfix,
                        '%' => .charge,
                        '$' => .spray_can,
                        else => .battery,
                    };
                    out.pickups[out.pickup_count] = .{ .x = xb, .y = yb, .kind = kind };
                    out.pickup_count += 1;
                },
                'a', 'w', 'b', 's', 'H' => {
                    if (out.enemy_count >= state.max_enemies) return error.TooManyEnemies;
                    const kind: state.EnemyKind = switch (ch) {
                        'a' => .gnat,
                        'w' => .wasp,
                        'b' => .beetle,
                        's' => .spider,
                        else => .boss,
                    };
                    out.enemies[out.enemy_count] = .{ .x = xb, .y = yb, .kind = kind };
                    out.enemy_count += 1;
                },
                else => return error.UnknownChar,
            }
        }
    }
    if (start_x == null) return error.NoStart;
    // Everything outside the drawn map is wall.
    for (0..size) |y| {
        for (0..size) |x| {
            if (y >= height or x >= width) out.cells[y][x] = default_wall + 1;
        }
    }
    out.width = @intCast(width);
    out.height = @intCast(height);
    out.start_x = start_x.?;
    out.start_y = start_y;
    out.start_angle = start_angle;
}

/// A Level whose slices point into `p` (p must outlive the Level).
pub fn level(p: *const Parsed, name: []const u8) levels.Level {
    return .{
        .name = name,
        .width = p.width,
        .height = p.height,
        .cells = p.cells,
        .start_x = p.start_x,
        .start_y = p.start_y,
        .start_angle = p.start_angle,
        .doors = p.doors[0..p.door_count],
        .pickups = p.pickups[0..p.pickup_count],
        .enemies = p.enemies[0..p.enemy_count],
        .default_wall = p.default_wall,
    };
}

/// Convenience for tests: parse into `storage` and return the Level.
pub fn parse_level(storage: *Parsed, name: []const u8, src: []const u8, default_wall: u8) Error!levels.Level {
    try parse(storage, src, default_wall);
    return level(storage, name);
}

const testing = std.testing;

test "test level parses at run time" {
    var p: Parsed = undefined;
    const l = try parse_level(&p, "test", @embedFile("levels/test.txt"), 0);
    const Level = levels.Level;
    try testing.expectEqual(@as(u8, 33), l.width);
    try testing.expectEqual(@as(u8, 24), l.height);
    try testing.expectEqual(@as(u8, 3), l.start_x);
    try testing.expectEqual(@as(u8, 3), l.start_y);
    try testing.expectEqual(@as(usize, 8), l.doors.len);
    try testing.expect(Level.is_door(l.cell(7, 4)));
    try testing.expect(l.doors[Level.door_index(l.cell(7, 4))].vertical);
    try testing.expect(Level.is_wall(l.cell(0, 0)));
    try testing.expect(Level.is_wall(l.cell(63, 63)));
    try testing.expectEqual(@as(u8, 0), l.cell(1, 1));
    // The M2 combat target: a gnat directly ahead of the start.
    try testing.expectEqual(@as(usize, 5), l.enemies.len);
    try testing.expectEqual(state.EnemyKind.gnat, l.enemies[0].kind);
    try testing.expectEqual(@as(u8, 6), l.enemies[0].x);
    try testing.expectEqual(@as(u8, 3), l.enemies[0].y);
}

fn expect_same(want: *const levels.Level, got: *const levels.Level) !void {
    try testing.expectEqualStrings(want.name, got.name);
    try testing.expectEqual(want.width, got.width);
    try testing.expectEqual(want.height, got.height);
    try testing.expect(std.mem.eql(u8, std.mem.asBytes(&want.cells), std.mem.asBytes(&got.cells)));
    try testing.expectEqual(want.start_x, got.start_x);
    try testing.expectEqual(want.start_y, got.start_y);
    try testing.expectEqual(want.start_angle, got.start_angle);
    try testing.expectEqual(want.default_wall, got.default_wall);
    try testing.expectEqualSlices(levels.DoorDef, want.doors, got.doors);
    try testing.expectEqualSlices(levels.PickupDef, want.pickups, got.pickups);
    try testing.expectEqualSlices(levels.EnemyDef, want.enemies, got.enemies);
}

// If this fails, a .txt changed without rerunning tools/gen_levels.sh.
test "levels/gen.zig matches the .txt sources" {
    var p: Parsed = undefined;
    const t = try parse_level(&p, "test", @embedFile("levels/test.txt"), 0);
    try expect_same(&levels.all[0], &t);
    const w = try parse_level(&p, "wolf_e1m1", @embedFile("levels/wolf_e1m1.txt"), 0);
    try expect_same(&levels.all[1], &w);
    try testing.expectEqual(@as(usize, 2), levels.all.len);
}

test "parse errors" {
    var p: Parsed = undefined;
    try testing.expectError(error.TwoStarts, parse(&p, "1111\n1S>1\n1S>1\n1111\n", 0));
    try testing.expectError(error.UnknownChar, parse(&p, "1111\n1S>1\n1.@1\n1111\n", 0));
    try testing.expectError(error.NoStart, parse(&p, "1111\n1..1\n1111\n", 0));
    try testing.expectError(error.BadStartArrow, parse(&p, "11111\n1S..1\n11111\n", 0));
}

test "door orientation" {
    var p: Parsed = undefined;
    // Walls left and right: passage runs north-south, panel east-west.
    const h = try parse_level(&p, "h",
        \\11111
        \\1S>.1
        \\1#D#1
        \\1...1
        \\11111
    , 0);
    try testing.expectEqual(@as(usize, 1), h.doors.len);
    try testing.expectEqual(@as(u8, 2), h.doors[0].x);
    try testing.expectEqual(@as(u8, 2), h.doors[0].y);
    try testing.expect(!h.doors[0].vertical);
    // Walls above and below: passage runs east-west, panel north-south.
    const v = try parse_level(&p, "v",
        \\1111111
        \\1S>D..1
        \\1111111
    , 0);
    try testing.expectEqual(@as(usize, 1), v.doors.len);
    try testing.expect(v.doors[0].vertical);
    try testing.expect(levels.Level.is_door(v.cell(3, 1)));
    // The arrow after S is floor; short rows are padded with the default
    // wall ('#', texture 2 -> cell 3), as is everything outside the map.
    // Rows starting with '#' are comments, so mini-levels start rows with a digit.
    const s = try parse_level(&p, "short", "222\n2S>.2\n222\n", 2);
    try testing.expectEqual(@as(u8, 5), s.width);
    try testing.expectEqual(@as(u8, 0), s.cell(2, 1));
    try testing.expectEqual(@as(u8, 3), s.cell(4, 0));
    try testing.expectEqual(@as(u8, 3), s.cell(10, 10));
}
