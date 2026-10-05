//! Levels (SPEC.md section 6). The ASCII files in `levels/*.txt` are the
//! source of truth; `tools/gen_levels.sh` parses them on the host with
//! `level_parse.zig` and writes `levels/gen.zig`, plain literal data. There is
//! deliberately no comptime parsing here: it made the macOS compiler run out
//! of memory. Tests build mini-levels with `level_parse.parse_level`.
//!
//! Cell encoding (`Level.cell(x, y)`; `cells` holds the drawn width x
//! height, row-major, y down; everything outside is wall):
//!   0         floor
//!   1..8      wall, texture index cell-1 in walls.png
//!   64..127   door number (cell - 64) into `Level.doors`
//! Everything else is reserved. Walls 9..63 are reserved for more textures.
const fixed = @import("fixed.zig");
const state = @import("state.zig");

pub const size = 64;
pub const door_base: u8 = 64;

/// `secret` (legend `X`): looks like the wall around it (wall texture
/// `DoorDef.tex`), opens when the player walks into it, never closes, and
/// enemies cannot open it (Wolf3D pushwall, bump-activated).
pub const DoorKind = enum(u8) { plain = 0, coral = 1, iris = 2, gold = 3, exit = 4, secret = 5 };

pub const DoorDef = struct {
    x: u8,
    y: u8,
    kind: DoorKind,
    /// true: the door panel runs north-south (passage is east-west, walls
    /// above and below). false: panel runs east-west.
    vertical: bool,
    /// Secret doors only: walls.png cell drawn on the panel (0..7).
    tex: u8 = 0,
};

pub const PickupKind = enum(u8) {
    key_coral,
    key_iris,
    key_gold,
    hotfix,
    charge,
    spray_can,
    battery,
    debugger,
    /// M9 deathmatch weapon pad (legend `@`): shows `Match.pad_item[k]`, rotates on respawn.
    pad,
};

pub const PickupDef = struct { x: u8, y: u8, kind: PickupKind };
pub const EnemyDef = struct { x: u8, y: u8, kind: state.EnemyKind };
/// Deathmatch spawn point (legend `P`, M7); the parser faces it down the
/// longest open run of floor from its cell.
pub const Spawn = struct { x: u8, y: u8, angle: fixed.Angle };
pub const max_spawns = 16;

pub const Level = struct {
    name: []const u8,
    width: u8,
    height: u8,
    /// `width * height` cells, row-major (M8: packed instead of a 64x64
    /// array per level, 22 KB less flash for the party code).
    cells: []const u8,
    start_x: u8,
    start_y: u8,
    start_angle: fixed.Angle,
    doors: []const DoorDef,
    pickups: []const PickupDef,
    enemies: []const EnemyDef,
    /// Deathmatch spawn points; empty in the campaign levels.
    spawns: []const Spawn = &.{},
    /// Texture (0-based) used for '#'.
    default_wall: u8,

    /// Outside the drawn width x height: `default_wall + 1` inside the 64x64
    /// grid, 1 beyond it (as when `cells` was the whole grid).
    pub fn cell(self: *const Level, x: i32, y: i32) u8 {
        // Negative coordinates wrap to huge unsigned ones: one compare each.
        const ux: u32 = @bitCast(x);
        const uy: u32 = @bitCast(y);
        // Height first: the width then stays in one register for the index.
        if (uy < self.height and ux < self.width) return self.cells[uy * self.width + ux];
        return if (ux < size and uy < size) self.default_wall + 1 else 1;
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
/// Deathmatch arenas (M7, Data Hall M8), in the order of the lobby's ARENA
/// row. `match.Rules.arena` has two bits: at most four arenas.
pub const arena_indices = [_]u8{ 5, 6, 7 };
pub const arena_names = [_][]const u8{ "SERVER ROOM", "BUILD FARM", "DATA HALL" };
/// The head count each arena is built for (its spawn count): the party
/// lobby suggests the smallest arena that fits the players (`suggest_arena`),
/// and the host may still pick any.
pub const arena_max_players = [_]u8{ 6, 8, 16 };

/// The arena (index into `arena_indices`) suggested for `players`: the
/// first whose suggested maximum fits, else the biggest.
pub fn suggest_arena(players: u8) u8 {
    for (arena_max_players, 0..) |m, i| {
        if (players <= m) return @intCast(i);
    }
    return arena_max_players.len - 1;
}

/// Generated from `levels/*.txt`; order is the manifest in `gen_levels.zig`.
pub const all = @import("levels/gen.zig").all;
