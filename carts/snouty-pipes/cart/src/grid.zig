//! The invisible 3D grid the pipes grow through (SPEC.md section 3): sizes,
//! directions, the per-cell primitive `Prim` every other module draws from,
//! occupancy, and the pipe walk. Pure logic, host-tested, no cart API.
const std = @import("std");
const math = @import("math.zig");
const rng = @import("rng.zig");

/// Grid size in cells (SPEC decision 2). Cell (i, j, k) has its centre at
/// world (i - (nx-1)/2, j - (ny-1)/2, k - (nz-1)/2): one cell = one world unit,
/// the grid box spans [-n/2, n/2] on each axis.
pub const nx = 12;
pub const ny = 10;
pub const nz = 12;
pub const cell_count = nx * ny * nz;

/// Axis directions of travel. `none` marks a pipe's start (as `din`) or end
/// (as `dout`).
pub const Dir = enum(u3) {
    px,
    nx,
    py,
    ny,
    pz,
    nz,
    none = 7,

    pub fn axis(d: Dir) u2 {
        return @intCast(@backingInt(d) >> 1);
    }
    /// +1 or -1 along `axis()`.
    pub fn sign(d: Dir) f32 {
        return if (@backingInt(d) & 1 == 0) 1.0 else -1.0;
    }
    /// Unit vector along `d` (zero for `none`). A switch, not a vector
    /// store: vector indices must be comptime-known on the cart targets.
    pub fn vec(d: Dir) math.Vec3 {
        return switch (d) {
            .px => .{ 1, 0, 0 },
            .nx => .{ -1, 0, 0 },
            .py => .{ 0, 1, 0 },
            .ny => .{ 0, -1, 0 },
            .pz => .{ 0, 0, 1 },
            .nz => .{ 0, 0, -1 },
            .none => @splat(0),
        };
    }
    pub fn opposite(d: Dir) Dir {
        return @fromBackingInt(@intCast(@backingInt(d) ^ 1));
    }
    pub fn step(d: Dir) [3]i8 {
        var s: [3]i8 = .{ 0, 0, 0 };
        s[d.axis()] = if (@backingInt(d) & 1 == 0) 1 else -1;
        return s;
    }
};

/// How a turning cell is drawn (SPEC section 4). `teapot` is the easter egg:
/// the two half cylinders of a ball joint with a teapot in place of the ball.
pub const Joint = enum(u2) { ball, elbow, teapot };

/// One cell of one pipe: everything needed to draw it, in 32 bits (the
/// history ring holds these). The path through the cell runs from the face
/// it entered by (centre - din * 0.5) to the face it leaves by (centre +
/// dout * 0.5). din == none: pipe start (ball cap at the centre, half
/// cylinder out). dout == none: pipe end (half cylinder in, ball cap).
/// din == dout: straight. Otherwise a turn, drawn as `joint` says (joint
/// is ignored for straight cells and caps).
pub const Prim = packed struct(u32) {
    x: u5,
    y: u5,
    z: u5,
    din: Dir,
    dout: Dir,
    color: u4,
    joint: Joint = .ball,
    _pad: u5 = 0,

    pub fn center(p: Prim) math.Vec3 {
        return cell_center(p.x, p.y, p.z);
    }
    pub fn is_turn(p: Prim) bool {
        return p.din != .none and p.dout != .none and p.din != p.dout;
    }
};

pub fn cell_center(x: u32, y: u32, z: u32) math.Vec3 {
    return math.vec3(
        @as(f32, @floatFromInt(x)) - @as(f32, nx - 1) * 0.5,
        @as(f32, @floatFromInt(y)) - @as(f32, ny - 1) * 0.5,
        @as(f32, @floatFromInt(z)) - @as(f32, nz - 1) * 0.5,
    );
}

/// One bit per cell.
pub const Occupancy = struct {
    bits: [(cell_count + 31) / 32]u32 = @splat(0),
    filled: u16 = 0,

    pub fn index(x: u32, y: u32, z: u32) u32 {
        return (z * ny + y) * nx + x;
    }
    pub fn get(self: *const Occupancy, x: u32, y: u32, z: u32) bool {
        const i = index(x, y, z);
        return self.bits[i >> 5] & (@as(u32, 1) << @intCast(i & 31)) != 0;
    }
    pub fn set(self: *Occupancy, x: u32, y: u32, z: u32) void {
        const i = index(x, y, z);
        const m = @as(u32, 1) << @intCast(i & 31);
        if (self.bits[i >> 5] & m == 0) self.filled += 1;
        self.bits[i >> 5] |= m;
    }
    pub fn unset(self: *Occupancy, x: u32, y: u32, z: u32) void {
        const i = index(x, y, z);
        const m = @as(u32, 1) << @intCast(i & 31);
        if (self.bits[i >> 5] & m != 0) self.filled -= 1;
        self.bits[i >> 5] &= ~m;
    }
    pub fn clear(self: *Occupancy) void {
        self.* = .{};
    }
};

