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

/// Per screen cell (row-major, row 0 top): presence 0..1 and nearness 0..1.
pub const Cells = struct {
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
}

/// MIRROR: flip the sensor's left-right. The estimator's background is
/// per screen cell, so it starts afresh (it relearns within a few frames).
pub fn set_mirror(on: bool) void {
    sensor.set_mirror(on);
    sensor_est = .{};
    sensor_pose = .{};
    sensor_cells = .{};
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
            sensor_cells = cells_from(&sensor_pose, &f, sensor.orientation);
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
/// (the zone's distance) per screen cell; empty unless the estimator
/// reports a hand (a one-frame stray reading it rejects lights nothing).
pub fn cells_from(p: *const tof_pose.Pose, f: *const types.Frame, orient: types.Orientation) Cells {
    var out: Cells = .{};
    if (!p.present) return out;
    for (0..types.zones) |ci| {
        const cov = p.coverage[ci];
        if (cov <= 0) continue;
        const zi = orient.index(@intCast(ci % 3), @intCast(ci / 3));
        const mm: f32 = @floatFromInt(f.zones[zi].near.mm);
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
/// position (x, y = +-1 at the outer cell centres).
pub fn stick_field(hh: Hand) Cells {
    const z_mm = config.far_mm - hh.z * (config.far_mm - config.near_mm);
    // The outer cell centres are 11 degrees off axis (33 / 3).
    const lateral = z_mm * 0.194;
    const scene: synth.Scene = .{ .hand = .{
        .x_mm = hh.x * lateral,
        .y_mm = hh.y * lateral,
        .z_mm = z_mm,
        .half_w = 45,
        .half_h = 75,
        .roll = hh.roll,
        .pitch = hh.pitch,
    } };
    var out: Cells = .{};
    for (0..types.zones) |ci| {
        const hit = synth.cell_hit(&scene, @intCast(ci % 3), @intCast(ci / 3));
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
    var f: types.Frame = .{};
    f.zones[4].near = .{ .mm = 200, .confidence = 200 };
    try std.testing.expectEqual(@as(f32, 0), cells_from(&p, &f, .{}).presence[4]);
    p.present = true;
    try std.testing.expectEqual(@as(f32, 1), cells_from(&p, &f, .{}).presence[4]);
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
