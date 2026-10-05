//! The mesh as a body that follows the hand (SPEC.md section 3): its 6DoF
//! transform on critically damped springs, and the deformations' secondary
//! motion on underdamped ones. Produces the render parameters every tick.
//!
//! - Transform: position toward the hand (follow_gain of the way, so the
//!   hand leads), depth from hand z, mesh yaw from hand roll (right side
//!   away turns the mesh's right side away), mesh pitch from hand pitch,
//!   in-plane roll from hand yaw, on top of a slow autonomous spin.
//! - REACH: bulge toward the hand point, amplitude from proximity squared.
//! - JELLY: shear driven by the body's sideways acceleration, squash by
//!   its vertical and depth acceleration (and a punch).
//! - TWIST: torsion toward swirl, kicked by the hand's turning speed.
//! - SHOCKWAVE: a punch launches a ripple from the point facing the hand,
//!   with a flash and a screen shake.
//!
//! No cart API: host-tested.
const std = @import("std");
const config = @import("config.zig");
const math = @import("math.zig");
const mesh = @import("mesh.zig");
const hand_mod = @import("hand.zig");

const V3 = [3]f32;

pub const Ripple = struct {
    /// Object-space unit direction of the impact.
    dir: V3,
    /// Wave front: 0 at the impact, 1 at the antipode.
    front: f32,
    /// Amplitude (object units), fading as it travels.
    amp: f32,
};

pub const Params = struct {
    /// Object to eye rotation (rows) and uniform scale.
    rot: [3]V3,
    scale: f32 = 1,
    /// Mesh centre in eye space (camera at z = config.rest_distance).
    pos: V3,
    /// REACH: object-space unit direction toward the hand, amplitude.
    reach_dir: V3 = .{ 0, 0, 1 },
    reach_amp: f32 = 0,
    /// TWIST: radians per unit of object y.
    twist: f32 = 0,
    /// JELLY: eye x shear per unit eye y, and squash (y scale - 1).
    shear: f32 = 0,
    squash: f32 = 0,
    ripples: []const Ripple = &.{},
    /// Ramp index boost (the punch flash).
    flash: f32 = 0,
    /// Draw the mesh's optional faces (SNOUTY's tongue).
    optional: bool = false,
    /// Screen shake, pixels.
    shake_x: i32 = 0,
    shake_y: i32 = 0,
};

/// x'' = omega^2 (target - x) - 2 zeta omega x' + force, semi-implicit Euler.
pub const Spring = struct {
    x: f32 = 0,
    v: f32 = 0,

    /// Steps one tick; returns the acceleration.
    pub fn step(s: *Spring, target: f32, omega: f32, zeta: f32, force: f32, step_dt: f32) f32 {
        const a = omega * omega * (target - s.x) - 2.0 * zeta * omega * s.v + force;
        s.v += a * step_dt;
        s.x += s.v * step_dt;
        return a;
    }
};

const dt: f32 = 1.0 / 60.0;
const two_pi: f32 = 2.0 * std.math.pi;

var pos: [3]Spring = @splat(.{});
var yaw_off: Spring = .{};
var pitch: Spring = .{};
var roll: Spring = .{};
var auto_yaw: f32 = 0.62;
var jelly: Spring = .{};
var squash: Spring = .{};
var twist: Spring = .{};
var reach: f32 = 0;
var ripples: [config.max_ripples]Ripple = undefined;
var ripple_count: usize = 0;
var flash: f32 = 0;
var shake: u32 = 0;
var rng: u32 = 0x1234567;
var ticks: u32 = 0;

/// Deformation energy 0..~2 (sound grit, debug).
pub var energy: f32 = 0;
/// Shockwaves alive.
pub fn ripples_alive() usize {
    return ripple_count;
}

pub fn reset() void {
    pos = @splat(.{});
    yaw_off = .{};
    pitch = .{};
    roll = .{};
    auto_yaw = 0.62;
    jelly = .{};
    squash = .{};
    twist = .{};
    reach = 0;
    ripple_count = 0;
    flash = 0;
    shake = 0;
    ticks = 0;
}

/// A punch's effects without a hand (the A button in any source).
pub fn punch(dir_obj: V3) void {
    if (ripple_count == ripples.len) {
        // Replace the oldest.
        for (1..ripples.len) |i| ripples[i - 1] = ripples[i];
        ripple_count -= 1;
    }
    ripples[ripple_count] = .{ .dir = dir_obj, .front = 0, .amp = config.ripple_amp };
    ripple_count += 1;
    flash = config.flash_boost;
    shake = config.shake_frames;
    squash.v -= 3.5;
}

