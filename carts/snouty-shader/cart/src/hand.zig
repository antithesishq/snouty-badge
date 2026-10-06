//! The virtual hand and its 3x3 field, and where they come from (SPEC.md
//! section 4; adapted from snouty-morph's hand.zig):
//!
//! - SENSOR: sensor frames (sensor.zig) through the pose estimator.
//! - STICK: B + stick moves a hand held at `config.stick_z`, B + A punches.
//!   Takes over at once, hands back after config.stick_timeout ticks.
//! - NONE: no sensor and no stick: no hand, an empty field.
//!
//! Priority: a sensed hand, then recent stick input, then the sensor (no
//! hand in view: an empty field), then none. Nothing fakes a hand (Adrian,
//! 2026-10-06: a scripted attract hand made the sensor hard to demo).
//! Besides the pose, each source gives the per-cell presence and nearness
//! (`cells`) that become the field. No cart API here (host-tested).
//!
//! ZONES (docs/TOF.md M5): GRID (the 3x3 normal map) or STRIPES (8
//! full-height stripes, finer side to side, no vertical axis). `layout` is
//! what the sensor is asked for; every frame is read by the pose with its
//! own `frame.layout` (frames in flight around a switch are ignored), and
//! `Cells.layout` tells the field which kind of cells it holds.
const std = @import("std");
const tof_pose = @import("tof").pose;
const config = @import("config.zig");
const math = @import("math.zig");
const sensor = @import("sensor.zig");

const synth = tof_pose.synth;
const types = tof_pose.types;

pub const Source = enum(u8) { none, stick, sensor };

/// Normalised hand: x, y in -1..1 (screen right/up), z 0 far .. 1 near;
/// angles in radians, velocities per second.
pub const Hand = struct {
    present: bool = false,
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    pitch: f32 = 0,
    roll: f32 = 0,
    yaw: f32 = 0,
    vx: f32 = 0,
    vy: f32 = 0,
    vz: f32 = 0,
    vyaw: f32 = 0,
    swirl: f32 = 0,
    /// A punch landed this tick.
    punch: bool = false,
};

/// Per screen cell (row-major, row 0 top; STRIPES: entries 0..7 left to
/// right): presence 0..1 and nearness 0..1.
pub const Cells = struct {
    layout: types.Layout = .grid,
    presence: [types.zones]f32 = @splat(0),
    near: [types.zones]f32 = @splat(0),
};

/// The stick this tick: directions held while steering, and a punch.
pub const Stick = struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    punch: bool = false,
    /// B is held (steering mode): keeps the stick source alive.
    steer: bool = false,

    pub fn active(s: Stick) bool {
        return s.up or s.down or s.left or s.right or s.punch;
    }
};

pub var source: Source = .none;
pub var hand: Hand = .{};
pub var cells: Cells = .{};
/// The pose behind the hand (the sensor's; zeroed otherwise).
pub var pose: tof_pose.Pose = .{};
pub var has_sensor = false;
/// ZONES: the layout asked of the sensor (and the stick hand's field).
pub var layout: types.Layout = .grid;

var tick: u32 = 0;
var sensor_est: tof_pose.Estimator = .{};
var last_seq: u32 = 0xffff_ffff;
var sensor_pose: tof_pose.Pose = .{};
var sensor_cells: Cells = .{};
var stick_idle: u32 = config.stick_timeout;
var punch_cool: u32 = 0;
var stick_hand: Hand = .{};
var stick_cells: Cells = .{};

pub fn reset() void {
    source = .none;
    hand = .{};
    cells = .{};
    pose = .{};
    tick = 0;
    sensor_est = .{};
    last_seq = 0xffff_ffff;
    sensor_pose = .{};
    sensor_cells = .{};
    stick_idle = config.stick_timeout;
    punch_cool = 0;
    stick_hand = .{};
    stick_cells = .{};
    has_sensor = false;
    layout = .grid;
}

/// MIRROR: flip the sensor's left-right. The estimator starts afresh (its
/// filters would otherwise glide across the screen); it keeps its layout.
pub fn set_mirror(on: bool) void {
    sensor.set_mirror(on);
    fresh_estimator();
}

