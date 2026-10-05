//! Triangle fills for the column-major framebuffer (`fb[x][y]`), from
//! demosnout's head part: screen points in 28.4 fixed point, edges walked
//! column by column in 16.16, pixel centres inside the triangle covered,
//! shared edges with no gap and no overlap, clipped to the screen.
//!
//! `fill_flat` writes one pixel value per column run (a memset).
//! `fill_gouraud` interpolates a shade ramp index (16.16) with the
//! triangle's constant gradient, one add per pixel, plus a 4x4 ordered
//! dither on its fraction (config.dither), and looks the colour up in the
//! material's ramp.
//!
//! Generic over the framebuffer (`fb: anytype`, an array of 160 columns of
//! 128 pixels) so the host tests can fill plain u16 arrays.
const std = @import("std");
const config = @import("config.zig");

pub const width = 160;
pub const height = 128;

/// A screen point in 28.4 fixed point (1/16 pixel).
pub const Point = struct { x: i32, y: i32 };

/// Counter-clockwise in object space (y up) is clockwise on screen (y
/// down): a negative screen cross product faces the viewer.
pub inline fn front_facing(a: Point, b: Point, c: Point) bool {
    const cr = @as(i64, b.x - a.x) * (c.y - a.y) - @as(i64, b.y - a.y) * (c.x - a.x);
    return cr < 0;
}

/// One triangle edge walked column by column: y (16.16) at the current
/// column's centre and its per-column step.
const Edge = struct {
    y: i32,
    step: i32,

    fn init(p: Point, q: Point, x0: i32) Edge {
        const dx: i64 = q.x - p.x; // > 0 by the caller
        const dy: i64 = q.y - p.y;
        const xc: i64 = @as(i64, x0) * 16 + 8 - p.x;
        const y = (@as(i64, p.y) << 12) + @divFloor((xc * dy) << 12, dx);
        const step = @divFloor(dy << 16, dx);
        return .{ .y = clamp_i32(y), .step = clamp_i32(step) };
    }
};

inline fn clamp_i32(v: i64) i32 {
    return @intCast(std.math.clamp(v, -(1 << 30), 1 << 30));
}

inline fn col_ceil(x: i32) i32 {
    return (x + 7) >> 4;
}

inline fn row_ceil(y: i32) i32 {
    return (y + 0x7fff) >> 16;
}

inline fn before(p: Point, q: Point) bool {
    return p.x < q.x or (p.x == q.x and p.y < q.y);
}

/// What a column run is filled with.
fn Shader(comptime P: type) type {
    return struct {
        flat: P,
        /// Gouraud: ramp index (16.16) at vertex `a`, its gradient in x
        /// and y (16.16 per 1/16 pixel), the ramp.
        gouraud: bool = false,
        a: Point = .{ .x = 0, .y = 0 },
        la: i64 = 0,
        gx: i64 = 0,
        gy: i64 = 0,
        ramp: []const P = &.{},
    };
}

/// 4x4 Bayer thresholds in 1/16 of an index step, as 16.16 offsets.
const bayer = [4][4]i32{
    .{ 0 * 4096, 8 * 4096, 2 * 4096, 10 * 4096 },
    .{ 12 * 4096, 4 * 4096, 14 * 4096, 6 * 4096 },
    .{ 3 * 4096, 11 * 4096, 1 * 4096, 9 * 4096 },
    .{ 15 * 4096, 7 * 4096, 13 * 4096, 5 * 4096 },
};

pub fn fill_flat(fb: anytype, a: Point, b: Point, c: Point, px: anytype) void {
    const P = @TypeOf(px);
    fill(fb, a, b, c, Shader(P){ .flat = px });
}

