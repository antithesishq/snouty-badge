//! The hand over the sensor (SPEC section 2): its height (the slide) and
//! its place left to right (the embouchure), from the lib/tof_pose.zig
//! pose of each frame, in either zone layout (ZONES: GRID, the 3x3 of map
//! 6, or STRIPES, the 8-stripe user mask; docs/TOF.md M5). Pure data,
//! host-tested.
//!
//! - Which zones are the hand comes from the pose's background model
//!   (`Pose.coverage`: a zone nearer than what it learned behind it), so a
//!   ceiling, a wall or the table edge never plays.
//! - Height: the pose's `height_mm`, the mean height of the near cluster
//!   (every hand zone within `cluster_mm`, 40, of the nearest, each zone's
//!   distance turned into a height with its own ray). This is the M1 rule
//!   the cart had in its own tables, moved into lib/tof_pose.zig so it
//!   works for any layout. The single nearest zone jumps between
//!   fingertips, knuckles and the forearm as the hand moves sideways (the
//!   theremin's M1.2 lesson); the cluster mean does not, and the 3-frame
//!   median in play.zig drops what is left of a spike.
//! - Left to right: the pose's arm-rejected centroid (the near cluster
//!   only, so a forearm reaching in from one side does not pull it), as
//!   the angle off the sensor's axis (tangent `x_mm / z_mm`), mapped to a
//!   lip tension 0..4096 across +-`span` of that tangent. An angle, not
//!   millimetres, keeps both ends reachable at every height (the field is
//!   narrow near the sensor). The span is per layout: GRID keeps M1's
//!   (0.85 of map 6's outer cell centres); STRIPES, which resolve about
//!   3x finer, spread the partials a little wider (each about one stripe).
const tof = @import("tof");
const tof_types = tof.types;
const tof_pose = tof.pose;
const Layout = tof_types.Layout;

pub const Config = struct {
    /// Lip span (tangent of the hand's angle off the axis at which the lip
    /// reaches its ends) per layout. GRID: 0.85 x tan(41/3 deg), M1's
    /// `lip_span` 0.85 in GRID pose units, a little inside the outer cells'
    /// centres so both ends are reachable with the hand still over the
    /// sensor. STRIPES: 0.32 (17.7 deg, about the outer stripes' centres),
    /// so a partial is 5.2 deg wide, about one inner stripe (4.8 deg): at
    /// least two of the half-stripe steps that stripe membership alone
    /// gives fall in every partial, whatever the confidence does. Spans
    /// of 0.22..0.30 leave some partial at some height between two such
    /// steps (as little as 3 % of its share with a saturated confidence);
    /// 0.31..0.34 give every middle partial at least 85 % of its share
    /// from 12 to 45 cm (the scan in the host test below).
    span_grid: f32 = 0.85 * 0.24316,
    span_stripes: f32 = 0.32,

    pub fn span(c: Config, l: Layout) f32 {
        return if (l == .stripes) c.span_stripes else c.span_grid;
    }
};

/// The pose estimator's settings for this cart: the wide SPAD map's field
/// of view (GRID; STRIPES take theirs from the SPAD array) and the hand
/// window. cluster_mm (40, the library default) is M1's height cluster.
pub const pose_config: tof_pose.Config = .{ .fov_x_deg = 41, .fov_y_deg = 52, .min_mm = 15, .max_mm = 650, .min_confidence = 8 };

pub const Reading = struct {
    /// Hand height (mm), null: no hand this frame.
    height_mm: ?u16 = null,
    /// Lip tension 0..4096 (left .. right as the player sees the screen),
    /// null: the pose has no hand (hold the last).
    lip_t: ?i32 = null,
    /// The layout the frame was measured with, and its screen cells.
    layout: Layout = .grid,
    cols: u8 = 3,
    rows: u8 = 3,
    /// Hand zones this frame (bit per screen cell, row-major).
    cells: u16 = 0,
    /// Of those, the near cluster (what the height and the lip came from).
    cluster: u16 = 0,
};

pub fn read(pose: *const tof_pose.Pose, cfg: Config) Reading {
    var r: Reading = .{ .layout = pose.layout, .cols = pose.cols, .rows = pose.rows };
    if (pose.present) r.lip_t = lip_t(pose, cfg.span(pose.layout));
    if (!pose.seen) return r;
    for (pose.coverage, 0..) |c, ci| {
        if (c > 0) r.cells |= @as(u16, 1) << @intCast(ci);
    }
    r.cluster = pose.cluster;
    // height_mm is 0 until the pose reports the hand present (its
    // `appear_frames`: a one-frame blip in one zone is not a hand).
    if (pose.present and pose.height_mm >= 1) r.height_mm = @intFromFloat(@min(pose.height_mm + 0.5, 65535.0));
    return r;
}

/// The hand's angle off the axis (tangent), screen right positive.
pub fn tangent(pose: *const tof_pose.Pose) f32 {
    return if (pose.z_mm > 1) pose.x_mm / pose.z_mm else 0;
}