/// ZONES: ask the sensor for `l` (stop, SPAD page, start: a few frames)
/// and read that layout from now on; everything learned starts afresh.
pub fn set_layout(l: types.Layout) void {
    layout = l;
    sensor.set_layout(l);
    fresh_estimator();
    stick_cells = .{ .layout = l };
}

fn fresh_estimator() void {
    sensor_est = .{};
    sensor_est.set_layout(layout);
    sensor_pose = .{};
    sensor_cells = .{ .layout = layout };
    last_seq = 0xffff_ffff;
}

/// True while a real hand is over the sensor (attract stays off).
pub fn sensed() bool {
    return source == .sensor and pose.present;
}

/// One 60 Hz tick.
pub fn update(stick: Stick, now_us: u64) void {
    tick +%= 1;
    if (punch_cool > 0) punch_cool -= 1;

    sensor.poll(now_us);
    if (sensor.sensor_frame()) |f| {
        has_sensor = true;
        if (f.seq != last_seq) {
            last_seq = f.seq;
            sensor_pose = sensor_est.update(&f, sensor.histograms(), sensor.orientation);
            sensor_cells = cells_from(&sensor_pose);
        }
    }
    if (stick.active()) stick_idle = 0 else if (!stick.steer or stick_idle >= config.stick_timeout) {
        stick_idle +|= 1;
    }

    const previous = source;
    source = if (has_sensor and sensor_pose.present)
        .sensor
    else if (stick_idle < config.stick_timeout)
        .stick
    else if (has_sensor)
        .sensor
    else
        .none;
    if (source == .stick and previous != .stick) {
        // The stick picks up where the hand was.
        stick_hand = hand;
        stick_hand.punch = false;
        stick_hand.present = true;
    }

    switch (source) {
        .sensor => {
            pose = sensor_pose;
            from_pose(sensor_pose);
            cells = sensor_cells;
        },
        .stick => {
            update_stick(stick);
            pose = .{};
            hand = stick_hand;
            cells = stick_cells;
        },
        .none => {
            pose = .{};
            from_pose(pose);
            cells = .{};
        },
    }
}

/// Presence (the estimator's background-subtracted coverage) and nearness
/// (the zone's perpendicular height) per screen cell, in the pose's layout;
/// empty unless the estimator reports a hand (a one-frame stray reading it
/// rejects lights nothing).
pub fn cells_from(p: *const tof_pose.Pose) Cells {
    var out: Cells = .{ .layout = p.layout };
    if (!p.present) return out;
    const n = @as(usize, p.cols) * p.rows;
    for (0..n) |ci| {
        const cov = p.coverage[ci];
        const mm = p.depth_mm[ci];
        if (cov <= 0 or mm <= 0) continue;
        out.presence[ci] = math.clamp01(cov);
        out.near[ci] = nearness(mm);
    }
    return out;
}

pub fn nearness(mm: f32) f32 {
    return math.clamp01((config.far_mm - mm) / (config.far_mm - config.near_mm));
}

/// Pose (mm, radians) to the normalised hand; punches from the fast z velocity.
fn from_pose(p: tof_pose.Pose) void {
    hand.punch = false;
    hand.present = p.present;
    if (!p.present) {
        // Between sightings: ease velocities to rest, keep the rest.
        hand.vx *= 0.8;
        hand.vy *= 0.8;
        hand.vz *= 0.8;
        hand.vyaw *= 0.8;
        hand.swirl *= 0.8;
        hand.z *= 0.97;
        return;
    }
    const span = config.far_mm - config.near_mm;
    hand.x = std.math.clamp(p.x, -1.3, 1.3);
    hand.y = std.math.clamp(p.y, -1.3, 1.3);
    hand.z = nearness(p.z_mm);
    hand.pitch = p.pitch * p.conf_pitch;
    hand.roll = p.roll * p.conf_roll;
    hand.yaw = p.yaw * p.conf_yaw;
    hand.vx = p.vx;
    hand.vy = p.vy;
    hand.vz = -p.vz_mm_s / span;
    hand.vyaw = p.vyaw * p.conf_yaw;
    hand.swirl = p.swirl;
    if (p.seen and p.vz_fast_mm_s < -config.punch_mm_s and punch_cool == 0) {
        hand.punch = true;
        punch_cool = config.punch_cooldown;
    }
}

