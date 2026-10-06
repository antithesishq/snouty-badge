//! The depth/presence field (SPEC.md section 1): nine cell values (0..1,
//! row-major, row 0 at the top of the screen) upsampled into a smooth
//! 80x64 field `f` (0..255, column-major like the surface) by a separable
//! Catmull-Rom spline through the cell centres, the edge cells repeated
//! beyond the border. A value at any pixel is a fixed linear mix of the
//! nine cells, so the weights are tables (`init`) and `build` is two
//! passes of three integer multiply-adds per pixel (~0.3 ms).
//!
//! STRIPES (docs/TOF.md M5): eight stripe values, each spanning the
//! field's full height, so the field has no vertical structure: a
//! Catmull-Rom spline through the stripes' centres (`stripe_x`, their
//! true angles, the outer centres at the same pixels the pose's x = +-1
//! maps to) gives one value per column, written down the whole column.
const std = @import("std");
const surface = @import("surface.zig");
const types = @import("tof").types;
const zones = @import("tof").zones;

pub const w = surface.w;
pub const h = surface.h;

/// The field, 0..255.
pub var f: [w][h]u8 = @splat(@splat(0));
/// Its largest value this frame.
pub var peak: u8 = 0;

/// Q8 weights of the three columns (rows) at each x (y).
var wx: [w][3]i32 = undefined;
var wy: [h][3]i32 = undefined;

/// STRIPES: surface x of each stripe's centre (left to right), and per
/// column the first of four stripes and their Q8 Catmull-Rom weights.
pub const stripes = 8;
pub var stripe_x: [stripes]f32 = undefined;
/// Surface pixels per unit of pose x in STRIPES (outer stripe centres at
/// x = +-1): wider than GRID's 26.67, since the stripes span the whole
/// 43 deg array where the normal map spans 33 deg.
pub const stripe_scale: f32 = 33.33;
var sx_base: [w]u8 = undefined;
var sx_w: [w][4]i32 = undefined;

pub fn init() void {
    for (0..w) |x| wx[x] = weights_q8(@as(f32, @floatFromInt(x)), w);
    for (0..h) |y| wy[y] = weights_q8(@as(f32, @floatFromInt(y)), h);
    // Stripe centres from the lib's geometry (symmetric, so MIRROR does
    // not move them).
    const g = zones.Geometry.init(.stripes, .{}, 33, 32);
    for (0..stripes) |k| stripe_x[k] = 40.0 + g.zones[k].tx / g.half_x * stripe_scale;
    for (0..w) |x| {
        // Pixel centre to a fractional stripe index (linear between the
        // centres, clamped to the ends), then uniform Catmull-Rom.
        const px = @as(f32, @floatFromInt(x)) + 0.5;
        var u: f32 = 0;
        if (px >= stripe_x[stripes - 1]) {
            u = stripes - 1;
        } else if (px > stripe_x[0]) {
            var k: usize = 0;
            while (px > stripe_x[k + 1]) k += 1;
            u = @as(f32, @floatFromInt(k)) + (px - stripe_x[k]) / (stripe_x[k + 1] - stripe_x[k]);
        }
        const fl = @min(@floor(u), stripes - 2);
        const t = u - fl;
        const t2 = t * t;
        const t3 = t2 * t;
        const b = [4]f32{
            0.5 * (-t + 2.0 * t2 - t3),
            0.5 * (2.0 - 5.0 * t2 + 3.0 * t3),
            0.5 * (t + 4.0 * t2 - 3.0 * t3),
            0.5 * (-t2 + t3),
        };
        // Stripes base - 1 .. base + 2, clamped at the ends: fold the
        // weights of out-of-range stripes onto the end ones.
        const base: i32 = @as(i32, @intFromFloat(fl)) - 1;
        const first: i32 = std.math.clamp(base, 0, stripes - 4);
        sx_base[x] = @intCast(first);
        var acc: [4]f32 = @splat(0);
        for (0..4) |k| {
            const idx = std.math.clamp(base + @as(i32, @intCast(k)), 0, stripes - 1);
            acc[@intCast(idx - first)] += b[k];
        }
        // Q8, the rounding residue on the heaviest weight: sums to 256
        // exactly, so a uniform field stays uniform.
        var sum: i32 = 0;
        var big: usize = 0;
        for (0..4) |k| {
            sx_w[x][k] = @intFromFloat(@round(acc[k] * 256.0));
            sum += sx_w[x][k];
            if (acc[k] > acc[big]) big = k;
        }
        sx_w[x][big] += 256 - sum;
    }
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

/// Upsample `cells` (0..1 each) into `f`: the 3x3 grid, or the first
/// eight entries as stripes (left to right).
pub fn build(cells: *const [9]f32, layout: types.Layout) void {
    if (layout == .stripes) return build_stripes(cells);
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

fn build_stripes(cells: *const [9]f32) void {
    var v: [stripes]i32 = undefined; // Q8
    for (0..stripes) |k| v[k] = @intFromFloat(std.math.clamp(cells[k], 0.0, 1.0) * 256.0);
    var top: u8 = 0;
    for (0..w) |x| {
        const b = sx_base[x];
        const wk = sx_w[x];
        const s = (wk[0] * v[b] + wk[1] * v[b + 1] + wk[2] * v[b + 2] + wk[3] * v[b + 3]) >> 8;
        const c: u8 = @intCast(std.math.clamp(s, 0, 255));
        @memset(&f[x], c);
        top = @max(top, c);
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
    build(&cells, .grid);
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
    build(&cells, .grid);
    for (0..w) |x| for (0..h) |y| try t.expect(f[x][y] >= 126 and f[x][y] <= 129);
}

test "field: stripes on one side light that side over the full height" {
    const t = std.testing;
    init();
    // Stripe centres increase, symmetric, the outer ones at x = +-1.
    for (1..stripes) |k| try t.expect(stripe_x[k] > stripe_x[k - 1]);
    try t.expectApproxEqAbs(@as(f32, 80.0), stripe_x[0] + stripe_x[stripes - 1], 1e-3);
    try t.expectApproxEqAbs(40.0 - stripe_scale, stripe_x[0], 1e-3);
    // Weights sum to one everywhere.
    for (0..w) |x| try t.expectEqual(@as(i32, 256), sx_w[x][0] + sx_w[x][1] + sx_w[x][2] + sx_w[x][3]);
    var cells: [9]f32 = @splat(0);
    cells[5] = 1.0;
    cells[6] = 1.0; // right of centre
    cells[8] = 1.0; // not a stripe: ignored
    build(&cells, .stripes);
    const sx: usize = @intFromFloat(@round(stripe_x[6]));
    for (0..h) |y| {
        try t.expect(f[sx][y] > 240);
        try t.expectEqual(f[sx][0], f[sx][y]);
        try t.expectEqual(@as(u8, 0), f[3][y]);
    }
    try t.expect(peak > 240);
    // Smooth across.
    for (0..w - 1) |x| try t.expect(@abs(@as(i32, f[x + 1][0]) - @as(i32, f[x][0])) <= 40);
    // Uniform stripes give a uniform field.
    cells = @splat(0.5);
    build(&cells, .stripes);
    for (0..w) |x| try t.expect(f[x][7] >= 126 and f[x][7] <= 129);
}