/// `la`, `lb`, `lc`: ramp indices at the vertices, 0 <= l < ramp.len - 1.
pub fn fill_gouraud(fb: anytype, a: Point, b: Point, c: Point, la: f32, lb: f32, lc: f32, ramp: anytype) void {
    const P = @TypeOf(ramp[0]);
    const ax: f32 = @floatFromInt(a.x);
    const ay: f32 = @floatFromInt(a.y);
    const bx = @as(f32, @floatFromInt(b.x)) - ax;
    const by = @as(f32, @floatFromInt(b.y)) - ay;
    const cx = @as(f32, @floatFromInt(c.x)) - ax;
    const cy = @as(f32, @floatFromInt(c.y)) - ay;
    const det = bx * cy - cx * by;
    // Slivers under ~1 square pixel: one shade.
    if (@abs(det) < 256.0) {
        const l: usize = @intFromFloat((la + lb + lc) * (1.0 / 3.0));
        return fill(fb, a, b, c, Shader(P){ .flat = ramp[l] });
    }
    const inv = 65536.0 / det;
    const gx = ((lb - la) * cy - (lc - la) * by) * inv;
    const gy = ((lc - la) * bx - (lb - la) * cx) * inv;
    const lim: f32 = 64.0 * 65536.0;
    fill(fb, a, b, c, Shader(P){
        .flat = ramp[0],
        .gouraud = true,
        .a = a,
        .la = @intFromFloat(la * 65536.0),
        .gx = @intFromFloat(std.math.clamp(gx, -lim, lim)),
        .gy = @intFromFloat(std.math.clamp(gy, -lim, lim)),
        .ramp = ramp,
    });
}

fn fill(fb: anytype, a: Point, b: Point, c: Point, sh: anytype) void {
    var v0 = a;
    var v1 = b;
    var v2 = c;
    if (before(v1, v0)) std.mem.swap(Point, &v0, &v1);
    if (before(v2, v1)) std.mem.swap(Point, &v1, &v2);
    if (before(v1, v0)) std.mem.swap(Point, &v0, &v1);
    const xs = col_ceil(v0.x);
    const xm = col_ceil(v1.x);
    const xe = col_ceil(v2.x);
    if (xs >= xe) return;
    var long = Edge.init(v0, v2, xs);
    if (xs < xm) {
        var e = Edge.init(v0, v1, xs);
        columns(fb, xs, xm, &long, &e, sh);
    }
    if (xm < xe) {
        var e = Edge.init(v1, v2, xm);
        columns(fb, xm, xe, &long, &e, sh);
    }
}

fn columns(fb: anytype, x0: i32, x1: i32, long: *Edge, e: *Edge, sh: anytype) void {
    var x = x0;
    if (x < 0) {
        const k: i32 = @min(0, x1) - x;
        long.y +%= long.step *% k;
        e.y +%= e.step *% k;
        x += k;
    }
    const end = @min(x1, width);
    while (x < end) : (x += 1) {
        const top = @min(long.y, e.y);
        const bot = @max(long.y, e.y);
        const y0: usize = @intCast(std.math.clamp(row_ceil(top), 0, height));
        const y1: usize = @intCast(std.math.clamp(row_ceil(bot), 0, height));
        if (y0 < y1) {
            const col = &fb[@intCast(x)];
            if (!sh.gouraud) {
                @memset(col[y0..y1], sh.flat);
            } else {
                gouraud_run(col, x, y0, y1, sh);
            }
        }
        long.y +%= long.step;
        e.y +%= e.step;
    }
}

