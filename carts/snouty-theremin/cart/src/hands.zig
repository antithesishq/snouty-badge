//! Hands from a sensor frame (SPEC section 3): which zones play pitch and
//! which play volume, in the two layouts, with the breakout's mounting
//! (`tof_types.Orientation`) and the player's handedness applied. Pure
//! data, host-tested.
const tof_types = @import("tof").types;
const Frame = tof_types.Frame;

pub const Layout = enum(u1) {
    /// The closest hand anywhere over the grid plays pitch; volume fixed.
    one_hand,
    /// One column of zones plays pitch, the opposite column volume (a
    /// classic theremin: the pitch antenna on the right).
    two_hand,

    pub fn label(l: Layout) []const u8 {
        return if (l == .one_hand) "1 HAND" else "2 HAND";
    }
};

pub const Config = struct {
    layout: Layout = .one_hand,
    /// How the breakout faces on the badge (docs/TOF.md deferred question 2).
    orientation: tof_types.Orientation = .{},
    /// Two-hand only: pitch on the screen's left column instead of the
    /// right (left-handed players, or a breakout mounted mirrored).
    pitch_left: bool = false,
    /// A target counts when its confidence is at least this (a knob: the
    /// 8820's confidence scale is untested on hardware).
    min_confidence: u8 = 8,
    /// Closer than this is the cover glass or noise.
    min_mm: u16 = 15,
    /// Further than this is not a hand (the room, the ceiling).
    max_mm: u16 = 650,
};

/// What the zones say about the hands. Screen cells are `row * 3 + col`
/// with col 0 on the left as the player sees the screen.
pub const Hands = struct {
    pitch_mm: ?u16 = null,
    volume_mm: ?u16 = null,
    /// The screen cell the pitch reading came from (one-hand).
    pitch_cell: ?u4 = null,
    /// Two-hand: the screen columns read for pitch and volume.
    pitch_col: u2 = 2,
    volume_col: u2 = 0,
    /// Every screen cell's hand distance (null: nothing hand-like there).
    grid: [9]?u16 = @splat(null),
};

fn hand_mm(cfg: Config, z: tof_types.Zone) ?u16 {
    const t = z.near;
    if (!t.valid() or t.confidence < cfg.min_confidence) return null;
    if (t.mm < cfg.min_mm or t.mm > cfg.max_mm) return null;
    return t.mm;
}

fn closer(a: ?u16, b: ?u16) ?u16 {
    const x = a orelse return b;
    const y = b orelse return a;
    return @min(x, y);
}

pub fn read(frame: *const Frame, cfg: Config) Hands {
    var h: Hands = .{};
    for (0..3) |r| for (0..3) |c| {
        const dev = cfg.orientation.index(@intCast(c), @intCast(r));
        h.grid[r * 3 + c] = hand_mm(cfg, frame.zones[dev]);
    };
    switch (cfg.layout) {
        .one_hand => {
            for (h.grid, 0..) |g, i| {
                const mm = g orelse continue;
                if (h.pitch_mm == null or mm < h.pitch_mm.?) {
                    h.pitch_mm = mm;
                    h.pitch_cell = @intCast(i);
                }
            }
        },
        .two_hand => {
            h.pitch_col = if (cfg.pitch_left) 0 else 2;
            h.volume_col = 2 - h.pitch_col;
            for (0..3) |r| {
                h.pitch_mm = closer(h.pitch_mm, h.grid[r * 3 + h.pitch_col]);
                h.volume_mm = closer(h.volume_mm, h.grid[r * 3 + h.volume_col]);
            }
        },
    }
    return h;
}

/// Where the hand is over the grid, for the one-hand highlight: from
/// lib/tof_pose.zig's coverage-weighted centroid, which moves square to
/// square with the hand. The closest zone (`pitch_cell`) does not: over a
/// hand most zones read about the same distance, so it jumps between
/// fingertips, knuckles and the forearm whichever way the hand goes.
pub const Track = struct {
    /// The screen cell under the hand (row * 3 + col), null: no hand.
    cell: ?u4 = null,
    /// Continuous position, -1..1 at the outer cells' centres; y up.
    x: f32 = 0,
    y: f32 = 0,
};

/// How far past a cell edge (in cells) the hand must go before the
/// highlight moves: no flicker while the hand rests on a boundary.
pub const track_margin: f32 = 0.15;

pub fn track(prev: Track, present: bool, x: f32, y: f32) Track {
    if (!present) return .{};
    const col = track_axis(if (prev.cell) |c| c % 3 else null, x);
    // Rows count down the screen; y is up.
    const row = track_axis(if (prev.cell) |c| c / 3 else null, -y);
    return .{ .cell = @as(u4, row) * 3 + col, .x = x, .y = y };
}

fn track_axis(prev: ?u4, v: f32) u2 {
    if (prev) |p| {
        const centre: f32 = @floatFromInt(@as(i32, p) - 1);
        if (@abs(v - centre) < 0.5 + track_margin) return @intCast(p);
    }
    return if (v < -0.5) 0 else if (v > 0.5) 2 else 1;
}

// ---- Host tests ----

const std = @import("std");
const testing = std.testing;

fn frame_with(cells: [9]u16) Frame {
    var f: Frame = .{};
    for (cells, 0..) |mm, i| {
        if (mm != 0) f.zones[i].near = .{ .mm = mm, .confidence = 200 };
    }
    return f;
}