test "prim is 32 bits and dir helpers agree" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Prim));
    try std.testing.expectEqual(Dir.nx, Dir.px.opposite());
    try std.testing.expectEqual(@as(u2, 2), Dir.nz.axis());
    try std.testing.expectEqual(@as(f32, -1.0), Dir.ny.sign());
}

/// Odds that a walk changes direction at a step (SPEC section 3, the
/// reference's `turnRandomness`): otherwise it keeps going straight when it
/// can.
pub const turn_odds: f32 = 0.25;

/// The head of one pipe walking the grid: a port of the reference's
/// `createPipe` without its string-keyed set (occupancy is a bit per cell).
/// The walker only moves; choosing where to go is a separate call, so a pipe
/// steered by the joystick (M3) calls `can_move` and `advance` itself.
pub const Pipe = struct {
    /// The head cell (occupied).
    x: u5 = 0,
    y: u5 = 0,
    z: u5 = 0,
    /// Direction the head was entered by: `none` at a pipe start.
    din: Dir = .none,
    /// Heading kept by a straight step; a fresh pipe gets a random one.
    heading: Dir = .px,
    color: u4 = 0,

    /// Neighbour of the head in direction `d`, or null outside the box.
    pub fn neighbour(self: *const Pipe, d: Dir) ?[3]u5 {
        return step_from(self.x, self.y, self.z, d);
    }

    /// True if the neighbour in direction `d` is inside the box and free.
    pub fn can_move(self: *const Pipe, occ: *const Occupancy, d: Dir) bool {
        const n = self.neighbour(d) orelse return false;
        return !occ.get(n[0], n[1], n[2]);
    }

    /// True if any of the six neighbours is free.
    pub fn can_move_any(self: *const Pipe, occ: *const Occupancy) bool {
        for (all_dirs) |d| {
            if (self.can_move(occ, d)) return true;
        }
        return false;
    }

    /// The reference's rule: straight on with odds 1 - `turn` if that cell
    /// is free, else the six directions in random order, first free one
    /// wins. Null = boxed in, the pipe dies.
    pub fn choose(self: *const Pipe, occ: *const Occupancy, r: *rng.Xorshift, turn: f32) ?Dir {
        if (r.unit() >= turn and self.can_move(occ, self.heading)) return self.heading;
        var dirs = all_dirs;
        var n: u32 = dirs.len;
        while (n > 0) {
            const i = r.below(n);
            const d = dirs[i];
            dirs[i] = dirs[n - 1];
            n -= 1;
            if (self.can_move(occ, d)) return d;
        }
        return null;
    }

    /// Moves the head one cell along `d` (which `can_move` allowed), marks
    /// the new cell occupied and returns the finished cell left behind: its
    /// exit is now known. `joint` only matters if that cell turns.
    pub fn advance(self: *Pipe, occ: *Occupancy, d: Dir, joint: Joint) Prim {
        const done = self.head(d, joint);
        const n = self.neighbour(d).?;
        self.x = n[0];
        self.y = n[1];
        self.z = n[2];
        self.din = d;
        self.heading = d;
        occ.set(n[0], n[1], n[2]);
        return done;
    }

    /// The head cell as a primitive leaving by `dout` (`none` = pipe end).
    pub fn head(self: *const Pipe, dout: Dir, joint: Joint) Prim {
        return .{
            .x = self.x,
            .y = self.y,
            .z = self.z,
            .din = self.din,
            .dout = dout,
            .color = self.color,
            .joint = joint,
        };
    }

    /// True if the head would turn when leaving by `d`.
    pub fn turns(self: *const Pipe, d: Dir) bool {
        return self.din != .none and self.din != d;
    }
};

pub const all_dirs = [6]Dir{ .px, .nx, .py, .ny, .pz, .nz };

