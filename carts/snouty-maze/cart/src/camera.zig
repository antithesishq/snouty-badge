//! Camera state, world-to-view basis and the M1 debug fly camera.
//! Track B implements the fly controls; the basis convention is fixed here.
//! No cart API: host-testable.
const std = @import("std");
const math = @import("math.zig");
const maze = @import("maze.zig");
const Vec3 = math.Vec3;
const Angle = math.Angle;

pub const eye_height: f32 = 0.5;

pub const Camera = struct {
    pos: Vec3 = math.vec3(0.5, eye_height, 0.5),
    /// Heading: 0 looks toward -z (north), deg(90) toward +x (east).
    yaw: Angle = 0,
    /// Positive pitches the view down. deg(90) looks straight down.
    pitch: Angle = 0,
    /// Roll about the view axis; deg(180) is upside down.
    roll: Angle = 0,

    /// World-to-view rotation. View space: +x right, +y up, +z forward.
    /// view = basis(p - pos). Composition: yaw, then pitch, then roll.
    pub fn basis(c: *const Camera) math.Mat3 {
        const sy = math.sin_angle(c.yaw);
        const cy = math.cos_angle(c.yaw);
        const sp = math.sin_angle(c.pitch);
        const cp = math.cos_angle(c.pitch);
        const sr = math.sin_angle(c.roll);
        const cr = math.cos_angle(c.roll);
        // Yaw: forward = (sy, 0, -cy), right = (cy, 0, sy), up = (0, 1, 0).
        const yaw_m: math.Mat3 = .{ .r = .{
            math.vec3(cy, 0, sy),
            math.vec3(0, 1, 0),
            math.vec3(sy, 0, -cy),
        } };
        // Pitch down by `pitch` about the view x axis.
        const pitch_m: math.Mat3 = .{ .r = .{
            math.vec3(1, 0, 0),
            math.vec3(0, cp, sp),
            math.vec3(0, -sp, cp),
        } };
        // Roll about the view z axis.
        const roll_m: math.Mat3 = .{ .r = .{
            math.vec3(cr, -sr, 0),
            math.vec3(sr, cr, 0),
            math.vec3(0, 0, 1),
        } };
        return roll_m.mul(pitch_m.mul(yaw_m));
    }

    pub inline fn to_view(c: *const Camera, b: math.Mat3, p: Vec3) Vec3 {
        return b.apply(p - c.pos);
    }
};

pub var cam: Camera = .{};

/// Put the camera at the start cell centre at eye height, facing the
/// start cell's open side (north, east, south, west preference).
pub fn reset(m: *const maze.Maze) void {
    const sx = m.start[0];
    const sz = m.start[1];
    var yaw: Angle = 0;
    for ([_]maze.Dir{ .n, .e, .s, .w }) |d| {
        if (!m.has_wall(sx, sz, d)) {
            yaw = dir_yaw(d);
            break;
        }
    }
    cam = .{
        .pos = math.vec3(@as(f32, @floatFromInt(sx)) + 0.5, eye_height, @as(f32, @floatFromInt(sz)) + 0.5),
        .yaw = yaw,
    };
}

/// Yaw that faces `d` (n = 0, e = deg(90), ...).
pub fn dir_yaw(d: maze.Dir) Angle {
    return @as(Angle, @backingInt(d)) << 14;
}

/// Compass quadrant of a yaw, rounding to the nearest of N/E/S/W.
pub fn heading(yaw: Angle) maze.Dir {
    return @fromBackingInt(@as(u2, @intCast((yaw +% 0x2000) >> 14)));
}

pub const walk_step: f32 = 1.0 / 30.0; // 2 cells/s
pub const climb_step: f32 = 1.0 / 60.0; // 1 cell/s
pub const turn_step: Angle = math.deg(1.5); // 90 deg/s
pub const pitch_step: i32 = math.deg(1.0); // 60 deg/s
pub const min_height: f32 = 0.1;
pub const max_height: f32 = 40.0;
const pitch_limit: i32 = math.deg(90);

