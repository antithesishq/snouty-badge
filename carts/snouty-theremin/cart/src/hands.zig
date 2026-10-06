//! Hands from a sensor frame (SPEC section 3): which zones play pitch and
//! which play volume, in the two layouts, with the breakout's mounting
//! (`tof_types.Orientation`) and the player's handedness applied. Pure
//! data, host-tested.
//!
//! Zones (docs/TOF.md M5): a frame is the 3x3 GRID or the 8 STRIPES, as
//! its own `frame.layout` says (the frames in flight around a ZONES
//! switch carry the old one); lib/tof_zones.zig gives the screen order.
//! The grid below (`Hands.grid`) is per screen cell either way: 3x3, or
//! 8x1 for STRIPES (1x8 if an orientation transposes).
const tof = @import("tof");
const tof_types = tof.types;
const tof_zones = tof.zones;
const Frame = tof_types.Frame;

pub const Layout = enum(u1) {
    /// The closest hand anywhere over the grid plays pitch; volume fixed.
    one_hand,
    /// One side of the zones plays pitch, the opposite side volume (a
    /// classic theremin: the pitch antenna on the right). GRID: the outer
    /// columns. STRIPES: the outer three stripes of each side, the middle
    /// two a dead band so one hand never plays both.
    two_hand,

    pub fn label(l: Layout) []const u8 {
        return if (l == .one_hand) "1 HAND" else "2 HAND";
    }
};

/// The ZONES setting: the sensor's zone layout (docs/TOF.md M5).
pub const Zones = enum(u1) {
    grid,
    stripes,

    pub fn layout(z: Zones) tof_types.Layout {
        return if (z == .grid) .grid else .stripes;
    }

    pub fn label(z: Zones) []const u8 {
        return z.layout().label();
    }
};

/// STRIPES two-hand: stripes per hand on each side (the rest is a dead band).
pub const stripes_per_hand = 3;

pub const Config = struct {
    layout: Layout = .one_hand,
    /// How the breakout faces on the badge (docs/TOF.md deferred question 2).
    orientation: tof_types.Orientation = .{},
    /// Two-hand only: pitch on the screen's left side instead of the
    /// right (left-handed players, or a breakout mounted mirrored).
    pitch_left: bool = false,
    /// A target counts when its confidence is at least this (a knob: the
    /// 8820's confidence scale is untested on hardware).
    min_confidence: u8 = 8,
    /// Closer than this is the cover glass or noise.
    min_mm: u16 = 15,
    /// STRIPES: a user SPAD mask has no crosstalk calibration, so very
    /// near returns may be the package's own (lib/tof_pose.zig's
    /// `min_mm_stripes`, docs/TOF.md M5).
    min_mm_stripes: u16 = 40,
    /// Further than this is not a hand (the room, the ceiling).
    max_mm: u16 = 650,
};

/// What the zones say about the hands. Screen cells are `row * cols + col`
/// with col 0 on the left as the player sees the screen.
pub const Hands = struct {
    pitch_mm: ?u16 = null,
    volume_mm: ?u16 = null,
    /// The screen cell the pitch reading came from (one-hand).
    pitch_cell: ?u4 = null,
    /// The frame's layout and its screen cells.
    layout: tof_types.Layout = .grid,
    cols: u4 = 3,
    rows: u4 = 3,
    /// Two-hand: the screen columns read for pitch and for volume, the
    /// first of `group` columns each (GRID: one column; STRIPES: three).
    pitch_col: u4 = 2,
    volume_col: u4 = 0,
    group: u4 = 1,
    /// Every screen cell's hand distance (null: nothing hand-like there).
    grid: [9]?u16 = @splat(null),
};

fn hand_mm(cfg: Config, min_mm: u16, z: tof_types.Zone) ?u16 {
    const t = z.near;
    if (!t.valid() or t.confidence < cfg.min_confidence) return null;
    if (t.mm < min_mm or t.mm > cfg.max_mm) return null;
    return t.mm;
}

fn closer(a: ?u16, b: ?u16) ?u16 {
    const x = a orelse return b;
    const y = b orelse return a;
    return @min(x, y);
}

/// The geometry of `frame` (its own layout tag; the field of view only
/// matters for angles, which `read` does not use).
pub fn geometry(layout: tof_types.Layout, orient: tof_types.Orientation) tof_zones.Geometry {
    const l: tof_types.Layout = if (layout == .stripes) .stripes else .grid;
    return tof_zones.Geometry.init(l, orient, 41, 52);
}