/// Pose to a lip tension 0..4096: -span is 0, +span 4096.
pub fn lip_t(pose: *const tof_pose.Pose, span: f32) i32 {
    return lip_t_of(tangent(pose), span);
}

pub fn lip_t_of(tan_x: f32, span: f32) i32 {
    const u = (tan_x + span) / (2.0 * span);
    const c = if (u < 0) 0 else if (u > 1) 1 else u;
    return @intFromFloat(c * 4096.0 + 0.5);
}

/// The hand x (mm, screen right positive) whose lip sits in the middle of
/// `partial`'s band at height `z_mm` (the demo hand's inverse of `read`).
pub fn x_for(partial: u4, pedal: bool, z_mm: f32, span: f32) f32 {
    const horn_ = @import("horn.zig");
    const t = horn_.t_for(@as(i32, partial) * horn_.lip_one, pedal);
    const u = @as(f32, @floatFromInt(t)) / 4096.0;
    return (2.0 * u - 1.0) * span * z_mm;
}

// ---- Host tests ----

const std = @import("std");
const testing = std.testing;
const horn = @import("horn.zig");
const Frame = tof_types.Frame;

fn frame_with(cells: [9]u16) Frame {
    var f: Frame = .{};
    for (cells, 0..) |d, i| {
        if (d != 0) f.zones[i].near = .{ .mm = d, .confidence = 200 };
    }
    return f;
}

test "hand: height is the near cluster's mean, the room is not a hand" {
    var est: tof_pose.Estimator = .{ .config = pose_config };
    // A hand over the middle and right at ~200 mm, the forearm at 300 on
    // the left, the ceiling (beyond the window) behind.
    const f = frame_with(.{ 1300, 210, 196, 300, 204, 200, 1300, 1300, 230 });
    var r: Reading = .{};
    for (0..3) |i| {
        var g = f;
        g.seq = @intCast(i);
        g.time_us = 1_000_000 + @as(u64, i) * 33_333;
        const p = est.update(&g, null, .{});
        r = read(&p, .{});
    }
    // As heights (off-axis rays are longer than the height): 201, 182,
    // 204, 194, 214 are within 40 of the nearest (182); the forearm's
    // 300 mm (292 high) is not. The same 199 as M1's integer tables.
    try testing.expectEqual(@as(?u16, 199), r.height_mm);
    try testing.expect(r.lip_t != null);
    try testing.expect(r.cells & (1 << 0) == 0);
    try testing.expect(r.cluster & (1 << 3) == 0 and r.cells & (1 << 3) != 0);
    // Nothing but the room: no hand.
    const empty = frame_with(.{ 1300, 1300, 1300, 1300, 1300, 1300, 1300, 1300, 1300 });
    var e2: tof_pose.Estimator = .{ .config = pose_config };
    const p2 = e2.update(&empty, null, .{});
    try testing.expectEqual(@as(?u16, null), read(&p2, .{}).height_mm);
}

test "hand: lip tension spans 0..4096 over the span, clamped" {
    try testing.expectEqual(@as(i32, 0), lip_t_of(-0.2, 0.2));
    try testing.expectEqual(@as(i32, 2048), lip_t_of(0, 0.2));
    try testing.expectEqual(@as(i32, 4096), lip_t_of(0.2, 0.2));
    try testing.expectEqual(@as(i32, 4096), lip_t_of(3, 0.2));
    try testing.expectEqual(@as(i32, 0), lip_t_of(-3, 0.2));
    // GRID keeps M1's mapping: x = +-0.85 of the outer cells' centres.
    const cfg: Config = .{};
    try testing.expectApproxEqAbs(@as(f32, 0.85 * 0.24316), cfg.span(.grid), 1e-6);
}

/// A synthetic hand (lib/tof_synth.zig) at (x_mm, z_mm) in `layout`,
/// run through the pose and `read` for `frames` frames; the last reading.
fn synth_reading(est: *tof_pose.Estimator, seq: *u32, layout: Layout, x_mm: f32, z_mm: f32, frames: u32, mirror: bool) Reading {
    var scene: tof.synth.Scene = .{ .layout = layout, .fov_x_deg = 41, .fov_y_deg = 52, .noise_mm = 2 };
    scene.background_mm = @splat(1300);
    scene.hand = .{ .x_mm = x_mm, .z_mm = z_mm, .pitch = 0.15 };
    var r: Reading = .{};
    var seed: u32 = seq.* *% 2654435761 +% 1;
    const orient: tof_types.Orientation = .{ .flip_x = mirror };
    for (0..frames) |_| {
        var f: Frame = .{ .seq = seq.*, .time_us = 1_000_000 + @as(u64, seq.*) * 33_333 };
        tof.synth.render(&scene, orient, &f, null, &seed);
        const p = est.update(&f, null, orient);
        r = read(&p, .{});
        seq.* += 1;
    }
    return r;
}

