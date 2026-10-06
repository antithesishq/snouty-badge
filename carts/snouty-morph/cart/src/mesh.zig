//! The four meshes (SPEC.md section 3), generated in code at start() into
//! static pools: KNOT (a (2,3) torus knot tube, rainbow), BOING (a UV
//! sphere in a purple and white checker, after the Amiga ball), SNOUTY
//! (demosnout's head, one midpoint subdivision so it can bend) and IRIS
//! (the Antithesis Iris mark: two extruded ring arcs around a diamond).
//!
//! Object space is right-handed: x right, y up, +z toward the viewer at
//! rest. Faces are counter-clockwise seen from outside. Every mesh is
//! centred and scaled to radius 1; `nrm` holds unit base normals (the
//! deformations push vertices along them). No comptime loops: the only
//! comptime data is the head's const table.
const std = @import("std");
const config = @import("config.zig");
const math = @import("math.zig");
const head = @import("head_mesh.zig");

pub const Shading = enum { flat, gouraud };
pub const Backdrop = enum { copper, plasma, stars, ice };
pub const max_materials = 12;

pub const Mesh = struct {
    name: []const u8,
    pos: []const [3]f32,
    nrm: []const [3]f32,
    faces: []const [3]u16,
    mat: []const u8,
    /// Material colours (0xRRGGBB) and depth bias toward the viewer (the
    /// head's eye decals sit just above a big skull facet).
    rgb: []const u32,
    bias: []const f32,
    shading: Shading,
    backdrop: Backdrop,
    /// The last `optional` faces are drawn only on request (SNOUTY's tongue).
    optional: u16 = 0,
    /// Drawn size relative to radius 1 (a long thin mesh reads small).
    size: f32 = 1,
};

pub const count = 4;
pub var meshes: [count]Mesh = undefined;

/// All four meshes together (1458 vertices, 2812 faces with config.zig's
/// knobs; the mesh test checks they fit). Trimmed from 2048 / 4096 in M5:
/// the `-Dtof-fake=true` build (the sensor model and the STRIPES code)
/// overflowed the RAM window by ~2.4 KB. Raise them with the mesh knobs.
const pool_verts = 1600;
const pool_faces = 3072;
var pos_pool: [pool_verts][3]f32 = undefined;
var nrm_pool: [pool_verts][3]f32 = undefined;
var face_pool: [pool_faces][3]u16 = undefined;
var mat_pool: [pool_faces]u8 = undefined;
var used_verts: usize = 0;
var used_faces: usize = 0;

/// Builds every mesh. Call once from start().
pub fn init() void {
    used_verts = 0;
    used_faces = 0;
    meshes[0] = build_knot();
    meshes[1] = build_boing();
    meshes[2] = build_snouty();
    meshes[3] = build_iris();
}

