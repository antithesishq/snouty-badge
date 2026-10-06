//! Synthetic TMF8820 frames from a hand scene (docs/TOF.md, the inverse of
//! lib/tof_pose.zig): a flat hand (an ellipse in a tilted plane), an
//! optional forearm (a strip sloping away from the sensor), in front of a
//! per-cell background, seen by the zones of a layout (lib/tof_zones.zig:
//! the 3x3 grid or the 8 stripes). Each zone casts a bundle of rays over
//! its share of the field of view (8x8 for a grid cell, 4 across by 16
//! along a stripe); rays that hit the hand or arm make the near target
//! (mean distance, confidence from the covered fraction and 1/d^2, or a
//! saturated 255), the rest see the background (the far target when the
//! hand covers part of the zone). Optional histograms put a Gaussian peak
//! per target, area proportional to fraction / d^2.
//!
//! Used by the pose estimator's host tests and by the carts' demo hands,
//! which run the real estimator on these frames. Pure f32, no
//! allocation, deterministic (the optional noise is a seeded xorshift).
//! Not a register model of the device: lib/tof_virtual.zig is that.
const std = @import("std");
const types = @import("tof_types.zig");
const zones_mod = @import("tof_zones.zig");

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

/// A forearm: a flat strip from the hand's centre toward `dir`, rising
/// away from the sensor. Where the hand is nearer (over the hand itself)
/// the hand hides it.
pub const Arm = struct {
    /// Direction from the hand toward the elbow, screen radians from +x
    /// (pi: the arm comes in from the left).
    dir: f32 = std.math.pi,
    /// mm of height gained per mm along the arm (1: 45 deg).
    slope: f32 = 0.6,
    half_w: f32 = 32,
    /// Length along the strip's ground projection (mm).
    length: f32 = 320,
};

