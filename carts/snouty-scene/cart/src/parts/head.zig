//! Part 8, Snouty head (6 bars, 12 s): a flat-shaded low-poly Snouty head
//! tumbling in space over a dark dithered gradient and a slow starfield.
//! The mesh is a const table (74 vertices, 93 triangles, written by
//! tools/gen_head_mesh.py between the mesh markers below): a 6-segment
//! ellipsoid skull, a three-ring snout curving down to a pink nose tip,
//! two ears with dark insides, two eyes built as raised quads (grey
//! glasses rim, white lens, dark pupil) and a red tongue that flicks out
//! on the third beat of every bar, in the colours of the Snouty sprite.
//!
//! Per frame, in f32: a steady spin about the vertical axis with pitch
//! and roll swaying at other rates, a gentle bob, a fly-in from far away
//! over the first 100 frames and a 3% scale pulse on every beat; one
//! perspective divide per vertex, results rounded
//! to 28.4 fixed point. Per face: back-face cull on the integer screen
//! winding, one directional light plus ambient quantised to 16 shades per
//! material (precomputed at init), mean-depth key. Visible faces are
//! insertion-sorted far to near (painter's algorithm, no z buffer; the eye
//! decals get a depth bias so they draw over the skull facet under them)
//! and filled column by column with 16.16 edge stepping, one memset per
//! column run, which suits the column-major framebuffer. Pixel coverage is
//! all integer, so wasm and thumb agree bit for bit.
const std = @import("std");
const cart = @import("cart-api");
const math = @import("../math.zig");
const palette = @import("../palette.zig");
const fx = @import("../fx.zig");
const rng = @import("../rng.zig");

pub const name: []const u8 = "Snouty head";

// ---------------------------------------------------------------------------
// Tunables.

/// Focal length in pixels and camera distance to the head's centre once it
/// has flown in; the mesh radius is 1.4, so it spans about 100 px.
const focal: f32 = 110.0;
const distance: f32 = 3.2;
/// Start distance of the fly-in and its length in frames.
const fly_from: f32 = 14.0;
const fly_frames: f32 = 100.0;
/// Spin rate in turns per frame; pitch and roll sway (amplitude in turns,
/// period in frames).
const yaw_rate: f32 = 1.0 / 330.0;
/// Start yaw: the fly-in turns from the left profile to the face (0 is the
/// right profile, 0.75 faces the viewer).
const yaw0: f32 = 0.62;
const pitch_amp: f32 = 0.09;
const pitch_period: f32 = 533.0;
const roll_amp: f32 = 0.05;
const roll_period: f32 = 777.0;
/// Tongue flick: starts `tongue_at` frames into every bar, lasts
/// `tongue_frames`.
const tongue_at = 60;
const tongue_frames = 24;
/// Bob amplitude (world units) and period (frames).
const bob_amp: f32 = 0.10;
const bob_period: f32 = 240.0;
/// Beat pulse: +3% on the beat, decaying over 6 frames.
const pulse_amp: f32 = 0.03;
const pulse_frames = 6;
const frames_per_beat = 30;
/// Light direction (toward the light, world space, +z toward the viewer).
const light = [3]f32{ -0.48, 0.58, 0.66 };
const ambient: u32 = 90; // 0.35 of 256
const star_count = 40;

// ---------------------------------------------------------------------------
// Materials.

const mat_count = 8;
const mat_rgb = [mat_count]u32{
    0x8e42de, // head: Snouty purple
    0xa864ec, // snout: lighter purple
    0x3a1850, // ear insides
    0xf4efdf, // eye white
    0x17121e, // pupil
    0xe070c8, // nose tip
    0x5a5068, // glasses rim
    0xee453c, // tongue
};
/// Depth bias (world units, toward the viewer) per material: the eye
/// decals sit just above a big skull facet whose mean depth can be nearer.
const mat_bias = [mat_count]f32{ 0, 0, 0, 0.35, 0.45, 0, 0.30, 0 };
const levels = 16;

