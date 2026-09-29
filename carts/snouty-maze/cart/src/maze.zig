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

/// One generator step: the wall on side `dir` of cell (x, z) was removed
/// (and the matching wall of the neighbour). A full maze has w*h - 1.
pub const Carve = packed struct(u16) { x: u4, z: u4, dir: Dir, _pad: u6 = 0 };

pub const Maze = struct {
    w: u8 = 12,
    h: u8 = 12,
    cells: [max_cells]Cell = @splat(.{}),
    start: [2]u8 = .{ 0, 0 },
    finish: [2]u8 = .{ 11, 11 },
    runs: [max_runs]Run = undefined,
    run_count: u16 = 0,
    /// Carve order recorded by `generate`, `carve_count` = w*h - 1 entries.
    carve_log: [max_cells - 1]Carve = undefined,
    carve_count: u16 = 0,
    /// Carves `runs` currently shows (`reveal`); carve_count after generate.
    revealed: u16 = 0,

    pub fn cell(m: *const Maze, x: u8, z: u8) Cell {
        return m.cells[@as(usize, z) * max_size + x];
    }

    pub fn has_wall(m: *const Maze, x: u8, z: u8, d: Dir) bool {
        return m.cell(x, z).wall(d);
    }

    fn idx(x: u8, z: u8) usize {
        return @as(usize, z) * max_size + x;
    }

    /// Perfect maze of w x h cells (each 2..max_size), start (0, 0), finish
    /// the BFS-farthest cell, and merged wall runs.
    pub fn generate(m: *Maze, w: u8, h: u8, r: *rng.Xorshift) void {
        std.debug.assert(w >= 2 and w <= max_size and h >= 2 and h <= max_size);
        m.w = w;
        m.h = h;
        m.cells = @splat(.{});
        m.start = .{ 0, 0 };
        carve(m, r);
        m.finish = farthest_from(m, m.start);
        build_runs(m, &m.cells);
        m.revealed = m.carve_count;
    }

    /// Rebuilds `runs` as if only the first k carves had happened (all
    /// walls up, then k removed); k is clamped to carve_count. `cells`,
    /// `start` and `finish` keep the final maze, so the follower and the
    /// actors never see a partial one. reveal(carve_count) gives the runs
    /// `generate` built. About 2 * 17 * 16 segment tests plus the k wall
    /// removals: cheap enough for every OVERHEAD tick.
    pub fn reveal(m: *Maze, k: u16) void {
        const n = @min(k, m.carve_count);
        reveal_cells = @splat(.{});
        for (m.carve_log[0..n]) |c| {
            const x: u8 = c.x;
            const z: u8 = c.z;
            clear_wall(&reveal_cells, x, z, c.dir);
            const nb = m.neighbour(x, z, c.dir).?;
            clear_wall(&reveal_cells, nb[0], nb[1], c.dir.opposite());
        }
        build_runs(m, &reveal_cells);
        m.revealed = n;
    }

    /// The cell the most recent revealed carve opened into (the carve
    /// head), or null before the first carve and once carving is done.
    pub fn carve_head(m: *const Maze) ?[2]u8 {
        if (m.revealed == 0 or m.revealed >= m.carve_count) return null;
        const c = m.carve_log[m.revealed - 1];
        return m.neighbour(c.x, c.z, c.dir);
    }

    /// Iterative recursive backtracker from the start cell.
    fn carve(m: *Maze, r: *rng.Xorshift) void {
        m.carve_count = 0;
        var sp: usize = 0;
        stack[sp] = .{ m.start[0], m.start[1] };
        sp += 1;
        m.cells[idx(m.start[0], m.start[1])].visited = true;
        while (sp > 0) {
            const x = stack[sp - 1][0];
            const z = stack[sp - 1][1];
            var options: [4]Dir = undefined;
            var n: u32 = 0;
            for ([_]Dir{ .n, .e, .s, .w }) |d| {
                if (m.neighbour(x, z, d)) |nb| {
                    if (!m.cells[idx(nb[0], nb[1])].visited) {
                        options[n] = d;
                        n += 1;
                    }
                }
            }
            if (n == 0) {
                sp -= 1;
                continue;
            }
            const d = options[r.below(n)];
            const nb = m.neighbour(x, z, d).?;
            m.carve_log[m.carve_count] = .{ .x = @intCast(x), .z = @intCast(z), .dir = d };
            m.carve_count += 1;
            m.set_wall(x, z, d, false);
            m.set_wall(nb[0], nb[1], d.opposite(), false);
            m.cells[idx(nb[0], nb[1])].visited = true;
            stack[sp] = nb;
            sp += 1;
        }
        for (&m.cells) |*c| c.visited = false;
    }

    /// The cell one step in `d`, or null at the maze boundary.
    pub fn neighbour(m: *const Maze, x: u8, z: u8, d: Dir) ?[2]u8 {
        const nx = @as(i16, x) + d.dx();
        const nz = @as(i16, z) + d.dz();
        if (nx < 0 or nz < 0 or nx >= m.w or nz >= m.h) return null;
        return .{ @intCast(nx), @intCast(nz) };
    }

    fn set_wall(m: *Maze, x: u8, z: u8, d: Dir, present: bool) void {
        const c = &m.cells[idx(x, z)];
        switch (d) {
            .n => c.n = present,
            .e => c.e = present,
            .s => c.s = present,
            .w => c.w = present,
        }
    }

    fn clear_wall(cells: *[max_cells]Cell, x: u8, z: u8, d: Dir) void {
        const c = &cells[idx(x, z)];
        switch (d) {
            .n => c.n = false,
            .e => c.e = false,
            .s => c.s = false,
            .w => c.w = false,
        }
    }

    /// BFS through open walls; returns the reachable cell with the largest
    /// distance (first found on ties).
    fn farthest_from(m: *const Maze, from: [2]u8) [2]u8 {
        const unseen = std.math.maxInt(u16);
        dist = @splat(unseen);
        var head: usize = 0;
        var tail: usize = 0;
        queue[tail] = from;
        tail += 1;
        dist[idx(from[0], from[1])] = 0;
        var best = from;
        var best_d: u16 = 0;
        while (head < tail) {
            const cur = queue[head];
            head += 1;
            const cd = dist[idx(cur[0], cur[1])];
            if (cd > best_d) {
                best_d = cd;
                best = cur;
            }
            for ([_]Dir{ .n, .e, .s, .w }) |d| {
                if (m.has_wall(cur[0], cur[1], d)) continue;
                const nb = m.neighbour(cur[0], cur[1], d) orelse continue;
                if (dist[idx(nb[0], nb[1])] != unseen) continue;
                dist[idx(nb[0], nb[1])] = cd + 1;
                queue[tail] = nb;
                tail += 1;
            }
        }
        return best;
    }

    /// Wall segment on horizontal grid line z (0..h) between x and x+1.
    pub fn x_segment(m: *const Maze, x: u8, z: u8) bool {
        return if (z < m.h) m.has_wall(x, z, .n) else m.has_wall(x, m.h - 1, .s);
    }

    /// Wall segment on vertical grid line x (0..w) between z and z+1.
    pub fn z_segment(m: *const Maze, x: u8, z: u8) bool {
        return if (x < m.w) m.has_wall(x, z, .w) else m.has_wall(m.w - 1, z, .e);
    }

    /// Segment tests like x_segment / z_segment, on any cell grid.
    fn x_seg(m: *const Maze, cells: *const [max_cells]Cell, x: u8, z: u8) bool {
        return if (z < m.h) cells[idx(x, z)].n else cells[idx(x, m.h - 1)].s;
    }
    fn z_seg(m: *const Maze, cells: *const [max_cells]Cell, x: u8, z: u8) bool {
        return if (x < m.w) cells[idx(x, z)].w else cells[idx(m.w - 1, z)].e;
    }

    /// Merge consecutive wall segments of `cells` on every grid line into
    /// runs (m.cells for the final maze, reveal_cells while carving).
    fn build_runs(m: *Maze, cells: *const [max_cells]Cell) void {
        var count: u16 = 0;
        var z: u8 = 0;
        while (z <= m.h) : (z += 1) {
            var x: u8 = 0;
            while (x < m.w) {
                if (!m.x_seg(cells, x, z)) {
                    x += 1;
                    continue;
                }
                const x0 = x;
                while (x < m.w and m.x_seg(cells, x, z)) x += 1;
                m.runs[count] = .{ .x = x0, .z = z, .len = x - x0, .axis = .x };
                count += 1;
            }
        }
        var x: u8 = 0;
        while (x <= m.w) : (x += 1) {
            var zz: u8 = 0;
            while (zz < m.h) {
                if (!m.z_seg(cells, x, zz)) {
                    zz += 1;
                    continue;
                }
                const z0 = zz;
                while (zz < m.h and m.z_seg(cells, x, zz)) zz += 1;
                m.runs[count] = .{ .x = x, .z = z0, .len = zz - z0, .axis = .z };
                count += 1;
            }
        }
        m.run_count = count;
    }

    /// ASCII picture: `+--+` walls, `S` start, `F` finish.
    pub fn dump(m: *const Maze, out: []u8) []const u8 {
        var n: usize = 0;
        var z: u8 = 0;
        while (z <= m.h) : (z += 1) {
            var x: u8 = 0;
            while (x < m.w) : (x += 1) {
                const seg = if (m.x_segment(x, z)) "+--" else "+  ";
                @memcpy(out[n..][0..3], seg);
                n += 3;
            }
            out[n] = '+';
            out[n + 1] = '\n';
            n += 2;
            if (z == m.h) break;
            x = 0;
            while (x <= m.w) : (x += 1) {
                out[n] = if (m.z_segment(x, z)) '|' else ' ';
                n += 1;
                if (x == m.w) break;
                const mark: u8 = if (x == m.start[0] and z == m.start[1]) 'S' else if (x == m.finish[0] and z == m.finish[1]) 'F' else ' ';
                out[n] = mark;
                out[n + 1] = mark;
                n += 2;
            }
            out[n] = '\n';
            n += 1;
        }
        return out[0..n];
    }
};

