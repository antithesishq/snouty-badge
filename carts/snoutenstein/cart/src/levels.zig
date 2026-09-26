//! Levels: ASCII files in `levels/` parsed at comptime (SPEC.md section 6).
//!
//! Cell encoding (`Level.cells[y][x]`, row-major, y down):
//!   0         floor
//!   1..8      wall, texture index cell-1 in walls.png
//!   64..127   door number (cell - 64) into `Level.doors`
//! Everything else is reserved. Walls 9..63 are reserved for more textures.
const std = @import("std");
const fixed = @import("fixed.zig");
const state = @import("state.zig");

pub const size = 64;
pub const door_base: u8 = 64;

pub const DoorKind = enum(u8) { plain = 0, coral = 1, iris = 2, gold = 3, exit = 4 };

pub const DoorDef = struct {
    x: u8,
    y: u8,
    kind: DoorKind,
    /// true: the door panel runs north-south (passage is east-west, walls
    /// above and below). false: panel runs east-west.
    vertical: bool,
};

pub const PickupKind = enum(u8) { key_coral, key_iris, key_gold, hotfix, charge, spray_can, battery };

pub const PickupDef = struct { x: u8, y: u8, kind: PickupKind };
pub const EnemyDef = struct { x: u8, y: u8, kind: state.EnemyKind };

pub const Level = struct {
    name: []const u8,
    width: u8,
    height: u8,
    cells: [size][size]u8,
    start_x: u8,
    start_y: u8,
    start_angle: fixed.Angle,
    doors: []const DoorDef,
    pickups: []const PickupDef,
    enemies: []const EnemyDef,
    /// Texture (0-based) used for '#'.
    default_wall: u8,

    pub fn cell(self: *const Level, x: i32, y: i32) u8 {
        if (x < 0 or y < 0 or x >= size or y >= size) return 1;
        return self.cells[@intCast(y)][@intCast(x)];
    }
    pub fn is_wall(c: u8) bool {
        return c >= 1 and c < door_base;
    }
    pub fn is_door(c: u8) bool {
        return c >= door_base and c < door_base + state.max_doors;
    }
    pub fn door_index(c: u8) u8 {
        return c - door_base;
    }
};

pub const all = [_]Level{
    parse("test", @embedFile("levels/test.txt"), 0),
};

fn is_wall_char(ch: u8) bool {
    return ch == '#' or (ch >= '1' and ch <= '8');
}

pub fn parse(comptime name: []const u8, comptime src: []const u8, comptime default_wall: u8) Level {
    @setEvalBranchQuota(400_000);
    comptime {
        var cells: [size][size]u8 = @splat(@splat(0));
        var raw: [size][size]u8 = @splat(@splat(' '));
        var width: usize = 0;
        var height: usize = 0;
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trimEnd(u8, line_raw, "\r ");
            if (line.len == 0 or line[0] == '#') continue;
            if (height >= size) @compileError(name ++ ": more than 64 rows");
            if (line.len > size) @compileError(name ++ ": row wider than 64");
            for (line, 0..) |ch, x| raw[height][x] = ch;
            if (line.len > width) width = line.len;
            height += 1;
        }
        // Rows shorter than the widest are padded with wall so the map is closed.
        for (0..height) |y| {
            for (0..width) |x| if (raw[y][x] == ' ') {
                raw[y][x] = '#';
            };
        }

        var doors: []const DoorDef = &.{};
        var pickups: []const PickupDef = &.{};
        var enemies: []const EnemyDef = &.{};
        var start_x: ?u8 = null;
        var start_y: u8 = 0;
        var start_angle: fixed.Angle = 0;

        for (0..height) |y| {
            var x: usize = 0;
            while (x < width) : (x += 1) {
                const ch = raw[y][x];
                switch (ch) {
                    '.' => {},
                    '#' => cells[y][x] = default_wall + 1,
                    '1'...'8' => cells[y][x] = ch - '0',
                    'D', 'C', 'I', 'G', 'E' => {
                        if (doors.len >= state.max_doors) @compileError(name ++ ": more than 64 doors");
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
                        cells[y][x] = door_base + @as(u8, @intCast(doors.len));
                        doors = doors ++ [_]DoorDef{.{ .x = x, .y = y, .kind = kind, .vertical = vertical }};
                    },
                    'S' => {
                        if (start_x != null) @compileError(name ++ ": two starts");
                        start_x = x;
                        start_y = y;
                        const dir = if (x + 1 < width) raw[y][x + 1] else '>';
                        start_angle = switch (dir) {
                            '>' => 0,
                            'v' => fixed.deg(90),
                            '<' => fixed.deg(180),
                            '^' => fixed.deg(270),
                            else => @compileError(name ++ ": start must be followed by one of > v < ^"),
                        };
                        if (x + 1 < width and (dir == '>' or dir == 'v' or dir == '<' or dir == '^')) {
                            x += 1; // the arrow cell is floor
                        }
                    },
                    'c', 'i', 'g', '+', '%', '$', '*' => {
                        if (pickups.len >= state.max_pickups) @compileError(name ++ ": too many pickups");
                        const kind: PickupKind = switch (ch) {
                            'c' => .key_coral,
                            'i' => .key_iris,
                            'g' => .key_gold,
                            '+' => .hotfix,
                            '%' => .charge,
                            '$' => .spray_can,
                            else => .battery,
                        };
                        pickups = pickups ++ [_]PickupDef{.{ .x = x, .y = y, .kind = kind }};
                    },
                    'a', 'w', 'b', 's', 'H' => {
                        if (enemies.len >= state.max_enemies) @compileError(name ++ ": too many enemies");
                        const kind: state.EnemyKind = switch (ch) {
                            'a' => .gnat,
                            'w' => .wasp,
                            'b' => .beetle,
                            's' => .spider,
                            else => .boss,
                        };
                        enemies = enemies ++ [_]EnemyDef{.{ .x = x, .y = y, .kind = kind }};
                    },
                    else => @compileError(name ++ ": unknown level character '" ++ [_]u8{ch} ++ "'"),
                }
            }
        }
        if (start_x == null) @compileError(name ++ ": no start (S)");
        // Everything outside the drawn map is wall.
        for (0..size) |y| {
            for (0..size) |x| if (y >= height or x >= width) {
                cells[y][x] = default_wall + 1;
            };
        }
        return .{
            .name = name,
            .width = width,
            .height = height,
            .cells = cells,
            .start_x = start_x.?,
            .start_y = start_y,
            .start_angle = start_angle,
            .doors = doors,
            .pickups = pickups,
            .enemies = enemies,
            .default_wall = default_wall,
        };
    }
}

test "test level parses" {
    const l = &all[0];
    try std.testing.expectEqual(@as(u8, 33), l.width);
    try std.testing.expectEqual(@as(u8, 24), l.height);
    try std.testing.expectEqual(@as(u8, 3), l.start_x);
    try std.testing.expectEqual(@as(u8, 3), l.start_y);
    try std.testing.expect(l.doors.len == 8);
    try std.testing.expect(Level.is_door(l.cell(7, 4)));
    try std.testing.expect(l.doors[Level.door_index(l.cell(7, 4))].vertical);
    try std.testing.expect(Level.is_wall(l.cell(0, 0)));
    try std.testing.expect(Level.is_wall(l.cell(63, 63)));
    try std.testing.expectEqual(@as(u8, 0), l.cell(1, 1));
}
