//! Builds the frame's polygon list from the maze and camera: finish tile,
//! wall runs (sorted front to back, world-space backface culling), floor,
//! ceiling, then the actors (M3); wall pictures go in just before the walls.
//! Frustum rejection and near clipping happen in raster.
const math = @import("../math.zig");
const maze = @import("../maze.zig");
const camera = @import("../camera.zig");
const raster = @import("raster.zig");
const textures = @import("textures.zig");
const sprite = @import("sprite.zig");
const mesh = @import("mesh.zig");
const actors = @import("../actors.zig");

pub const wall_half: f32 = 0.05;
pub const wall_height: f32 = 1.0;
/// Vertical scale of everything above the floor (walls, ceiling, pictures,
/// actors): 1 normally, 0 -> 1 while the maze rises out of the floor
/// (autopilot GROW; main.update sets it every tick).
pub var height_scale: f32 = 1.0;
pub const finish_lift: f32 = 0.002;

const Vec3 = math.Vec3;
const vec3 = math.vec3;

/// Run submission order, kept across frames: insertion sort on an almost
/// sorted array is linear, so a moving camera costs about n compares.
var order: [maze.max_runs]u16 = undefined;
var order_n: u16 = 0;
var keys: [maze.max_runs]u16 = undefined;

/// Wall pictures: half size, centre height, offset out from the face.
pub const pic_half: f32 = 0.25;
pub const pic_height: f32 = 0.55;
pub const pic_offset: f32 = 0.005;

pub fn draw(m: *const maze.Maze, cam: *const camera.Camera) void {
    const b = cam.basis();
    const pos = cam.pos;
    const w: f32 = @floatFromInt(m.w);
    const h: f32 = @floatFromInt(m.h);

    // Finish tile before the floor: where the two z values quantise to the
    // same u16 the greater-than test keeps the tile. While OVERHEAD carves
    // the new maze (C4) the finish tile and the actors wait for the end,
    // and the carve head cell is a flat tile instead.
    const carving = m.revealed < m.carve_count;
    const top = wall_height * height_scale;
    if (pos[1] > finish_lift) {
        if (!carving) {
            const fx: f32 = @floatFromInt(m.finish[0]);
            const fz: f32 = @floatFromInt(m.finish[1]);
            horizontal(cam, b, fx, fz, fx + 1, fz + 1, finish_lift, .{ .textured = &textures.finish });
        } else if (m.carve_head()) |hc| {
            const fx: f32 = @floatFromInt(hc[0]);
            const fz: f32 = @floatFromInt(hc[1]);
            horizontal(cam, b, fx, fz, fx + 1, fz + 1, finish_lift, .{ .flat = textures.carve_head_color });
        }
    }

    // Pictures before the walls, for the same reason.
    if (pos[1] < top) {
        for (m.runs[0..m.run_count]) |run| draw_pictures(cam, b, run);
    }

    // Walls, nearest first so the z test rejects hidden floor and far walls
    // before texturing. Wall faces and tops go in as occluders: their
    // per-column records let raster skip later walls, and the floor and
    // ceiling rows, that they hide (exact, see raster.Occ).
    sort_runs(m, pos);
    for (order[0..m.run_count]) |i| draw_run(cam, b, m.runs[i]);

    if (pos[1] > 0) horizontal(cam, b, 0, 0, w, h, 0, .{ .textured = &textures.floor });
    if (pos[1] < top) horizontal(cam, b, 0, 0, w, h, top, .{ .textured = &textures.ceiling });

    if (!carving) draw_actors(cam, b);
}

/// Snouty (billboard below the ceiling, floor sprite above it), the sphere,
/// the smiley, the logo and the Start button, from `actors` state.
fn draw_actors(cam: *const camera.Camera, b: math.Mat3) void {
    const s = actors.snouty;
    // Sheet cells 0, 1 face left, 2, 3 face right: pick the pair from the
    // movement against the camera's right, then the walk phase.
    const right = vec3(math.cos_angle(cam.yaw), 0, math.sin_angle(cam.yaw));
    const mv = vec3(@floatFromInt(s.dir.dx()), 0, @floatFromInt(s.dir.dz()));
    const pair: usize = if (math.dot(right, mv) >= 0) 2 else 0;
    const frame = &textures.snouty[pair + s.phase];
    const hs = height_scale;
    if (cam.pos[1] < wall_height * hs) {
        sprite.draw_billboard(cam, b, s.pos, actors.snouty_size, hs, frame);
    } else {
        sprite.draw_floor_sprite(cam, b, s.pos, actors.snouty_size, frame);
    }

    mesh.draw_sphere(cam, b, squash(actors.sphere.pos), actors.sphere_radius * hs, .{ 0xc0, 0xc0, 0xc0 });
    mesh.draw_spin_quad(cam, b, squash(actors.smiley.pos), actors.quad_half, hs, actors.smiley.angle, &textures.smiley);
    mesh.draw_spin_quad(cam, b, squash(actors.logo.pos), actors.quad_half, hs, actors.logo.angle, &textures.logo);
    mesh.draw_spin_quad(cam, b, squash(actors.start_button), actors.quad_half, hs, actors.start_angle, &textures.start);
}

