//! Synthetic TMF8820 frames from a hand scene (docs/TOF.md, the inverse of
//! lib/tof_pose.zig): a flat hand (an ellipse in a tilted plane) in front
//! of a per-zone background, seen by the sensor's 3x3 zones. Each zone
//! casts an 8x8 bundle of rays over its share of the field of view; rays
//! that hit the hand make the near target (mean distance, confidence from
//! the covered fraction and 1/d^2), the rest see the background (the far
//! target when the hand covers part of the zone). Optional histograms put
//! a Gaussian peak per target, area proportional to fraction / d^2.
//!
//! Used by the pose estimator's host tests and by snouty-morph's ghost
//! hand, which runs the real estimator on these frames. Pure f32, no
//! allocation, deterministic (the optional noise is a seeded xorshift).
//! Not a register model of the device: lib/tof_virtual.zig is that.
const std = @import("std");
const types = @import("tof_types.zig");

/// Sensor space: x right and y up as the viewer sees the screen (after
/// the orientation), z from the sensor toward the hand, millimetres.
pub const Hand = struct {
    x_mm: f32 = 0,
    y_mm: f32 = 0,
    z_mm: f32 = 200,
    /// Ellipse semi-axes: across the hand and along it (fingers up at yaw 0).
    half_w: f32 = 45,
    half_h: f32 = 90,
    /// Radians. pitch > 0: the top of the hand is farther from the sensor
    /// (z grows with y); roll > 0: its right side is farther (z grows with
    /// x); yaw > 0 turns the long axis from vertical toward -x
    /// (counter-clockwise as the viewer sees it).
    pitch: f32 = 0,
    roll: f32 = 0,
    yaw: f32 = 0,
};

pub const Scene = struct {
    hand: ?Hand = .{},
    /// Background distance along each screen cell's centre ray (row-major,
    /// row 0 top, col 0 left), 0 = nothing within range.
    background_mm: [types.zones]u16 = @splat(0),
    fov_x_deg: f32 = 33,
    fov_y_deg: f32 = 32,
    /// Histogram bin width (docs/TOF.md: ~57 mm).
    bin_mm: f32 = 57,
    /// Peak noise of the reported distances (mm, uniform), 0 = none.
    noise_mm: f32 = 0,
};

/// Rays per zone side (8x8 per zone).
pub const rays = 8;
/// Below this covered fraction a zone reports no hand target.
pub const min_fraction: f32 = 0.06;

/// Confidence the model reports for `fraction` of a zone at `mm`:
/// saturating in the returned signal, which falls as 1/d^2.
pub fn confidence(fraction: f32, mm: f32) u8 {
    const r = 300.0 / @max(mm, 10.0);
    const s = fraction * r * r;
    const c = 255.0 * s / (s + 0.3);
    return @intFromFloat(std.math.clamp(c, 1.0, 255.0));
}

/// Covered fraction and mean distance of one screen cell.
pub const CellHit = struct { fraction: f32, mm: f32 };