// ---------------------------------------------------------------------------
// State.

var shades: [mat_count][levels]cart.Pixel = undefined;
var normals: [faces.len][3]f32 = undefined;
var proj: [vertices.len]Point = undefined;
var depth: [vertices.len]f32 = undefined;
var order: [faces.len]Visible = undefined;

const Star = struct { x: u16, y: u8, speed: u8, bright: u8 };
var stars: [star_count]Star = undefined;
var star_px: [8]cart.Pixel = undefined;
/// Where the tongue tip (the last vertex) retracts to: its roots' centre.
var tongue_root: [3]f32 = undefined;
const tongue_tip = vertices.len - 1;

/// A screen point in 28.4 fixed point (1/16 pixel).
pub const Point = struct { x: i32, y: i32 };
/// A visible face: sort key (larger = farther), face index, its shade.
pub const Visible = struct { key: i32, face: u8, px: cart.Pixel };

pub fn init() void {
    for (&shades, mat_rgb) |*row, rgb| {
        for (row, 0..) |*s, l| {
            const f: u32 = ambient + ((256 - ambient) * @as(u32, @intCast(l))) / (levels - 1);
            s.* = palette.pixel(palette.mix_rgb(0, rgb, f));
        }
    }
    for (&normals, faces) |*n, f| {
        const a = vertices[f[0]];
        const b = vertices[f[1]];
        const c = vertices[f[2]];
        const u = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
        const v = [3]f32{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
        var x = [3]f32{ u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0] };
        const inv = 1.0 / @sqrt(x[0] * x[0] + x[1] * x[1] + x[2] * x[2]);
        for (&x) |*e| e.* *= inv;
        n.* = x;
    }
    for (0..3) |i| {
        const r = vertices[tongue_tip - 3 .. tongue_tip];
        tongue_root[i] = (r[0][i] + r[1][i] + r[2][i]) / 3.0;
    }
    for (&star_px, 0..) |*p, i| {
        const f: u32 = @intCast(40 + i * 30);
        p.* = palette.pixel(palette.mix_rgb(0x0c0a1c, 0xc8c0f0, f));
    }
}

pub fn enter() void {
    var r = rng.Xorshift.init(0x5a0a7e);
    for (&stars) |*s| {
        s.* = .{
            .x = @intCast(r.below(160 * 64)),
            .y = @intCast(r.below(128)),
            .speed = @intCast(4 + r.below(20)),
            .bright = @intCast(r.below(8)),
        };
    }
}