/// Writes one mesh's vertices and faces into the pools.
const Builder = struct {
    v0: usize,
    f0: usize,
    nv: usize = 0,
    nf: usize = 0,

    fn begin() Builder {
        return .{ .v0 = used_verts, .f0 = used_faces };
    }

    fn vert(b: *Builder, p: [3]f32, n: [3]f32) u16 {
        std.debug.assert(b.v0 + b.nv < pool_verts and b.nv < config.max_verts);
        pos_pool[b.v0 + b.nv] = p;
        nrm_pool[b.v0 + b.nv] = n;
        b.nv += 1;
        return @intCast(b.nv - 1);
    }

    fn face(b: *Builder, i: u16, j: u16, k: u16, m: u8) void {
        std.debug.assert(b.f0 + b.nf < pool_faces and b.nf < config.max_faces);
        face_pool[b.f0 + b.nf] = .{ i, j, k };
        mat_pool[b.f0 + b.nf] = m;
        b.nf += 1;
    }

    /// A face wound so its normal points away from `inside`.
    fn face_out(b: *Builder, i: u16, j: u16, k: u16, m: u8, inside: [3]f32) void {
        const pa = b.at(i);
        const n = tri_normal(pa, b.at(j), b.at(k));
        const c = centroid(pa, b.at(j), b.at(k));
        const out = sub(c, inside);
        if (dot(n, out) < 0) b.face(i, k, j, m) else b.face(i, j, k, m);
    }

    fn at(b: *const Builder, i: u16) [3]f32 {
        return pos_pool[b.v0 + i];
    }

    /// Recomputes base normals from the faces (area weighted), for meshes
    /// without analytic normals.
    fn face_normals(b: *Builder) void {
        const nrm = nrm_pool[b.v0 .. b.v0 + b.nv];
        for (nrm) |*n| n.* = .{ 0, 0, 0 };
        for (face_pool[b.f0 .. b.f0 + b.nf]) |f| {
            const n = tri_normal(b.at(f[0]), b.at(f[1]), b.at(f[2]));
            for (f) |vi| {
                for (0..3) |a| nrm[vi][a] += n[a];
            }
        }
        for (nrm) |*n| n.* = normalized(n.*);
    }

    /// Centres the mesh on its bounding box and scales it to radius 1
    /// (over the vertices of the first `core_faces` faces).
    fn normalize_size(b: *Builder, core_faces: usize) f32 {
        const pos = pos_pool[b.v0 .. b.v0 + b.nv];
        var lo = [3]f32{ 1e9, 1e9, 1e9 };
        var hi = [3]f32{ -1e9, -1e9, -1e9 };
        for (face_pool[b.f0 .. b.f0 + core_faces]) |f| for (f) |vi| for (0..3) |a| {
            lo[a] = @min(lo[a], pos[vi][a]);
            hi[a] = @max(hi[a], pos[vi][a]);
        };
        const c = [3]f32{ (lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2 };
        var r: f32 = 0;
        for (face_pool[b.f0 .. b.f0 + core_faces]) |f| for (f) |vi| {
            r = @max(r, len(sub(pos[vi], c)));
        };
        const k = 1.0 / r;
        for (pos) |*q| q.* = scale(sub(q.*, c), k);
        return k;
    }

    fn finish(b: *Builder, m: Mesh) Mesh {
        used_verts = b.v0 + b.nv;
        used_faces = b.f0 + b.nf;
        var out = m;
        out.pos = pos_pool[b.v0..used_verts];
        out.nrm = nrm_pool[b.v0..used_verts];
        out.faces = face_pool[b.f0..used_faces];
        out.mat = mat_pool[b.f0..used_faces];
        return out;
    }
};

// ---------------------------------------------------------------------------
// KNOT.

const knot_rgb = [12]u32{
    0xff3050, 0xff7a28, 0xffc830, 0xb8f030, 0x40e070, 0x20d8c0,
    0x30a8ff, 0x4868ff, 0x8a48ff, 0xc840f0, 0xff40b8, 0xff4878,
};
const zero_bias: [max_materials]f32 = @splat(0);

fn knot_curve(t: f32) [3]f32 {
    // (2,3) torus knot, t in turns.
    const r = 2.0 + math.cos_turns(3.0 * t);
    return .{ r * math.cos_turns(2.0 * t), r * math.sin_turns(2.0 * t), math.sin_turns(3.0 * t) };
}

fn build_knot() Mesh {
    var b = Builder.begin();
    const segs = config.knot_segments;
    const sides = config.knot_sides;
    const tube: f32 = 0.55;
    for (0..segs) |s| {
        const t = @as(f32, @floatFromInt(s)) / segs;
        const c = knot_curve(t);
        const tangent = normalized(sub(knot_curve(t + 0.001), knot_curve(t - 0.001)));
        // The curve's xy speed never vanishes, so this frame never flips.
        const bin = normalized(cross(tangent, .{ 0, 0, 1 }));
        const nor = cross(bin, tangent);
        for (0..sides) |k| {
            const a = @as(f32, @floatFromInt(k)) / sides;
            const ca = math.cos_turns(a);
            const sa = math.sin_turns(a);
            const n = [3]f32{ ca * nor[0] + sa * bin[0], ca * nor[1] + sa * bin[1], ca * nor[2] + sa * bin[2] };
            _ = b.vert(add(c, scale(n, tube)), n);
        }
    }
    for (0..segs) |s| {
        const s1 = (s + 1) % segs;
        const m: u8 = @intCast(s * knot_rgb.len / segs);
        const inside = scale(add(knot_curve(@as(f32, @floatFromInt(s)) / segs), knot_curve(@as(f32, @floatFromInt(s1)) / segs)), 0.5);
        for (0..sides) |k| {
            const k1 = (k + 1) % sides;
            const a: u16 = @intCast(s * sides + k);
            const bb: u16 = @intCast(s1 * sides + k);
            const c: u16 = @intCast(s1 * sides + k1);
            const d: u16 = @intCast(s * sides + k1);
            b.face_out(a, bb, c, m, inside);
            b.face_out(a, c, d, m, inside);
        }
    }
    _ = b.normalize_size(b.nf);
    return b.finish(.{
        .name = "KNOT",
        .pos = &.{},
        .nrm = &.{},
        .faces = &.{},
        .mat = &.{},
        .rgb = &knot_rgb,
        .bias = &zero_bias,
        .shading = .gouraud,
        .backdrop = .copper,
    });
}

// ---------------------------------------------------------------------------
// BOING.

const boing_rgb = [2]u32{ 0x9a48e8, 0xf2eef8 };

fn build_boing() Mesh {
    var b = Builder.begin();
    const lat = config.boing_lat;
    const lon = config.boing_lon;
    const top = b.vert(.{ 0, 1, 0 }, .{ 0, 1, 0 });
    for (1..lat) |i| {
        const phi = @as(f32, @floatFromInt(i)) / (2.0 * lat);
        const y = math.cos_turns(phi);
        const r = math.sin_turns(phi);
        for (0..lon) |j| {
            const th = @as(f32, @floatFromInt(j)) / lon;
            const p = [3]f32{ r * math.cos_turns(th), y, r * math.sin_turns(th) };
            _ = b.vert(p, p);
        }
    }
    const bottom = b.vert(.{ 0, -1, 0 }, .{ 0, -1, 0 });
    const o = [3]f32{ 0, 0, 0 };
    const ring = struct {
        fn at(i: usize, j: usize) u16 {
            return @intCast(1 + (i - 1) * lon + (j % lon));
        }
    }.at;
    for (0..lat) |i| {
        for (0..lon) |j| {
            const m: u8 = @intCast(((i / 2) + (j / 2)) & 1);
            if (i == 0) {
                b.face_out(top, ring(1, j), ring(1, j + 1), m, o);
            } else if (i == lat - 1) {
                b.face_out(bottom, ring(lat - 1, j + 1), ring(lat - 1, j), m, o);
            } else {
                b.face_out(ring(i, j), ring(i + 1, j), ring(i + 1, j + 1), m, o);
                b.face_out(ring(i, j), ring(i + 1, j + 1), ring(i, j + 1), m, o);
            }
        }
    }
    return b.finish(.{
        .name = "BOING",
        .pos = &.{},
        .nrm = &.{},
        .faces = &.{},
        .mat = &.{},
        .rgb = &boing_rgb,
        .bias = &zero_bias,
        .shading = .gouraud,
        .backdrop = if (config.plasma) .plasma else .stars,
    });
}

// ---------------------------------------------------------------------------
// SNOUTY.

const snouty_rgb = [8]u32{
    0x8e42de, // head: Snouty purple
    0xa864ec, // snout
    0x3a1850, // ear insides
    0xf4efdf, // eye white
    0x17121e, // pupil
    0xe070c8, // nose tip
    0x5a5068, // glasses rim
    0xee453c, // tongue
};
/// demosnout's eye-decal bias, in its 1.4-radius units (scaled at build).
const snouty_bias_src = [8]f32{ 0, 0, 0, 0.35, 0.45, 0, 0.30, 0 };
var snouty_bias: [8]f32 = undefined;

/// Edge midpoint cache for subdivision: key (lo << 16 | hi) + 1, 0 = empty.
const cache_len = 2048;
var cache_key: [cache_len]u32 = undefined;
var cache_val: [cache_len]u16 = undefined;

fn cache_clear() void {
    @memset(&cache_key, 0);
}

fn midpoint(b: *Builder, i: u16, j: u16) u16 {
    const lo = @min(i, j);
    const hi = @max(i, j);
    const key = ((@as(u32, lo) << 16) | hi) + 1;
    var h = (key *% 2654435761) >> 21;
    while (true) : (h = (h + 1) & (cache_len - 1)) {
        if (cache_key[h] == key) return cache_val[h];
        if (cache_key[h] == 0) break;
    }
    const v = b.vert(scale(add(b.at(i), b.at(j)), 0.5), .{ 0, 0, 0 });
    cache_key[h] = key;
    cache_val[h] = v;
    return v;
}

/// Splits each face of `src` (builder vertex indices) into four, in order.
fn subdivide(b: *Builder, src: []const [4]u16, out: [][4]u16) usize {
    var n: usize = 0;
    for (src) |f| {
        const ab = midpoint(b, f[0], f[1]);
        const bc = midpoint(b, f[1], f[2]);
        const ca = midpoint(b, f[2], f[0]);
        out[n + 0] = .{ f[0], ab, ca, f[3] };
        out[n + 1] = .{ ab, f[1], bc, f[3] };
        out[n + 2] = .{ ca, bc, f[2], f[3] };
        out[n + 3] = .{ ab, bc, ca, f[3] };
        n += 4;
    }
    return n;
}

var scratch_a: [512][4]u16 = undefined;
var scratch_b: [512][4]u16 = undefined;

fn build_snouty() Mesh {
    var b = Builder.begin();
    for (head.vertices) |v| _ = b.vert(v, .{ 0, 0, 0 });
    for (head.faces, 0..) |f, i| scratch_a[i] = .{ f[0], f[1], f[2], f[3] };
    cache_clear();
    const n = subdivide(&b, scratch_a[0..head.faces.len], &scratch_b);
    for (scratch_b[0..n]) |f| b.face(f[0], f[1], f[2], @intCast(f[3]));
    const optional: u16 = head.tongue_faces * 4;
    const k = b.normalize_size(n - optional);
    b.face_normals();
    for (&snouty_bias, snouty_bias_src) |*d, s| d.* = s * 1.4 * k;
    return b.finish(.{
        .name = "SNOUTY",
        .pos = &.{},
        .nrm = &.{},
        .faces = &.{},
        .mat = &.{},
        .rgb = &snouty_rgb,
        .bias = &snouty_bias,
        .shading = .flat,
        .backdrop = .stars,
        .optional = optional,
        .size = 1.25,
    });
}

// ---------------------------------------------------------------------------
// IRIS: the mark (lib/iris_mark.zig) is a ring broken into two arcs, a
// half turn apart, around a diamond. Traced from the bitmap: arcs from 70
// to 200 degrees and from 250 to 380, inner radius 0.62, outer 1.

const iris_rgb = [2]u32{ 0xe8eaf4, 0x8e42de };

fn build_iris() Mesh {
    var b = Builder.begin();
    arc(&b, 70.0 / 360.0, 200.0 / 360.0);
    arc(&b, 250.0 / 360.0, 380.0 / 360.0);
    diamond(&b);
    _ = b.normalize_size(b.nf);
    b.face_normals();
    return b.finish(.{
        .name = "IRIS",
        .pos = &.{},
        .nrm = &.{},
        .faces = &.{},
        .mat = &.{},
        .rgb = &iris_rgb,
        .bias = &zero_bias,
        .shading = .flat,
        .backdrop = .ice,
    });
}

fn arc(b: *Builder, a0: f32, a1: f32) void {
    const segs = config.iris_arc_segments;
    const r_in: f32 = 0.62;
    const r_out: f32 = 1.0;
    const hd: f32 = 0.17;
    const base: u16 = @intCast(b.nv);
    for (0..segs + 1) |s| {
        const a = a0 + (a1 - a0) * @as(f32, @floatFromInt(s)) / segs;
        const c = math.cos_turns(a);
        const sn = math.sin_turns(a);
        _ = b.vert(.{ r_in * c, r_in * sn, hd }, .{ 0, 0, 0 });
        _ = b.vert(.{ r_out * c, r_out * sn, hd }, .{ 0, 0, 0 });
        _ = b.vert(.{ r_out * c, r_out * sn, -hd }, .{ 0, 0, 0 });
        _ = b.vert(.{ r_in * c, r_in * sn, -hd }, .{ 0, 0, 0 });
    }
    const rm = (r_in + r_out) / 2;
    for (0..segs) |s| {
        const am = a0 + (a1 - a0) * (@as(f32, @floatFromInt(s)) + 0.5) / segs;
        const inside = [3]f32{ rm * math.cos_turns(am), rm * math.sin_turns(am), 0 };
        const q: u16 = base + @as(u16, @intCast(s * 4));
        for (0..4) |side| {
            const e0: u16 = @intCast(side);
            const e1: u16 = @intCast((side + 1) % 4);
            b.face_out(q + e0, q + 4 + e0, q + 4 + e1, 0, inside);
            b.face_out(q + e0, q + 4 + e1, q + e1, 0, inside);
        }
    }
    // End caps, pushed inward for the inside point.
    for ([_]usize{ 0, segs }) |s| {
        const q: u16 = base + @as(u16, @intCast(s * 4));
        const step: f32 = if (s == 0) 0.5 else -0.5;
        const a = a0 + (a1 - a0) * (@as(f32, @floatFromInt(s)) + step) / segs;
        const inside = [3]f32{ rm * math.cos_turns(a), rm * math.sin_turns(a), 0 };
        b.face_out(q, q + 1, q + 2, 0, inside);
        b.face_out(q, q + 2, q + 3, 0, inside);
    }
}

fn diamond(b: *Builder) void {
    const rd: f32 = 0.42;
    const hz: f32 = 0.22;
    const base: u16 = @intCast(b.nv);
    _ = b.vert(.{ rd, 0, 0 }, .{ 0, 0, 0 });
    _ = b.vert(.{ 0, rd, 0 }, .{ 0, 0, 0 });
    _ = b.vert(.{ -rd, 0, 0 }, .{ 0, 0, 0 });
    _ = b.vert(.{ 0, -rd, 0 }, .{ 0, 0, 0 });
    _ = b.vert(.{ 0, 0, hz }, .{ 0, 0, 0 });
    _ = b.vert(.{ 0, 0, -hz }, .{ 0, 0, 0 });
    var n: usize = 0;
    for (0..4) |i| {
        const r0 = base + @as(u16, @intCast(i));
        const r1 = base + @as(u16, @intCast((i + 1) % 4));
        // Counter-clockwise from outside: front (+z) apex, then back.
        scratch_a[n] = .{ r0, r1, base + 4, 1 };
        scratch_a[n + 1] = .{ r1, r0, base + 5, 1 };
        n += 2;
    }
    cache_clear();
    var src: *[512][4]u16 = &scratch_a;
    var dst: *[512][4]u16 = &scratch_b;
    for (0..config.iris_diamond_levels) |_| {
        n = subdivide(b, src[0..n], dst);
        std.mem.swap(*[512][4]u16, &src, &dst);
    }
    for (src[0..n]) |f| b.face(f[0], f[1], f[2], @intCast(f[3]));
}

// ---------------------------------------------------------------------------
// Small vector helpers on [3]f32 (tables never hold @Vector).

pub fn add(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}
pub fn sub(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
pub fn scale(a: [3]f32, k: f32) [3]f32 {
    return .{ a[0] * k, a[1] * k, a[2] * k };
}
pub fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
pub fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
pub fn len(a: [3]f32) f32 {
    return @sqrt(dot(a, a));
}
pub fn normalized(a: [3]f32) [3]f32 {
    const l = len(a);
    return if (l > 1e-12) scale(a, 1.0 / l) else .{ 0, 0, 1 };
}
fn tri_normal(a: [3]f32, b: [3]f32, c: [3]f32) [3]f32 {
    return cross(sub(b, a), sub(c, a));
}
fn centroid(a: [3]f32, b: [3]f32, c: [3]f32) [3]f32 {
    return scale(add(add(a, b), c), 1.0 / 3.0);
}

// ---------------------------------------------------------------------------
// Host tests.

test "meshes: sizes, indices, unit radius, outward winding" {
    math.init_tables();
    init();
    for (meshes) |m| {
        try std.testing.expect(m.pos.len <= config.max_verts);
        try std.testing.expect(m.faces.len <= config.max_faces);
        var r: f32 = 0;
        for (m.pos) |p| r = @max(r, len(p));
        try std.testing.expect(r < 1.6);
        for (m.faces, m.mat) |f, mt| {
            for (f) |i| try std.testing.expect(i < m.pos.len);
            try std.testing.expect(mt < m.rgb.len);
        }
        for (m.nrm) |n| try std.testing.expectApproxEqAbs(@as(f32, 1), len(n), 1e-3);
        // Outward: the face normal agrees with its vertices' base normals
        // on nearly every face (subdivided flat parts may tie).
        var bad: usize = 0;
        for (m.faces) |f| {
            const n = tri_normal(m.pos[f[0]], m.pos[f[1]], m.pos[f[2]]);
            const vn = add(add(m.nrm[f[0]], m.nrm[f[1]]), m.nrm[f[2]]);
            if (dot(n, vn) <= 0) bad += 1;
        }
        try std.testing.expect(bad * 50 <= m.faces.len);
    }
    try std.testing.expectEqual(@as(usize, config.knot_segments * config.knot_sides), meshes[0].pos.len);
    try std.testing.expectEqual(@as(usize, config.boing_lon * 2 * (config.boing_lat - 1)), meshes[1].faces.len);
    try std.testing.expectEqual(@as(usize, head.faces.len * 4), meshes[2].faces.len);
    // Every mesh fits the shared pools.
    try std.testing.expect(used_verts <= pool_verts and used_faces <= pool_faces);
}
