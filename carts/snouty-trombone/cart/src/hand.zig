//! The hand over the sensor (SPEC section 2): its height (the slide) and
//! its place left to right (the embouchure), from one frame and the
//! lib/tof_pose.zig pose of that frame. Pure data, host-tested.
//!
//! - Which zones are the hand comes from the pose's background model
//!   (`Pose.coverage`: a zone nearer than what it learned behind it), so a
//!   ceiling, a wall or the table edge never plays.
//! - Height: each hand zone's distance along its ray turned into a
//!   height above the sensor (`tables.cell_depth_q12`), then the nearest
//!   and every hand zone within `cluster_mm` of it, averaged. The single nearest zone jumps between
//!   fingertips, knuckles and the forearm as the hand moves sideways (the
//!   theremin's M1.2 lesson); the cluster mean does not, and the 3-frame
//!   median in play.zig drops what is left of a spike.
//! - Left to right: the pose's coverage-weighted centroid x (-1..1 at the
//!   outer cells' centres), never the closest zone, mapped to a lip
//!   tension 0..4096 across `lip_span`.
const tof = @import("tof");
const tof_types = tof.types;
const tof_pose = tof.pose;
const Frame = tof_types.Frame;
const tables = @import("gen/tables.zig");

pub const Config = struct {
    /// How the breakout faces on the badge (docs/TOF.md deferred question
    /// 2); MIRROR sets flip_x.
    orientation: tof_types.Orientation = .{},
    /// Zones this much further than the nearest hand zone are the wrist
    /// or the forearm's far end: not averaged into the height.
    cluster_mm: u16 = 40,
    /// Pose x at which the lip reaches its ends (+-lip_span is the whole
    /// range): a little inside the outer cells' centres, so both ends are
    /// reachable with the hand still over the sensor.
    lip_span: f32 = 0.85,
};

/// The pose estimator's settings for this cart: the wide SPAD map's field
/// of view (sensor.zig asks for map 6) and the hand window.
pub const pose_config: tof_pose.Config = .{ .fov_x_deg = 41, .fov_y_deg = 52, .min_mm = 15, .max_mm = 650, .min_confidence = 8 };

pub const Reading = struct {
    /// Hand height (mm), null: no hand this frame.
    height_mm: ?u16 = null,
    /// Lip tension 0..4096 (left .. right as the player sees the screen),
    /// null: the pose has no hand (hold the last).
    lip_t: ?i32 = null,
    /// Hand zones this frame (screen cells), for the screen.
    cells: u9 = 0,
};

pub fn read(frame: *const Frame, pose: *const tof_pose.Pose, cfg: Config) Reading {
    var r: Reading = .{};
    if (!pose.seen) {
        if (pose.present) r.lip_t = lip_t(pose.x, cfg.lip_span);
        return r;
    }
    var near: u16 = 0xFFFF;
    var mm: [tof_types.zones]u16 = @splat(0);
    for (0..tof_types.zones) |ci| {
        if (pose.coverage[ci] <= 0) continue;
        const z = frame.zones[cfg.orientation.index(@intCast(ci % 3), @intCast(ci / 3))];
        if (!z.near.valid()) continue;
        const h: u16 = @intCast((@as(u32, z.near.mm) * tables.cell_depth_q12[ci] + 2048) >> 12);
        mm[ci] = @max(h, 1);
        near = @min(near, mm[ci]);
        r.cells |= @as(u9, 1) << @intCast(ci);
    }
    if (near == 0xFFFF) return r;
    var sum: u32 = 0;
    var n: u32 = 0;
    for (mm) |d| {
        if (d == 0 or d > near + cfg.cluster_mm) continue;
        sum += d;
        n += 1;
    }
    r.height_mm = @intCast((sum + n / 2) / n);
    if (pose.present) r.lip_t = lip_t(pose.x, cfg.lip_span);
    return r;
}

