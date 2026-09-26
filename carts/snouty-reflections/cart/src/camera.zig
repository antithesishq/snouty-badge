//! Orbiting camera and the screen-to-ray mapping (PLAN.md "Screen to ray",
//! "Camera"). Built once per frame; the tracer adds right*u per column and
//! up*v per row from the comptime tables below.
const math = @import("math.zig");
const Vec3 = math.Vec3;
const vec3 = math.vec3;
const splat = math.splat;

pub const width = 160;
pub const height = 128;

/// tan(30 deg): horizontal FOV 60 degrees.
pub const tan_h: f32 = 0.57735;

pub const orbit_radius: f32 = 4.5;
pub const orbit_height: f32 = 1.6;
/// Frames per revolution (30 s at 20 fps).
pub const orbit_frames = 600;
pub const target = vec3(0.0, 0.9, 0.0);

/// u(x) = (x + 0.5 - 80) / 80 * tan_h, one per column.
pub const u_table: [width]f32 = blk: {
    var t: [width]f32 = undefined;
    for (0..width) |x| {
        const fx: f32 = @floatFromInt(x);
        t[x] = (fx + 0.5 - 80.0) / 80.0 * tan_h;
    }
    break :blk t;
};

/// v(y) = -(y + 0.5 - 64) / 80 * tan_h, one per row.
pub const v_table: [height]f32 = blk: {
    var t: [height]f32 = undefined;
    for (0..height) |y| {
        const fy: f32 = @floatFromInt(y);
        t[y] = -(fy + 0.5 - 64.0) / 80.0 * tan_h;
    }
    break :blk t;
};

pub const Camera = struct {
    eye: Vec3,
    fwd: Vec3,
    right: Vec3,
    up: Vec3,
};

pub fn at_frame(frame: u32) Camera {
    // theta = frame / 600 turns; wrap first so precision never degrades.
    const theta = @as(f32, @floatFromInt(frame % orbit_frames)) * (1.0 / @as(f32, orbit_frames));
    const eye = vec3(
        orbit_radius * math.sin_turns(theta),
        orbit_height,
        orbit_radius * math.cos_turns(theta),
    );
    const fwd = math.normalize(target - eye);
    const right = math.normalize(math.cross(fwd, vec3(0.0, 1.0, 0.0)));
    const up = math.cross(right, fwd);
    return .{ .eye = eye, .fwd = fwd, .right = right, .up = up };
}
