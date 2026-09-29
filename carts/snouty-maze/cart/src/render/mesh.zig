//! Comptime meshes for the actors: a flat-shaded UV sphere and a two-sided
//! spinning textured quad.
const std = @import("std");
const cart = @import("cart-api");
const math = @import("../math.zig");
const camera = @import("../camera.zig");
const raster = @import("raster.zig");
const clip = @import("clip.zig");
const textures = @import("textures.zig");

const Vec3 = math.Vec3;
const vec3 = math.vec3;
const splat = math.splat;

// ---------------------------------------------------------------------------
// UV sphere: `rings` latitude bands (the two polar bands are triangle fans,
// the rest quads) by `segs` longitude segments, unit radius.

const rings = 8;
const segs = 12;
const vert_count = 2 + (rings - 1) * segs;
const face_count = rings * segs;
/// Light levels: intensity (level + 1) / 8.
const levels = 8;

/// Plain `[3]f32`, not `Vec3`: on the thumb target Zig lays a struct with
/// `@Vector(3, f32)` fields out as 40 bytes while LLVM emits the comptime
/// table with a 48-byte stride, so every face after the first was read
/// from the wrong offset (found by badge-bench, 2026-09-27). Arrays have one
/// layout everywhere.
const Face = struct {
    idx: [4]u8,
    n: u8,
    /// Unit plane normal (outward).
    normal: [3]f32,
    /// A point on the face plane (unit sphere), for the backface test.
    point: [3]f32,
    level: u8,
};

const Mesh = struct {
    verts: [vert_count]Vec3,
    faces: [face_count]Face,
};

fn ring_vert(k: usize, s: usize) u8 {
    if (k == 0) return 0;
    if (k == rings) return vert_count - 1;
    return @intCast(1 + (k - 1) * segs + (s % segs));
}

const sphere: Mesh = blk: {
    @setEvalBranchQuota(100000);
    var m: Mesh = undefined;
    m.verts[0] = vec3(0, 1, 0);
    m.verts[vert_count - 1] = vec3(0, -1, 0);
    for (1..rings) |k| {
        const lat: f64 = std.math.pi * @as(f64, @floatFromInt(k)) / rings;
        for (0..segs) |s| {
            const lon: f64 = 2.0 * std.math.pi * @as(f64, @floatFromInt(s)) / segs;
            m.verts[ring_vert(k, s)] = vec3(
                @floatCast(@sin(lat) * @cos(lon)),
                @floatCast(@cos(lat)),
                @floatCast(@sin(lat) * @sin(lon)),
            );
        }
    }
    const light = math.normalize(vec3(0.4, 0.8, -0.45));
    var f: usize = 0;
    for (0..rings) |k| {
        for (0..segs) |s| {
            var face: Face = undefined;
            const a = ring_vert(k, s);
            const b = ring_vert(k, s + 1);
            const c = ring_vert(k + 1, s + 1);
            const d = ring_vert(k + 1, s);
            if (k == 0) {
                face.idx = .{ a, c, d, 0 };
                face.n = 3;
            } else if (k == rings - 1) {
                face.idx = .{ a, b, c, 0 };
                face.n = 3;
            } else {
                face.idx = .{ a, b, c, d };
                face.n = 4;
            }
            // Centroid of the face's vertices lies on its plane (the quads
            // are planar trapezoids); by symmetry its direction is the
            // plane normal.
            var sum = vec3(0, 0, 0);
            for (face.idx[0..face.n]) |i| sum += m.verts[i];
            const centroid = sum / splat(@floatFromInt(face.n));
            face.point = centroid;
            face.normal = math.normalize(centroid);
            const lambert = @max(0.0, math.dot(face.normal, light));
            const shade = 0.15 + 0.85 * lambert;
            face.level = @intFromFloat(@min(levels - 1, @floor(shade * levels)));
            m.faces[f] = face;
            f += 1;
        }
    }
    break :blk m;
};