/// An actor position with its height scaled by `height_scale`.
fn squash(p: Vec3) Vec3 {
    return vec3(p[0], p[1] * height_scale, p[2]);
}

/// Hangs a wall picture on about one cell-length segment in eight of a run
/// (a cheap hash of the segment picks it and the face), 0.005 out from the
/// face, only when the camera is on that side. u runs to the viewer's
/// right and v = 0 is the top, as on the walls, so it is never mirrored.
fn draw_pictures(cam: *const camera.Camera, b: math.Mat3, run: maze.Run) void {
    const pos = cam.pos;
    const x: u32 = run.x;
    const z: u32 = run.z;
    const along_x = run.axis == .x;
    const axis: u32 = if (along_x) 0 else 1;
    const y0 = (pic_height - pic_half) * height_scale;
    const y1 = (pic_height + pic_half) * height_scale;
    var k: u32 = 0;
    while (k < run.len) : (k += 1) {
        const sx = if (along_x) x + k else x;
        const sz = if (along_x) z else z + k;
        const hash = sx * 7 + sz * 13 + axis * 3;
        if (hash % 8 != 0) continue;
        const second = (hash / 8) & 1 != 0;
        const fx: f32 = @floatFromInt(sx);
        const fz: f32 = @floatFromInt(sz);
        if (along_x) {
            // Segment from x = sx to sx + 1 on grid line z = sz.
            const a = fx + 0.5 - pic_half;
            const c = fx + 0.5 + pic_half;
            if (second) {
                const pz = fz + wall_half + pic_offset; // south face, seen looking north
                if (pos[2] <= pz) continue;
                picture(cam, b, vec3(a, y0, pz), vec3(c, y0, pz), vec3(c, y1, pz), vec3(a, y1, pz));
            } else {
                const pz = fz - wall_half - pic_offset; // north face, seen looking south
                if (pos[2] >= pz) continue;
                picture(cam, b, vec3(c, y0, pz), vec3(a, y0, pz), vec3(a, y1, pz), vec3(c, y1, pz));
            }
        } else {
            const a = fz + 0.5 - pic_half;
            const c = fz + 0.5 + pic_half;
            if (second) {
                const px = fx + wall_half + pic_offset; // east face, seen looking west
                if (pos[0] <= px) continue;
                picture(cam, b, vec3(px, y0, c), vec3(px, y0, a), vec3(px, y1, a), vec3(px, y1, c));
            } else {
                const px = fx - wall_half - pic_offset; // west face, seen looking east
                if (pos[0] >= px) continue;
                picture(cam, b, vec3(px, y0, a), vec3(px, y0, c), vec3(px, y1, c), vec3(px, y1, a));
            }
        }
    }
}

/// World-space corners bottom-left, bottom-right, top-right, top-left as
/// seen by the viewer.
fn picture(cam: *const camera.Camera, b: math.Mat3, bl: Vec3, br: Vec3, tr: Vec3, tl: Vec3) void {
    const m = textures.wall_pic.uv_max;
    const v = [4]raster.Vertex{
        .{ .p = cam.to_view(b, bl), .u = 0, .v = m },
        .{ .p = cam.to_view(b, br), .u = m, .v = m },
        .{ .p = cam.to_view(b, tr), .u = m, .v = 0 },
        .{ .p = cam.to_view(b, tl), .u = 0, .v = 0 },
    };
    raster.draw_polygon(&v, .{ .textured = &textures.wall_pic });
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
    const top = wall_height * height_scale;

    // Corners in view space, index = xi | yi << 1 | zi << 2.
    var c: [8]Vec3 = undefined;
    for (0..8) |i| {
        const px = if (i & 1 != 0) x1 else x0;
        const py: f32 = if (i & 2 != 0) top else 0;
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
    if (pos[1] > top) {
        const v = [4]raster.Vertex{
            .{ .p = c[2], .u = 0, .v = 0 },
            .{ .p = c[3], .u = 0, .v = 0 },
            .{ .p = c[7], .u = 0, .v = 0 },
            .{ .p = c[6], .u = 0, .v = 0 },
        };
        raster.draw_occluder(&v, .{ .flat = textures.top_color });
    }
}

fn face(bl: Vec3, br: Vec3, tr: Vec3, tl: Vec3, ua: f32, ub: f32, fill: raster.Fill) void {
    const v = [4]raster.Vertex{
        .{ .p = bl, .u = ua, .v = 1 },
        .{ .p = br, .u = ub, .v = 1 },
        .{ .p = tr, .u = ub, .v = 0 },
        .{ .p = tl, .u = ua, .v = 0 },
    };
    raster.draw_occluder(&v, fill);
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
        const d = vec3(mx, wall_height * height_scale * 0.5, mz) - pos;
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