test "hands: one hand takes the closest valid zone" {
    var f = frame_with(.{ 0, 300, 0, 0, 180, 0, 0, 0, 1200 });
    // A weak target closer still is ignored.
    f.zones[0].near = .{ .mm = 90, .confidence = 3 };
    // A second object behind does not matter.
    f.zones[4].far = .{ .mm = 900, .confidence = 200 };
    const h = read(&f, .{});
    try testing.expectEqual(@as(?u16, 180), h.pitch_mm);
    try testing.expectEqual(@as(?u4, 4), h.pitch_cell);
    try testing.expectEqual(@as(?u16, null), h.volume_mm);
    // 1200 mm is the room, not a hand.
    try testing.expectEqual(@as(?u16, null), h.grid[8]);
    // Nothing at all: no hand.
    const empty: Frame = .{};
    try testing.expectEqual(@as(?u16, null), read(&empty, .{}).pitch_mm);
}

test "hands: two hands read opposite columns, mirrored on request" {
    // Device rows: [L M R]; pitch hand on the right at 150, volume hand on
    // the left at 320, the middle sees the pitch hand's edge.
    const f = frame_with(.{
        330, 0,   160,
        320, 200, 150,
        0,   0,   170,
    });
    const h = read(&f, .{ .layout = .two_hand });
    try testing.expectEqual(@as(?u16, 150), h.pitch_mm);
    try testing.expectEqual(@as(?u16, 320), h.volume_mm);
    try testing.expectEqual(@as(u2, 2), h.pitch_col);
    // Pitch on the left: the hands swap.
    const l = read(&f, .{ .layout = .two_hand, .pitch_left = true });
    try testing.expectEqual(@as(?u16, 320), l.pitch_mm);
    try testing.expectEqual(@as(?u16, 150), l.volume_mm);
    // A breakout mounted mirrored (flip_x) swaps them back.
    const m = read(&f, .{ .layout = .two_hand, .pitch_left = true, .orientation = .{ .flip_x = true } });
    try testing.expectEqual(@as(?u16, 150), m.pitch_mm);
    try testing.expectEqual(@as(?u16, 320), m.volume_mm);
    // Mirrored only: pitch reads the device's left column.
    const mo = read(&f, .{ .layout = .two_hand, .orientation = .{ .flip_x = true } });
    try testing.expectEqual(@as(?u16, 320), mo.pitch_mm);
    // The grid is in screen order: with flip_x the device's right column is
    // the screen's left.
    try testing.expectEqual(@as(?u16, 150), mo.grid[3]);
}

test "hands: transpose turns rows into columns" {
    // Device top row is the hand; transposed, it is the screen's left column.
    const f = frame_with(.{ 140, 150, 160, 0, 0, 0, 0, 0, 0 });
    const h = read(&f, .{ .layout = .two_hand, .pitch_left = true, .orientation = .{ .transpose = true } });
    try testing.expectEqual(@as(?u16, 140), h.pitch_mm);
    try testing.expectEqual(@as(?u16, null), h.volume_mm);
}

test "hands: the track follows the centroid across cells, with hysteresis" {
    var t = track(.{}, true, 0, 0);
    try testing.expectEqual(@as(?u4, 4), t.cell);
    // Just past the edge: stays in the centre cell.
    t = track(t, true, 0.6, 0);
    try testing.expectEqual(@as(?u4, 4), t.cell);
    // Well past it: the right cell, and back needs the same margin.
    t = track(t, true, 0.7, 0);
    try testing.expectEqual(@as(?u4, 5), t.cell);
    t = track(t, true, 0.4, 0);
    try testing.expectEqual(@as(?u4, 5), t.cell);
    t = track(t, true, 0.3, 0);
    try testing.expectEqual(@as(?u4, 4), t.cell);
    // y is up: the top row is row 0. Beyond the grid clamps to the edge.
    t = track(t, true, -2, 1.5);
    try testing.expectEqual(@as(?u4, 0), t.cell);
    // No hand: no cell; a fresh hand takes the plain nearest cell.
    t = track(t, false, 0, 0);
    try testing.expectEqual(@as(?u4, null), t.cell);
    try testing.expectEqual(@as(?u4, 8), track(t, true, 0.55, -0.55).cell);
}

test "hands: a hand sweeping across the wide map walks the track left to right" {
    const tof = @import("tof");
    var est: tof.pose.Estimator = .{ .config = .{ .fov_x_deg = 41, .fov_y_deg = 52, .max_mm = 650, .min_confidence = 8 } };
    // A flat hand 25 cm up, a little tilted, with the sensor's ~2 mm noise:
    // the closest zone is a coin toss, the centroid is not.
    var scene: tof.synth.Scene = .{ .fov_x_deg = 41, .fov_y_deg = 52, .noise_mm = 3 };
    var seed: u32 = 7;
    var t: Track = .{};
    var last_col: u4 = 0;
    var cols: u8 = 0;
    const n = 90;
    for (0..n) |i| {
        const s: f32 = @as(f32, @floatFromInt(i)) / (n - 1);
        scene.hand = .{ .x_mm = -140 + 280 * s, .z_mm = 250, .pitch = 0.2 };
        var f: Frame = .{ .seq = @intCast(i), .time_us = 1_000_000 + @as(u64, i) * 33_333 };
        tof.synth.render(&scene, .{}, &f, null, &seed);
        const p = est.update(&f, null, .{});
        t = track(t, p.present, p.x, p.y);
        const c = t.cell orelse continue;
        try testing.expectEqual(@as(u4, 1), c / 3);
        try testing.expect(c % 3 >= last_col);
        if (c % 3 != last_col or cols == 0) cols += 1;
        last_col = c % 3;
    }
    try testing.expectEqual(@as(u4, 2), last_col);
    try testing.expectEqual(@as(u8, 3), cols);
}