/// One tick: follow `h`, run the springs, return what to draw.
pub fn update(h: hand_mod.Hand) Params {
    ticks +%= 1;
    // Transform.
    const target = V3{
        h.x * config.travel_x * config.follow_gain,
        h.y * config.travel_y * config.follow_gain,
        (h.z - 0.35) * config.travel_z,
    };
    var acc: V3 = undefined;
    for (&pos, target, 0..) |*s, t, i| acc[i] = s.step(t, config.follow_omega, 1.0, 0, dt);
    auto_yaw = math.fract(auto_yaw + config.auto_spin * dt);
    _ = yaw_off.step(h.roll * h.conf_roll * config.tilt_gain / two_pi, 8.0, 1.0, 0, dt);
    _ = pitch.step(-h.pitch * h.conf_pitch * config.tilt_gain / two_pi, 8.0, 1.0, 0, dt);
    _ = roll.step(h.yaw * h.conf_yaw * config.yaw_gain / two_pi, 8.0, 1.0, 0, dt);
    const rot = rotation(auto_yaw + yaw_off.x, pitch.x, roll.x);
    const p = V3{ pos[0].x, pos[1].x, pos[2].x };

    // JELLY and TWIST.
    _ = jelly.step(0, config.jelly_omega, config.jelly_zeta, -config.jelly_drive * acc[0], dt);
    _ = squash.step(0, config.squash_omega, config.squash_zeta, -config.squash_drive * (0.6 * acc[1] + acc[2]), dt);
    const twist_target = std.math.clamp(h.swirl * config.swirl_twist - h.vyaw * config.twist_drive, -config.twist_max, config.twist_max);
    _ = twist.step(twist_target, config.twist_omega, config.twist_zeta, 0, dt);
    jelly.x = std.math.clamp(jelly.x, -config.jelly_max, config.jelly_max);
    squash.x = std.math.clamp(squash.x, -0.45, 0.45);
    twist.x = std.math.clamp(twist.x, -config.twist_max, config.twist_max);

    // REACH: toward the hand point, which sits in front of the mesh.
    reach += (config.reach_amp * h.z * h.z - reach) * 0.12;
    const hp = V3{ h.x * config.travel_x, h.y * config.travel_y, p[2] + 1.6 };
    const reach_dir = mesh.normalized(to_object(rot, mesh.sub(hp, p)));

    // SHOCKWAVE.
    if (h.punch) punch(reach_dir);
    var i: usize = 0;
    while (i < ripple_count) {
        var r = &ripples[i];
        r.front += config.ripple_speed * dt;
        const life = r.front * (1.0 / (config.ripple_speed * config.ripple_life));
        if (life >= 1.0) {
            for (i + 1..ripple_count) |j| ripples[j - 1] = ripples[j];
            ripple_count -= 1;
            continue;
        }
        r.amp = config.ripple_amp * (1.0 - life) * (1.0 - life);
        i += 1;
    }
    flash *= config.flash_decay;
    var sx: i32 = 0;
    var sy: i32 = 0;
    if (shake > 0) {
        shake -= 1;
        const k: i32 = @intCast(@min(config.shake_px, (shake + 2) / 3));
        sx = @as(i32, @intCast(next_rand() % @as(u32, @intCast(2 * k + 1)))) - k;
        sy = @as(i32, @intCast(next_rand() % @as(u32, @intCast(2 * k + 1)))) - k;
    }

    var ripple_energy: f32 = 0;
    for (ripples[0..ripple_count]) |r| ripple_energy += r.amp;
    energy = @abs(jelly.x) * 2.0 + @abs(squash.x) * 3.0 + @abs(twist.x) * 0.3 + reach + ripple_energy * 4.0;

    const breathe = 1.0 + 0.015 * math.sin_turns(@as(f32, @floatFromInt(ticks)) / 150.0);
    return .{
        .rot = rot,
        .scale = breathe,
        .pos = p,
        .reach_dir = reach_dir,
        .reach_amp = reach,
        .twist = twist.x,
        .shear = jelly.x,
        .squash = squash.x,
        .ripples = ripples[0..ripple_count],
        .flash = flash,
        .optional = h.z > 0.78,
        .shake_x = sx,
        .shake_y = sy,
    };
}

fn next_rand() u32 {
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
}