fn update_stick(s: Stick) void {
    const dt: f32 = 1.0 / 60.0;
    var hh = &stick_hand;
    const px = hh.x;
    const py = hh.y;
    const pz = hh.z;
    const dx: f32 = @as(f32, @floatFromInt(@intFromBool(s.right))) - @as(f32, @floatFromInt(@intFromBool(s.left)));
    const dy: f32 = @as(f32, @floatFromInt(@intFromBool(s.up))) - @as(f32, @floatFromInt(@intFromBool(s.down)));
    hh.present = true;
    hh.x = std.math.clamp(hh.x + dx * config.stick_speed * dt, -1.0, 1.0);
    hh.y = std.math.clamp(hh.y + dy * config.stick_speed * dt, -1.0, 1.0);
    hh.z += (config.stick_z - hh.z) * 0.08;
    hh.vx = (hh.x - px) / dt;
    hh.vy = (hh.y - py) / dt;
    hh.vz = (hh.z - pz) / dt;
    // Lean into the motion: the hand tilts the way it travels.
    hh.roll += (hh.vx * 0.30 - hh.roll) * 0.12;
    hh.pitch += (-hh.vy * 0.25 - hh.pitch) * 0.12;
    hh.yaw *= 0.97;
    hh.vyaw = 0;
    hh.swirl = hh.x * hh.vy - hh.y * hh.vx;
    hh.punch = s.punch and punch_cool == 0;
    if (hh.punch) punch_cool = 8;
    // The field: tof_synth's coverage of a hand at the stick position,
    // every other tick (the sensor's rate).
    if (tick & 1 == 0) stick_cells = stick_field(hh.*);
}

/// Per-cell coverage and nearness of a 90 x 150 mm hand at the stick hand's
/// position (x, y = +-1 at the outer zone centres) in the current layout.
pub fn stick_field(hh: Hand) Cells {
    const z_mm = config.far_mm - hh.z * (config.far_mm - config.near_mm);
    var scene: synth.Scene = .{ .layout = layout, .hand = .{
        .x_mm = 0,
        .y_mm = 0,
        .z_mm = z_mm,
        .half_w = 45,
        .half_h = 75,
        .roll = hh.roll,
        .pitch = hh.pitch,
    } };
    const g = synth.geometry(&scene, .{});
    // The outer zone centres: 11 deg off axis for GRID (33 / 3), 18 deg
    // for STRIPES. STRIPES has no y: the hand stays mid-height.
    scene.hand.?.x_mm = hh.x * z_mm * g.half_x;
    // (GRID's y keeps M3's x scale: its rows are 10.7 deg, close enough.)
    if (g.has_y) scene.hand.?.y_mm = hh.y * z_mm * g.half_x;
    var out: Cells = .{ .layout = layout };
    for (0..g.n) |ci| {
        const hit = synth.zone_hit(&scene, &g.zones[ci], 0);
        if (hit.fraction < synth.min_fraction) continue;
        out.presence[ci] = hit.fraction;
        out.near[ci] = nearness(hit.mm);
    }
    return out;
}

// ---------------------------------------------------------------------------
// Host tests.

test "hand: with no sensor and no stick nothing moves" {
    math.init_tables();
    reset();
    for (0..60 * 20) |i| {
        update(.{}, @as(u64, i) * 16_667);
        try std.testing.expectEqual(Source.none, source);
        try std.testing.expect(!hand.present and !hand.punch);
        for (0..9) |ci| try std.testing.expectEqual(@as(f32, 0), cells.presence[ci]);
    }
    try std.testing.expect(!sensed());
}

test "hand: a frame the estimator does not call a hand lights no cell" {
    var p: tof_pose.Pose = .{};
    p.coverage = @splat(0);
    p.coverage[4] = 1;
    p.depth_mm[4] = 200;
    try std.testing.expectEqual(@as(f32, 0), cells_from(&p).presence[4]);
    p.present = true;
    const c = cells_from(&p);
    try std.testing.expectEqual(@as(f32, 1), c.presence[4]);
    try std.testing.expectApproxEqAbs(nearness(200), c.near[4], 1e-6);
    // Coverage without a height (a frame too weak to measure) lights nothing.
    p.depth_mm[4] = 0;
    try std.testing.expectEqual(@as(f32, 0), cells_from(&p).presence[4]);
}

