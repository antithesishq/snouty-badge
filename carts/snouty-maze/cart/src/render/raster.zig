//! Column-major convex polygon rasterizer with a u16 z buffer.
//!
//! The framebuffer is `[x][y]`, so this is a scanline rasterizer with the
//! axes swapped: the polygon's edges are walked once to find, for every
//! screen column, the top and bottom crossing; then each column's vertical
//! span is filled with stride-1 stores into the framebuffer and z buffer.
//!
//! Attributes: 1/z, u/z and v/z are affine in screen space. Instead of
//! interpolating them along edges they are derived once per polygon from
//! the view-space plane (see `Grad`), which is exact, independent of
//! clipping and cheap (three cross products and one divide per polygon).
//! Spans are walked in segments of 8 pixels: one divide at each segment end
//! for perspective-correct u, v, affine 16.16 stepping inside, `& 31` wrap.
//!
//! Fill convention (top-left rule, axes swapped): pixel (x, y) is covered
//! when its centre (x + 0.5, y + 0.5) satisfies x_left <= cx < x_right for
//! the column range and y_top <= cy < y_bottom inside the column. Every
//! edge is evaluated from its lower-x endpoint whichever polygon owns it,
//! so shared edges give bit-identical crossings: no cracks, no double draw.
//!
//! Guard band: projected vertex coordinates stay f32 (clamping a vertex
//! would bend its edges); every value converted to an integer (column range,
//! span rows) is clamped to [-4096, 4096] and then to the screen first.
const cart = @import("cart-api");
const math = @import("../math.zig");
const clip = @import("clip.zig");
const textures = @import("textures.zig");

pub const Vertex = clip.Vertex;

pub const Fill = union(enum) {
    textured: *const textures.Texture,
    flat: cart.Pixel,
    /// Textured, palette index 0 skipped, for billboards.
    sprite: *const textures.Texture,
};

/// Horizontal FOV 66 degrees: focal length in pixels.
pub const focal: f32 = 123.2;

/// 1/z scaled by this is stored in the z buffer; near = 0.05 gives 40,960.
pub const z_scale: f32 = 2048.0;

pub var zbuf: [cart.screen_width][cart.screen_height]u16 = undefined;

const sw = cart.screen_width;
const sh = cart.screen_height;
const cx_screen: f32 = @as(f32, @floatFromInt(sw)) / 2.0;
const cy_screen: f32 = @as(f32, @floatFromInt(sh)) / 2.0;
const guard: f32 = 4096.0;

/// Frustum half-slopes (80 / focal = 0.6494, 64 / focal = 0.5195), rounded
/// up so the test only ever keeps too much.
const slope_x: f32 = 0.65;
const slope_y: f32 = 0.52;

/// Tunables.
///
/// Segment length for the perspective divide.
const seg = 8;
/// Per-column occlusion (see `Occ`). Off gives the plain z-buffer path, for
/// A/B checks that the culling changes no pixel.
const use_occlusion = true;
/// Slack, in z buffer units, on the bounds that feed the occlusion tests:
/// the span arithmetic's worst fixed-point stepping error is under one unit
/// (see `span_q_max`), so 2 is conservative; larger only culls less.
const occ_slack: u32 = 2;

/// Segment endpoints convert u, v to 16.16 (then packed to 5.11 + 5.11 for
/// the inner loop, see inner_tex); z values are 20.12 fixed point.
const uv_frac = 16;
const q_frac = 12;
/// u, v clamp in texels before conversion to 16.16 (masking makes the
/// value irrelevant beyond the wrap; this only prevents i32 overflow).
const uv_limit: f32 = 16384.0;
const q_max: f32 = 65535.0;

/// rcp[n] = 1 / (n - 1): the step scale for a run of n samples whose
/// first and last values are known. rcp[0] and rcp[1] are 0.
const rcp: [sh + 1]f32 = blk: {
    var t: [sh + 1]f32 = undefined;
    t[0] = 0;
    t[1] = 0;
    for (2..sh + 1) |i| t[i] = 1.0 / @as(f32, @floatFromInt(i - 1));
    break :blk t;
};