/// Cell next to (x, y, z) along `d`, or null outside the box.
pub fn step_from(x: u5, y: u5, z: u5, d: Dir) ?[3]u5 {
    const s = d.step();
    const p = [3]i32{ @as(i32, x) + s[0], @as(i32, y) + s[1], @as(i32, z) + s[2] };
    if (p[0] < 0 or p[0] >= nx or p[1] < 0 or p[1] >= ny or p[2] < 0 or p[2] >= nz) return null;
    return .{ @intCast(p[0]), @intCast(p[1]), @intCast(p[2]) };
}

/// Starts a pipe at a uniformly random cell. Fails (null) if that cell is
/// taken or boxed in; otherwise marks it occupied. One rng draw per axis
/// plus one for the heading, whether it succeeds or not.
pub fn spawn(occ: *Occupancy, r: *rng.Xorshift, color: u4) ?Pipe {
    return spawn_in(occ, r, color, .{ 0, 0, 0 }, .{ nx, ny, nz });
}

/// `spawn` limited to the cells in [lo, hi) (steer mode's play box). The
/// same rng draws as `spawn`, which is this over the whole grid.
pub fn spawn_in(occ: *Occupancy, r: *rng.Xorshift, color: u4, lo: [3]u5, hi: [3]u5) ?Pipe {
    const p: Pipe = .{
        .x = @intCast(lo[0] + r.below(hi[0] - lo[0])),
        .y = @intCast(lo[1] + r.below(hi[1] - lo[1])),
        .z = @intCast(lo[2] + r.below(hi[2] - lo[2])),
        .heading = all_dirs[r.below(6)],
        .color = color,
    };
    if (occ.get(p.x, p.y, p.z) or !p.can_move_any(occ)) return null;
    occ.set(p.x, p.y, p.z);
    return p;
}

/// Marks every cell outside [lo, hi) occupied: steer mode's walls, so the
/// walk and the crash test treat them like pipes.
pub fn fill_outside(occ: *Occupancy, lo: [3]u5, hi: [3]u5) void {
    for (0..nz) |z| {
        for (0..ny) |y| {
            for (0..nx) |x| {
                const inside = x >= lo[0] and x < hi[0] and y >= lo[1] and y < hi[1] and z >= lo[2] and z < hi[2];
                if (!inside) occ.set(@intCast(x), @intCast(y), @intCast(z));
            }
        }
    }
}

test "walks never overlap or leave the box over 10k seeded steps" {
    var r = rng.Xorshift.init(12345);
    var occ: Occupancy = .{};
    var seen: Occupancy = .{};
    var steps: u32 = 0;
    var pipes: u32 = 0;
    while (steps < 10_000) {
        if (occ.filled > cell_count * 7 / 10) {
            occ.clear();
            seen.clear();
        }
        var p = spawn(&occ, &r, 0) orelse continue;
        pipes += 1;
        try std.testing.expect(!seen.get(p.x, p.y, p.z));
        seen.set(p.x, p.y, p.z);
        while (p.choose(&occ, &r, turn_odds)) |d| {
            const from = [3]u5{ p.x, p.y, p.z };
            const prim = p.advance(&occ, d, .elbow);
            steps += 1;
            try std.testing.expectEqual(d, prim.dout);
            try std.testing.expectEqual(from, [3]u5{ prim.x, prim.y, prim.z });
            try std.testing.expect(p.x < nx and p.y < ny and p.z < nz);
            try std.testing.expect(!seen.get(p.x, p.y, p.z));
            seen.set(p.x, p.y, p.z);
        }
        try std.testing.expect(!p.can_move_any(&occ));
        try std.testing.expectEqual(seen.filled, occ.filled);
    }
    try std.testing.expect(pipes > 20);
}

test "a walk mostly goes straight" {
    var r = rng.Xorshift.init(7);
    var occ: Occupancy = .{};
    var straight: u32 = 0;
    var total: u32 = 0;
    for (0..200) |_| {
        occ.clear();
        var p = spawn(&occ, &r, 0) orelse continue;
        for (0..6) |_| {
            const d = p.choose(&occ, &r, turn_odds) orelse break;
            if (p.din != .none) {
                total += 1;
                if (d == p.din) straight += 1;
            }
            _ = p.advance(&occ, d, .elbow);
        }
    }
    // 0.75 kept plus 1/6 of the random picks, minus wall bounces.
    try std.testing.expect(straight * 100 > total * 60);
    try std.testing.expect(straight * 100 < total * 90);
}