pub fn read(frame: *const Frame, cfg: Config) Hands {
    const g = geometry(frame.layout, cfg.orientation);
    return read_with(frame, cfg, &g);
}

/// `read` with the geometry already at hand (it must be the frame's layout).
pub fn read_with(frame: *const Frame, cfg: Config, g: *const tof_zones.Geometry) Hands {
    var h: Hands = .{ .layout = g.layout, .cols = @intCast(g.cols), .rows = @intCast(g.rows) };
    const min_mm = if (g.layout == .stripes) cfg.min_mm_stripes else cfg.min_mm;
    for (g.zones[0..g.n], 0..) |z, ci| h.grid[ci] = hand_mm(cfg, min_mm, frame.zones[z.dev]);
    switch (cfg.layout) {
        .one_hand => {
            for (h.grid[0..g.n], 0..) |c, i| {
                const mm = c orelse continue;
                if (h.pitch_mm == null or mm < h.pitch_mm.?) {
                    h.pitch_mm = mm;
                    h.pitch_cell = @intCast(i);
                }
            }
        },
        .two_hand => {
            // Sides along the screen's x axis; a transposed STRIPES layout
            // (one column) has none, so its top and bottom stand in.
            const along_x = h.cols > 1;
            const n: u4 = if (along_x) h.cols else h.rows;
            h.group = if (n == 3) 1 else stripes_per_hand;
            const last: u4 = n - h.group;
            h.pitch_col = if (cfg.pitch_left) 0 else last;
            h.volume_col = if (cfg.pitch_left) last else 0;
            for (0..g.n) |ci| {
                const pos: u4 = @intCast(if (along_x) ci % h.cols else ci / h.cols);
                if (pos >= h.pitch_col and pos < h.pitch_col + h.group) h.pitch_mm = closer(h.pitch_mm, h.grid[ci]);
                if (pos >= h.volume_col and pos < h.volume_col + h.group) h.volume_mm = closer(h.volume_mm, h.grid[ci]);
            }
        },
    }
    return h;
}

/// Where the hand is over the zones, for the one-hand highlight: from
/// lib/tof_pose.zig's coverage-weighted centroid of the near cluster
/// (arm rejection, docs/TOF.md M5), which moves cell to cell with the
/// hand. The closest zone (`pitch_cell`) does not: over a hand most zones
/// read about the same distance, so it jumps between fingertips,
/// knuckles and the forearm whichever way the hand goes.
pub const Track = struct {
    /// The screen cell under the hand (row * cols + col), null: no hand.
    cell: ?u4 = null,
    /// Continuous position, -1..1 at the outer zones' centres; y up.
    x: f32 = 0,
    y: f32 = 0,
    /// The same as fractional screen columns / rows (0 = the first
    /// zone's centre), for the dot.
    fc: f32 = 0,
    fr: f32 = 0,
    /// The layout the cell indexes (a switch starts the track afresh).
    layout: tof_types.Layout = .grid,
};

/// How far past a cell edge (in cells) the hand must go before the
/// highlight moves: no flicker while the hand rests on a boundary.
pub const track_margin: f32 = 0.15;

pub fn track(prev: Track, present: bool, x: f32, y: f32, g: *const tof_zones.Geometry) Track {
    if (!present) return .{};
    const p: ?u4 = if (prev.layout == g.layout) prev.cell else null;
    const cols: u4 = @intCast(g.cols);
    // GRID: x = -1..1 is columns 0..2 (and beyond, clamped by the cell);
    // STRIPES: the stripes' own centres.
    const fc: f32 = if (g.layout == .grid) x + 1 else g.col_at(x);
    const fr: f32 = if (g.layout == .grid) 1 - y else g.row_at(y);
    const col = track_axis(if (p) |c| c % cols else null, fc, g.cols);
    const row = track_axis(if (p) |c| c / cols else null, fr, g.rows);
    return .{ .cell = row * cols + col, .x = x, .y = y, .fc = fc, .fr = fr, .layout = g.layout };
}