/// Per-column span edges for the polygon being drawn.
var col_top: [sw]f32 = undefined;
var col_bot: [sw]f32 = undefined;

/// Per-column occlusion record: every pixel of rows [top, bot) of the
/// column holds a z buffer value >= q (top >= bot: no record). Only
/// occluder draws (opaque walls, `draw_occluder`) create records, from a
/// lower bound of the z values their span left behind (written or already
/// nearer); z values only grow within a frame, so a record stays true until
/// `begin_frame`. A later span, segment or whole polygon whose rows lie
/// inside the record and whose largest possible z value is <= q would fail
/// every z test (the test is strictly greater), so skipping it changes no
/// pixel: the culling is exact, not approximate.
const Occ = struct { top: u8 = 0, bot: u8 = 0, q: u16 = 0 };
var occ: [sw]Occ = @splat(.{});

/// Frame counters, collected on wasm only (the harness reads them through
/// the debug exports below); compiled out on hardware.
const collect_stats = cart.is_wasm;
pub const Stats = struct {
    polys_in: u32 = 0,
    polys_drawn: u32 = 0,
    columns: u32 = 0,
    pixels: u32 = 0,
    /// Segments that paid the perspective divide.
    segments: u32 = 0,
    /// Textured segments skipped because every pixel failed the z test.
    skipped: u32 = 0,
    written: u32 = 0,
};
pub var stats: Stats = .{};

comptime {
    if (cart.is_wasm) {
        @export(&debug_raster_polys_in, .{ .name = "debug_raster_polys_in" });
        @export(&debug_raster_polys_drawn, .{ .name = "debug_raster_polys_drawn" });
        @export(&debug_raster_columns, .{ .name = "debug_raster_columns" });
        @export(&debug_raster_pixels, .{ .name = "debug_raster_pixels" });
        @export(&debug_raster_segments, .{ .name = "debug_raster_segments" });
        @export(&debug_raster_skipped, .{ .name = "debug_raster_skipped" });
        @export(&debug_raster_written, .{ .name = "debug_raster_written" });
    }
}
fn debug_raster_polys_in() callconv(.c) u32 {
    return stats.polys_in;
}
fn debug_raster_polys_drawn() callconv(.c) u32 {
    return stats.polys_drawn;
}
fn debug_raster_columns() callconv(.c) u32 {
    return stats.columns;
}
fn debug_raster_pixels() callconv(.c) u32 {
    return stats.pixels;
}
fn debug_raster_segments() callconv(.c) u32 {
    return stats.segments;
}
fn debug_raster_skipped() callconv(.c) u32 {
    return stats.skipped;
}
fn debug_raster_written() callconv(.c) u32 {
    return stats.written;
}

/// Clears the z buffer. Call once per frame before any draw_polygon.
pub fn begin_frame() void {
    @memset(@as(*[sw * sh]u16, @ptrCast(&zbuf)), 0);
    if (use_occlusion) @memset(&occ, .{});
    if (collect_stats) stats = .{};
}

/// Screen-space affine gradients of 1/z (scaled to z buffer units), u/z and
/// v/z (in texels): value at pixel coordinate (sx, sy) = x * sx + y * sy + o.
const Grad = struct {
    zx: f32,
    zy: f32,
    zo: f32,
    ux: f32,
    uy: f32,
    uo: f32,
    vx: f32,
    vy: f32,
    vo: f32,
};

/// Draws a convex polygon (3 or 4 view-space vertices, any winding) with
/// frustum rejection, near clipping, perspective projection and z test.
pub fn draw_polygon(verts: []const Vertex, fill: Fill) void {
    draw(verts, fill, false);
}

/// `draw_polygon` for an opaque polygon (textured or flat, not a sprite)
/// whose spans also leave per-column occlusion records for later polygons.
/// Submitting occluders nearest first makes the records most useful.
pub fn draw_occluder(verts: []const Vertex, fill: Fill) void {
    draw(verts, fill, fill != .sprite);
}