pub fn render(t: u32, fb: cart.FramebufferPtr) void {
    background(t, fb);

    const tf: f32 = @floatFromInt(t);
    const m = rotation(
        math.fract(yaw0 + tf * yaw_rate),
        pitch_amp * math.sin_turns(tf / pitch_period),
        roll_amp * math.sin_turns(tf / roll_period),
    );
    const beat = t % frames_per_beat;
    var scale: f32 = 1.0;
    if (beat < pulse_frames) scale += pulse_amp * @as(f32, @floatFromInt(pulse_frames - beat)) / pulse_frames;
    const bob = bob_amp * math.sin_turns(tf / bob_period);
    var dist = distance;
    if (tf < fly_frames) {
        const k = 1.0 - tf / fly_frames;
        dist += (fly_from - distance) * k * k * k;
    }

    // The tongue: out and back over tongue_frames, hidden otherwise.
    const in_bar = t % 120;
    const licking = in_bar >= tongue_at and in_bar < tongue_at + tongue_frames;
    var tip = vertices[tongue_tip];
    if (licking) {
        const k = math.sin_turns(@as(f32, @floatFromInt(in_bar - tongue_at)) / (2 * tongue_frames));
        for (&tip, tongue_root) |*e, r| e.* = r + (e.* - r) * k;
    }

    // Vertices: rotate, scale, bob, project to 28.4.
    for (vertices, &proj, &depth, 0..) |vc, *p, *d, vi| {
        const v = if (vi == tongue_tip) tip else vc;
        const x = (m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2]) * scale;
        const y = (m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2]) * scale + bob;
        const z = (m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2]) * scale;
        const zd = dist - z;
        const k = focal * 16.0 / zd;
        p.* = .{ .x = to_fixed(80.0 * 16.0 + x * k), .y = to_fixed(64.0 * 16.0 - y * k) };
        d.* = zd;
    }

    // Faces: cull, light, key.
    var n: usize = 0;
    const lv = normalized(light);
    const drawn = if (licking) faces.len else faces.len - tongue_faces;
    for (faces[0..drawn], normals[0..drawn], 0..) |f, nn, i| {
        const a = proj[f[0]];
        const b = proj[f[1]];
        const c = proj[f[2]];
        if (!front_facing(a, b, c)) continue;
        const wx = m[0][0] * nn[0] + m[0][1] * nn[1] + m[0][2] * nn[2];
        const wy = m[1][0] * nn[0] + m[1][1] * nn[1] + m[1][2] * nn[2];
        const wz = m[2][0] * nn[0] + m[2][1] * nn[1] + m[2][2] * nn[2];
        const l = wx * lv[0] + wy * lv[1] + wz * lv[2];
        const level: usize = if (l <= 0) 0 else @min(levels - 1, @as(usize, @intFromFloat(l * levels)));
        const zsum = depth[f[0]] + depth[f[1]] + depth[f[2]] - 3.0 * mat_bias[f[3]];
        order[n] = .{ .key = @intFromFloat(zsum * 1024.0), .face = @intCast(i), .px = shades[f[3]][level] };
        n += 1;
    }
    sort_far_to_near(order[0..n]);
    for (order[0..n]) |e| {
        const f = faces[e.face];
        fill_triangle(fb, proj[f[0]], proj[f[1]], proj[f[2]], e.px);
    }
}

fn background(t: u32, fb: cart.FramebufferPtr) void {
    // Slow drift of the bottom colour between violet and teal-blue.
    const s = math.sin_turns(@as(f32, @floatFromInt(t)) / 900.0);
    const f: u32 = @intFromFloat(128.0 + 127.0 * s);
    const top: u32 = 0x010106;
    const bottom = palette.mix_rgb(0x1c0a30, 0x081a34, f);
    // A 2x2 ordered dither hides the RGB565 bands of such a dark ramp:
    // even and odd columns get their own copy, rows alternate thresholds.
    var cols: [2][fx.height]cart.Pixel align(4) = undefined;
    for (0..fx.height) |y| {
        const c = palette.mix_rgb(top, bottom, @intCast((y * 256) / (fx.height - 1)));
        cols[0][y] = dithered(c, bayer[y & 1]);
        cols[1][y] = dithered(c, bayer[2 + (y & 1)]);
    }
    for (fb, 0..) |*col, x| col.* = cols[x & 1];
    for (stars) |st| {
        // x in 1/64 px, drifting left, wrapping over the 160 px width.
        const wrap = fx.width * 64;
        const x = (@as(u32, st.x) + wrap - (t * st.speed) % wrap) % wrap;
        fb[x >> 6][st.y] = star_px[st.bright];
    }
}

/// 2x2 Bayer thresholds in quarters of a quantisation step.
const bayer = [4]u32{ 0, 2, 3, 1 };

/// 0x00RRGGBB to a pixel, adding `q` quarters of the RGB565 step (8 for
/// red and blue, 4 for green) before truncation.
fn dithered(rgb: u32, q: u32) cart.Pixel {
    const r: u32 = @min(255, ((rgb >> 16) & 0xff) + 2 * q);
    const g: u32 = @min(255, ((rgb >> 8) & 0xff) + q);
    const b: u32 = @min(255, (rgb & 0xff) + 2 * q);
    return palette.pixel((r << 16) | (g << 8) | b);
}

