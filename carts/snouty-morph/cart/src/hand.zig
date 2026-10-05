//! The virtual hand and where it comes from (SPEC.md section 3, Sources):
//!
//! - HAND: sensor frames (sensor.zig) through the pose estimator.
//! - STICK: the joystick moves the hand, B + stick pushes/pulls and turns
//!   it, A punches. Takes over at once, hands back after
//!   config.stick_timeout ticks without input.
//! - GHOST (attract): a scripted hand rendered into synthetic sensor frames
//!   by tof_synth and run through its own estimator, so attract mode shows
//!   what the real estimator makes of a hand.
//!
//! Priority: a sensed hand, then recent stick input, then the ghost.
//! Everything downstream (body.zig) sees one `Hand`. No cart API here, so
//! the host tests drive it directly.
const std = @import("std");
const tof_pose = @import("tof").pose;
const config = @import("config.zig");
const math = @import("math.zig");
const sensor = @import("sensor.zig");

const synth = tof_pose.synth;
const types = tof_pose.types;

pub const Source = enum(u8) { ghost, stick, sensor };

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

pub var source: Source = .ghost;
pub var hand: Hand = .{};
/// The pose behind the hand (sensor or ghost; zeroed for the stick), and
/// the frame it came from, for the HUD's mini map.
pub var pose: tof_pose.Pose = .{};
pub var frame: types.Frame = .{};
pub var has_sensor = false;

var tick: u32 = 0;
var sensor_est: tof_pose.Estimator = .{};
var ghost_est: tof_pose.Estimator = .{};
var ghost_frame: types.Frame = .{};
var ghost_pose: tof_pose.Pose = .{};
var ghost_seed: u32 = 0x5eed;
var last_seq: u32 = 0xffff_ffff;
var sensor_pose: tof_pose.Pose = .{};
var stick_idle: u32 = config.stick_timeout;
var hand_idle: u32 = config.hand_timeout;
var punch_cool: u32 = 0;
var stick_hand: Hand = .{};