/// Debug fly controls (SPEC section 3, M1 column), one tick. Up/Down walk
/// along the horizontal heading; Left/Right turn; with A held Up/Down pitch
/// (Up looks up); with B held Up/Down rise and sink. No collision.
pub const Fly = struct { up: bool, down: bool, left: bool, right: bool, a: bool, b: bool };
pub fn debug_fly(f: Fly) void {
    if (f.left) cam.yaw -%= turn_step;
    if (f.right) cam.yaw +%= turn_step;
    const axis: f32 = @as(f32, @floatFromInt(@intFromBool(f.up))) - @as(f32, @floatFromInt(@intFromBool(f.down)));
    if (axis == 0) return;
    if (f.a) {
        // Signed shadow of the u16 pitch: [-180, 180) degrees.
        var p: i32 = @as(i16, @bitCast(cam.pitch));
        p -= @as(i32, @intFromFloat(axis)) * pitch_step;
        p = std.math.clamp(p, -pitch_limit, pitch_limit);
        cam.pitch = @bitCast(@as(i16, @intCast(p)));
    } else if (f.b) {
        cam.pos[1] = std.math.clamp(cam.pos[1] + axis * climb_step, min_height, max_height);
    } else {
        const s = axis * walk_step;
        cam.pos[0] += math.sin_angle(cam.yaw) * s;
        cam.pos[2] -= math.cos_angle(cam.yaw) * s;
    }
}

test "reset faces the open side" {
    var r = @import("rng.zig").Xorshift.init(1);
    var m: maze.Maze = .{};
    m.generate(12, 12, &r);
    reset(&m);
    try std.testing.expect(!m.has_wall(0, 0, heading(cam.yaw)));
    try std.testing.expectEqual(@as(f32, 0.5), cam.pos[0]);
    try std.testing.expectEqual(eye_height, cam.pos[1]);
}

test "debug fly" {
    cam = .{ .pos = math.vec3(0.5, eye_height, 0.5) };
    const none: Fly = .{ .up = false, .down = false, .left = false, .right = false, .a = false, .b = false };
    var f = none;
    f.up = true;
    for (0..30) |_| debug_fly(f);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), cam.pos[2], 1e-3);
    f = none;
    f.right = true;
    for (0..60) |_| debug_fly(f);
    try std.testing.expectEqual(maze.Dir.e, heading(cam.yaw));
    try std.testing.expectApproxEqAbs(@as(f32, 90), @as(f32, @floatFromInt(cam.yaw)) * 360.0 / 65536.0, 0.1);
    // A + Down pitches down, clamped at 90.
    f = none;
    f.a = true;
    f.down = true;
    for (0..200) |_| debug_fly(f);
    try std.testing.expectEqual(math.deg(90), cam.pitch);
    f.down = false;
    f.up = true;
    for (0..400) |_| debug_fly(f);
    try std.testing.expectEqual(@as(i16, -16384), @as(i16, @bitCast(cam.pitch)));
    // B + Down sinks, clamped at 0.1; B + Up climbs to 40.
    f = none;
    f.b = true;
    f.down = true;
    for (0..100) |_| debug_fly(f);
    try std.testing.expectEqual(min_height, cam.pos[1]);
    f.down = false;
    f.up = true;
    for (0..3000) |_| debug_fly(f);
    try std.testing.expectEqual(max_height, cam.pos[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), cam.pos[0], 1e-3);
    try std.testing.expectEqual(maze.Dir.w, heading(math.deg(280)));
    try std.testing.expectEqual(maze.Dir.n, heading(math.deg(350)));
}

test "basis conventions" {
    const c: Camera = .{ .pos = math.vec3(0, 0, 0) };
    const b = c.basis();
    // Facing north (-z): a point ahead has positive view z.
    const ahead = c.to_view(b, math.vec3(0, 0, -1));
    try std.testing.expectApproxEqAbs(@as(f32, 1), ahead[2], 1e-4);
    // East is to the right.
    const east = c.to_view(b, math.vec3(1, 0, 0));
    try std.testing.expectApproxEqAbs(@as(f32, 1), east[0], 1e-4);
    // Pitched 90 down: the floor below is ahead.
    const d: Camera = .{ .pos = math.vec3(0, 1, 0), .pitch = math.deg(90) };
    const below = d.to_view(d.basis(), math.vec3(0, 0, 0));
    try std.testing.expectApproxEqAbs(@as(f32, 1), below[2], 1e-4);
    // Rolled 180: up is down.
    const r: Camera = .{ .pos = math.vec3(0, 0, 0), .roll = math.deg(180) };
    const up = r.to_view(r.basis(), math.vec3(0, 1, 0));
    try std.testing.expectApproxEqAbs(@as(f32, -1), up[1], 1e-4);
}