inline fn to_fixed(v: f32) i32 {
    // Truncation of a positive value is floor; +0.5 rounds to nearest.
    return @as(i32, @intFromFloat(v + 65536.5)) - 65536;
}

fn normalized(v: [3]f32) [3]f32 {
    const inv = 1.0 / @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return .{ v[0] * inv, v[1] * inv, v[2] * inv };
}

/// Row-major Rz(roll) * Rx(pitch) * Ry(yaw), angles in turns.
fn rotation(yaw: f32, pitch: f32, roll: f32) [3][3]f32 {
    const cy = math.cos_turns(yaw);
    const sy = math.sin_turns(yaw);
    const cp = math.cos_turns(pitch);
    const sp = math.sin_turns(pitch);
    const cr = math.cos_turns(roll);
    const sr = math.sin_turns(roll);
    const ry = [3][3]f32{ .{ cy, 0, sy }, .{ 0, 1, 0 }, .{ -sy, 0, cy } };
    const rx = [3][3]f32{ .{ 1, 0, 0 }, .{ 0, cp, -sp }, .{ 0, sp, cp } };
    const rz = [3][3]f32{ .{ cr, -sr, 0 }, .{ sr, cr, 0 }, .{ 0, 0, 1 } };
    return mat_mul(rz, mat_mul(rx, ry));
}

fn mat_mul(a: [3][3]f32, b: [3][3]f32) [3][3]f32 {
    var out: [3][3]f32 = undefined;
    for (0..3) |i| for (0..3) |j| {
        out[i][j] = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j];
    };
    return out;
}

/// Counter-clockwise in world space (y up) is clockwise on screen (y down):
/// a negative screen cross product faces the viewer.
pub fn front_facing(a: Point, b: Point, c: Point) bool {
    const cross = @as(i64, b.x - a.x) * (c.y - a.y) - @as(i64, b.y - a.y) * (c.x - a.x);
    return cross < 0;
}

/// Insertion sort, larger key (farther) first; stable.
pub fn sort_far_to_near(list: []Visible) void {
    var i: usize = 1;
    while (i < list.len) : (i += 1) {
        const e = list[i];
        var j = i;
        while (j > 0 and list[j - 1].key < e.key) : (j -= 1) list[j] = list[j - 1];
        list[j] = e;
    }
}

/// One triangle edge walked column by column: y (16.16) at the current
/// column's centre and its per-column step. Every edge starts at the
/// first column right of its left end, so two triangles sharing an edge
/// step it identically and leave no gap or overlap.
const Edge = struct {
    y: i32,
    step: i32,

    fn init(p: Point, q: Point, x0: i32) Edge {
        const dx: i64 = q.x - p.x; // > 0 by the caller
        const dy: i64 = q.y - p.y;
        const xc: i64 = @as(i64, x0) * 16 + 8 - p.x;
        const y = (@as(i64, p.y) << 12) + @divFloor((xc * dy) << 12, dx);
        const step = @divFloor(dy << 16, dx);
        return .{ .y = clamp_i32(y), .step = clamp_i32(step) };
    }
};

inline fn clamp_i32(v: i64) i32 {
    return @intCast(std.math.clamp(v, -(1 << 30), 1 << 30));
}

/// First pixel column whose centre is at or right of x (28.4).
inline fn col_ceil(x: i32) i32 {
    return (x + 7) >> 4;
}

/// First pixel row whose centre is at or below y (16.16).
inline fn row_ceil(y: i32) i32 {
    return (y + 0x7fff) >> 16;
}

