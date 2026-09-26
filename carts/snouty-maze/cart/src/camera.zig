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

/// Put the camera at the start cell centre at eye height, facing north.
/// Track B: face the start cell's open direction instead.
pub fn reset(m: *const maze.Maze) void {
    cam = .{ .pos = math.vec3(@as(f32, @floatFromInt(m.start[0])) + 0.5, eye_height, @as(f32, @floatFromInt(m.start[1])) + 0.5) };
}

/// Debug fly controls (SPEC section 3, M1 column). Track B implements.
pub const Fly = struct { up: bool, down: bool, left: bool, right: bool, a: bool, b: bool };
pub fn debug_fly(f: Fly) void {
    _ = f;
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
