//! The mesh pipeline (SPEC.md section 4). Per frame, for the current mesh:
//!
//! 1. Vertices: REACH and SHOCKWAVE push each base vertex along its base
//!    normal, TWIST turns it about the object's y axis by an angle that
//!    grows with height, then the rotation and scale take it to eye space
//!    (right-handed, +z toward the camera), JELLY shears and squashes it
//!    about the mesh centre, the translation places it, and the
//!    perspective divide gives a 28.4 screen point and a depth.
//! 2. Faces: the eye-space cross product (accumulated into vertex normals
//!    for Gouraud meshes), back-face cull on the integer screen winding,
//!    and a bucket on mean depth (painter's order without a sort: buckets
//!    far to near, O(faces)).
//! 3. Light: ambient + diffuse + a sharp specular, as an index into the
//!    material's 64-entry ramp (dark, the base colour, white), plus the
//!    punch flash; per vertex (Gouraud) or per face (flat).
//! 4. Fill far to near (raster.zig).
const std = @import("std");
const cart = @import("cart-api");
const config = @import("config.zig");
const math = @import("math.zig");
const mesh = @import("mesh.zig");
const palette = @import("palette.zig");
const raster = @import("raster.zig");
const body = @import("body.zig");

const Point = raster.Point;
const V3 = [3]f32;

pub const Params = body.Params;

const levels = config.ramp_levels;
var ramps: [mesh.max_materials][levels + 1]cart.Pixel = undefined;

var proj: [config.max_verts]Point = undefined;
var depth: [config.max_verts]f32 = undefined;
var eye: [config.max_verts]V3 = undefined;
var vnorm: [config.max_verts]V3 = undefined;
var lum: [config.max_verts]f32 = undefined;
var next: [config.max_faces]u16 = undefined;
var bucket_head: [config.sort_buckets]u16 = undefined;
const none: u16 = 0xffff;

/// Toward the light (eye space) and the half vector with the view axis.
const light: V3 = .{ -0.45, 0.55, 0.70 };
var light_n: V3 = undefined;
var half_n: V3 = undefined;

/// Faces drawn last frame (debug export, bench notes).
pub var drawn: u32 = 0;

pub fn init() void {
    light_n = mesh.normalized(light);
    half_n = mesh.normalized(mesh.add(light_n, .{ 0, 0, 1 }));
}

/// Builds the shade ramps for `m`'s materials.
pub fn set_mesh(m: *const mesh.Mesh) void {
    for (m.rgb, 0..) |rgb, mi| {
        const dark = palette.mix_rgb(0x05030c, rgb, 18);
        for (&ramps[mi], 0..) |*e, i| {
            const c = if (i <= config.ramp_base)
                palette.mix_rgb(dark, rgb, @intCast(i * 256 / config.ramp_base))
            else
                palette.mix_rgb(rgb, 0xffffff, @intCast(@min(256, (i - config.ramp_base) * 256 / (levels - 1 - config.ramp_base))));
            e.* = palette.pixel(c);
        }
    }
}

inline fn shade(n: V3, flash: f32) f32 {
    const d = @max(0.0, mesh.dot(n, light_n));
    var s = @max(0.0, mesh.dot(n, half_n));
    inline for (0..comptime std.math.log2_int(u32, config.specular_power)) |_| s *= s;
    const base: f32 = config.ramp_base;
    const l = config.ambient_index + (base - config.ambient_index) * d + (levels - 1 - base) * s + flash;
    return std.math.clamp(l, 0.0, levels - 1.05);
}