/// Fills the pixels whose centres lie inside triangle abc (28.4 screen
/// points, any winding), clipped to the screen: column x covers centres
/// in [left, right), row y covers centres in [top, bottom).
pub fn fill_triangle(fb: *cart.Framebuffer, a: Point, b: Point, c: Point, px: cart.Pixel) void {
    var v0 = a;
    var v1 = b;
    var v2 = c;
    if (before(v1, v0)) std.mem.swap(Point, &v0, &v1);
    if (before(v2, v1)) std.mem.swap(Point, &v1, &v2);
    if (before(v1, v0)) std.mem.swap(Point, &v0, &v1);
    const xs = col_ceil(v0.x);
    const xm = col_ceil(v1.x);
    const xe = col_ceil(v2.x);
    if (xs >= xe) return;
    var long = Edge.init(v0, v2, xs);
    if (xs < xm) {
        var e = Edge.init(v0, v1, xs);
        columns(fb, xs, xm, &long, &e, px);
    }
    if (xm < xe) {
        var e = Edge.init(v1, v2, xm);
        columns(fb, xm, xe, &long, &e, px);
    }
}

inline fn before(p: Point, q: Point) bool {
    return p.x < q.x or (p.x == q.x and p.y < q.y);
}

fn columns(fb: *cart.Framebuffer, x0: i32, x1: i32, long: *Edge, e: *Edge, px: cart.Pixel) void {
    var x = x0;
    // Columns left of the screen: step the edges past them in one go.
    if (x < 0) {
        const k: i32 = @min(0, x1) - x;
        long.y +%= long.step *% k;
        e.y +%= e.step *% k;
        x += k;
    }
    const end = @min(x1, fx.width);
    while (x < end) : (x += 1) {
        const top = @min(long.y, e.y);
        const bot = @max(long.y, e.y);
        const y0: usize = @intCast(std.math.clamp(row_ceil(top), 0, fx.height));
        const y1: usize = @intCast(std.math.clamp(row_ceil(bot), 0, fx.height));
        if (y0 < y1) @memset(fb[@intCast(x)][y0..y1], px);
        long.y +%= long.step;
        e.y +%= e.step;
    }
}

