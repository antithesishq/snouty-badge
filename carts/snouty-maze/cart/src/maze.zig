//! Maze grid, generator and wall runs. Track B implements (PLAN.md); this
//! stub draws a boundary-only maze so the renderer has geometry from M0.
//! No cart API here: `zig build test` runs this on the host.
const std = @import("std");
const rng = @import("rng.zig");

pub const max_size = 16;
pub const max_cells = max_size * max_size;
/// Upper bound on wall segments (and so on runs): every edge of the grid.
pub const max_runs = 2 * max_size * (max_size + 1);

/// n = -z, e = +x, s = +z, w = -x.
pub const Dir = enum(u2) {
    n,
    e,
    s,
    w,
    pub fn opposite(d: Dir) Dir {
        return @fromBackingInt(@intCast(@backingInt(d) +% 2));
    }
    pub fn left(d: Dir) Dir {
        return @fromBackingInt(@intCast(@backingInt(d) +% 3));
    }
    pub fn right(d: Dir) Dir {
        return @fromBackingInt(@intCast(@backingInt(d) +% 1));
    }
    pub fn dx(d: Dir) i8 {
        return switch (d) {
            .e => 1,
            .w => -1,
            else => 0,
        };
    }
    pub fn dz(d: Dir) i8 {
        return switch (d) {
            .s => 1,
            .n => -1,
            else => 0,
        };
    }
};

/// Wall bits: true = wall present on that side.
pub const Cell = packed struct(u8) {
    n: bool = true,
    e: bool = true,
    s: bool = true,
    w: bool = true,
    visited: bool = false,
    _pad: u3 = 0,

    pub fn wall(c: Cell, d: Dir) bool {
        return switch (d) {
            .n => c.n,
            .e => c.e,
            .s => c.s,
            .w => c.w,
        };
    }
};

pub const Axis = enum(u8) { x, z };

/// A straight wall panel starting at grid vertex (x, z) and running `len`
/// cells along `axis`. The renderer turns it into a box 0.1 thick.
pub const Run = struct { x: u8, z: u8, len: u8, axis: Axis };

pub const Maze = struct {
    w: u8 = 12,
    h: u8 = 12,
    cells: [max_cells]Cell = @splat(.{}),
    start: [2]u8 = .{ 0, 0 },
    finish: [2]u8 = .{ 11, 11 },
    runs: [max_runs]Run = undefined,
    run_count: u16 = 0,

    pub fn cell(m: *const Maze, x: u8, z: u8) Cell {
        return m.cells[@as(usize, z) * max_size + x];
    }

    pub fn has_wall(m: *const Maze, x: u8, z: u8, d: Dir) bool {
        return m.cell(x, z).wall(d);
    }

    /// Perfect maze of w x h cells, start/finish, merged runs.
    /// STUB: all walls present, four boundary runs only.
    pub fn generate(m: *Maze, w: u8, h: u8, r: *rng.Xorshift) void {
        _ = r;
        m.w = w;
        m.h = h;
        m.cells = @splat(.{});
        m.start = .{ 0, 0 };
        m.finish = .{ w - 1, h - 1 };
        m.run_count = 0;
        m.runs[0] = .{ .x = 0, .z = 0, .len = w, .axis = .x };
        m.runs[1] = .{ .x = 0, .z = h, .len = w, .axis = .x };
        m.runs[2] = .{ .x = 0, .z = 0, .len = h, .axis = .z };
        m.runs[3] = .{ .x = w, .z = 0, .len = h, .axis = .z };
        m.run_count = 4;
    }
};

test "stub maze has a boundary" {
    var r = rng.Xorshift.init(1);
    var m: Maze = .{};
    m.generate(12, 12, &r);
    try std.testing.expectEqual(@as(u16, 4), m.run_count);
    try std.testing.expect(m.has_wall(0, 0, .n));
}