pub const Scene = struct {
    hand: ?Hand = .{},
    arm: ?Arm = null,
    /// The zones that see it (lib/tof_zones.zig); the frame is tagged with it.
    layout: types.Layout = .grid,
    /// Confidence that does not track coverage: every target reports 255
    /// (the hardware may saturate; docs/TOF.md M5 open question 1).
    saturate: bool = false,
    /// Background distance along each screen cell's centre ray (row-major,
    /// row 0 top, col 0 left, the GRID's cells), 0 = nothing within range.
    /// A stripe sees the nearest background of the cells it spans.
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

/// Covered fraction and mean distance of one zone.
pub const CellHit = struct { fraction: f32, mm: f32 };

/// The geometry `scene` is seen through.
pub fn geometry(scene: *const Scene, orient: types.Orientation) zones_mod.Geometry {
    const l: types.Layout = if (scene.layout == .stripes) .stripes else .grid;
    return zones_mod.Geometry.init(l, orient, scene.fov_x_deg, scene.fov_y_deg);
}

/// GRID screen cell (col, row): the M3 call.
pub fn cell_hit(scene: *const Scene, col: u2, row: u2) CellHit {
    const g = zones_mod.Geometry.init(.grid, .{}, scene.fov_x_deg, scene.fov_y_deg);
    const ci = @as(usize, row) * 3 + col;
    return zone_hit(scene, &g.zones[ci], background(scene, &g.zones[ci]));
}

/// The background a zone sees: the nearest of the GRID cells whose centre
/// lies inside it (the nearest cell if none does).
pub fn background(scene: *const Scene, z: *const zones_mod.Zone) f32 {
    const wx = deg_to_rad(scene.fov_x_deg) / 3.0;
    const wy = deg_to_rad(scene.fov_y_deg) / 3.0;
    var inside = false;
    var best: f32 = 0;
    var near_d: f32 = 1e9;
    var near_bg: f32 = 0;
    for (0..3) |r| for (0..3) |c| {
        const dx = @abs((@as(f32, @floatFromInt(c)) - 1.0) * wx - z.ax);
        const dy = @abs((1.0 - @as(f32, @floatFromInt(r))) * wy - z.ay);
        const bg: f32 = @floatFromInt(scene.background_mm[r * 3 + c]);
        if (dx * dx + dy * dy < near_d) {
            near_d = dx * dx + dy * dy;
            near_bg = bg;
        }
        if (dx < z.hax + 1e-4 and dy < z.hay + 1e-4) {
            inside = true;
            if (bg > 0) best = if (best == 0) bg else @min(best, bg);
        }
    };
    // A zone holding no cell centre (a stripe between them) sees the nearest cell.
    return if (inside) best else near_bg;
}

/// Rays across and along a zone: 8x8 for a grid cell, 4 x 16 for a stripe.
fn ray_counts(z: *const zones_mod.Zone) [2]u32 {
    if (z.hay > 3.0 * z.hax) return .{ 4, 16 };
    if (z.hax > 3.0 * z.hay) return .{ 16, 4 };
    return .{ rays, rays };
}

pub fn zone_hit(scene: *const Scene, z: *const zones_mod.Zone, bg: f32) CellHit {
    const h = scene.hand orelse return .{ .fraction = 0, .mm = 0 };
    const tr = tan(h.roll);
    const tp = tan(h.pitch);
    const cy = cos(h.yaw);
    const sy = sin(h.yaw);
    const n = ray_counts(z);
    var hits: u32 = 0;
    var sum: f32 = 0;
    for (0..n[1]) |j| {
        for (0..n[0]) |i| {
            const fx = (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(n[0])) - 0.5;
            const fy = (@as(f32, @floatFromInt(j)) + 0.5) / @as(f32, @floatFromInt(n[1])) - 0.5;
            const rx = tan(z.ax + 2.0 * fx * z.hax);
            const ry = tan(z.ay - 2.0 * fy * z.hay);
            const sec = @sqrt(1.0 + rx * rx + ry * ry);
            var d: f32 = 1e9;
            // Plane z = cz + tr (x - cx) + tp (y - cy); ray (t rx, t ry, t).
            const den = 1.0 - tr * rx - tp * ry;
            if (den > 0.05) {
                const t = (h.z_mm - tr * h.x_mm - tp * h.y_mm) / den;
                if (t > 0) {
                    const dx = t * rx - h.x_mm;
                    const dy = t * ry - h.y_mm;
                    // Into the hand's own axes (undo the yaw).
                    const u = cy * dx + sy * dy;
                    const v = -sy * dx + cy * dy;
                    if ((u * u) / (h.half_w * h.half_w) + (v * v) / (h.half_h * h.half_h) <= 1.0) d = t * sec;
                }
            }
            if (scene.arm) |a| {
                if (arm_t(&h, &a, rx, ry)) |t| d = @min(d, t * sec);
            }
            if (d >= 1e9) continue;
            if (bg > 0 and d >= bg) continue;
            hits += 1;
            sum += d;
        }
    }
    if (hits == 0) return .{ .fraction = 0, .mm = 0 };
    return .{ .fraction = @as(f32, @floatFromInt(hits)) / @as(f32, @floatFromInt(n[0] * n[1])), .mm = sum / @as(f32, @floatFromInt(hits)) };
}

/// Depth parameter t (the hit's z) of ray (rx, ry, 1) on the arm strip.
fn arm_t(h: *const Hand, a: *const Arm, rx: f32, ry: f32) ?f32 {
    const dx = cos(a.dir);
    const dy = sin(a.dir);
    // Strip: W + s (dx, dy, slope) + w (-dy, dx, 0), W = the hand's centre.
    // Normal (-slope dx, -slope dy, 1).
    const nx = -a.slope * dx;
    const ny = -a.slope * dy;
    const den = nx * rx + ny * ry + 1.0;
    if (den <= 0.05) return null;
    const t = (nx * h.x_mm + ny * h.y_mm + h.z_mm) / den;
    if (t <= 0) return null;
    const px = t * rx - h.x_mm;
    const py = t * ry - h.y_mm;
    const s = px * dx + py * dy;
    const w = -px * dy + py * dx;
    if (s < 0 or s > a.length or @abs(w) > a.half_w) return null;
    return t;
}

/// Renders `scene` into `frame.zones` in device order through `orient`
/// and the scene's layout (screen cell ci is device zone
/// `geometry.zones[ci].dev`; zones the layout does not use are empty),
/// and into `hist` when given. `seed` drives the noise (and is advanced).
pub fn render(scene: *const Scene, orient: types.Orientation, frame: *types.Frame, hist: ?*types.Histograms, seed: *u32) void {
    const g = geometry(scene, orient);
    frame.layout = g.layout;
    frame.zones = @splat(.{});
    if (hist) |hp| {
        for (&hp.bins) |*ch| @memset(ch, 40);
        hp.seq = frame.seq;
        add_peak(&hp.bins[0], 1.0, 4000.0);
    }
    for (g.zones[0..g.n]) |*zg| {
        const zi = zg.dev;
        const bg = background(scene, zg);
        const hit = zone_hit(scene, zg, bg);
        var zone: types.Zone = .{};
        var targets: [2]types.Target = .{ .{}, .{} };
        var fracs: [2]f32 = .{ 0, 0 };
        var n: usize = 0;
        if (hit.fraction >= min_fraction) {
            targets[n] = target(scene, hit.mm + noise(scene, seed), hit.fraction);
            fracs[n] = hit.fraction;
            n += 1;
        }
        if (bg > 0 and hit.fraction < 0.94) {
            targets[n] = target(scene, bg + noise(scene, seed), 1.0 - hit.fraction);
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
                add_peak(&hp.bins[@as(usize, zi) + 1], mm / scene.bin_mm, f * r * r * 20000.0);
            }
        }
    }
}

