//! Zone layouts and their geometry (docs/TOF.md M5). Where each zone of a
//! frame looks, as the screen sees it after the breakout's orientation:
//! the 3x3 grid of the pre-defined SPAD maps, or the 8 full-height stripes
//! of the user mask `tof_spad.stripes()`. lib/tof_pose.zig estimates the
//! hand from it, lib/tof_synth.zig renders synthetic frames through it,
//! and carts draw their zone maps with it. f32, no libm, no allocation.
//!
//! Screen cells: `cols` x `rows`, row-major, row 0 at the top, col 0 on
//! the left as the player sees the screen. GRID is 3x3. STRIPES is 8x1
//! (stripe 0 on the left), or 1x8 (stripe 0 at the top) when the
//! orientation transposes: the stripes run along the device's 18-column
//! axis, so a quarter turn makes them measure the screen's vertical axis
//! and the layout then has no horizontal resolution (`has_x` false).
//!
//! Angles: x right and y up on the screen, radians from the optical axis.
//! GRID keeps lib/tof_pose.zig's M3 convention: the configured field of
//! view (`fov_x_deg`, `fov_y_deg`) is the screen's, in three equal cells,
//! whatever the orientation. STRIPES comes from the SPAD array itself
//! (DS000693 7.4.1: one SPAD is 2.4 deg across the 18 columns, 5.6 deg
//! along the 10 rows), turned by the orientation.
const std = @import("std");
const types = @import("tof_types.zig");
const spad = @import("tof_spad.zig");

pub const Layout = types.Layout;
pub const Orientation = types.Orientation;

/// Most zones a layout has (the frame's nine).
pub const max_zones = types.zones;

/// DS000693 7.4.1: one SPAD's field of view.
pub const spad_col_deg: f32 = 2.4;
pub const spad_row_deg: f32 = 5.6;

/// SPAD column 0 is the left of the device's view, the same side as zone
/// 1 of the pre-defined maps (docs/TOF.md section 3, inferred in M2). If
/// the badge shows STRIPES mirrored against GRID, set this.
pub const stripes_reversed = false;

/// The layouts a cart can pick (ZONES).
pub const selectable = [_]Layout{ .grid, .stripes };

pub const Zone = struct {
    /// Index into `Frame.zones` (and histogram channel `dev + 1`).
    dev: u4 = 0,
    /// Centre angle and half extent, screen axes (radians).
    ax: f32 = 0,
    ay: f32 = 0,
    hax: f32 = 0,
    hay: f32 = 0,
    /// Centre tangents (the pose works in tangent space) and the zone's
    /// width in tangent units along each axis.
    tx: f32 = 0,
    ty: f32 = 0,
    wx: f32 = 0,
    wy: f32 = 0,
};

