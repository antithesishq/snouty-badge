//! The virtual hand and where it comes from (SPEC.md section 3, Sources):
//!
//! - HAND: sensor frames (sensor.zig) through the pose estimator.
//! - STICK: the joystick moves the hand, B + stick pushes/pulls and turns
//!   it, A punches. Takes over at once, hands back after
//!   config.stick_timeout ticks without input.
//! - NONE: no sensor and no stick: the hand rests where it was.
//!
//! Priority: a sensed hand, then recent stick input, then the sensor (no
//! hand in view: the hand rests), then none. Nothing fakes a hand (Adrian,
//! 2026-10-06: a scripted attract hand made the sensor hard to demo).
//! Everything downstream (body.zig) sees one `Hand`. No cart API here, so
//! the host tests drive it directly.
const std = @import("std");
const tof_pose = @import("tof").pose;
const config = @import("config.zig");
const math = @import("math.zig");
const sensor = @import("sensor.zig");

const types = tof_pose.types;
const synth = tof_pose.synth;
const Geometry = tof_pose.zones.Geometry;

pub const Source = enum(u8) { none, stick, sensor };

/// Normalised hand: x, y in -1..1 (screen right/up), z 0 far .. 1 near;
/// angles in radians (pitch > 0: top away; roll > 0: right side away; yaw
/// > 0: turned counter-clockwise), velocities per second.
pub const Hand = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0.35,
    pitch: f32 = 0,
    roll: f32 = 0,
    yaw: f32 = 0,
    conf_pitch: f32 = 0,
    conf_roll: f32 = 0,
    conf_yaw: f32 = 0,
    vx: f32 = 0,
    vy: f32 = 0,
    vz: f32 = 0,
    vyaw: f32 = 0,
    swirl: f32 = 0,
    /// A punch landed this tick.
    punch: bool = false,
};

/// The stick and buttons this tick (held, except `a_pressed`).
pub const Stick = struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    b: bool = false,
    a_pressed: bool = false,

    fn active(s: Stick) bool {
        return s.up or s.down or s.left or s.right or s.b or s.a_pressed;
    }
};

pub var source: Source = .none;
pub var hand: Hand = .{};
/// The pose behind the hand (the sensor's; zeroed otherwise), and
/// the frame it came from, for the HUD's mini map.
pub var pose: tof_pose.Pose = .{};
pub var frame: types.Frame = .{};
pub var has_sensor = false;
/// ZONES (docs/TOF.md M5): the sensor's zone layout and its geometry (the
/// HUD's zone map draws it).
pub var zones: types.Layout = .grid;
pub var geom: Geometry = .{};
/// Pose x, y to the GRID field's scale: the pose's +-1 is the outer zones'
/// centres, 11 deg off axis in GRID (map 1) and 18 deg in STRIPES, so the
/// same hand moves the mesh as far in either layout.
var x_scale: f32 = 1;
var y_scale: f32 = 1;

/// The estimator's settings: the defaults (normal map 1, 33 x 32 deg; the
/// near cluster's arm rejection for x, y and the hand body's window for
/// z, tilt and yaw, lib/tof_pose.zig).
const pose_config: tof_pose.Config = .{};

var tick: u32 = 0;
var sensor_est: tof_pose.Estimator = .{ .config = pose_config };
var last_seq: u32 = 0xffff_ffff;
var sensor_pose: tof_pose.Pose = .{};
var stick_idle: u32 = config.stick_timeout;
var punch_cool: u32 = 0;
var stick_hand: Hand = .{};

pub fn reset() void {
    source = .none;
    hand = .{};
    pose = .{};
    tick = 0;
    sensor_est = .{ .config = pose_config };
    sensor_pose = .{};
    last_seq = 0xffff_ffff;
    stick_idle = config.stick_timeout;
    punch_cool = 0;
    stick_hand = .{};
    has_sensor = false;
    frame = .{};
    zones = .grid;
    sensor.set_layout(.grid);
    set_geometry();
}

/// ZONES: switch the sensor and the estimator to `l`. The estimator starts
/// afresh (zone i looks elsewhere now); until frames of the new layout
/// arrive the hand rests where it was.
pub fn set_zones(l: types.Layout) void {
    if (l == zones) return;
    zones = l;
    sensor.set_layout(l);
    sensor_est.set_layout(l);
    sensor_pose = .{};
    last_seq = 0xffff_ffff;
    set_geometry();
}

fn set_geometry() void {
    geom = Geometry.init(zones, sensor.orientation, pose_config.fov_x_deg, pose_config.fov_y_deg);
    const grid = Geometry.init(.grid, sensor.orientation, pose_config.fov_x_deg, pose_config.fov_y_deg);
    x_scale = if (geom.has_x) geom.half_x / grid.half_x else 1;
    y_scale = if (geom.has_y) geom.half_y / grid.half_y else 1;
}