pub fn cell_hit(scene: *const Scene, col: u2, row: u2) CellHit {
    const h = scene.hand orelse return .{ .fraction = 0, .mm = 0 };
    const wx = deg_to_rad(scene.fov_x_deg) / 3.0;
    const wy = deg_to_rad(scene.fov_y_deg) / 3.0;
    const bg: f32 = @floatFromInt(scene.background_mm[@as(usize, row) * 3 + col]);
    const tr = tan(h.roll);
    const tp = tan(h.pitch);
    const cy = cos(h.yaw);
    const sy = sin(h.yaw);
    var hits: u32 = 0;
    var sum: f32 = 0;
    for (0..rays) |j| {
        for (0..rays) |i| {
            const fx = (@as(f32, @floatFromInt(i)) + 0.5) / rays - 0.5;
            const fy = (@as(f32, @floatFromInt(j)) + 0.5) / rays - 0.5;
            const ax = (@as(f32, @floatFromInt(col)) - 1.0 + fx) * wx;
            const ay = (1.0 - @as(f32, @floatFromInt(row)) - fy) * wy;
            const rx = tan(ax);
            const ry = tan(ay);
            // Plane z = cz + tr (x - cx) + tp (y - cy); ray (t rx, t ry, t).
            const den = 1.0 - tr * rx - tp * ry;
            if (den <= 0.05) continue;
            const t = (h.z_mm - tr * h.x_mm - tp * h.y_mm) / den;
            if (t <= 0) continue;
            const dx = t * rx - h.x_mm;
            const dy = t * ry - h.y_mm;
            // Into the hand's own axes (undo the yaw).
            const u = cy * dx + sy * dy;
            const v = -sy * dx + cy * dy;
            if ((u * u) / (h.half_w * h.half_w) + (v * v) / (h.half_h * h.half_h) > 1.0) continue;
            const d = t * @sqrt(1.0 + rx * rx + ry * ry);
            if (bg > 0 and d >= bg) continue;
            hits += 1;
            sum += d;
        }
    }
    if (hits == 0) return .{ .fraction = 0, .mm = 0 };
    return .{ .fraction = @as(f32, @floatFromInt(hits)) / (rays * rays), .mm = sum / @as(f32, @floatFromInt(hits)) };
}

/// Renders `scene` into `frame.zones` in device order through `orient`
/// (screen cell (col, row) is device zone `orient.index(col, row)`), and
/// into `hist` when given. `seed` drives the noise (and is advanced).
pub fn render(scene: *const Scene, orient: types.Orientation, frame: *types.Frame, hist: ?*types.Histograms, seed: *u32) void {
    if (hist) |hp| {
        for (&hp.bins) |*ch| @memset(ch, 40);
        hp.seq = frame.seq;
        add_peak(&hp.bins[0], 1.0, 4000.0);
    }
    for (0..3) |row| {
        for (0..3) |col| {
            const zi = orient.index(@intCast(col), @intCast(row));
            const hit = cell_hit(scene, @intCast(col), @intCast(row));
            const bg: f32 = @floatFromInt(scene.background_mm[row * 3 + col]);
            var zone: types.Zone = .{};
            var targets: [2]types.Target = .{ .{}, .{} };
            var fracs: [2]f32 = .{ 0, 0 };
            var n: usize = 0;
            if (hit.fraction >= min_fraction) {
                targets[n] = target(hit.mm + noise(scene, seed), hit.fraction);
                fracs[n] = hit.fraction;
                n += 1;
            }
            if (bg > 0 and hit.fraction < 0.94) {
                targets[n] = target(bg + noise(scene, seed), 1.0 - hit.fraction);
                fracs[n] = 1.0 - hit.fraction;
                n += 1;
            }
            if (n > 0) zone.near = targets[0];
            if (n > 1) zone.far = targets[1];
            frame.zones[zi] = zone;
            if (hist) |hp| {
                for (targets[0..n], fracs[0..n]) |t, f| {
                    const mm: f32 = @floatFromInt(t.mm);
                    const r = 300.0 / @max(mm, 10.0);
                    add_peak(&hp.bins[zi + 1], mm / scene.bin_mm, f * r * r * 20000.0);
                }
            }
        }
    }
}

fn target(mm: f32, fraction: f32) types.Target {
    return .{
        .mm = @intFromFloat(std.math.clamp(mm + 0.5, 1.0, 65535.0)),
        .confidence = confidence(fraction, mm),
    };
}

/// A Gaussian peak (sigma 0.8 bins) of total area `area` centred at `bin`.
fn add_peak(ch: *[types.hist_bins]u32, bin: f32, area: f32) void {
    const sigma: f32 = 0.8;
    const centre: i32 = @intFromFloat(@floor(bin + 0.5));
    var b = centre - 3;
    while (b <= centre + 3) : (b += 1) {
        if (b < 0 or b >= types.hist_bins) continue;
        const d = (@as(f32, @floatFromInt(b)) - bin) / sigma;
        // exp(-d^2/2) by a short rational fit (no libm on the badge).
        const g = 1.0 / (1.0 + 0.5 * d * d + 0.125 * d * d * d * d);
        ch[@intCast(b)] += @intFromFloat(area * 0.4987 * g / sigma);
    }
}