fn draw(verts: []const Vertex, fill: Fill, occluder: bool) void {
    if (verts.len < 3 or verts.len > clip.max_in) return;
    if (collect_stats) stats.polys_in += 1;
    if (outside_frustum(verts)) return;

    const g = gradients(verts) orelse return;

    var cv: [clip.max_out]Vertex = undefined;
    const n = clip.clip_near(verts, &cv);
    if (n < 3) return;

    // Project. z >= near after clipping, so the divide is safe; the values
    // may be far outside the screen and stay f32.
    var px: [clip.max_out]f32 = undefined;
    var py: [clip.max_out]f32 = undefined;
    var xmin: f32 = guard;
    var xmax: f32 = -guard;
    for (cv[0..n], 0..) |v, i| {
        const iz = 1.0 / v.p[2];
        px[i] = cx_screen + focal * v.p[0] * iz;
        py[i] = cy_screen - focal * v.p[1] * iz;
        xmin = @min(xmin, px[i]);
        xmax = @max(xmax, px[i]);
    }
    const c0 = to_index(xmin, sw);
    const c1 = to_index(xmax, sw);
    if (c0 >= c1) return;
    if (use_occlusion and hidden(&g, cv[0..n], &py, c0, c1)) return;

    // Winding: with y down, positive signed area means edges running
    // towards +x are the top edges.
    var area: f32 = 0;
    for (0..n) |i| {
        const j = if (i + 1 == n) 0 else i + 1;
        area += px[i] * py[j] - px[j] * py[i];
    }
    if (area == 0) return;
    const plus_is_top = area > 0;

    // A column that no edge writes (only possible through rounding in a
    // nearly degenerate polygon) keeps an empty span.
    @memset(col_top[c0..c1], guard);
    @memset(col_bot[c0..c1], -guard);

    for (0..n) |i| {
        const j = if (i + 1 == n) 0 else i + 1;
        if (px[i] == px[j]) continue;
        const plus = px[j] > px[i];
        const l = if (plus) i else j;
        const r = if (plus) j else i;
        const e0 = @max(c0, to_index(px[l], sw));
        const e1 = @min(c1, to_index(px[r], sw));
        if (e0 >= e1) continue;
        const lx = px[l];
        const ly = py[l];
        const slope = (py[r] - ly) / (px[r] - lx);
        const dst = if (plus == plus_is_top) &col_top else &col_bot;
        var c = e0;
        while (c < e1) : (c += 1) {
            dst[c] = ly + (@as(f32, @floatFromInt(c)) + 0.5 - lx) * slope;
        }
    }

    if (collect_stats) stats.polys_drawn += 1;
    switch (fill) {
        .flat => |color| columns(.flat, c0, c1, &g, color, {}, occluder),
        .textured => |t| columns(.textured, c0, c1, &g, undefined, colors(t), occluder),
        .sprite => |t| columns(.sprite, c0, c1, &g, undefined, Src(true){ .texels = t.texels, .pal = t.palette }, false),
    }
}