pub fn draw(fb: *cart.Framebuffer, m: *const mesh.Mesh, p: Params) void {
    const nv = m.pos.len;
    const nf = m.faces.len - if (p.optional) 0 else m.optional;
    const cx: f32 = @floatFromInt((80 + p.shake_x) * 16);
    const cy: f32 = @floatFromInt((64 + p.shake_y) * 16);
    const cam = config.rest_distance;

    // 1. Vertices.
    for (0..nv) |i| {
        const n = m.nrm[i];
        var v = m.pos[i];
        var d: f32 = 0;
        if (p.reach_amp > 0) {
            var s = @max(0.0, mesh.dot(n, p.reach_dir));
            inline for (0..comptime std.math.log2_int(u32, config.reach_power)) |_| s *= s;
            d += p.reach_amp * s;
        }
        for (p.ripples) |r| {
            const u = (1.0 - mesh.dot(n, r.dir)) * 0.5;
            const x = u - r.front;
            const w: f32 = 0.3;
            if (x > -w and x < w) {
                const e = 1.0 - (x * x) / (w * w);
                d += r.amp * e * e * math.cos_turns(x * config.ripple_waves);
            }
        }
        if (d != 0) v = mesh.add(v, mesh.scale(n, d));
        if (p.twist != 0) {
            const a = p.twist * v[1] * (1.0 / (2.0 * std.math.pi));
            const c = math.cos_turns(a);
            const s = math.sin_turns(a);
            v = .{ c * v[0] + s * v[2], v[1], -s * v[0] + c * v[2] };
        }
        var e = V3{
            (p.rot[0][0] * v[0] + p.rot[0][1] * v[1] + p.rot[0][2] * v[2]) * p.scale,
            (p.rot[1][0] * v[0] + p.rot[1][1] * v[1] + p.rot[1][2] * v[2]) * p.scale,
            (p.rot[2][0] * v[0] + p.rot[2][1] * v[1] + p.rot[2][2] * v[2]) * p.scale,
        };
        e[0] += p.shear * e[1];
        const across = 1.0 - 0.5 * p.squash;
        e = .{ e[0] * across + p.pos[0], e[1] * (1.0 + p.squash) + p.pos[1], e[2] * across + p.pos[2] };
        eye[i] = e;
        const zd = @max(0.3, cam - e[2]);
        depth[i] = zd;
        const k = config.focal * 16.0 / zd;
        proj[i] = .{ .x = to_fixed(cx + e[0] * k), .y = to_fixed(cy - e[1] * k) };
    }

    // 2. Faces: normals, cull, buckets.
    const gouraud = m.shading == .gouraud;
    if (gouraud) @memset(vnorm[0..nv], .{ 0, 0, 0 });
    @memset(&bucket_head, none);
    const zc = cam - p.pos[2];
    const zspan: f32 = 2.2 * @max(1.0, p.scale);
    const bscale = @as(f32, config.sort_buckets) / (2.0 * zspan);
    const zmin = zc - zspan;
    drawn = 0;
    for (m.faces[0..nf], 0..) |f, fi| {
        if (gouraud) {
            const n = mesh.cross(mesh.sub(eye[f[1]], eye[f[0]]), mesh.sub(eye[f[2]], eye[f[0]]));
            inline for (0..3) |k| vnorm[f[k]] = mesh.add(vnorm[f[k]], n);
        }
        if (!raster.front_facing(proj[f[0]], proj[f[1]], proj[f[2]])) continue;
        const z = (depth[f[0]] + depth[f[1]] + depth[f[2]]) * (1.0 / 3.0) - m.bias[m.mat[fi]];
        const bf = std.math.clamp((z - zmin) * bscale, 0.0, @as(f32, config.sort_buckets - 1));
        const b: usize = @intFromFloat(bf);
        next[fi] = bucket_head[b];
        bucket_head[b] = @intCast(fi);
        drawn += 1;
    }

    // 3. Vertex light (Gouraud).
    if (gouraud) {
        for (0..nv) |i| {
            const n = vnorm[i];
            const l2 = mesh.dot(n, n);
            const unit = if (l2 > 1e-20) mesh.scale(n, 1.0 / @sqrt(l2)) else V3{ 0, 0, 1 };
            lum[i] = shade(unit, p.flash);
        }
    }

    // 4. Fill far to near.
    var b: usize = config.sort_buckets;
    while (b > 0) {
        b -= 1;
        var fi = bucket_head[b];
        while (fi != none) : (fi = next[fi]) {
            const f = m.faces[fi];
            const ramp = &ramps[m.mat[fi]];
            if (gouraud) {
                raster.fill_gouraud(fb, proj[f[0]], proj[f[1]], proj[f[2]], lum[f[0]], lum[f[1]], lum[f[2]], ramp);
            } else {
                const n = mesh.normalized(mesh.cross(mesh.sub(eye[f[1]], eye[f[0]]), mesh.sub(eye[f[2]], eye[f[0]])));
                const l: usize = @intFromFloat(shade(n, p.flash) + 0.5);
                raster.fill_flat(fb, proj[f[0]], proj[f[1]], proj[f[2]], ramp[l]);
            }
        }
    }
}

inline fn to_fixed(v: f32) i32 {
    const c = std.math.clamp(v, -60000.0, 60000.0);
    return @as(i32, @intFromFloat(c + 65536.5)) - 65536;
}