/// Row-major Rz(roll) * Rx(pitch) * Ry(yaw), angles in turns.
pub fn rotation(yaw: f32, pitch_t: f32, roll_t: f32) [3]V3 {
    const cy = math.cos_turns(yaw);
    const sy = math.sin_turns(yaw);
    const cp = math.cos_turns(pitch_t);
    const sp = math.sin_turns(pitch_t);
    const cr = math.cos_turns(roll_t);
    const sr = math.sin_turns(roll_t);
    const ry = [3]V3{ .{ cy, 0, sy }, .{ 0, 1, 0 }, .{ -sy, 0, cy } };
    const rx = [3]V3{ .{ 1, 0, 0 }, .{ 0, cp, -sp }, .{ 0, sp, cp } };
    const rz = [3]V3{ .{ cr, -sr, 0 }, .{ sr, cr, 0 }, .{ 0, 0, 1 } };
    return mat_mul(rz, mat_mul(rx, ry));
}

pub fn mat_mul(a: [3]V3, b: [3]V3) [3]V3 {
    var out: [3]V3 = undefined;
    for (0..3) |r| for (0..3) |c| {
        out[r][c] = a[r][0] * b[0][c] + a[r][1] * b[1][c] + a[r][2] * b[2][c];
    };
    return out;
}

/// Eye-space vector to object space (the transpose of `rot`).
pub fn to_object(rot: [3]V3, v: V3) V3 {
    return .{
        rot[0][0] * v[0] + rot[1][0] * v[1] + rot[2][0] * v[2],
        rot[0][1] * v[0] + rot[1][1] * v[1] + rot[2][1] * v[2],
        rot[0][2] * v[0] + rot[1][2] * v[1] + rot[2][2] * v[2],
    };
}

// ---------------------------------------------------------------------------
// Host tests.

test "body: follows the hand, jelly wobbles after a jerk and settles" {
    math.init_tables();
    reset();
    var h: hand_mod.Hand = .{};
    for (0..120) |_| _ = update(h);
    var prm = update(h);
    try std.testing.expect(@abs(prm.shear) < 0.01);
    try std.testing.expect(@abs(prm.pos[0]) < 0.01);
    h.x = 1;
    var max_shear: f32 = 0;
    var sign_changes: u32 = 0;
    var last: f32 = 0;
    for (0..90) |_| {
        prm = update(h);
        max_shear = @max(max_shear, @abs(prm.shear));
        if (prm.shear * last < 0) sign_changes += 1;
        if (prm.shear != 0) last = prm.shear;
    }
    try std.testing.expect(max_shear > 0.1);
    try std.testing.expect(sign_changes >= 2);
    try std.testing.expect(@abs(prm.pos[0] - config.travel_x * config.follow_gain) < 0.05);
    for (0..400) |_| prm = update(h);
    try std.testing.expect(@abs(prm.shear) < 0.02);
}

test "body: reach grows with proximity and points at the hand" {
    math.init_tables();
    reset();
    var h: hand_mod.Hand = .{ .z = 0 };
    var prm = update(h);
    for (0..60) |_| prm = update(h);
    try std.testing.expect(prm.reach_amp < 0.01);
    h.z = 1;
    h.x = 1;
    for (0..60) |_| prm = update(h);
    try std.testing.expect(prm.reach_amp > 0.45 * config.reach_amp);
    // The hand leads the mesh to the right: the reach direction, back in
    // eye space, points right and toward the camera.
    const d = mat_vec(prm.rot, prm.reach_dir);
    try std.testing.expect(d[0] > 0.2 and d[2] > 0.5);
    try std.testing.expect(prm.optional);
}

test "body: a punch launches a ripple, a flash and a shake, then they fade" {
    math.init_tables();
    reset();
    var h: hand_mod.Hand = .{};
    _ = update(h);
    h.punch = true;
    var prm = update(h);
    h.punch = false;
    try std.testing.expectEqual(@as(usize, 1), prm.ripples.len);
    try std.testing.expect(prm.flash > 20);
    var shook = false;
    for (0..30) |_| {
        prm = update(h);
        if (prm.shake_x != 0 or prm.shake_y != 0) shook = true;
    }
    try std.testing.expect(shook);
    for (0..120) |_| prm = update(h);
    try std.testing.expectEqual(@as(usize, 0), prm.ripples.len);
    try std.testing.expect(prm.flash < 0.5);
}

test "body: swirl twists" {
    math.init_tables();
    reset();
    const h: hand_mod.Hand = .{ .swirl = 1.0 };
    var prm = update(h);
    for (0..120) |_| prm = update(h);
    try std.testing.expect(prm.twist > 0.8);
}

fn mat_vec(m: [3]V3, v: V3) V3 {
    return .{ mesh.dot(m[0], v), mesh.dot(m[1], v), mesh.dot(m[2], v) };
}