/// Pose x to a lip tension 0..4096: -span is 0, +span 4096.
pub fn lip_t(x: f32, span: f32) i32 {
    const u = (x + span) / (2.0 * span);
    const c = if (u < 0) 0 else if (u > 1) 1 else u;
    return @intFromFloat(c * 4096.0 + 0.5);
}

// ---- Host tests ----

const std = @import("std");
const testing = std.testing;
const horn = @import("horn.zig");

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
        r = read(&g, &p, .{});
    }
    // As heights (off-axis rays are longer than the height): 201, 182,
    // 204, 194, 214 are within 40 of the nearest (182); the forearm's
    // 300 mm (292 high) is not.
    try testing.expectEqual(@as(?u16, 199), r.height_mm);
    try testing.expect(r.lip_t != null);
    try testing.expect(r.cells & (1 << 0) == 0);
    // Nothing but the room: no hand.
    const empty = frame_with(.{ 1300, 1300, 1300, 1300, 1300, 1300, 1300, 1300, 1300 });
    var e2: tof_pose.Estimator = .{ .config = pose_config };
    const p2 = e2.update(&empty, null, .{});
    try testing.expectEqual(@as(?u16, null), read(&empty, &p2, .{}).height_mm);
}

test "hand: lip tension spans 0..4096 over the span, clamped" {
    try testing.expectEqual(@as(i32, 0), lip_t(-0.85, 0.85));
    try testing.expectEqual(@as(i32, 2048), lip_t(0, 0.85));
    try testing.expectEqual(@as(i32, 4096), lip_t(0.85, 0.85));
    try testing.expectEqual(@as(i32, 4096), lip_t(3, 0.85));
    try testing.expectEqual(@as(i32, 0), lip_t(-3, 0.85));
}

/// A synthetic hand (lib/tof_synth.zig, the wide map) at (x_mm, z_mm),
/// run through the pose and `read` for `frames` frames; the last reading.
fn synth_reading(est: *tof_pose.Estimator, seq: *u32, x_mm: f32, z_mm: f32, frames: u32, mirror: bool) Reading {
    var scene: tof.synth.Scene = .{ .fov_x_deg = 41, .fov_y_deg = 52, .noise_mm = 2 };
    scene.background_mm = @splat(1300);
    scene.hand = .{ .x_mm = x_mm, .z_mm = z_mm, .pitch = 0.15 };
    var r: Reading = .{};
    var seed: u32 = seq.* *% 2654435761 +% 1;
    const orient: tof_types.Orientation = .{ .flip_x = mirror };
    for (0..frames) |_| {
        var f: Frame = .{ .seq = seq.*, .time_us = 1_000_000 + @as(u64, seq.*) * 33_333 };
        tof.synth.render(&scene, orient, &f, null, &seed);
        const p = est.update(&f, null, orient);
        r = read(&f, &p, .{ .orientation = orient });
        seq.* += 1;
    }
    return r;
}

test "hand: height follows the synthetic hand across the slide's throw" {
    var est: tof_pose.Estimator = .{ .config = pose_config };
    var seq: u32 = 0;
    const map: horn.SlideMap = .{};
    var z: f32 = 100;
    while (z <= 450) : (z += 50) {
        const r = synth_reading(&est, &seq, 0, z, 6, false);
        const h: f32 = @floatFromInt(r.height_mm.?);
        // The cluster mean of a slightly tilted hand: within ~3% of its height.
        try testing.expect(@abs(h - z) < z * 0.03 + 3);
        const want = map.slide(@intFromFloat(z));
        try testing.expect(@abs(map.slide(r.height_mm.?) - want) <= 25);
    }
}

test "hand: sweeping the hand left to right walks the partials up, once each" {
    // At a mid-throw height (4th position), the hand sweeping slowly from
    // well left to well right through the real pose: the embouchure climbs
    // 2..8 without ever going back down (the centroid, not the argmin zone).
    for ([_]bool{ false, true }) |mirror| {
        var est: tof_pose.Estimator = .{ .config = pose_config };
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
            const r = synth_reading(&est, &seq, x, 270, 1, mirror);
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
    }
}