fn estimator(layout: Layout) tof_pose.Estimator {
    var est: tof_pose.Estimator = .{ .config = pose_config };
    est.set_layout(layout);
    return est;
}

test "hand: height follows the synthetic hand across the slide's throw, both layouts" {
    for ([_]Layout{ .grid, .stripes }) |l| {
        var est = estimator(l);
        var seq: u32 = 0;
        const map: horn.SlideMap = .{};
        var z: f32 = 100;
        while (z <= 450) : (z += 50) {
            const r = synth_reading(&est, &seq, l, 0, z, 6, false);
            try testing.expectEqual(l, r.layout);
            const h: f32 = @floatFromInt(r.height_mm.?);
            // The cluster mean of a slightly tilted hand: within ~3% of its height.
            try testing.expect(@abs(h - z) < z * 0.03 + 3);
            const want = map.slide(@intFromFloat(z));
            try testing.expect(@abs(map.slide(r.height_mm.?) - want) <= 25);
        }
    }
}

test "hand: sweeping the hand left to right walks the partials up, once each" {
    // At a mid-throw height (4th position), the hand sweeping slowly from
    // well left to well right through the real pose: the embouchure climbs
    // 2..8 without ever going back down (the centroid, not the argmin zone).
    for ([_]Layout{ .grid, .stripes }) |l| for ([_]bool{ false, true }) |mirror| {
        var est = estimator(l);
        var seq: u32 = 0;
        var e: horn.Embouchure = .{ .partial = 2 };
        var lip: i32 = horn.lip_for(0, false);
        var last: u4 = 2;
        var seen: [9]bool = @splat(false);
        const n = 160;
        for (0..n) |i| {
            const s: f32 = @as(f32, @floatFromInt(i)) / (n - 1);
            // The scene is in screen space; MIRROR's flip round-trips through the
            // device order and back.
            const x = -180 + 360 * s;
            const r = synth_reading(&est, &seq, l, x, 270, 1, mirror);
            if (r.lip_t) |t| {
                // play.zig's smoothing: half the gap per update.
                lip += @divTrunc(horn.lip_for(t, false) - lip, 2);
            }
            _ = e.update(lip, false);
            try testing.expect(e.partial >= last);
            last = e.partial;
            seen[e.partial] = true;
        }
        for (2..9) |p| try testing.expect(seen[p]);
    };
}

/// Each partial's band of hand x (mm) at height `z`: settled readings at
/// 1 mm steps, the partial the lip value rounds to (no hysteresis).
fn bands(l: Layout, z: f32, saturate: bool) [9]f32 {
    var width: [9]f32 = @splat(0);
    const span = (Config{}).span(l);
    const reach = span * z * 1.1;
    var x: f32 = -reach;
    while (x <= reach) : (x += 1) {
        var est = estimator(l);
        var scene: tof.synth.Scene = .{ .layout = l, .saturate = saturate, .fov_x_deg = 41, .fov_y_deg = 52 };
        scene.background_mm = @splat(1300);
        scene.hand = .{ .x_mm = x, .z_mm = z };
        var seed: u32 = 9;
        var p: tof_pose.Pose = .{};
        for (0..8) |k| {
            var f: Frame = .{ .seq = @intCast(k), .time_us = 1_000_000 + @as(u64, k) * 33_333 };
            tof.synth.render(&scene, .{}, &f, null, &seed);
            p = est.update(&f, null, .{});
        }
        const lip = horn.lip_for(read(&p, .{}).lip_t.?, false);
        const n: usize = @intCast(@min(@max(@divFloor(lip + horn.lip_one / 2, horn.lip_one), 2), 8));
        width[n] += 1;
    }
    return width;
}

/// The narrowest middle partial (3..7) band over heights 12..45 cm, as a
/// fraction of its share of the span.
fn worst_band(l: Layout, saturate: bool) f32 {
    const span = (Config{}).span(l);
    var worst: f32 = 9;
    var z: f32 = 120;
    while (z <= 450) : (z += 30) {
        const w = bands(l, z, saturate);
        for (3..8) |p| worst = @min(worst, w[p] / (2.0 * span * z / 7.0));
    }
    return worst;
}

test "hand: STRIPES give every partial its band at every height; GRID cannot" {
    // A still hand must be able to hold each partial. M1 (GRID) left some
    // middle partials a few mm of hand travel, or none, at some heights:
    // the pose's x steps over 3 columns, whatever the span. In STRIPES,
    // with a span of about one stripe per partial, every middle partial
    // keeps most of its share, also when the confidence carries no
    // coverage (saturated: stripe membership only).
    for ([_]bool{ false, true }) |sat| {
        const s = worst_band(.stripes, sat);
        const g = worst_band(.grid, sat);
        try testing.expect(s > 0.75);
        try testing.expect(g < 0.3);
    }
}