/// Frustum half-slopes and their plane-normal lengths, sqrt(1 + s^2).
const slope_x: f32 = 0.65;
const slope_y: f32 = 0.52;
const norm_x: f32 = 1.193;
const norm_y: f32 = 1.128;

/// Flat-shaded sphere. Faces are culled in world space against the camera
/// position (same test as a view-space normal check, fewer multiplies) and
/// lit by a fixed world light, so each face's grey level is comptime; only
/// the 8-entry Pixel table depends on `rgb`.
pub fn draw_sphere(cam: *const camera.Camera, b: math.Mat3, centre: Vec3, radius: f32, rgb: [3]u8) void {
    const vc = cam.to_view(b, centre);
    // Whole-sphere frustum rejection.
    if (vc[2] < clip.near - radius) return;
    if (@abs(vc[0]) - slope_x * vc[2] > norm_x * radius) return;
    if (@abs(vc[1]) - slope_y * vc[2] > norm_y * radius) return;

    var pal: [levels]cart.Pixel = undefined;
    for (&pal, 0..) |*p, l| {
        const k: u32 = l + 1;
        p.* = .from_color(.rgb(((@as(u32, rgb[0]) * k) >> 3) << 16 |
            ((@as(u32, rgb[1]) * k) >> 3) << 8 |
            ((@as(u32, rgb[2]) * k) >> 3)));
    }

    // Rows of b scaled by the radius: view = vc + rb.apply(unit vertex).
    const rb: math.Mat3 = .{ .r = .{ b.r[0] * splat(radius), b.r[1] * splat(radius), b.r[2] * splat(radius) } };
    var vv: [vert_count]Vec3 = undefined;
    for (&vv, sphere.verts) |*o, u| o.* = vc + rb.apply(u);

    const rel = centre - cam.pos;
    for (sphere.faces) |face| {
        // Visible when the eye is on the outer side of the face plane.
        const normal: Vec3 = face.normal;
        const point: Vec3 = face.point;
        if (math.dot(normal, rel + point * splat(radius)) >= 0) continue;
        var pv: [4]raster.Vertex = undefined;
        for (0..4) |i| pv[i] = .{ .p = vv[face.idx[i]], .u = 0, .v = 0 };
        raster.draw_polygon(pv[0..face.n], .{ .flat = pal[face.level] });
    }
}

/// Square textured quad centred on `centre`, 2 * half_size across, turned
/// by `angle` about the vertical axis (angle 0 faces +z, towards a camera
/// south of it looking north). Two-sided: seen from behind, u is mirrored so the image
/// still reads left to right (the logo is not shown backwards). `y_scale`
/// squashes the height (the maze rising at the start).
pub fn draw_spin_quad(cam: *const camera.Camera, b: math.Mat3, centre: Vec3, half_size: f32, y_scale: f32, angle: math.Angle, tex: *const textures.Texture) void {
    const ca = math.cos_angle(angle);
    const sa = math.sin_angle(angle);
    const r = vec3(ca, 0, sa) * splat(half_size);
    const up = vec3(0, half_size * y_scale, 0);
    // Front normal r x up: +z at angle 0.
    const n = vec3(-sa, 0, ca);
    const seen_front = math.dot(n, cam.pos - centre) >= 0;
    const m = tex.uv_max;
    const ul: f32 = if (seen_front) 0 else m;
    const ur: f32 = if (seen_front) m else 0;
    const v = [4]raster.Vertex{
        .{ .p = cam.to_view(b, centre - r - up), .u = ul, .v = m },
        .{ .p = cam.to_view(b, centre + r - up), .u = ur, .v = m },
        .{ .p = cam.to_view(b, centre + r + up), .u = ur, .v = 0 },
        .{ .p = cam.to_view(b, centre - r + up), .u = ul, .v = 0 },
    };
    raster.draw_polygon(&v, .{ .sprite = tex });
}
