//! Levels (SPEC.md section 6). The ASCII files in `levels/*.txt` are the
//! source of truth; `tools/gen_levels.sh` parses them on the host with
//! `level_parse.zig` and writes `levels/gen.zig`, plain literal data. There is
//! deliberately no comptime parsing here: it made the macOS compiler run out
//! of memory. Tests build mini-levels with `level_parse.parse_level`.
//!
//! Cell encoding (`Level.cells[y][x]`, row-major, y down):
//!   0         floor
//!   1..8      wall, texture index cell-1 in walls.png
//!   64..127   door number (cell - 64) into `Level.doors`
//! Everything else is reserved. Walls 9..63 are reserved for more textures.
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

/// The campaign is `all[0..campaign_len]`; the debug levels follow it.
pub const campaign_len = 3;
pub const test_index = 3;
pub const e1m1_index = 4;

/// Generated from `levels/*.txt`; order is the manifest in `gen_levels.zig`.
pub const all = @import("levels/gen.zig").all;