// Generator scratch in .bss (never on the small cart stack).
var stack: [max_cells][2]u8 = undefined;
var queue: [max_cells][2]u8 = undefined;
var dist: [max_cells]u16 = undefined;
/// Wall grid `reveal` rebuilds the partial maze in.
var reveal_cells: [max_cells]Cell = undefined;

/// Set true to print a 12x12 maze during `zig build test`.
const print_ascii = false;

test "Dir helpers" {
    try std.testing.expectEqual(Dir.s, Dir.n.opposite());
    try std.testing.expectEqual(Dir.w, Dir.e.opposite());
    try std.testing.expectEqual(Dir.w, Dir.n.left());
    try std.testing.expectEqual(Dir.e, Dir.n.right());
    try std.testing.expectEqual(Dir.n, Dir.w.right());
    try std.testing.expectEqual(Dir.s, Dir.w.left());
    for ([_]Dir{ .n, .e, .s, .w }) |d| {
        try std.testing.expectEqual(d, d.left().right());
        try std.testing.expectEqual(-d.dx(), d.opposite().dx());
        try std.testing.expectEqual(-d.dz(), d.opposite().dz());
        try std.testing.expectEqual(@as(i8, 1), @as(i8, @intCast(@abs(d.dx()) + @abs(d.dz()))));
    }
    try std.testing.expectEqual(@as(i8, -1), Dir.n.dz());
    try std.testing.expectEqual(@as(i8, 1), Dir.e.dx());
}