// ---------------------------------------------------------------------------
// Mesh, from tools/gen_head_mesh.py (snout along +x, y up, radius 1.4).
// mesh-begin
// 74 vertices, 93 faces; the last vertex is the tongue tip, the last
// three faces the tongue.
pub const vertices = [_][3]f32{
    .{ -1.2722, -0.0126, 0.0000 },
    .{ -1.0601, -0.0126, 0.4567 },
    .{ -1.0601, 0.4069, 0.2284 },
    .{ -1.0601, 0.4069, -0.2284 },
    .{ -1.0601, -0.0126, -0.4567 },
    .{ -1.0601, -0.4321, -0.2284 },
    .{ -1.0601, -0.4321, 0.2284 },
    .{ -0.5480, -0.0126, 0.6459 },
    .{ -0.5480, 0.5806, 0.3230 },
    .{ -0.5480, 0.5806, -0.3230 },
    .{ -0.5480, -0.0126, -0.6459 },
    .{ -0.5480, -0.6059, -0.3230 },
    .{ -0.5480, -0.6059, 0.3230 },
    .{ -0.0360, -0.0126, 0.4567 },
    .{ -0.0360, 0.4069, 0.2284 },
    .{ -0.0360, 0.4069, -0.2284 },
    .{ -0.0360, -0.0126, -0.4567 },
    .{ -0.0360, -0.4321, -0.2284 },
    .{ -0.0360, -0.4321, 0.2284 },
    .{ 0.1957, -0.1301, 0.3230 },
    .{ 0.1957, 0.1751, 0.1615 },
    .{ 0.1957, 0.1751, -0.1615 },
    .{ 0.1957, -0.1301, -0.3230 },
    .{ 0.1957, -0.4352, -0.1615 },
    .{ 0.1957, -0.4352, 0.1615 },
    .{ 0.7046, -0.2573, 0.2544 },
    .{ 0.7046, -0.0200, 0.1272 },
    .{ 0.7046, -0.0200, -0.1272 },
    .{ 0.7046, -0.2573, -0.2544 },
    .{ 0.7046, -0.4946, -0.1272 },
    .{ 0.7046, -0.4946, 0.1272 },
    .{ 1.1156, -0.3845, 0.2055 },
    .{ 1.1156, -0.1980, 0.1028 },
    .{ 1.1156, -0.1980, -0.1028 },
    .{ 1.1156, -0.3845, -0.2055 },
    .{ 1.1156, -0.5710, -0.1028 },
    .{ 1.1156, -0.5710, 0.1028 },
    .{ 1.2722, -0.3649, 0.0000 },
    .{ -0.8346, 0.5928, 0.1542 },
    .{ -0.8346, 0.2545, 0.5343 },
    .{ -1.0890, 0.3141, 0.2468 },
    .{ -1.1560, 0.6059, 0.5065 },
    .{ -0.8346, 0.2545, -0.5343 },
    .{ -0.8346, 0.5928, -0.1542 },
    .{ -1.0890, 0.3141, -0.2468 },
    .{ -1.1560, 0.6059, -0.5065 },
    .{ 0.0340, 0.2338, 0.4287 },
    .{ -0.1953, 0.0557, 0.6412 },
    .{ -0.4247, 0.3326, 0.6257 },
    .{ -0.1953, 0.5107, 0.4132 },
    .{ -0.0018, 0.2562, 0.4732 },
    .{ -0.1826, 0.1157, 0.6408 },
    .{ -0.3635, 0.3340, 0.6285 },
    .{ -0.1826, 0.4744, 0.4610 },
    .{ -0.0508, 0.2813, 0.5234 },
    .{ -0.1302, 0.2196, 0.5970 },
    .{ -0.2096, 0.3155, 0.5916 },
    .{ -0.1302, 0.3771, 0.5180 },
    .{ 0.0340, 0.2338, -0.4287 },
    .{ -0.1953, 0.0557, -0.6412 },
    .{ -0.4247, 0.3326, -0.6257 },
    .{ -0.1953, 0.5107, -0.4132 },
    .{ -0.0018, 0.2562, -0.4732 },
    .{ -0.1826, 0.1157, -0.6408 },
    .{ -0.3635, 0.3340, -0.6285 },
    .{ -0.1826, 0.4744, -0.4610 },
    .{ -0.0508, 0.2813, -0.5234 },
    .{ -0.1302, 0.2196, -0.5970 },
    .{ -0.2096, 0.3155, -0.5916 },
    .{ -0.1302, 0.3771, -0.5180 },
    .{ 1.1548, -0.4726, 0.1077 },
    .{ 1.1548, -0.4726, -0.1077 },
    .{ 1.1267, -0.5663, 0.0000 },
    .{ 1.9047, -0.6975, 0.0000 },
};