inline fn gouraud_run(col: anytype, x: i32, y0: usize, y1: usize, sh: anytype) void {
    const dx: i64 = @as(i64, x) * 16 + 8 - sh.a.x;
    const dy: i64 = @as(i64, @intCast(y0)) * 16 + 8 - sh.a.y;
    const top = sh.la + sh.gx * dx + sh.gy * dy;
    const step64 = sh.gy * 16; // a pixel is 16 units of 1/16 px
    const n: i64 = @intCast(y1 - y0);
    const last = top + step64 * (n - 1);
    const max: i64 = @as(i64, @intCast(sh.ramp.len - 1)) << 16;
    const d = if (config.dither) bayer[@as(usize, @intCast(x)) & 3] else [4]i32{ 0, 0, 0, 0 };
    if (top >= 0 and last >= 0 and top < max - 65536 and last < max - 65536) {
        var i: i32 = @intCast(top);
        const step: i32 = @intCast(step64);
        var y = y0;
        while (y < y1) : (y += 1) {
            col[y] = sh.ramp[@intCast((i + d[y & 3]) >> 16)];
            i += step;
        }
    } else {
        // Extrapolated past the ramp (a sliver's clamped gradient): clamp.
        var i = top;
        var y = y0;
        while (y < y1) : (y += 1) {
            const v = std.math.clamp(i + d[y & 3], 0, max);
            col[y] = sh.ramp[@intCast(v >> 16)];
            i += step64;
        }
    }
}

// ---------------------------------------------------------------------------
// Host tests (u16 framebuffers).

const Fb = [width][height]u16;

fn pt(x: f32, y: f32) Point {
    return .{ .x = @intFromFloat(@round(x * 16)), .y = @intFromFloat(@round(y * 16)) };
}

fn count(fb: *const Fb, v: u16) usize {
    var n: usize = 0;
    for (fb) |col| for (col) |q| {
        if (q == v) n += 1;
    };
    return n;
}

test "raster: flat triangle and shared edges" {
    var fb: Fb = @splat(@splat(0));
    fill_flat(&fb, pt(10, 20), pt(18, 20), pt(10, 28), @as(u16, 1));
    try std.testing.expectEqual(@as(usize, 28), count(&fb, 1));
    fb = @splat(@splat(0));
    const q = [4]Point{ pt(3.3, 2.1), pt(61.7, 5.6), pt(57.2, 43.4), pt(0.8, 39.9) };
    fill_flat(&fb, q[0], q[1], q[2], @as(u16, 1));
    fill_flat(&fb, q[0], q[2], q[3], @as(u16, 2));
    var overlap_free = count(&fb, 1) + count(&fb, 2);
    fb = @splat(@splat(0));
    fill_flat(&fb, q[0], q[1], q[2], @as(u16, 1));
    overlap_free -= count(&fb, 1);
    fb = @splat(@splat(0));
    fill_flat(&fb, q[0], q[2], q[3], @as(u16, 2));
    try std.testing.expectEqual(count(&fb, 2), overlap_free);
}

test "raster: gouraud interpolates the ramp and clips safely" {
    var ramp: [65]u16 = undefined;
    for (&ramp, 0..) |*r, i| r.* = @intCast(i + 100);
    var fb: Fb = @splat(@splat(0));
    // Index 0 at the left, 60 at the right: columns increase left to right.
    fill_gouraud(&fb, pt(0, 0), pt(160, 64), pt(0, 128), 0, 60, 0, &ramp);
    const left = fb[2][64];
    const mid = fb[80][64];
    const right = fb[150][64];
    try std.testing.expect(left >= 100 and left <= 103);
    try std.testing.expect(mid >= 128 and mid <= 132);
    try std.testing.expect(right >= 154 and right <= 158);
    // Off-screen vertices and a sliver do not crash or index out of range.
    fill_gouraud(&fb, pt(-500, -400), pt(900, 30), pt(-200, 700), 1, 63, 30, &ramp);
    fill_gouraud(&fb, pt(10, 10), pt(150, 10.2), pt(80, 10.1), 0, 63, 63, &ramp);
    for (fb) |col| for (col) |v| try std.testing.expect(v == 0 or (v >= 100 and v <= 164));
}

test "raster: winding" {
    try std.testing.expect(!front_facing(pt(0, 0), pt(10, 0), pt(0, 10)));
    try std.testing.expect(front_facing(pt(0, 0), pt(0, 10), pt(10, 0)));
}