fn track_axis(prev: ?u4, v: f32, n: u8) u4 {
    if (n <= 1) return 0;
    if (prev) |p| {
        const centre: f32 = @floatFromInt(p);
        if (@abs(v - centre) < 0.5 + track_margin) return p;
    }
    const top: f32 = @floatFromInt(n - 1);
    const c = @min(@max(v, 0), top);
    return @intFromFloat(c + 0.5);
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
    try testing.expectEqual(@as(u4, 2), h.pitch_col);
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
    const g = geometry(.grid, .{});
    var t = track(.{}, true, 0, 0, &g);
    try testing.expectEqual(@as(?u4, 4), t.cell);
    // Just past the edge: stays in the centre cell.
    t = track(t, true, 0.6, 0, &g);
    try testing.expectEqual(@as(?u4, 4), t.cell);
    // Well past it: the right cell, and back needs the same margin.
    t = track(t, true, 0.7, 0, &g);
    try testing.expectEqual(@as(?u4, 5), t.cell);
    t = track(t, true, 0.4, 0, &g);
    try testing.expectEqual(@as(?u4, 5), t.cell);
    t = track(t, true, 0.3, 0, &g);
    try testing.expectEqual(@as(?u4, 4), t.cell);
    // y is up: the top row is row 0. Beyond the grid clamps to the edge.
    t = track(t, true, -2, 1.5, &g);
    try testing.expectEqual(@as(?u4, 0), t.cell);
    // No hand: no cell; a fresh hand takes the plain nearest cell.
    t = track(t, false, 0, 0, &g);
    try testing.expectEqual(@as(?u4, null), t.cell);
    try testing.expectEqual(@as(?u4, 8), track(t, true, 0.55, -0.55, &g).cell);
}

test "hands: a hand sweeping across the wide map walks the track left to right" {
    var est: tof.pose.Estimator = .{ .config = .{ .fov_x_deg = 41, .fov_y_deg = 52, .max_mm = 650, .min_confidence = 8 } };
    // A flat hand 25 cm up, a little tilted, with the sensor's ~2 mm noise:
    // the closest zone is a coin toss, the centroid is not.
    var scene: tof.synth.Scene = .{ .fov_x_deg = 41, .fov_y_deg = 52, .noise_mm = 3 };
    var seed: u32 = 7;
    var t: Track = .{};
    const g = geometry(.grid, .{});
    var last_col: u4 = 0;
    var cols: u8 = 0;
    const n = 90;
    for (0..n) |i| {
        const s: f32 = @as(f32, @floatFromInt(i)) / (n - 1);
        scene.hand = .{ .x_mm = -140 + 280 * s, .z_mm = 250, .pitch = 0.2 };
        var f: Frame = .{ .seq = @intCast(i), .time_us = 1_000_000 + @as(u64, i) * 33_333 };
        tof.synth.render(&scene, .{}, &f, null, &seed);
        const p = est.update(&f, null, .{});
        t = track(t, p.present, p.x, p.y, &g);
        const c = t.cell orelse continue;
        try testing.expectEqual(@as(u4, 1), c / 3);
        try testing.expect(c % 3 >= last_col);
        if (c % 3 != last_col or cols == 0) cols += 1;
        last_col = c % 3;
    }
    try testing.expectEqual(@as(u4, 2), last_col);
    try testing.expectEqual(@as(u8, 3), cols);
}

/// A STRIPES frame: stripe k (device order, left to right unmirrored) is
/// zone k + 1; 0 = nothing there.
fn stripes_with(mm: [8]u16) Frame {
    var f: Frame = .{ .layout = .stripes };
    for (mm, 1..) |d, i| {
        if (d != 0) f.zones[i].near = .{ .mm = d, .confidence = 200 };
    }
    return f;
}

test "hands: STRIPES, one hand takes the nearest stripe; the near limit is 40 mm" {
    var f = stripes_with(.{ 1300, 1300, 260, 240, 236, 250, 1300, 1300 });
    // Zone 0 (channel 1, unused by the mask) never counts, even if it reports.
    f.zones[0].near = .{ .mm = 100, .confidence = 200 };
    const h = read(&f, .{});
    try testing.expectEqual(@as(?u16, 236), h.pitch_mm);
    try testing.expectEqual(@as(?u4, 4), h.pitch_cell);
    try testing.expect(h.layout == .stripes and h.cols == 8 and h.rows == 1);
    try testing.expectEqual(@as(?u16, null), h.grid[0]);
    // 30 mm: crosstalk territory under a user mask, not a hand (GRID keeps 15).
    const close = stripes_with(.{ 0, 0, 0, 30, 0, 0, 0, 0 });
    try testing.expectEqual(@as(?u16, null), read(&close, .{}).pitch_mm);
    var g3 = frame_with(.{ 0, 0, 0, 0, 30, 0, 0, 0, 0 });
    g3.layout = .grid;
    try testing.expectEqual(@as(?u16, 30), read(&g3, .{}).pitch_mm);
}