/// a, b, c (counter-clockwise seen from outside), material.
pub const faces = [_][4]u8{
    .{ 0, 1, 2, 0 },
    .{ 0, 2, 3, 0 },
    .{ 0, 3, 4, 0 },
    .{ 0, 4, 5, 0 },
    .{ 0, 5, 6, 0 },
    .{ 0, 6, 1, 0 },
    .{ 1, 8, 2, 0 },
    .{ 1, 7, 8, 0 },
    .{ 2, 9, 3, 0 },
    .{ 2, 8, 9, 0 },
    .{ 3, 10, 4, 0 },
    .{ 3, 9, 10, 0 },
    .{ 4, 11, 5, 0 },
    .{ 4, 10, 11, 0 },
    .{ 5, 12, 6, 0 },
    .{ 5, 11, 12, 0 },
    .{ 6, 7, 1, 0 },
    .{ 6, 12, 7, 0 },
    .{ 7, 14, 8, 0 },
    .{ 7, 13, 14, 0 },
    .{ 8, 15, 9, 0 },
    .{ 8, 14, 15, 0 },
    .{ 9, 16, 10, 0 },
    .{ 9, 15, 16, 0 },
    .{ 10, 17, 11, 0 },
    .{ 10, 16, 17, 0 },
    .{ 11, 18, 12, 0 },
    .{ 11, 17, 18, 0 },
    .{ 12, 13, 7, 0 },
    .{ 12, 18, 13, 0 },
    .{ 13, 20, 14, 0 },
    .{ 13, 19, 20, 0 },
    .{ 14, 21, 15, 0 },
    .{ 14, 20, 21, 0 },
    .{ 15, 22, 16, 0 },
    .{ 15, 21, 22, 0 },
    .{ 16, 23, 17, 0 },
    .{ 16, 22, 23, 0 },
    .{ 17, 24, 18, 0 },
    .{ 17, 23, 24, 0 },
    .{ 18, 19, 13, 0 },
    .{ 18, 24, 19, 0 },
    .{ 19, 26, 20, 1 },
    .{ 19, 25, 26, 1 },
    .{ 20, 27, 21, 1 },
    .{ 20, 26, 27, 1 },
    .{ 21, 28, 22, 1 },
    .{ 21, 27, 28, 1 },
    .{ 22, 29, 23, 1 },
    .{ 22, 28, 29, 1 },
    .{ 23, 30, 24, 1 },
    .{ 23, 29, 30, 1 },
    .{ 24, 25, 19, 1 },
    .{ 24, 30, 25, 1 },
    .{ 25, 32, 26, 1 },
    .{ 25, 31, 32, 1 },
    .{ 26, 33, 27, 1 },
    .{ 26, 32, 33, 1 },
    .{ 27, 34, 28, 1 },
    .{ 27, 33, 34, 1 },
    .{ 28, 35, 29, 1 },
    .{ 28, 34, 35, 1 },
    .{ 29, 36, 30, 1 },
    .{ 29, 35, 36, 1 },
    .{ 30, 31, 25, 1 },
    .{ 30, 36, 31, 1 },
    .{ 37, 32, 31, 5 },
    .{ 37, 33, 32, 5 },
    .{ 37, 34, 33, 5 },
    .{ 37, 35, 34, 5 },
    .{ 37, 36, 35, 5 },
    .{ 37, 31, 36, 5 },
    .{ 38, 41, 39, 2 },
    .{ 39, 41, 40, 0 },
    .{ 40, 41, 38, 0 },
    .{ 42, 45, 43, 2 },
    .{ 43, 45, 44, 0 },
    .{ 44, 45, 42, 0 },
    .{ 46, 48, 47, 6 },
    .{ 46, 49, 48, 6 },
    .{ 50, 52, 51, 3 },
    .{ 50, 53, 52, 3 },
    .{ 54, 56, 55, 4 },
    .{ 54, 57, 56, 4 },
    .{ 58, 59, 60, 6 },
    .{ 58, 60, 61, 6 },
    .{ 62, 63, 64, 3 },
    .{ 62, 64, 65, 3 },
    .{ 66, 67, 68, 4 },
    .{ 66, 68, 69, 4 },
    .{ 70, 73, 71, 7 },
    .{ 71, 73, 72, 7 },
    .{ 72, 73, 70, 7 },
};
pub const tongue_faces = 3;
// mesh-end

// ---------------------------------------------------------------------------
// Host tests.

fn pt(x: f32, y: f32) Point {
    return .{ .x = to_fixed(x * 16), .y = to_fixed(y * 16) };
}

fn count(fb: *const cart.Framebuffer, px: cart.Pixel) usize {
    var nn: usize = 0;
    for (fb) |col| for (col) |q| {
        if (q == px) nn += 1;
    };
    return nn;
}