/// True when the whole polygon is behind the occlusion records: for every
/// column c0..c1 a record covers the polygon's row range (one row of slack
/// each side for the edge interpolation's rounding) with q >= the largest
/// z value any pixel of the polygon can get. That bound is the plane's
/// maximum over the pixel-centre rectangle plus a rounding allowance for
/// the three-term evaluation the spans use.
fn hidden(g: *const Grad, cv: []const Vertex, py: *const [clip.max_out]f32, c0: u32, c1: u32) bool {
    var ymin: f32 = guard;
    var ymax: f32 = -guard;
    for (py[0..cv.len]) |y| {
        ymin = @min(ymin, y);
        ymax = @max(ymax, y);
    }
    const r0 = to_index(ymin, sh) -| 1;
    const r1 = @min(sh, to_index(ymax, sh) + 1);
    if (r0 >= r1) return true;
    const xm = if (g.zx > 0) @as(f32, @floatFromInt(c1)) - 0.5 else @as(f32, @floatFromInt(c0)) + 0.5;
    const ym = if (g.zy > 0) @as(f32, @floatFromInt(r1)) - 0.5 else @as(f32, @floatFromInt(r0)) + 0.5;
    const tx = g.zx * xm;
    const ty = g.zy * ym;
    const err = (@abs(g.zo) + @abs(tx) + @abs(ty)) * 1e-5;
    const qmax = g.zo + tx + ty + err;
    if (!(qmax < q_max)) return false;
    const qb: u32 = @as(u32, @intFromFloat(@max(0.0, qmax))) + occ_slack;
    var c = c0;
    while (c < c1) : (c += 1) {
        const o = occ[c];
        if (o.top > r0 or o.bot < r1 or o.q < qb) return false;
    }
    return true;
}

/// Records that rows [y0, y1) of column x now hold z >= the span's lower
/// bound (`qs`, `qe`: its clamped end values). Keeps whichever of the old
/// record, the new one and their union (when they touch) covers the most
/// rows times q.
inline fn occlude(x: u32, y0: u32, y1: u32, qs: f32, qe: f32) void {
    const lo_f: u32 = @intFromFloat(@min(qs, qe));
    const lo = lo_f -| occ_slack;
    const o = occ[x];
    var best: Occ = .{ .top = @intCast(y0), .bot = @intCast(y1), .q = @intCast(lo) };
    if (o.top < o.bot) {
        var score: u32 = (y1 - y0) * lo;
        const old_score = @as(u32, o.bot - o.top) * o.q;
        if (old_score >= score) {
            best = o;
            score = old_score;
        }
        if (y0 <= o.bot and o.top <= y1) {
            const t = @min(o.top, y0);
            const b = @max(o.bot, y1);
            const q = @min(o.q, lo);
            if (@as(u32, b - t) * q > score) best = .{ .top = @intCast(t), .bot = @intCast(b), .q = @intCast(q) };
        }
    }
    occ[x] = best;
}

/// ceil(v - 0.5) clamped to [0, limit]: the first pixel index whose centre
/// is at or after v.
inline fn to_index(v: f32, comptime limit: u32) u32 {
    const c = @ceil(@min(guard, @max(-guard, v)) - 0.5);
    return @intFromFloat(@min(@as(f32, @floatFromInt(limit)), @max(0.0, c)));
}

/// True when every vertex fails the same view-frustum half-space test.
fn outside_frustum(verts: []const Vertex) bool {
    var behind = true;
    var left = true;
    var right = true;
    var above = true;
    var below = true;
    for (verts) |v| {
        const x = v.p[0];
        const y = v.p[1];
        const z = v.p[2];
        behind = behind and z < clip.near;
        left = left and x < -slope_x * z;
        right = right and x > slope_x * z;
        above = above and y > slope_y * z;
        below = below and y < -slope_y * z;
    }
    return behind or left or right or above or below;
}

/// Plane gradients from the first three (unclipped) vertices. Any attribute
/// A that is affine over the polygon's plane can be written as A = a . p
/// for view-space points p on the plane, so A / z = a . d with the pixel's
/// ray d = ((sx - 80) / f, (64 - sy) / f, 1): affine in (sx, sy). Solving
/// a . p_i = A_i with edge vectors keeps the determinant well conditioned.
/// Returns null for a plane (nearly) through the eye: it is edge-on and
/// covers no pixels.
fn gradients(verts: []const Vertex) ?Grad {
    const p0 = verts[0].p;
    const e1 = verts[1].p - p0;
    const e2 = verts[2].p - p0;
    const nrm = math.cross(e1, e2);
    const det = math.dot(p0, nrm);
    if (!(det * det > 1e-10 * math.dot(nrm, nrm))) return null;
    const inv = 1.0 / det;
    const c1 = math.cross(e2, p0);
    const c2 = math.cross(p0, e1);
    const tex: f32 = textures.size;
    const ua = verts[0].u * tex;
    const va = verts[0].v * tex;
    const a_z = nrm * math.splat(inv * z_scale);
    const a_u = (nrm * math.splat(ua) + c1 * math.splat(verts[1].u * tex - ua) + c2 * math.splat(verts[2].u * tex - ua)) * math.splat(inv);
    const a_v = (nrm * math.splat(va) + c1 * math.splat(verts[1].v * tex - va) + c2 * math.splat(verts[2].v * tex - va)) * math.splat(inv);
    var g: Grad = undefined;
    screen(a_z, &g.zx, &g.zy, &g.zo);
    screen(a_u, &g.ux, &g.uy, &g.uo);
    screen(a_v, &g.vx, &g.vy, &g.vo);
    return g;
}