test "hands: STRIPES, two hands on the outer three stripes of each side, mirrored on request" {
    // Volume hand over stripes 0..2, pitch hand over 5..7, a forearm edge in
    // the dead band (3, 4) that plays neither.
    const f = stripes_with(.{ 320, 310, 330, 120, 140, 160, 150, 170 });
    const h = read(&f, .{ .layout = .two_hand });
    try testing.expectEqual(@as(?u16, 150), h.pitch_mm);
    try testing.expectEqual(@as(?u16, 310), h.volume_mm);
    try testing.expectEqual(@as(u4, 5), h.pitch_col);
    try testing.expectEqual(@as(u4, 0), h.volume_col);
    try testing.expectEqual(@as(u4, 3), h.group);
    // Pitch on the left: they swap.
    const l = read(&f, .{ .layout = .two_hand, .pitch_left = true });
    try testing.expectEqual(@as(?u16, 310), l.pitch_mm);
    try testing.expectEqual(@as(?u16, 150), l.volume_mm);
    // MIRROR (flip_x): the device's left stripes are the screen's right.
    const m = read(&f, .{ .layout = .two_hand, .orientation = .{ .flip_x = true } });
    try testing.expectEqual(@as(?u16, 310), m.pitch_mm);
    try testing.expectEqual(@as(?u16, 150), m.volume_mm);
    try testing.expectEqual(@as(?u16, 320), m.grid[7]);
    // Transposed, the stripes stack down the screen: top plays volume
    // (pitch on the bottom side as the right stands in), nothing breaks.
    const t = read(&f, .{ .layout = .two_hand, .orientation = .{ .transpose = true } });
    try testing.expect(t.cols == 1 and t.rows == 8);
    try testing.expectEqual(@as(?u16, 150), t.pitch_mm);
}

test "hands: the frame's own layout tag decides, whatever the setting" {
    // A GRID frame read while ZONES already says STRIPES (in flight around a
    // switch): still the 3x3 grid.
    const f = frame_with(.{ 0, 0, 0, 0, 0, 200, 0, 0, 0 });
    const h = read(&f, .{});
    try testing.expect(h.layout == .grid and h.cols == 3);
    try testing.expectEqual(@as(?u4, 5), h.pitch_cell);
}

test "hands: the track walks the stripes one by one, with hysteresis" {
    const g = geometry(.stripes, .{});
    var t: Track = .{};
    var last: u4 = 0;
    var seen: [8]bool = @splat(false);
    var x: f32 = -1.2;
    while (x <= 1.2) : (x += 0.02) {
        t = track(t, true, x, 0.7, &g);
        const c = t.cell.?;
        try testing.expect(c >= last and c < 8);
        try testing.expect(t.fr == 0);
        last = c;
        seen[c] = true;
    }
    for (seen) |v| try testing.expect(v);
    // A GRID track does not carry over to STRIPES: a fresh cell.
    const gg = geometry(.grid, .{});
    const tg = track(.{}, true, 0.9, 0, &gg);
    try testing.expectEqual(@as(?u4, 5), tg.cell);
    const ts = track(tg, true, 0.9, 0, &g);
    try testing.expectEqual(tof_types.Layout.stripes, ts.layout);
    try testing.expect(ts.cell.? >= 6);
}

test "hands: a hand sweeping over the stripes walks the track through every stripe" {
    var est: tof.pose.Estimator = .{ .config = .{ .fov_x_deg = 41, .fov_y_deg = 52, .max_mm = 650, .min_confidence = 8 } };
    est.set_layout(.stripes);
    var scene: tof.synth.Scene = .{ .layout = .stripes, .fov_x_deg = 41, .fov_y_deg = 52, .noise_mm = 3 };
    scene.background_mm = @splat(1300);
    var seed: u32 = 7;
    var t: Track = .{};
    const g = geometry(.stripes, .{});
    var last: u4 = 0;
    var seen: [8]bool = @splat(false);
    const n = 120;
    for (0..n) |i| {
        const s: f32 = @as(f32, @floatFromInt(i)) / (n - 1);
        scene.hand = .{ .x_mm = -150 + 300 * s, .z_mm = 250, .pitch = 0.2 };
        var f: Frame = .{ .seq = @intCast(i), .time_us = 1_000_000 + @as(u64, i) * 33_333 };
        tof.synth.render(&scene, .{}, &f, null, &seed);
        const p = est.update(&f, null, .{});
        t = track(t, p.present, p.x, p.y, &g);
        const c = t.cell orelse continue;
        try testing.expect(c >= last);
        last = c;
        seen[c] = true;
    }
    for (seen) |v| try testing.expect(v);
}
