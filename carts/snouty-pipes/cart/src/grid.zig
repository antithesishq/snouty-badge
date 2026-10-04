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
        return @intCast(@intFromEnum(d) >> 1);
    }
    /// +1 or -1 along `axis()`.
    pub fn sign(d: Dir) f32 {
        return if (@intFromEnum(d) & 1 == 0) 1.0 else -1.0;
    }
    pub fn vec(d: Dir) math.Vec3 {
        var v: math.Vec3 = @splat(0);
        v[d.axis()] = d.sign();
        return v;
    }
    pub fn opposite(d: Dir) Dir {
        return @enumFromInt(@intFromEnum(d) ^ 1);
    }
    pub fn step(d: Dir) [3]i8 {
        var s: [3]i8 = .{ 0, 0, 0 };
        s[d.axis()] = if (@intFromEnum(d) & 1 == 0) 1 else -1;
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