/// A sensor frame (sensor.zig's, or a test's): the pose, if it is new.
pub fn take_frame(f: *const types.Frame) void {
    has_sensor = true;
    if (f.seq == last_seq) return;
    last_seq = f.seq;
    // A frame measured with the other layout (in flight around a switch)
    // is ignored by the estimator; keep it off the HUD too.
    if (f.layout != zones) return;
    sensor_pose = sensor_est.update(f, sensor.histograms(), sensor.orientation);
    frame = f.*;
}

/// One 60 Hz tick.
pub fn update(stick: Stick, now_us: u64) void {
    tick +%= 1;
    if (punch_cool > 0) punch_cool -= 1;
    const dt: f32 = 1.0 / 60.0;

    // The sensor, when there is one.
    sensor.poll(now_us);
    if (sensor.sensor_frame()) |f| take_frame(&f);
    if (stick.active()) stick_idle = 0 else stick_idle +|= 1;

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
    }

    switch (source) {
        .sensor => {
            pose = sensor_pose;
            from_pose(sensor_pose);
        },
        .stick => {
            update_stick(stick, dt);
            pose = .{};
            hand = stick_hand;
        },
        .none => {
            pose = .{};
            from_pose(pose);
        },
    }
}

/// Pose (mm, radians) to the normalised hand; punches from the fast z velocity.
fn from_pose(p: tof_pose.Pose) void {
    hand.punch = false;
    if (!p.present) {
        // Between sightings: ease back toward rest, keep the last angles.
        hand.vx *= 0.8;
        hand.vy *= 0.8;
        hand.vz *= 0.8;
        hand.vyaw *= 0.8;
        hand.swirl *= 0.8;
        return;
    }
    const span = config.far_mm - config.near_mm;
    // STRIPES has no vertical axis: y is 0 there (the mesh rests at the
    // centre height) and pitch / yaw come with zero confidence, which
    // body.zig's tilt springs already scale by.
    hand.x = std.math.clamp(p.x * x_scale, -1.3, 1.3);
    hand.y = std.math.clamp(p.y * y_scale, -1.3, 1.3);
    hand.z = std.math.clamp((config.far_mm - p.z_mm) / span, 0.0, 1.0);
    hand.pitch = p.pitch;
    hand.roll = p.roll;
    hand.yaw = p.yaw;
    hand.conf_pitch = p.conf_pitch;
    hand.conf_roll = p.conf_roll;
    hand.conf_yaw = p.conf_yaw;
    hand.vx = p.vx * x_scale;
    hand.vy = p.vy * y_scale;
    hand.vz = -p.vz_mm_s / span;
    hand.vyaw = p.vyaw * p.conf_yaw;
    hand.swirl = p.swirl * x_scale * y_scale;
    if (p.seen and p.vz_fast_mm_s < -config.punch_mm_s and punch_cool == 0) {
        hand.punch = true;
        punch_cool = config.punch_cooldown;
    }
}

fn update_stick(s: Stick, dt: f32) void {
    var h = &stick_hand;
    const px = h.x;
    const py = h.y;
    const pz = h.z;
    const pyaw = h.yaw;
    const dx: f32 = @as(f32, @floatFromInt(@intFromBool(s.right))) - @as(f32, @floatFromInt(@intFromBool(s.left)));
    const dy: f32 = @as(f32, @floatFromInt(@intFromBool(s.up))) - @as(f32, @floatFromInt(@intFromBool(s.down)));
    if (s.b) {
        h.z = std.math.clamp(h.z + dy * config.stick_z_speed * dt, 0.0, 1.0);
        h.yaw -= dx * config.stick_yaw_speed * dt;
    } else {
        h.x = std.math.clamp(h.x + dx * config.stick_speed * dt, -1.0, 1.0);
        h.y = std.math.clamp(h.y + dy * config.stick_speed * dt, -1.0, 1.0);
    }
    h.vx = (h.x - px) / dt;
    h.vy = (h.y - py) / dt;
    h.vz = (h.z - pz) / dt;
    h.vyaw = (h.yaw - pyaw) / dt;
    // Lean into the motion: the hand tilts the way it travels.
    h.roll += (h.vx * 0.30 - h.roll) * 0.12;
    h.pitch += (-h.vy * 0.25 - h.pitch) * 0.12;
    h.conf_pitch = 1;
    h.conf_roll = 1;
    h.conf_yaw = 1;
    h.swirl = h.x * h.vy - h.y * h.vx;
    h.punch = s.a_pressed and punch_cool == 0;
    if (h.punch) punch_cool = 8;
}

// ---------------------------------------------------------------------------
// Host tests.