fn check_maze(m: *const Maze) !void {
    const w = m.w;
    const h = m.h;
    // Walls agree between neighbours; boundary walls present.
    var passages: u32 = 0;
    for (0..h) |zi| for (0..w) |xi| {
        const x: u8 = @intCast(xi);
        const z: u8 = @intCast(zi);
        for ([_]Dir{ .n, .e, .s, .w }) |d| {
            if (m.neighbour(x, z, d)) |nb| {
                try std.testing.expectEqual(m.has_wall(x, z, d), m.has_wall(nb[0], nb[1], d.opposite()));
                if (!m.has_wall(x, z, d) and (d == .e or d == .s)) passages += 1;
            } else try std.testing.expect(m.has_wall(x, z, d));
        }
    };
    try std.testing.expectEqual(@as(u32, w) * h - 1, passages);
    // All reachable: flood fill.
    var seen: [max_cells]bool = @splat(false);
    var todo: [max_cells][2]u8 = undefined;
    var n: usize = 1;
    todo[0] = .{ 0, 0 };
    seen[0] = true;
    var reached: u32 = 1;
    while (n > 0) {
        n -= 1;
        const c = todo[n];
        for ([_]Dir{ .n, .e, .s, .w }) |d| {
            if (m.has_wall(c[0], c[1], d)) continue;
            const nb = m.neighbour(c[0], c[1], d).?;
            const i = @as(usize, nb[1]) * max_size + nb[0];
            if (seen[i]) continue;
            seen[i] = true;
            reached += 1;
            todo[n] = nb;
            n += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, w) * h, reached);
    try std.testing.expect(m.finish[0] != m.start[0] or m.finish[1] != m.start[1]);
    try std.testing.expect(m.finish[0] < w and m.finish[1] < h);
    // Runs cover every wall segment exactly once and nothing else.
    var xcov: [max_size + 1][max_size]u8 = @splat(@splat(0));
    var zcov: [max_size + 1][max_size]u8 = @splat(@splat(0));
    for (m.runs[0..m.run_count]) |r| {
        try std.testing.expect(r.len >= 1);
        for (0..r.len) |k| switch (r.axis) {
            .x => {
                try std.testing.expect(r.z <= h and r.x + k < w);
                xcov[r.z][r.x + k] += 1;
            },
            .z => {
                try std.testing.expect(r.x <= w and r.z + k < h);
                zcov[r.x][r.z + k] += 1;
            },
        };
    }
    for (0..h + 1) |zi| for (0..w) |xi| {
        const want: u8 = @intFromBool(m.x_segment(@intCast(xi), @intCast(zi)));
        try std.testing.expectEqual(want, xcov[zi][xi]);
    };
    for (0..w + 1) |xi| for (0..h) |zi| {
        const want: u8 = @intFromBool(m.z_segment(@intCast(xi), @intCast(zi)));
        try std.testing.expectEqual(want, zcov[xi][zi]);
    };
    // Runs are maximal: no two runs on a line touch end to start.
    for (m.runs[0..m.run_count]) |a| for (m.runs[0..m.run_count]) |b| {
        if (a.axis != b.axis) continue;
        if (a.axis == .x and a.z == b.z) try std.testing.expect(a.x + a.len != b.x);
        if (a.axis == .z and a.x == b.x) try std.testing.expect(a.z + a.len != b.z);
    };
}