inline fn screen(a: math.Vec3, gx: *f32, gy: *f32, go: *f32) void {
    gx.* = a[0] * (1.0 / focal);
    gy.* = -a[1] * (1.0 / focal);
    go.* = a[2] - cx_screen * gx.* - cy_screen * gy.*;
}

const Kind = enum { flat, textured, sprite };

/// Column loop, instantiated once per fill kind.
inline fn columns(comptime kind: Kind, c0: u32, c1: u32, g: *const Grad, color: cart.Pixel, src: anytype, occluder: bool) void {
    var c = c0;
    while (c < c1) : (c += 1) {
        const y0 = to_index(col_top[c], sh);
        const y1 = to_index(col_bot[c], sh);
        if (y0 >= y1) continue;
        const o = if (use_occlusion) occ[c] else Occ{};
        var qs: f32 = undefined;
        var qe: f32 = undefined;
        if (use_occlusion) {
            // The span's end values, computed exactly as the span code does.
            const fx = @as(f32, @floatFromInt(c)) + 0.5;
            const bz = g.zo + g.zx * fx;
            const fy0 = @as(f32, @floatFromInt(y0)) + 0.5;
            qs = clamp_q(bz + g.zy * fy0);
            qe = clamp_q(bz + g.zy * (fy0 + @as(f32, @floatFromInt(y1 - y0 - 1))));
            if (o.top <= y0 and o.bot >= y1 and span_q_max(qs, qe) < @as(f32, @floatFromInt(o.q))) continue;
        }
        if (collect_stats) {
            stats.columns += 1;
            stats.pixels += y1 - y0;
        }
        switch (kind) {
            .flat => span_flat(c, y0, y1, g, color),
            .textured => span_tex(false, c, y0, y1, g, src, o),
            .sprite => span_tex(true, c, y0, y1, g, src, o),
        }
        if (use_occlusion and occluder) occlude(c, y0, y1, qs, qe);
    }
}

/// Bound on the z values a span or segment with clamped end values qs, qe
/// writes. Each pixel's value is (q_start + i * dq) >> q_frac, q_start = qs
/// in 20.12 truncated, dq truncated towards zero, so it exceeds
/// floor(max(qs, qe)) by at most the float rounding of dq (well under one
/// unit). `span_q_max(qs, qe) < q` for an integer q, i.e.
/// max(qs, qe) < q - 1, therefore gives every pixel a value <= q - 1.
inline fn span_q_max(qs: f32, qe: f32) f32 {
    return @max(qs, qe) + @as(f32, @floatFromInt(occ_slack - 1));
}

inline fn clamp_q(q: f32) f32 {
    return @min(q_max, @max(0.0, q));
}

inline fn to_fixed(v: f32, comptime frac: u5) i32 {
    return @intFromFloat(v * @as(f32, 1 << frac));
}