pub const Geometry = struct {
    layout: Layout = .grid,
    orient: Orientation = .{},
    /// Zones in use (9 GRID, 8 STRIPES); `zones[0..n]` by screen cell.
    n: u8 = 0,
    cols: u8 = 0,
    rows: u8 = 0,
    zones: [max_zones]Zone = @splat(.{}),
    /// The layout resolves this screen axis (more than one zone along it).
    has_x: bool = true,
    has_y: bool = true,
    /// Tangent of the outer zones' centres per axis (pose x, y = +-1
    /// there); 1 for an axis without resolution.
    half_x: f32 = 1,
    half_y: f32 = 1,
    /// The GRID cell spacing (tangent) for the same field of view, in both
    /// layouts: the scale of the pose's spread confidences and ridge, so
    /// their meaning does not change with the layout.
    ref_x: f32 = 1,
    ref_y: f32 = 1,

    pub fn init(layout: Layout, orient: Orientation, fov_x_deg: f32, fov_y_deg: f32) Geometry {
        var g: Geometry = .{ .layout = layout, .orient = orient };
        const wx = deg(fov_x_deg) / 3.0;
        const wy = deg(fov_y_deg) / 3.0;
        g.ref_x = tan(wx);
        g.ref_y = tan(wy);
        switch (layout) {
            .stripes => g.init_stripes(),
            else => {
                g.n = 9;
                g.cols = 3;
                g.rows = 3;
                for (0..3) |r| for (0..3) |c| {
                    const ax = (@as(f32, @floatFromInt(c)) - 1.0) * wx;
                    const ay = (1.0 - @as(f32, @floatFromInt(r))) * wy;
                    var z = zone(orient.index(@intCast(c), @intCast(r)), ax, ay, wx / 2.0, wy / 2.0);
                    // M3's sub-zone shift used the cell spacing as every
                    // cell's width: kept, so GRID poses do not move.
                    z.wx = g.ref_x;
                    z.wy = g.ref_y;
                    g.zones[r * 3 + c] = z;
                };
                g.half_x = g.ref_x;
                g.half_y = g.ref_y;
            },
        }
        return g;
    }

    fn init_stripes(g: *Geometry) void {
        const n = spad.stripe_count;
        g.n = n;
        const fx: f32 = if (g.orient.flip_x) -1 else 1;
        const half_h = deg(spad_row_deg * spad.rows) / 2.0;
        for (0..n) |k| {
            // Device angle across the columns (u, right +) of stripe k.
            const a: f32 = @floatFromInt(spad.stripe_first[k]);
            const b: f32 = @floatFromInt(spad.stripe_first[k + 1]);
            var u = deg(((a + b) / 2.0 - spad.cols / 2.0) * spad_col_deg);
            if (stripes_reversed) u = -u;
            const hu = deg((b - a) * spad_col_deg) / 2.0;
            // Screen = orientation of the device's (u, v); v = 0 for every
            // stripe (full height), so flip_y changes nothing. Without
            // transpose x = fx u, y = fy v; with it x = -fy v, y = -fx u
            // (Orientation.index's inverse).
            var cell: usize = undefined;
            var z: Zone = undefined;
            const dev: u4 = @intCast(k + 1);
            if (!g.orient.transpose) {
                const x = fx * u;
                z = zone(dev, x, 0, hu, half_h);
                cell = if ((fx < 0) != stripes_reversed) n - 1 - k else k;
            } else {
                const y = -fx * u;
                z = zone(dev, 0, y, half_h, hu);
                // Row 0 is the top: the largest y.
                cell = if ((fx < 0) != stripes_reversed) n - 1 - k else k;
            }
            g.zones[cell] = z;
        }
        if (!g.orient.transpose) {
            g.cols = n;
            g.rows = 1;
            g.has_y = false;
            g.half_x = @abs(g.zones[0].tx);
            g.half_y = 1;
        } else {
            g.cols = 1;
            g.rows = n;
            g.has_x = false;
            g.half_x = 1;
            g.half_y = @abs(g.zones[0].ty);
        }
    }

    /// The screen cell showing device zone `dev`, or null if the layout
    /// does not use it.
    pub fn cell_of(g: *const Geometry, dev: usize) ?u4 {
        for (g.zones[0..g.n], 0..) |z, i| if (z.dev == dev) return @intCast(i);
        return null;
    }

    /// Screen (col, row) of cell `ci`.
    pub fn col(g: *const Geometry, ci: usize) u8 {
        return @intCast(ci % g.cols);
    }
    pub fn row(g: *const Geometry, ci: usize) u8 {
        return @intCast(ci / g.cols);
    }

    /// Pose x (-1..1 at the outer zones' centres) to a fractional screen
    /// column 0..cols-1 (the zone centres); likewise y (up) to a row.
    pub fn col_at(g: *const Geometry, x: f32) f32 {
        return pos_at(g, x * g.half_x, true);
    }
    pub fn row_at(g: *const Geometry, y: f32) f32 {
        return pos_at(g, y * g.half_y, false);
    }

    fn pos_at(g: *const Geometry, t: f32, x_axis: bool) f32 {
        const n: usize = if (x_axis) g.cols else g.rows;
        if (n <= 1) return 0;
        const stride: usize = if (x_axis) 1 else g.cols;
        // Zone centres along the axis, increasing with the index (x) or
        // decreasing (y: row 0 is the top).
        const s: f32 = if (x_axis) 1 else -1;
        const v = s * t;
        const first = s * axis_t(g, 0, x_axis);
        if (v <= first) return 0;
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const lo = s * axis_t(g, (i - 1) * stride, x_axis);
            const hi = s * axis_t(g, i * stride, x_axis);
            if (v <= hi) return @as(f32, @floatFromInt(i - 1)) + (v - lo) / @max(hi - lo, 1e-6);
        }
        return @floatFromInt(n - 1);
    }

    fn axis_t(g: *const Geometry, ci: usize, x_axis: bool) f32 {
        return if (x_axis) g.zones[ci].tx else g.zones[ci].ty;
    }
};

fn zone(dev: u4, ax: f32, ay: f32, hax: f32, hay: f32) Zone {
    return .{
        .dev = dev,
        .ax = ax,
        .ay = ay,
        .hax = hax,
        .hay = hay,
        .tx = tan(ax),
        .ty = tan(ay),
        .wx = tan(ax + hax) - tan(ax - hax),
        .wy = tan(ay + hay) - tan(ay - hay),
    };
}

fn deg(d: f32) f32 {
    return d * (std.math.pi / 180.0);
}