test "perfect mazes, runs and finish for seeds 0..99" {
    var m: Maze = .{};
    for ([_]u8{ 12, 16 }) |size| {
        for (0..100) |seed| {
            var r = rng.Xorshift.init(@intCast(seed));
            m.generate(size, size, &r);
            try check_maze(&m);
        }
    }
    var r = rng.Xorshift.init(3);
    m.generate(5, 9, &r);
    try check_maze(&m);
}

test "ascii dump" {
    var r = rng.Xorshift.init(1);
    var m: Maze = .{};
    m.generate(12, 12, &r);
    var buf: [4096]u8 = undefined;
    const s = m.dump(&buf);
    try std.testing.expect(s.len > 0);
    if (print_ascii) std.debug.print("\nseed 1, 12x12, {d} runs\n{s}", .{ m.run_count, s });
}

fn runs_equal(a: []const Run, b: []const Run) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.x != y.x or x.z != y.z or x.len != y.len or x.axis != y.axis) return false;
    }
    return true;
}

test "carve log and reveal: full, empty and every k" {
    var m: Maze = .{};
    var full: [max_runs]Run = undefined;
    for ([_][2]u8{ .{ 12, 12 }, .{ 16, 16 }, .{ 5, 9 } }) |size| {
        for (0..100) |seed| {
            var r = rng.Xorshift.init(@intCast(seed));
            m.generate(size[0], size[1], &r);
            const w = size[0];
            const h = size[1];
            try std.testing.expectEqual(@as(u16, w) * h - 1, m.carve_count);
            try std.testing.expectEqual(m.carve_count, m.revealed);
            const n = m.run_count;
            @memcpy(full[0..n], m.runs[0..n]);
            const cells = m.cells;
            const finish = m.finish;

            // reveal(0): every grid line is one whole run.
            m.reveal(0);
            try std.testing.expectEqual(@as(u16, 0), m.revealed);
            try std.testing.expectEqual(@as(u16, w + 1) + (h + 1), m.run_count);
            for (m.runs[0..m.run_count]) |run| {
                try std.testing.expectEqual(if (run.axis == .x) w else h, run.len);
            }
            try std.testing.expect(m.carve_head() == null);

            var k: u16 = 1;
            while (k < m.carve_count) : (k += 1) {
                m.reveal(k);
                try std.testing.expect(m.run_count <= max_runs);
                // The head is the cell the last carve opened into.
                try std.testing.expect(m.carve_head() != null);
            }

            m.reveal(m.carve_count);
            try std.testing.expect(runs_equal(full[0..n], m.runs[0..m.run_count]));
            try std.testing.expect(m.carve_head() == null);
            // Past the end clamps.
            m.reveal(1000);
            try std.testing.expectEqual(m.carve_count, m.revealed);
            try std.testing.expect(runs_equal(full[0..n], m.runs[0..m.run_count]));
            // The final maze never changes while revealing.
            try std.testing.expectEqualSlices(u8, std.mem.asBytes(&cells), std.mem.asBytes(&m.cells));
            try std.testing.expectEqual(finish, m.finish);
            try check_maze(&m);
        }
    }
}