/// Flat span: only the z value varies, and it is affine in y.
fn span_flat(x: u32, y0: u32, y1: u32, g: *const Grad, color: cart.Pixel) void {
    const fx = @as(f32, @floatFromInt(x)) + 0.5;
    const bz = g.zo + g.zx * fx;
    const n = y1 - y0;
    const fy0 = @as(f32, @floatFromInt(y0)) + 0.5;
    const qs = clamp_q(bz + g.zy * fy0);
    const qe = clamp_q(bz + g.zy * (fy0 + @as(f32, @floatFromInt(n - 1))));
    const zc = zbuf[x][y0..].ptr;
    const fc = cart.framebuffer[x][y0..].ptr;
    inner_flat(zc, fc, n, to_fixed(qs, q_frac), to_fixed((qe - qs) * rcp[n], q_frac), color);
}

noinline fn inner_flat(zc: [*]u16, fc: [*]cart.Pixel, n: u32, q_start: i32, dq: i32, color: cart.Pixel) void {
    var q = q_start;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const qz: u16 = @truncate(@as(u32, @bitCast(q)) >> q_frac);
        if (qz > zc[i]) {
            if (collect_stats) stats.written += 1;
            zc[i] = qz;
            fc[i] = color;
        }
        q +%= dq;
    }
}

/// Perspective-correct u, v (texels) at one sample row.
const Uv = struct { u: f32, v: f32 };

inline fn sample_uv(iz: f32, bu: f32, bv: f32, g: *const Grad, fy: f32) Uv {
    const r = z_scale / @max(1e-3, iz);
    return .{
        .u = @min(uv_limit, @max(-uv_limit, (bu + g.uy * fy) * r)),
        .v = @min(uv_limit, @max(-uv_limit, (bv + g.vy * fy) * r)),
    };
}

/// Sprites clamp instead of wrapping: samples lie inside the polygon, but
/// rounding can put an edge sample a hair outside [0, 32), and the & 31
/// wrap would then fetch the opposite border (a sprite whose feet touch
/// row 31 would grow stray pixels above its head). Clamping both segment
/// ends keeps every interpolated texel inside too.
const uv_edge: f32 = @as(f32, textures.size) - 1.0 / 2048.0;
inline fn sprite_clamp(comptime sprite: bool, s: Uv) Uv {
    if (!sprite) return s;
    return .{ .u = @min(uv_edge, @max(0.0, s.u)), .v = @min(uv_edge, @max(0.0, s.v)) };
}