fn target(scene: *const Scene, mm: f32, fraction: f32) types.Target {
    return .{
        .mm = @intFromFloat(std.math.clamp(mm + 0.5, 1.0, 65535.0)),
        .confidence = if (scene.saturate) 255 else confidence(fraction, mm),
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

test "synth: stripes see a narrow hand in a few stripes, tagged and in device order" {
    var scene: Scene = .{ .layout = .stripes, .fov_x_deg = 41, .fov_y_deg = 52, .hand = .{ .x_mm = 40, .z_mm = 200, .half_w = 25, .half_h = 80 } };
    scene.background_mm = @splat(900);
    var frame: types.Frame = .{};
    var seed: u32 = 1;
    render(&scene, .{}, &frame, null, &seed);
    try std.testing.expectEqual(types.Layout.stripes, frame.layout);
    try std.testing.expect(!frame.zones[0].near.valid());
    var lit: u32 = 0;
    var first: usize = 0;
    for (frame.zones[1..], 1..) |z, i| {
        if (z.near.valid() and z.near.mm < 400) {
            if (lit == 0) first = i;
            lit += 1;
        } else try std.testing.expectEqual(@as(u16, 900), z.near.mm);
    }
    // 50 mm wide at 200 mm is ~14 deg: three or four 4.8 deg stripes, right of centre.
    try std.testing.expect(lit >= 3 and lit <= 4);
    try std.testing.expect(first >= 5);
    // Mirrored, the same hand lands in the mirror-image stripes.
    var m: types.Frame = .{};
    render(&scene, .{ .flip_x = true }, &m, null, &seed);
    for (1..9) |i| try std.testing.expectEqual(frame.zones[i].near.mm < 400, m.zones[9 - i].near.mm < 400);
}

test "synth: an arm hides behind the hand and shows beside it, farther away" {
    var scene: Scene = .{ .layout = .stripes, .hand = .{ .x_mm = 30, .z_mm = 200, .half_w = 40, .half_h = 60 }, .arm = .{} };
    scene.background_mm = @splat(1200);
    var frame: types.Frame = .{};
    var seed: u32 = 1;
    render(&scene, .{}, &frame, null, &seed);
    // The arm runs off to the left: the leftmost stripes see it, farther than the hand.
    const left = frame.zones[1].near;
    const hand = frame.zones[6].near;
    try std.testing.expect(left.valid() and left.mm < 1200 and left.mm > hand.mm + 60);
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
