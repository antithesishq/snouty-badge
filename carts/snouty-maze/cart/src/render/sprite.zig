//! Actor sprites: upright billboards and floor-aligned quads, drawn with
//! `Fill.sprite` (palette index 0 transparent, per-pixel z test, so walls
//! hide actors correctly and actors never punch holes in what is behind).
const math = @import("../math.zig");
const camera = @import("../camera.zig");
const raster = @import("raster.zig");
const textures = @import("textures.zig");

const Vec3 = math.Vec3;
const vec3 = math.vec3;
const splat = math.splat;

/// Minimum lift above the floor for floor sprites.
pub const floor_lift: f32 = 0.003;
/// Upper bound for the depth-dependent lift (well below eye height).
const max_lift: f32 = 0.3;

/// Square upright billboard with its bottom edge centred on `pos` (feet on
/// the floor for y = 0), `size` cells wide and tall. It faces the camera's
/// heading (parallel to the view plane at pitch 0) and stays vertical in
/// the world, so it pitches and rolls with the maze, not with the screen.
/// Image top (v = 0) is up, image left (u = 0) on the viewer's left.
/// `y_scale` squashes the height (the maze rising at the start).
pub fn draw_billboard(cam: *const camera.Camera, b: math.Mat3, pos: Vec3, size: f32, y_scale: f32, tex: *const textures.Texture) void {
    const hs = size * 0.5;
    const r = vec3(math.cos_angle(cam.yaw), 0, math.sin_angle(cam.yaw)) * splat(hs);
    const up = vec3(0, size * y_scale, 0);
    const m = tex.uv_max;
    const v = [4]raster.Vertex{
        .{ .p = cam.to_view(b, pos - r), .u = 0, .v = m },
        .{ .p = cam.to_view(b, pos + r), .u = m, .v = m },
        .{ .p = cam.to_view(b, pos + r + up), .u = m, .v = 0 },
        .{ .p = cam.to_view(b, pos - r + up), .u = 0, .v = 0 },
    };
    raster.draw_polygon(&v, .{ .sprite = tex });
}

/// Square quad lying on the floor, centred on pos.x/z, with the image top
/// pointing along the camera's heading (screen up when looking straight
/// down). The sprite is drawn after the floor and the z test is strict, so
/// it must sit at least one z-buffer step (1 / z_scale in 1/z) above it:
/// dy >= d^2 / z_scale at view depth d, i.e. 0.003 is enough only up to
/// d = 2.5; from the overhead point (d = 15..21) it needs 0.1..0.2. The
/// lift is 1.5 steps' worth, never below floor_lift.
pub fn draw_floor_sprite(cam: *const camera.Camera, b: math.Mat3, pos: Vec3, size: f32, tex: *const textures.Texture) void {
    const hs = size * 0.5;
    const sy = math.sin_angle(cam.yaw);
    const cy = math.cos_angle(cam.yaw);
    const r = vec3(cy, 0, sy) * splat(hs);
    const f = vec3(sy, 0, -cy) * splat(hs);
    const d = cam.to_view(b, vec3(pos[0], 0, pos[2]))[2];
    const lift = @min(max_lift, @max(floor_lift, 1.5 * d * d * (1.0 / raster.z_scale)));
    const c = vec3(pos[0], lift, pos[2]);
    const m = tex.uv_max;
    const v = [4]raster.Vertex{
        .{ .p = cam.to_view(b, c - r + f), .u = 0, .v = 0 },
        .{ .p = cam.to_view(b, c + r + f), .u = m, .v = 0 },
        .{ .p = cam.to_view(b, c + r - f), .u = m, .v = m },
        .{ .p = cam.to_view(b, c - r - f), .u = 0, .v = m },
    };
    raster.draw_polygon(&v, .{ .sprite = tex });
}