/// Textured span in segments of `seg` pixels. The z value needs no divide,
/// so each segment is first z-tested alone; a segment hidden behind nearer
/// geometry (floor behind walls, far walls) costs no divide and no texel
/// fetch. A full segment's end sample is the next segment's start, so a
/// run of visible segments costs one divide each; the last segment ends on
/// its last pixel, so every sample lies inside the polygon.
fn span_tex(comptime sprite: bool, x: u32, y0: u32, y1: u32, g: *const Grad, src: Src(sprite), o: Occ) void {
    const fx = @as(f32, @floatFromInt(x)) + 0.5;
    const bz = g.zo + g.zx * fx;
    const bu = g.uo + g.ux * fx;
    const bv = g.vo + g.vx * fx;
    var zc = zbuf[x][y0..].ptr;
    var fc = cart.framebuffer[x][y0..].ptr;
    var fy = @as(f32, @floatFromInt(y0)) + 0.5;
    var rem = y1 - y0;
    var iz_s = bz + g.zy * fy;
    // Carried from one segment to the next (the end values of a segment are
    // the start values of the next, so each is computed once, bit for bit
    // what recomputing it would give): clamped z, its 20.12 form, and the
    // start sample with its packed form.
    var qs = clamp_q(iz_s);
    var q_start = to_fixed(qs, q_frac);
    var s: Uv = undefined;
    var uv: u32 = undefined;
    var s_valid = false;
    // Segment k's pixel parameters go to segs[k] and bit k of mask; the
    // pixel loops then run for the whole column in one call.
    var k: u32 = 0;
    var mask: u32 = 0;
    const zc0 = zc;
    const fc0 = fc;
    // Rows [row, ...) of the current segment; segments inside the
    // occlusion record skip the z reads of any_visible (same outcome).
    var row = y0;
    const occ_q: f32 = @floatFromInt(o.q);
    while (true) {
        const full = rem > seg;
        const len: u32 = if (full) seg else rem;
        const scale: f32 = if (full) 1.0 / @as(f32, seg) else rcp[len];
        const fy_e = fy + @as(f32, @floatFromInt(if (full) seg else len - 1));
        const iz_e = bz + g.zy * fy_e;
        const qe = clamp_q(iz_e);
        const occluded = use_occlusion and row >= o.top and row + len <= o.bot and span_q_max(qs, qe) < occ_q;
        const dq = to_fixed((qe - qs) * scale, q_frac);
        if (!occluded and any_visible(zc, len, q_start, dq)) {
            if (!s_valid) {
                s = sprite_clamp(sprite, sample_uv(iz_s, bu, bv, g, fy));
                uv = pack_uv(s.u, s.v);
            }
            const e = sprite_clamp(sprite, sample_uv(iz_e, bu, bv, g, fy_e));
            if (collect_stats) stats.segments += 1;
            segs[k] = .{ .q = q_start, .dq = dq, .uv = uv, .duv = pack_uv((e.u - s.u) * scale, (e.v - s.v) * scale) };
            mask |= @as(u32, 1) << @intCast(k);
            s = e;
            s_valid = true;
            if (full) uv = pack_uv(e.u, e.v);
        } else {
            if (collect_stats) stats.skipped += 1;
            s_valid = false;
        }
        if (!full) break;
        k += 1;
        rem -= seg;
        row += seg;
        zc += seg;
        fc += seg;
        fy = fy_e;
        iz_s = iz_e;
        qs = qe;
        q_start = to_fixed(qe, q_frac);
    }
    if (mask == 0) return;
    if (sprite) {
        draw_segs(true, zc0, fc0, mask, k, rem, src.texels, src.pal);
    } else {
        draw_segs(false, zc0, fc0, mask, k, rem, src, {});
    }
}

/// One segment's pixel parameters (see span_tex).
const Seg = struct { q: i32, dq: i32, uv: u32, duv: u32 };
var segs: [(sh + seg - 1) / seg]Seg = undefined;

/// Pixel loops for the visible segments of one column: bit k of `mask`
/// set means segment k (`seg` pixels at row offset k * seg) is drawn with
/// segs[k]; bit `last` is the final segment, `last_len` pixels, which ends
/// on the span's last pixel. Walks the pointers along with the mask so few
/// registers stay live around the unrolled pixel code.
noinline fn draw_segs(
    comptime sprite: bool,
    zc0: [*]u16,
    fc0: [*]cart.Pixel,
    mask: u32,
    last: u32,
    last_len: u32,
    src: if (sprite) *const [1024]u8 else *const [1024]cart.Pixel,
    pal: if (sprite) *const [16]cart.Pixel else void,
) void {
    const sv: Src(sprite) = if (sprite) .{ .texels = src, .pal = pal } else src;
    const last_bit = @as(u32, 1) << @intCast(last);
    var m = mask & ~last_bit;
    var sp: [*]const Seg = &segs;
    var zc = zc0;
    var fc = fc0;
    while (m != 0) {
        const t: u5 = @intCast(@ctz(m));
        m = (m >> t) >> 1;
        sp += t;
        zc += @as(u32, t) * seg;
        fc += @as(u32, t) * seg;
        const sg = sp[0];
        inner_tex8(sprite, zc, fc, sg.q, sg.dq, sg.uv, sg.duv, sv);
        sp += 1;
        zc += seg;
        fc += seg;
    }
    if (mask & last_bit != 0) {
        const sg = segs[last];
        inner_tex(sprite, zc0 + last * seg, fc0 + last * seg, last_len, sg.q, sg.dq, sg.uv, sg.duv, sv);
    }
}

/// True when at least one pixel of the segment passes the z test. Exits on
/// the first visible pixel, which for visible geometry is usually the
/// first one.
inline fn any_visible(zc: [*]u16, n: u32, q_start: i32, dq: i32) bool {
    var q = q_start;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const qz: u16 = @truncate(@as(u32, @bitCast(q)) >> q_frac);
        if (qz > zc[i]) return true;
        q +%= dq;
    }
    return false;
}

