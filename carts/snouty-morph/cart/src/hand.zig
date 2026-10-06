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

var tick: u32 = 0;
var sensor_est: tof_pose.Estimator = .{};
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
    sensor_est = .{};
    last_seq = 0xffff_ffff;
    stick_idle = config.stick_timeout;
    punch_cool = 0;
    stick_hand = .{};
    has_sensor = false;
}

/// One 60 Hz tick.
pub fn update(stick: Stick, now_us: u64) void {
    tick +%= 1;
    if (punch_cool > 0) punch_cool -= 1;
    const dt: f32 = 1.0 / 60.0;

    // The sensor, when there is one.
    sensor.poll(now_us);
    if (sensor.sensor_frame()) |f| {
        has_sensor = true;
        if (f.seq != last_seq) {
            last_seq = f.seq;
            sensor_pose = sensor_est.update(&f, sensor.histograms(), sensor.orientation);
            frame = f;
        }
    }
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
    hand.x = std.math.clamp(p.x, -1.3, 1.3);
    hand.y = std.math.clamp(p.y, -1.3, 1.3);
    hand.z = std.math.clamp((config.far_mm - p.z_mm) / span, 0.0, 1.0);
    hand.pitch = p.pitch;
    hand.roll = p.roll;
    hand.yaw = p.yaw;
    hand.conf_pitch = p.conf_pitch;
    hand.conf_roll = p.conf_roll;
    hand.conf_yaw = p.conf_yaw;
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
