//! Builds the frame's polygon list from the maze and camera: finish tile,
//! wall runs (sorted front to back, world-space backface culling), floor,
//! ceiling. Frustum rejection and near clipping happen in raster.
const math = @import("../math.zig");
const maze = @import("../maze.zig");
const camera = @import("../camera.zig");
const raster = @import("raster.zig");
const textures = @import("textures.zig");

pub const wall_half: f32 = 0.05;
pub const wall_height: f32 = 1.0;
pub const finish_lift: f32 = 0.002;

const Vec3 = math.Vec3;
const vec3 = math.vec3;

/// Run submission order, kept across frames: insertion sort on an almost
/// sorted array is linear, so a moving camera costs about n compares.
var order: [maze.max_runs]u16 = undefined;
var order_n: u16 = 0;
var keys: [maze.max_runs]u16 = undefined;

pub fn draw(m: *const maze.Maze, cam: *const camera.Camera) void {
    const b = cam.basis();
    const pos = cam.pos;
    const w: f32 = @floatFromInt(m.w);
    const h: f32 = @floatFromInt(m.h);

    // Finish tile before the floor: where the two z values quantise to the
    // same u16 the greater-than test keeps the tile.
    if (pos[1] > finish_lift) {
        const fx: f32 = @floatFromInt(m.finish[0]);
        const fz: f32 = @floatFromInt(m.finish[1]);
        horizontal(cam, b, fx, fz, fx + 1, fz + 1, finish_lift, .{ .textured = &textures.finish });
    }

    // Walls, nearest first so the z test rejects hidden floor and far walls
    // before texturing.
    sort_runs(m, pos);
    for (order[0..m.run_count]) |i| draw_run(cam, b, m.runs[i]);

    if (pos[1] > 0) horizontal(cam, b, 0, 0, w, h, 0, .{ .textured = &textures.floor });
    if (pos[1] < wall_height) horizontal(cam, b, 0, 0, w, h, wall_height, .{ .textured = &textures.ceiling });
}

/// Axis-aligned horizontal quad, u = x, v = z (one repeat per cell).
fn horizontal(cam: *const camera.Camera, b: math.Mat3, x0: f32, z0: f32, x1: f32, z1: f32, y: f32, fill: raster.Fill) void {
    const v = [4]raster.Vertex{
        .{ .p = cam.to_view(b, vec3(x0, y, z0)), .u = x0, .v = z0 },
        .{ .p = cam.to_view(b, vec3(x1, y, z0)), .u = x1, .v = z0 },
        .{ .p = cam.to_view(b, vec3(x1, y, z1)), .u = x1, .v = z1 },
        .{ .p = cam.to_view(b, vec3(x0, y, z1)), .u = x0, .v = z1 },
    };
    raster.draw_polygon(&v, fill);
}

/// A run as a box 0.1 thick, extended by wall_half at both ends. At most
/// two side faces plus the top are visible; each is chosen by comparing the
/// camera with the face plane in world space. Faces facing +-z use the lit
/// wall palette, faces facing +-x the dark one (so an x-axis run's long
/// sides are lit and a z-axis run's dark, and end caps match the walls
/// they are parallel to). u runs along the face in world cells, increasing
/// to the viewer's right; v is 0 at the top, 1 at the floor.
fn draw_run(cam: *const camera.Camera, b: math.Mat3, run: maze.Run) void {
    const x: f32 = @floatFromInt(run.x);
    const z: f32 = @floatFromInt(run.z);
    const len: f32 = @floatFromInt(run.len);
    const x0 = x - wall_half;
    const z0 = z - wall_half;
    const x1 = if (run.axis == .x) x + len + wall_half else x + wall_half;
    const z1 = if (run.axis == .z) z + len + wall_half else z + wall_half;
    const pos = cam.pos;

    // Corners in view space, index = xi | yi << 1 | zi << 2.
    var c: [8]Vec3 = undefined;
    for (0..8) |i| {
        const px = if (i & 1 != 0) x1 else x0;
        const py: f32 = if (i & 2 != 0) wall_height else 0;
        const pz = if (i & 4 != 0) z1 else z0;
        c[i] = cam.to_view(b, vec3(px, py, pz));
    }
    const lit: raster.Fill = .{ .textured = &textures.wall_lit };
    const dark: raster.Fill = .{ .textured = &textures.wall_dark };

    // Vertex order per face: bottom-left, bottom-right, top-right, top-left
    // as seen from outside.
    if (pos[2] < z0) face(c[1], c[0], c[2], c[3], -x1, -x0, lit); // north face, looking south
    if (pos[2] > z1) face(c[4], c[5], c[7], c[6], x0, x1, lit); // south face, looking north
    if (pos[0] < x0) face(c[0], c[4], c[6], c[2], z0, z1, dark); // west face, looking east
    if (pos[0] > x1) face(c[5], c[1], c[3], c[7], -z1, -z0, dark); // east face, looking west
    if (pos[1] > wall_height) {
        const v = [4]raster.Vertex{
            .{ .p = c[2], .u = 0, .v = 0 },
            .{ .p = c[3], .u = 0, .v = 0 },
            .{ .p = c[7], .u = 0, .v = 0 },
            .{ .p = c[6], .u = 0, .v = 0 },
        };
        raster.draw_polygon(&v, .{ .flat = textures.top_color });
    }
}

fn face(bl: Vec3, br: Vec3, tr: Vec3, tl: Vec3, ua: f32, ub: f32, fill: raster.Fill) void {
    const v = [4]raster.Vertex{
        .{ .p = bl, .u = ua, .v = 1 },
        .{ .p = br, .u = ub, .v = 1 },
        .{ .p = tr, .u = ub, .v = 0 },
        .{ .p = tl, .u = ua, .v = 0 },
    };
    raster.draw_polygon(&v, fill);
}

/// Sorts `order` by squared distance from the camera to each run's
/// midpoint (u16 key, 1/16 cell^2 units, saturating).
fn sort_runs(m: *const maze.Maze, pos: Vec3) void {
    const n = m.run_count;
    if (n != order_n) {
        for (0..n) |i| order[i] = @intCast(i);
        order_n = n;
    }
    for (m.runs[0..n], 0..) |run, i| {
        const half: f32 = @as(f32, @floatFromInt(run.len)) * 0.5;
        var mx: f32 = @floatFromInt(run.x);
        var mz: f32 = @floatFromInt(run.z);
        if (run.axis == .x) mx += half else mz += half;
        const d = vec3(mx, wall_height * 0.5, mz) - pos;
        keys[i] = @intFromFloat(@min(65535.0, math.dot(d, d) * 16.0));
    }
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const o = order[i];
        const k = keys[o];
        var j = i;
        while (j > 0 and keys[order[j - 1]] > k) : (j -= 1) order[j] = order[j - 1];
        order[j] = o;
    }
}