pub fn reset() void {
    source = .ghost;
    hand = .{};
    pose = .{};
    tick = 0;
    sensor_est = .{};
    ghost_est = .{};
    ghost_frame = .{};
    ghost_seed = 0x5eed;
    last_seq = 0xffff_ffff;
    stick_idle = config.stick_timeout;
    hand_idle = config.hand_timeout;
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
            if (sensor_pose.present) hand_idle = 0;
            frame = f;
        }
    }
    if (!sensor_pose.present) hand_idle +|= 1;
    if (stick.active()) stick_idle = 0 else stick_idle +|= 1;

    const previous = source;
    source = if (has_sensor and sensor_pose.present)
        .sensor
    else if (stick_idle < config.stick_timeout)
        .stick
    else if (has_sensor and hand_idle < config.hand_timeout)
        .sensor
    else
        .ghost;
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
        .ghost => {
            update_ghost();
            pose = ghost_pose;
            frame = ghost_frame;
            from_pose(ghost_pose);
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

/// The ghost: a synthetic frame every other tick (30 Hz, like the sensor).
fn update_ghost() void {
    if (tick & 1 != 0) return;
    const t = @as(f32, @floatFromInt(tick)) / 60.0;
    var scene: synth.Scene = .{ .hand = ghost_hand(t) };
    scene.background_mm = @splat(750);
    ghost_frame.seq +%= 1;
    ghost_frame.time_us = @as(u64, tick) * 16_667;
    synth.render(&scene, .{}, &ghost_frame, null, &ghost_seed);
    ghost_pose = ghost_est.update(&ghost_frame, null, .{});
}

/// Length of the ghost's routine (seconds).
pub const ghost_loop: f32 = 16.0;

/// The ghost's routine, in sensor millimetres: drift (jelly), approach
/// (reach), circle with a turning, elongated hand (twist, yaw), wind up
/// and punch (shockwave), then a big close hand rocking (tilt).
pub fn ghost_hand(t: f32) synth.Hand {
    const ph = t - ghost_loop * @floor(t / ghost_loop);
    var h: synth.Hand = .{
        .x_mm = 55.0 * math.sin_turns(0.23 * t),
        .y_mm = 42.0 * math.sin_turns(0.31 * t + 0.15),
        .z_mm = 300.0 + 40.0 * math.sin_turns(0.13 * t),
        .half_w = 40,
        .half_h = 85,
    };
    // Approach, 4 to 7.5 s.
    const a = bump(ph, 4.0, 7.5);
    h.z_mm += (115.0 - h.z_mm) * a;
    h.x_mm *= 1.0 - 0.6 * a;
    h.y_mm *= 1.0 - 0.6 * a;
    // Circle, 7.5 to 11 s.
    const c = plateau(ph, 7.5, 11.0, 0.5);
    const ang = (ph - 7.5) / 1.4;
    h.x_mm += (48.0 * math.cos_turns(ang) - h.x_mm) * c;
    h.y_mm += (44.0 * math.sin_turns(ang) - h.y_mm) * c;
    h.half_w += (22.0 - h.half_w) * c;
    h.half_h += (105.0 - h.half_h) * c;
    h.yaw = c * 0.9 * math.sin_turns((ph - 7.5) / 3.5);
    // Wind up and punch, 11 to 12.8 s.
    const p = plateau(ph, 11.0, 12.8, 0.3);
    h.x_mm *= 1.0 - p;
    h.y_mm *= 1.0 - p;
    if (ph >= 11.0 and ph < 11.8) {
        h.z_mm += (430.0 - h.z_mm) * math.smoothstep01((ph - 11.0) / 0.8);
    } else if (ph >= 11.8 and ph < 12.0) {
        h.z_mm = 430.0 + (120.0 - 430.0) * ((ph - 11.8) / 0.2);
    } else if (ph >= 12.0 and ph < 12.8) {
        h.z_mm = 120.0 + (h.z_mm - 120.0) * math.smoothstep01((ph - 12.0) / 0.8);
    }
    // A big hand rocking close to the sensor, 12.8 to 16 s.
    const r = plateau(ph, 12.8, 16.0, 0.4);
    const rk = (ph - 12.8) / 1.6;
    h.z_mm += (170.0 - h.z_mm) * r;
    h.half_w += (110.0 - h.half_w) * r;
    h.half_h += (130.0 - h.half_h) * r;
    h.pitch = r * 0.45 * math.sin_turns(rk);
    h.roll = r * 0.45 * math.cos_turns(rk);
    h.x_mm *= 1.0 - r;
    h.y_mm *= 1.0 - r;
    return h;
}

/// 0 outside [a, b], a smooth hump inside.
fn bump(x: f32, a: f32, b: f32) f32 {
    if (x <= a or x >= b) return 0;
    const s = math.sin_turns((x - a) / (b - a) * 0.5);
    return s * s;
}

/// 0 outside [a, b], 1 inside, with smooth ramps of `ramp` seconds.
fn plateau(x: f32, a: f32, b: f32, ramp: f32) f32 {
    if (x <= a or x >= b) return 0;
    return math.smoothstep01((x - a) / ramp) * math.smoothstep01((b - x) / ramp);
}

// ---------------------------------------------------------------------------
// Host tests.

test "hand: the ghost drives the estimator through all its moves" {
    math.init_tables();
    reset();
    var saw_present = false;
    var punches: u32 = 0;
    var min_z: f32 = 1;
    var max_z: f32 = 0;
    var max_yaw: f32 = 0;
    var max_pitch: f32 = 0;
    var max_x: f32 = 0;
    const ticks: u32 = @intFromFloat(ghost_loop * 60.0);
    for (0..ticks) |i| {
        update(.{}, @as(u64, i) * 16_667);
        try std.testing.expectEqual(Source.ghost, source);
        if (!pose.present) continue;
        saw_present = true;
        if (hand.punch) punches += 1;
        min_z = @min(min_z, hand.z);
        max_z = @max(max_z, hand.z);
        max_yaw = @max(max_yaw, @abs(hand.yaw) * hand.conf_yaw);
        max_pitch = @max(max_pitch, @abs(hand.pitch) * hand.conf_pitch);
        max_x = @max(max_x, @abs(hand.x));
    }
    try std.testing.expect(saw_present);
    try std.testing.expectEqual(@as(u32, 1), punches);
    try std.testing.expect(max_z > 0.85 and min_z < 0.45);
    try std.testing.expect(max_yaw > 0.2);
    try std.testing.expect(max_pitch > 0.2);
    try std.testing.expect(max_x > 0.5);
}

test "hand: the stick takes over and hands back to the ghost" {
    math.init_tables();
    reset();
    for (0..10) |i| update(.{}, @as(u64, i) * 16_667);
    try std.testing.expectEqual(Source.ghost, source);
    for (0..30) |_| update(.{ .right = true }, 0);
    try std.testing.expectEqual(Source.stick, source);
    try std.testing.expect(hand.x > 0.3 and hand.vx > 0);
    for (0..30) |_| update(.{ .b = true, .up = true }, 0);
    try std.testing.expect(hand.z > 0.6);
    update(.{ .a_pressed = true }, 0);
    try std.testing.expect(hand.punch);
    for (0..config.stick_timeout) |_| update(.{}, 0);
    try std.testing.expectEqual(Source.ghost, source);
}