/// u and v share one register: u in bits 16..31, v in bits 0..15, each
/// 5.11 fixed point, so both wrap at 32 texels for free. A carry out of the
/// v field lands in u's lowest fraction bit, an error of 1/2048 texel.
inline fn inner_tex(
    comptime sprite: bool,
    zc: [*]u16,
    fc: [*]cart.Pixel,
    n: u32,
    q_start: i32,
    dq: i32,
    uv_start: u32,
    duv: u32,
    src: Src(sprite),
) void {
    var q = q_start;
    var uv = uv_start;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        tex_pixel(sprite, zc, fc, i, q, uv, src);
        q +%= dq;
        uv +%= duv;
    }
}

/// A full segment: exactly `seg` pixels, straight-line code with constant
/// offsets, so nothing but the two accumulators, their steps and four
/// pointers is live.
inline fn inner_tex8(
    comptime sprite: bool,
    zc: [*]u16,
    fc: [*]cart.Pixel,
    q_start: i32,
    dq: i32,
    uv_start: u32,
    duv: u32,
    src: Src(sprite),
) void {
    var q = q_start;
    var uv = uv_start;
    inline for (0..seg) |i| {
        tex_pixel(sprite, zc, fc, i, q, uv, src);
        q +%= dq;
        uv +%= duv;
    }
}

inline fn tex_pixel(comptime sprite: bool, zc: [*]u16, fc: [*]cart.Pixel, i: usize, q: i32, uv: u32, src: Src(sprite)) void {
    const qz: u16 = @truncate(@as(u32, @bitCast(q)) >> q_frac);
    if (qz > zc[i]) {
        const idx = ((uv >> 27) << 5) | ((uv >> 11) & 31);
        if (sprite) {
            const t = src.texels[idx];
            if (t != 0) {
                if (collect_stats) stats.written += 1;
                zc[i] = qz;
                fc[i] = src.pal[t];
            }
        } else {
            if (collect_stats) stats.written += 1;
            zc[i] = qz;
            fc[i] = src[idx];
        }
    }
}

/// Texel source of the pixel loops: sprites read the palette index (0 is
/// transparent), opaque textures a colour grid (one load instead of two,
/// and one register fewer in the unrolled loop).
fn Src(comptime sprite: bool) type {
    return if (sprite) struct { texels: *const [1024]u8, pal: *const [16]cart.Pixel } else *const [1024]cart.Pixel;
}

/// Colour grids texels -> palette, built on first use of a texture/palette
/// pair and kept (textures and palettes are fixed after start). More pairs
/// than slots reuse slots round robin, which is only slower.
const color_slots = 8;
var color_keys: [color_slots]struct { texels: ?*const [1024]u8 = null, pal: ?*const [16]cart.Pixel = null } = @splat(.{});
var color_grid: [color_slots][1024]cart.Pixel = undefined;
var color_next: u32 = 0;

fn colors(tex: *const textures.Texture) *const [1024]cart.Pixel {
    for (&color_keys, 0..) |*k, i| {
        if (k.texels == tex.texels and k.pal == tex.palette) return &color_grid[i];
    }
    const i = color_next;
    color_next = (color_next + 1) % color_slots;
    color_keys[i] = .{ .texels = tex.texels, .pal = tex.palette };
    for (&color_grid[i], tex.texels) |*c, t| c.* = tex.palette[t];
    return &color_grid[i];
}

/// Packs u and v (texels, f32) into the inner loop's 5.11 + 5.11 layout.
inline fn pack_uv(u: f32, v: f32) u32 {
    const ui: u32 = @bitCast(to_fixed(u, uv_frac));
    const vi: u32 = @bitCast(to_fixed(v, uv_frac));
    return ((ui << 11) & 0xffff0000) | ((vi >> 5) & 0xffff);
}
