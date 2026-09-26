//! Builds the frame's polygon list from the maze and camera: floor, ceiling,
//! wall runs (world-space backface culling), tops, finish tile. Track A owns.
//! STUB: draws each run's two long faces and a floor quad, no culling.
const cart = @import("cart-api");
const math = @import("../math.zig");
const maze = @import("../maze.zig");
const camera = @import("../camera.zig");
const raster = @import("raster.zig");
const textures = @import("textures.zig");

pub const wall_half: f32 = 0.05;
pub const wall_height: f32 = 1.0;

pub fn draw(m: *const maze.Maze, cam: *const camera.Camera) void {
    const b = cam.basis();
    const w: f32 = @floatFromInt(m.w);
    const h: f32 = @floatFromInt(m.h);

    // Floor.
    quad(cam, b, .{ math.vec3(0, 0, 0), math.vec3(w, 0, 0), math.vec3(w, 0, h), math.vec3(0, 0, h) }, .{ 0, 0, w, 0, w, h, 0, h }, .{ .flat = .from_color(.{ .r = 8, .g = 8, .b = 10 }) });

    for (m.runs[0..m.run_count]) |run| {
        const x: f32 = @floatFromInt(run.x);
        const z: f32 = @floatFromInt(run.z);
        const len: f32 = @floatFromInt(run.len);
        switch (run.axis) {
            .x => {
                const xa = x - wall_half;
                const xb = x + len + wall_half;
                side(cam, b, math.vec3(xa, 0, z - wall_half), math.vec3(xb, 0, z - wall_half), &textures.wall_lit);
                side(cam, b, math.vec3(xa, 0, z + wall_half), math.vec3(xb, 0, z + wall_half), &textures.wall_lit);
            },
            .z => {
                const za = z - wall_half;
                const zb = z + len + wall_half;
                side(cam, b, math.vec3(x - wall_half, 0, za), math.vec3(x - wall_half, 0, zb), &textures.wall_dark);
                side(cam, b, math.vec3(x + wall_half, 0, za), math.vec3(x + wall_half, 0, zb), &textures.wall_dark);
            },
        }
    }
}

/// Vertical wall face from ground point a to ground point b, one texture
/// repeat per cell along its length.
fn side(cam: *const camera.Camera, b: math.Mat3, a: math.Vec3, c: math.Vec3, tex: *const textures.Texture) void {
    const len = math.length(c - a);
    quad(cam, b, .{ a, c, c + math.vec3(0, wall_height, 0), a + math.vec3(0, wall_height, 0) }, .{ 0, 1, len, 1, len, 0, 0, 0 }, .{ .textured = tex });
}

fn quad(cam: *const camera.Camera, b: math.Mat3, p: [4]math.Vec3, uv: [8]f32, fill: raster.Fill) void {
    var v: [4]raster.Vertex = undefined;
    for (0..4) |i| v[i] = .{ .p = cam.to_view(b, p[i]), .u = uv[i * 2], .v = uv[i * 2 + 1] };
    raster.draw_polygon(&v, fill);
}