fn noise(scene: *const Scene, seed: *u32) f32 {
    if (scene.noise_mm == 0) return 0;
    var x = seed.*;
    if (x == 0) x = 0x9e3779b9;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    seed.* = x;
    const u = @as(f32, @floatFromInt(x >> 8)) / 16777216.0; // 0..1
    return (u * 2.0 - 1.0) * scene.noise_mm;
}

// Small f32 helpers without libm (the badge build links none): sine and
// cosine by range reduction and a 7th-order polynomial, tangent from them.
pub fn deg_to_rad(d: f32) f32 {
    return d * (std.math.pi / 180.0);
}

pub fn sin(x: f32) f32 {
    // Reduce to [-pi, pi].
    const two_pi: f32 = 2.0 * std.math.pi;
    var a = x - two_pi * @floor(x / two_pi + 0.5);
    // To [-pi/2, pi/2] by symmetry.
    if (a > std.math.pi / 2.0) a = std.math.pi - a;
    if (a < -std.math.pi / 2.0) a = -std.math.pi - a;
    const a2 = a * a;
    return a * (1.0 - a2 / 6.0 * (1.0 - a2 / 20.0 * (1.0 - a2 / 42.0 * (1.0 - a2 / 72.0))));
}

pub fn cos(x: f32) f32 {
    return sin(x + std.math.pi / 2.0);
}

pub fn tan(x: f32) f32 {
    return sin(x) / cos(x);
}

test "synth: trig helpers" {
    const t = std.testing;
    try t.expectApproxEqAbs(@as(f32, 0.5), sin(deg_to_rad(30)), 1e-5);
    try t.expectApproxEqAbs(@as(f32, 0.5), cos(deg_to_rad(60)), 1e-5);
    try t.expectApproxEqAbs(@as(f32, 1.0), tan(deg_to_rad(45)), 1e-5);
    try t.expectApproxEqAbs(@as(f32, 0.5), sin(deg_to_rad(-210)), 1e-5);
}

test "synth: a big flat hand fills every zone at its distance" {
    const scene: Scene = .{ .hand = .{ .z_mm = 200, .half_w = 300, .half_h = 300 } };
    var frame: types.Frame = .{};
    var seed: u32 = 1;
    render(&scene, .{}, &frame, null, &seed);
    for (frame.zones, 0..) |z, i| {
        try std.testing.expect(z.near.valid());
        try std.testing.expect(!z.far.valid());
        // Corner rays are longer than the perpendicular 200 mm.
        const lo: u16 = 200;
        const hi: u16 = if (i == 4) 203 else 215;
        try std.testing.expect(z.near.mm >= lo and z.near.mm <= hi);
    }
}

test "synth: a hand over part of a zone gives near and far targets" {
    var scene: Scene = .{ .hand = .{ .x_mm = 60, .z_mm = 250, .half_w = 30, .half_h = 200 } };
    scene.background_mm = @splat(700);
    var frame: types.Frame = .{};
    var hist: types.Histograms = .{};
    var seed: u32 = 1;
    render(&scene, .{}, &frame, &hist, &seed);
    // Right column (col 2) is partly covered; left column sees only the wall.
    const right = frame.zones[1 * 3 + 2];
    try std.testing.expect(right.near.valid() and right.far.valid());
    try std.testing.expect(right.near.mm < 280 and right.far.mm == 700);
    const left = frame.zones[1 * 3 + 0];
    try std.testing.expectEqual(@as(u16, 700), left.near.mm);
    try std.testing.expect(!left.far.valid());
    // The histogram has a peak at the hand's bin in the right zone.
    const ch = hist.bins[1 + 1 * 3 + 2];
    const b: usize = @intFromFloat(@floor(@as(f32, @floatFromInt(right.near.mm)) / 57.0 + 0.5));
    try std.testing.expect(ch[b] > 200);
}