test "hand: with no sensor and no stick the hand rests" {
    math.init_tables();
    reset();
    const rest = hand;
    for (0..60 * 20) |i| {
        update(.{}, @as(u64, i) * 16_667);
        try std.testing.expectEqual(Source.none, source);
        try std.testing.expect(!pose.present and !hand.punch);
        try std.testing.expectEqual(rest.x, hand.x);
        try std.testing.expectEqual(rest.y, hand.y);
        try std.testing.expectEqual(rest.z, hand.z);
    }
}

test "hand: the stick takes over and lets go" {
    math.init_tables();
    reset();
    for (0..10) |i| update(.{}, @as(u64, i) * 16_667);
    try std.testing.expectEqual(Source.none, source);
    for (0..30) |_| update(.{ .right = true }, 0);
    try std.testing.expectEqual(Source.stick, source);
    try std.testing.expect(hand.x > 0.3 and hand.vx > 0);
    for (0..30) |_| update(.{ .b = true, .up = true }, 0);
    try std.testing.expect(hand.z > 0.6);
    update(.{ .a_pressed = true }, 0);
    try std.testing.expect(hand.punch);
    for (0..config.stick_timeout) |_| update(.{}, 0);
    try std.testing.expectEqual(Source.none, source);
}

/// A synthetic hand (lib/tof_synth.zig) over the sensor in `layout`, seen
/// through the cart's orientation, fed as sensor frame `seq`.
fn feed(layout: types.Layout, seq: u32, x_mm: f32, z_mm: f32, seed: *u32) void {
    var scene: synth.Scene = .{ .layout = layout, .hand = .{ .x_mm = x_mm, .y_mm = 25, .z_mm = z_mm, .half_w = 40, .half_h = 80, .pitch = 0.3 } };
    scene.background_mm = @splat(1300);
    var f: types.Frame = .{ .seq = seq, .time_us = 1_000_000 + @as(u64, seq) * 33_333 };
    synth.render(&scene, sensor.orientation, &f, null, seed);
    take_frame(&f);
}

test "hand: STRIPES moves x, rests y, no pitch or yaw, and never snaps" {
    math.init_tables();
    reset();
    set_zones(.stripes);
    try std.testing.expectEqual(@as(u8, 8), geom.cols);
    var seed: u32 = 7;
    var seq: u32 = 0;
    var last_x: ?f32 = null;
    var t: u64 = 0;
    // A hand sweeping right then left, 30 Hz frames, 60 Hz updates.
    for (0..240) |i| {
        const s: f32 = @as(f32, @floatFromInt(i % 120)) / 119.0;
        const x = if (i < 120) -50 + 100 * s else 50 - 100 * s;
        if (i % 2 == 0) {
            feed(.stripes, seq, x, 220, &seed);
            seq += 1;
        }
        t += 16_667;
        update(.{}, t);
        if (source != .sensor or !pose.present) continue;
        try std.testing.expect(pose.layout == .stripes and pose.cols == 8);
        try std.testing.expectEqual(@as(f32, 0), hand.y);
        try std.testing.expectEqual(@as(f32, 0), hand.conf_pitch);
        try std.testing.expectEqual(@as(f32, 0), hand.conf_yaw);
        // At most a half-stripe step (~0.12 here) per frame; body.zig's
        // follow spring smooths the mesh on top.
        if (last_x) |lx| try std.testing.expect(@abs(hand.x - lx) < 0.2);
        last_x = hand.x;
    }
    try std.testing.expect(last_x != null);
}

test "hand: the same hand moves the mesh as far in GRID as in STRIPES; switching drops stale frames" {
    math.init_tables();
    var xs: [2]f32 = undefined;
    for ([_]types.Layout{ .grid, .stripes }, 0..) |l, k| {
        reset();
        set_zones(l);
        var seed: u32 = 9;
        for (0..20) |i| {
            feed(l, @intCast(i), 30, 220, &seed);
            update(.{}, @as(u64, i) * 16_667);
        }
        try std.testing.expect(pose.present);
        xs[k] = hand.x;
    }
    // Pose x is normalised per layout; the cart rescales STRIPES to GRID's field.
    try std.testing.expect(xs[0] > 0.3 and @abs(xs[0] - xs[1]) < 0.15);
    // In STRIPES now: a GRID frame still in flight changes nothing.
    const before = pose;
    var seed: u32 = 3;
    feed(.grid, 100, -40, 200, &seed);
    update(.{}, 2_000_000);
    try std.testing.expectEqual(before.seq, pose.seq);
    try std.testing.expectEqual(types.Layout.stripes, frame.layout);
    // Back to GRID: the estimator starts afresh, the hand rests meanwhile.
    const rest_x = hand.x;
    set_zones(.grid);
    update(.{}, 2_016_667);
    try std.testing.expect(!pose.present);
    try std.testing.expectEqual(rest_x, hand.x);
}