/// Runs `n` synthetic frames of `scene` through a fresh estimator in
/// `l` and returns the cells.
fn synth_cells(l: types.Layout, scene: *const synth.Scene, n: u32) Cells {
    var est: tof_pose.Estimator = .{};
    est.set_layout(l);
    var seed: u32 = 7;
    var p: tof_pose.Pose = .{};
    for (0..n) |i| {
        var f: types.Frame = .{ .seq = @intCast(i), .time_us = 1_000_000 + @as(u64, i) * 33_333 };
        synth.render(scene, sensor.default_orientation, &f, null, &seed);
        p = est.update(&f, null, sensor.default_orientation);
    }
    return cells_from(&p);
}

test "hand: STRIPES cells follow a hand on one side, GRID frames are ignored" {
    var scene: synth.Scene = .{ .layout = .stripes, .hand = .{ .x_mm = 60, .y_mm = 40, .z_mm = 220, .half_w = 30, .half_h = 60 } };
    scene.background_mm = @splat(1200);
    const c = synth_cells(.stripes, &scene, 10);
    try std.testing.expectEqual(types.Layout.stripes, c.layout);
    // Right half lit, left half dark, nothing past the eighth entry.
    var right: f32 = 0;
    for (4..8) |k| right += c.presence[k];
    for (0..3) |k| try std.testing.expectEqual(@as(f32, 0), c.presence[k]);
    try std.testing.expect(right > 0.5);
    try std.testing.expectEqual(@as(f32, 0), c.presence[8]);
    // A GRID estimator reading STRIPES frames: no hand, empty cells.
    const g = synth_cells(.grid, &scene, 10);
    for (g.presence) |v| try std.testing.expectEqual(@as(f32, 0), v);
}

test "hand: switching ZONES restarts the estimator in the new layout; MIRROR keeps it" {
    math.init_tables();
    reset();
    set_layout(.stripes);
    try std.testing.expectEqual(types.Layout.stripes, sensor_est.layout);
    try std.testing.expectEqual(types.Layout.stripes, sensor_cells.layout);
    set_mirror(true);
    try std.testing.expectEqual(types.Layout.stripes, sensor_est.layout);
    set_mirror(false);
    // The stick hand's field follows the layout: a hand on the right
    // lights the right stripes, the same at any height.
    for (0..60) |_| update(.{ .steer = true, .right = true, .up = true }, 0);
    try std.testing.expectEqual(Source.stick, source);
    try std.testing.expectEqual(types.Layout.stripes, cells.layout);
    try std.testing.expect(cells.presence[6] > 0.2);
    try std.testing.expectEqual(@as(f32, 0), cells.presence[0]);
    set_layout(.grid);
    try std.testing.expectEqual(types.Layout.grid, sensor_est.layout);
    reset();
}

test "hand: B + stick steers a hand whose field follows it, then hands back" {
    math.init_tables();
    reset();
    for (0..10) |i| update(.{}, @as(u64, i) * 16_667);
    try std.testing.expectEqual(Source.none, source);
    for (0..60) |_| update(.{ .steer = true, .right = true, .up = true }, 0);
    try std.testing.expectEqual(Source.stick, source);
    try std.testing.expect(hand.x > 0.5 and hand.y > 0.5);
    // The top-right cell is lit, the bottom-left one is not.
    try std.testing.expect(cells.presence[2] > 0.3);
    try std.testing.expectEqual(@as(f32, 0), cells.presence[6]);
    update(.{ .steer = true, .punch = true }, 0);
    try std.testing.expect(hand.punch);
    // Holding B alone keeps the stick hand.
    for (0..config.stick_timeout + 10) |_| update(.{ .steer = true }, 0);
    try std.testing.expectEqual(Source.stick, source);
    for (0..config.stick_timeout + 1) |_| update(.{}, 0);
    try std.testing.expectEqual(Source.none, source);
}
