//! The depth/presence field (SPEC.md section 1): nine cell values (0..1,
//! row-major, row 0 at the top of the screen) upsampled into a smooth
//! 80x64 field `f` (0..255, column-major like the surface) by a separable
//! Catmull-Rom spline through the cell centres, the edge cells repeated
//! beyond the border. A value at any pixel is a fixed linear mix of the
//! nine cells, so the weights are tables (`init`) and `build` is two
//! passes of three integer multiply-adds per pixel (~0.3 ms).
const std = @import("std");
const surface = @import("surface.zig");

pub const w = surface.w;
pub const h = surface.h;

/// The field, 0..255.
pub var f: [w][h]u8 = @splat(@splat(0));
/// Its largest value this frame.
pub var peak: u8 = 0;

/// Q8 weights of the three columns (rows) at each x (y).
var wx: [w][3]i32 = undefined;
var wy: [h][3]i32 = undefined;

pub fn init() void {
    for (0..w) |x| wx[x] = weights_q8(@as(f32, @floatFromInt(x)), w);
    for (0..h) |y| wy[y] = weights_q8(@as(f32, @floatFromInt(y)), h);
}

/// Catmull-Rom weights of the three cell centres at pixel `p` of `n`.
pub fn weights(p: f32, n: comptime_int) [3]f32 {
    const u = (p + 0.5) * 3.0 / @as(f32, n) - 0.5;
    const fl = @floor(u);
    const t = u - fl;
    const t2 = t * t;
    const t3 = t2 * t;
    const b = [4]f32{
        0.5 * (-t + 2.0 * t2 - t3),
        0.5 * (2.0 - 5.0 * t2 + 3.0 * t3),
        0.5 * (t + 4.0 * t2 - 3.0 * t3),
        0.5 * (-t2 + t3),
    };
    var out: [3]f32 = @splat(0);
    const base_i: i32 = @intFromFloat(fl);
    for (0..4) |k| {
        const idx = std.math.clamp(base_i - 1 + @as(i32, @intCast(k)), 0, 2);
        out[@intCast(idx)] += b[k];
    }
    return out;
}

fn weights_q8(p: f32, n: comptime_int) [3]i32 {
    const wf = weights(p, n);
    var out: [3]i32 = undefined;
    for (0..3) |i| out[i] = @intFromFloat(@round(wf[i] * 256.0));
    return out;
}

/// Upsample `cells` (0..1 each) into `f`.
pub fn build(cells: *const [9]f32) void {
    var v: [3][3]i32 = undefined; // [row][col], Q8
    for (0..3) |r| for (0..3) |c| {
        v[r][c] = @intFromFloat(std.math.clamp(cells[r * 3 + c], 0.0, 1.0) * 256.0);
    };
    var rows: [3][w]i32 = undefined; // Q16
    for (0..3) |r| for (0..w) |x| {
        rows[r][x] = wx[x][0] * v[r][0] + wx[x][1] * v[r][1] + wx[x][2] * v[r][2];
    };
    var top: u8 = 0;
    for (0..w) |x| {
        const r0 = rows[0][x];
        const r1 = rows[1][x];
        const r2 = rows[2][x];
        const col = &f[x];
        for (0..h) |y| {
            const s = (wy[y][0] * r0 + wy[y][1] * r1 + wy[y][2] * r2) >> 16;
            const c: u8 = @intCast(std.math.clamp(s, 0, 255));
            col[y] = c;
            top = @max(top, c);
        }
    }
    peak = top;
}

test "field: weights interpolate the cell centres and sum to one" {
    const t = std.testing;
    for (0..w) |x| {
        const wf = weights(@floatFromInt(x), w);
        try t.expectApproxEqAbs(@as(f32, 1.0), wf[0] + wf[1] + wf[2], 1e-4);
    }
    // At the centre column the middle cell has all the weight.
    const c = weights(39.5, w);
    try t.expectApproxEqAbs(@as(f32, 1.0), c[1], 1e-4);
}

test "field: one lit cell makes a smooth bump centred on it" {
    const t = std.testing;
    init();
    var cells: [9]f32 = @splat(0);
    cells[2] = 1.0; // top right
    build(&cells);
    // Peak near the top-right cell centre (x ~67, y ~11), dark far away.
    try t.expect(f[66][10] > 240);
    try t.expectEqual(@as(u8, 0), f[5][60]);
    try t.expect(peak > 240);
    // Smooth: neighbouring pixels never jump by much.
    for (0..w - 1) |x| for (0..h) |y| {
        const d = @as(i32, f[x + 1][y]) - @as(i32, f[x][y]);
        try t.expect(@abs(d) <= 24);
    };
    // Uniform cells give a uniform field.
    cells = @splat(0.5);
    build(&cells);
    for (0..w) |x| for (0..h) |y| try t.expect(f[x][y] >= 126 and f[x][y] <= 129);
}