test "head: column raster of a known triangle" {
    var fb: cart.Framebuffer align(cart.framebuffer_alignment) = undefined;
    const bg: cart.Pixel = .from_color(.{ .r = 0, .g = 0, .b = 0 });
    const ink: cart.Pixel = .from_color(.{ .r = 31, .g = 0, .b = 0 });
    fx.clear(&fb, bg);
    // Right triangle with 8 px legs at (10, 20): pixel (u, v) has its
    // centre inside when u + v + 1 < 8, the 28 pixels with u + v <= 6.
    fill_triangle(&fb, pt(10, 20), pt(18, 20), pt(10, 28), ink);
    try std.testing.expectEqual(@as(usize, 28), count(&fb, ink));
    for (0..8) |u| for (0..8) |v| {
        const want = if (u + v <= 6) ink else bg;
        try std.testing.expectEqual(want, fb[10 + u][20 + v]);
    };
    // Winding does not matter.
    fx.clear(&fb, bg);
    fill_triangle(&fb, pt(10, 28), pt(18, 20), pt(10, 20), ink);
    try std.testing.expectEqual(@as(usize, 28), count(&fb, ink));
}

test "head: shared edges leave no gap and no overlap, clipping is safe" {
    var fb: cart.Framebuffer align(cart.framebuffer_alignment) = undefined;
    const bg: cart.Pixel = .from_color(.{ .r = 0, .g = 0, .b = 0 });
    const ink_a: cart.Pixel = .from_color(.{ .r = 31, .g = 0, .b = 0 });
    const ink_b: cart.Pixel = .from_color(.{ .r = 0, .g = 0, .b = 31 });
    const q = [4]Point{ pt(3.3, 2.1), pt(61.7, 5.6), pt(57.2, 43.4), pt(0.8, 39.9) };
    fx.clear(&fb, bg);
    fill_triangle(&fb, q[0], q[1], q[2], ink_a);
    const na = count(&fb, ink_a);
    fx.clear(&fb, bg);
    fill_triangle(&fb, q[0], q[2], q[3], ink_b);
    const nb = count(&fb, ink_b);
    fx.clear(&fb, bg);
    fill_triangle(&fb, q[0], q[1], q[2], ink_a);
    fill_triangle(&fb, q[0], q[2], q[3], ink_b);
    try std.testing.expectEqual(na + nb, count(&fb, ink_a) + count(&fb, ink_b));
    // The quad's area is 2182 px.
    var inside: usize = 0;
    for (0..fx.width) |x| for (0..fx.height) |y| {
        if (fb[x][y] != bg) inside += 1;
    };
    try std.testing.expect(inside > 2100 and inside < 2260);
    // Far off-screen vertices clip without crashing and fill the screen.
    fx.clear(&fb, bg);
    fill_triangle(&fb, pt(-400, -300), pt(700, -300), pt(-400, 900), ink_a);
    try std.testing.expectEqual(@as(usize, fx.width * fx.height), count(&fb, ink_a));
}

test "head: sort far to near and back-face winding" {
    var list = [_]Visible{
        .{ .key = 5, .face = 0, .px = @bitCast(@as(u16, 0)) },
        .{ .key = 9, .face = 1, .px = @bitCast(@as(u16, 0)) },
        .{ .key = -2, .face = 2, .px = @bitCast(@as(u16, 0)) },
        .{ .key = 9, .face = 3, .px = @bitCast(@as(u16, 0)) },
        .{ .key = 7, .face = 4, .px = @bitCast(@as(u16, 0)) },
    };
    sort_far_to_near(&list);
    const want = [_]u8{ 1, 3, 4, 0, 2 };
    for (list, want) |e, w| try std.testing.expectEqual(w, e.face);
    // Screen y points down: (0,0) (0,10) (10,0) is counter-clockwise on
    // screen, so clockwise in y-up world terms: back-facing.
    try std.testing.expect(front_facing(pt(0, 0), pt(10, 0), pt(0, 10)) == false);
    try std.testing.expect(front_facing(pt(0, 0), pt(0, 10), pt(10, 0)));
}

test "head: mesh indices and materials" {
    for (faces) |f| {
        for (f[0..3]) |i| try std.testing.expect(i < vertices.len);
        try std.testing.expect(f[3] < mat_count);
    }
    try std.testing.expect(faces.len <= 96 and vertices.len <= 80);
}