// sin / cos / tan without libm (as lib/tof_synth.zig).
fn sin(x: f32) f32 {
    const two_pi: f32 = 2.0 * std.math.pi;
    var a = x - two_pi * @floor(x / two_pi + 0.5);
    if (a > std.math.pi / 2.0) a = std.math.pi - a;
    if (a < -std.math.pi / 2.0) a = -std.math.pi - a;
    const a2 = a * a;
    return a * (1.0 - a2 / 6.0 * (1.0 - a2 / 20.0 * (1.0 - a2 / 42.0 * (1.0 - a2 / 72.0))));
}

fn tan(x: f32) f32 {
    return sin(x) / sin(x + std.math.pi / 2.0);
}

// ---- Host tests ----

const testing = std.testing;

test "zones: GRID is the M3 3x3 geometry through Orientation.index" {
    const o: Orientation = .{ .flip_x = true, .transpose = true };
    const g = Geometry.init(.grid, o, 41, 52);
    try testing.expectEqual(@as(u8, 9), g.n);
    for (0..3) |r| for (0..3) |c| {
        const z = g.zones[r * 3 + c];
        try testing.expectEqual(o.index(@intCast(c), @intCast(r)), z.dev);
        try testing.expectApproxEqAbs((@as(f32, @floatFromInt(c)) - 1.0) * g.ref_x, z.tx, 1e-6);
        try testing.expectApproxEqAbs((1.0 - @as(f32, @floatFromInt(r))) * g.ref_y, z.ty, 1e-6);
    };
    try testing.expect(g.has_x and g.has_y);
    try testing.expectEqual(@as(?u4, 4), g.cell_of(4));
}

test "zones: STRIPES left to right, mirrored by flip_x, vertical when transposed" {
    const g = Geometry.init(.stripes, .{}, 41, 52);
    try testing.expectEqual(@as(u8, 8), g.n);
    try testing.expectEqual(@as(u8, 8), g.cols);
    try testing.expectEqual(@as(u8, 1), g.rows);
    try testing.expect(g.has_x and !g.has_y);
    // Stripe k is device zone k + 1, increasing x, symmetric.
    for (0..8) |k| {
        try testing.expectEqual(@as(u4, @intCast(k + 1)), g.zones[k].dev);
        try testing.expectEqual(@as(f32, 0), g.zones[k].ty);
        if (k > 0) try testing.expect(g.zones[k].tx > g.zones[k - 1].tx);
        try testing.expectApproxEqAbs(-g.zones[7 - k].tx, g.zones[k].tx, 1e-5);
    }
    // Inner stripes 4.8 deg, outer 7.2 deg, outer centre at 18 deg.
    try testing.expectApproxEqAbs(deg(2.4), g.zones[3].hax, 1e-6);
    try testing.expectApproxEqAbs(deg(3.6), g.zones[0].hax, 1e-6);
    try testing.expectApproxEqAbs(tan(deg(18)), g.half_x, 1e-5);
    try testing.expectEqual(@as(?u4, null), g.cell_of(0));
    // flip_x: stripe 0 (device left) is the screen's right.
    const m = Geometry.init(.stripes, .{ .flip_x = true }, 41, 52);
    try testing.expectEqual(@as(u4, 8), m.zones[0].dev);
    try testing.expect(m.zones[0].tx < 0);
    // flip_y changes nothing (full height).
    const fy = Geometry.init(.stripes, .{ .flip_y = true }, 41, 52);
    for (0..8) |k| try testing.expectEqual(g.zones[k].tx, fy.zones[k].tx);
    // Transposed: a column of 8 rows, device left at the top, no x.
    const t = Geometry.init(.stripes, .{ .transpose = true }, 41, 52);
    try testing.expectEqual(@as(u8, 1), t.cols);
    try testing.expectEqual(@as(u8, 8), t.rows);
    try testing.expect(!t.has_x and t.has_y);
    try testing.expectEqual(@as(u4, 1), t.zones[0].dev);
    try testing.expect(t.zones[0].ty > 0 and t.zones[7].ty < 0);
}

test "zones: pose position to fractional cells" {
    const g = Geometry.init(.stripes, .{}, 41, 52);
    try testing.expectApproxEqAbs(@as(f32, 0), g.col_at(-1), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 7), g.col_at(1), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 3.5), g.col_at(0), 1e-5);
    try testing.expectEqual(@as(f32, 0), g.row_at(0.5));
    const gr = Geometry.init(.grid, .{}, 41, 52);
    try testing.expectApproxEqAbs(@as(f32, 1), gr.col_at(0), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), gr.row_at(1), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.5), gr.row_at(-0.5), 1e-5);
}
