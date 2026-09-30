//! Freeze-frame progressive path tracer (SPEC.md section 5b, PLAN.md M4
//! "The M4 estimator, exactly"). While the view is frozen it replaces the
//! real-time tracer: one sample per pixel per pass, whole columns at a time,
//! into a 160 x 128 accumulator that lives in arena.words (shared with the
//! real-time water.primary_fade_rt, PLAN.md M4 "Memory").
//!
//! The frozen scene is the real-time scene of that View (bob heights,
//! drifted sun, logo spin, wave phases, preset sky and colours) with every
//! preset's full content whatever the variant: sunset chrome +
//! glass, midnight chrome + matte, noon chrome + matte + small chrome,
//! storm chrome; rings in every preset; the logo in every ray. fade = 1.
//!
//! tools/reference.py --pt implements the same estimator in f64 with the
//! same integer RNG (bit for bit), so the cart's first passes can be
//! compared sample for sample. Everything here is f32, iterative, no
//! allocation, no libm (math.sin_turns).
//!
//! Accumulator layout (for debug_pt_accum readers): arena.words[x * 128 +
//! y], column-major like the framebuffer; r bits 0-10 (q / 512), g bits
//! 11-21 (q / 512), b bits 22-31 (q / 256), fixed point over [0, 4).
const std = @import("std");
const cart = @import("cart-api");
const math = @import("math.zig");
const camera = @import("camera.zig");
const scene = @import("scene.zig");
const water = @import("water.zig");
const iris = @import("iris.zig");
const dither = @import("dither.zig");
const trace = @import("trace.zig");
const arena = @import("arena.zig");
const variant = @import("variant.zig");
const Vec3 = math.Vec3;
const vec3 = math.vec3;
const splat = math.splat;
const dot = math.dot;

// ---------------------------------------------------------------- knobs

/// Passes after which the image counts as converged and step() stops.
pub const max_passes: u32 = 256;
/// Tracing time per update (the rest of the 50 ms frame is display(), the
/// dither and the overshoot of the last column).
pub const slice_us: u32 = 36_000;
/// wasm has no clock: step() traces exactly this many columns per update
/// there. The integrator sets it from the bench rate.
pub const wasm_columns_per_update: u32 = 40;

// Estimator knobs (PLAN.md M4 "The M4 estimator, exactly"). tools/reference.py
// --pt takes the same values; change both together.
/// Depth of field, focused on the chrome sphere's centre plane.
pub const dof: bool = true;
/// Lens radius in world units (Adrian 2026-09-30: subtle).
pub const lens_radius: f32 = 0.05;
/// Angular radius of the sun (and moon) disc, degrees: soft shadows and a
/// soft glitter path.
pub const sun_radius: f32 = 1.5;
/// Gloss of the water: the ripple normal is tilted by up to this.
pub const water_roughness: f32 = 0.08;
/// Throughput scale of a matte sphere's diffuse bounce (the real-time look
/// had a 0.15 ambient; the full sky dome without it washes the matte out).
pub const sky_fill: f32 = 0.3;
/// A sample is clamped to this per channel (fireflies; the accumulator
/// holds [0, 4)).
pub const sample_clamp: f32 = 4.0;
/// Vertices 0 .. max_bounces; the last is terminal (no further ray).
pub const max_bounces: u32 = 4;

/// Profiling switch: the path's parts become separate functions so
/// `badge-bench --symbols` attributes their cycles. Ship false.
const pt_split = false;
const split: std.builtin.CallModifier = if (pt_split) .never_inline else .auto;

// ---------------------------------------------------------------- state

const width = camera.width;
const height = camera.height;

/// Samples each pixel of column x holds.
var n_col: [width]u32 = @splat(0);
/// Next column step() traces.
var cursor: u32 = 0;

/// The frozen scene, built once by begin().
const Frozen = struct {
    sc: scene.Frame,
    wf: water.Frame,
    ir: iris.Frame,
    eye: Vec3,
    fwd: Vec3,
    right: Vec3,
    up: Vec3,
    /// Focus distance along fwd: dot(chrome centre - eye, fwd).
    focus: f32,
    /// Sphere centres at the frozen time.
    c_chrome: Vec3,
    c_slot2: Vec3,
    c_small: Vec3,
    /// What the second slot holds; whether the small chrome is there.
    slot2: scene.Slot2,
    third: bool,
    /// Screen bounds of the objects for primary rays (plan_rows).
    proj: [4]Proj,
    /// onb(L) for the sun disc samples.
    e1: Vec3,
    e2: Vec3,
};
var fz: Frozen = undefined;

// ---------------------------------------------------------------- interface

/// Seed the accumulator from the framebuffer the real-time tracer has just
/// drawn for `view` (decode RGB565 to linear, n = 0 in every column), take
/// the arena, and set up the frozen scene. Call after trace.render_frame
/// in the same update.
pub fn begin(view: trace.View) void {
    arena.owner = .pt;
    setup(view);
    seed();
    n_col = @splat(0);
    cursor = 0;
}

/// Trace whole columns (one sample per pixel each) until
/// micros_since_boot() >= deadline_us, at least one column; on wasm,
/// exactly wasm_columns_per_update columns. Nothing once done().
pub fn step(deadline_us: u64) void {
    if (!active()) return;
    if (cart.is_wasm) return step_columns(wasm_columns_per_update);
    while (!done()) {
        trace_column();
        if (cart.micros_since_boot() >= deadline_us) break;
    }
}

/// Trace `n` whole columns (fewer if done() comes first). For step() on
/// wasm and for debug_pt_run (n passes = 160 n columns from a pass
/// boundary).
pub fn step_columns(n: u32) void {
    if (!active()) return;
    var i: u32 = 0;
    while (i < n and !done()) : (i += 1) trace_column();
}

/// Run synchronously until passes() has grown by n, or done(). No-op when
/// not active. For the wasm debug_pt_run export (a pass started mid-way is
/// finished first, so the result is always whole passes).
pub fn run_passes(n: u32) void {
    if (!active()) return;
    const target = passes() +| n;
    while (!done() and passes() < target) trace_column();
}

/// Dither the accumulator mean to the framebuffer (dither.quantise in the
/// current mode, then the caller's dither.end_frame()).
pub noinline fn display() void {
    if (!active()) return;
    const fb = cart.framebuffer;
    for (0..width) |x| {
        const col = arena.words[x * height ..][0..height];
        for (col, 0..) |w, y| {
            const m = @min(splat(1.0), decode(w));
            fb[x][y] = dither.quantise(@intCast(x), @intCast(y), m);
        }
    }
}

/// Give the arena back to the real-time tracer (no-op when not active).
pub fn release() void {
    if (!active()) return;
    arena.owner = .realtime;
    water.invalidate_tables();
}

pub fn active() bool {
    return arena.owner == .pt;
}

/// Completed passes (the minimum over columns). Columns are traced in
/// order, so the last column always holds the minimum.
pub fn passes() u32 {
    return n_col[width - 1];
}

pub fn done() bool {
    return passes() >= max_passes;
}

// ---------------------------------------------------------------- accumulator

const r_scale: f32 = 512.0;
const g_scale: f32 = 512.0;
const b_scale: f32 = 256.0;
const max_q = vec3(2047.0, 2047.0, 1023.0);
const q_scale = vec3(r_scale, g_scale, b_scale);

inline fn decode(w: u32) Vec3 {
    const r: f32 = @floatFromInt(w & 2047);
    const g: f32 = @floatFromInt((w >> 11) & 2047);
    const b: f32 = @floatFromInt(w >> 22);
    return vec3(r, g, b) * comptime vec3(1.0 / r_scale, 1.0 / g_scale, 1.0 / b_scale);
}

/// The real-time frame, decoded from RGB565 (r5 / 31, g6 / 63, b5 / 31)
/// and rounded up to the accumulator's grid, so that display() in dither
/// mode none gives back exactly the same pixels: q = ceil(c * scale / max)
/// puts q / scale * max in [c, c + max / scale), and max / scale < 1/8.
fn seed() void {
    const fb = cart.framebuffer;
    for (0..width) |x| {
        const col = arena.words[x * height ..][0..height];
        for (col, 0..) |*w, y| {
            const c = fb[x][y].to_color();
            w.* = seed_r[c.r] | seed_g[c.g] | seed_b[c.b];
        }
    }
}

/// The seed's per-channel words: ceil(c * scale / max) in its bit field.
const seed_r: [32]u32 = blk: {
    var t: [32]u32 = undefined;
    for (&t, 0..) |*q, c| q.* = (c * 512 + 30) / 31;
    break :blk t;
};
const seed_g: [64]u32 = blk: {
    var t: [64]u32 = undefined;
    for (&t, 0..) |*q, c| q.* = ((c * 512 + 62) / 63) << 11;
    break :blk t;
};
const seed_b: [32]u32 = blk: {
    var t: [32]u32 = undefined;
    for (&t, 0..) |*q, c| q.* = ((c * 256 + 30) / 31) << 22;
    break :blk t;
};

// ---------------------------------------------------------------- random numbers

/// Chris Wellons' lowbias32 hash.
inline fn lowbias32(v0: u32) u32 {
    var v = v0;
    v ^= v >> 16;
    v *%= 0x7feb352d;
    v ^= v >> 15;
    v *%= 0x846ca68b;
    v ^= v >> 16;
    return v;
}

/// (h >> 8) * 2^-24: exact in f32, in [0, 1).
inline fn to_unit(h: u32) f32 {
    return @as(f32, @floatFromInt(h >> 8)) * 0x1p-24;
}

/// key = (n * 64 + d) * 20480 + y * 160 + x = pk + d * 20480 with pk =
/// n * 64 * 20480 + y * 160 + x (all wrapping).
const dim_stride: u32 = width * height;

inline fn hash(pk: u32, d: u32) u32 {
    return lowbias32(pk +% d *% dim_stride);
}

inline fn rnd(pk: u32, d: u32) f32 {
    return to_unit(hash(pk, d));
}

/// The R2 sequence's multipliers 2^32 / g and 2^32 / g^2, g the plastic
/// number.
const r2_a0: u32 = 3242174889;
const r2_a1: u32 = 2447445414;

const bluenoise = dither.bluenoise_bytes;

// ---------------------------------------------------------------- scene setup

inline fn seconds(t: u32) f32 {
    return @as(f32, @floatFromInt(t)) * (1.0 / @as(comptime_float, variant.fps));
}

/// onb(n): s = n.z >= 0 ? 1 : -1; a = -1 / (s + n.z); b = n.x n.y a.
inline fn onb(n: Vec3) [2]Vec3 {
    const s: f32 = if (n[2] >= 0.0) 1.0 else -1.0;
    const a = -1.0 / (s + n[2]);
    const b = n[0] * n[1] * a;
    return .{
        vec3(1.0 + s * n[0] * n[0] * a, s * b, -s * n[0]),
        vec3(b, s + n[1] * n[1] * a, -n[1]),
    };
}

/// The same per-frame values trace.render_frame computes for `view`, with
/// the full content of the preset.
fn setup(view: trace.View) void {
    const h = @min(@max(view.height, camera.min_height), camera.max_height);
    const basis = camera.basis_at(h);
    const cam = camera.at(view.orbit, &basis);

    var ys = [3]f32{ scene.chrome.y0, scene.slot2.y0, scene.small.y0 };
    var sun = scene.consts_of(view.preset).sun_dir;
    if (scene.motion) {
        const s = seconds(view.t);
        const bob = s * (1.0 / scene.bob_period);
        inline for (.{ scene.chrome, scene.slot2, scene.small }, 0..) |g, i| {
            ys[i] = g.y0 + scene.bob_lift + scene.bob_amp * math.sin_turns(bob + g.phase);
        }
        if (scene.sun_drift) {
            const a = (scene.drift_deg / 360.0) * math.sin_turns(s * (1.0 / scene.drift_period));
            const sn = math.sin_turns(a);
            const cs = math.sin_turns(a + 0.25);
            sun = vec3(sun[0] * cs + sun[2] * sn, sun[1], sun[2] * cs - sun[0] * sn);
        }
    }
    fz.sc = scene.frame_at(view.preset, 1.0, sun, ys);
    fz.slot2 = switch (view.preset) {
        .sunset => .glass,
        .midnight, .noon => .matte,
        .storm => .none,
    };
    fz.third = view.preset == .noon;
    fz.c_chrome = vec3(scene.chrome.x, ys[0], scene.chrome.z);
    fz.c_slot2 = vec3(scene.slot2.x, ys[1], scene.slot2.z);
    fz.c_small = vec3(scene.small.x, ys[2], scene.small.z);

    fz.wf = water.frame_at(view.t, view.preset);
    if (scene.motion) {
        water.add_ring(&fz.wf, scene.chrome.x, scene.chrome.z);
        if (fz.slot2 != .none) water.add_ring(&fz.wf, scene.slot2.x, scene.slot2.z);
        if (fz.third) water.add_ring(&fz.wf, scene.small.x, scene.small.z);
    }
    fz.ir = iris.at_frame(view.t, &fz.sc, 1.0);

    fz.eye = cam.eye;
    fz.fwd = cam.fwd;
    fz.right = cam.right;
    fz.up = cam.up;
    fz.focus = dot(fz.c_chrome - cam.eye, cam.fwd);
    fz.proj = .{
        proj_of(fz.c_chrome, scene.chrome.r, true),
        proj_of(fz.c_slot2, scene.slot2.r, fz.slot2 != .none),
        proj_of(fz.c_small, scene.small.r, fz.third),
        proj_of(iris.centre, iris.radius, true),
    };
    const e = onb(sun);
    fz.e1 = e[0];
    fz.e2 = e[1];
}

// ---------------------------------------------------------------- primary bounds

/// Primary-ray bounds of one object (a sphere, or the logo's bounding
/// sphere) in camera coordinates: the rows of each column whose rays may
/// meet it, so the other rows skip its test (PLAN.md M4: bounds like the
/// real-time tracer's, never changing the picture).
///
/// A primary ray starts at o = eye + off (off in the lens plane, |off| <=
/// lens_radius) and passes through P = eye + w f, w = fwd + right u + up v
/// the pinhole ray of its jittered pixel (dot(w, fwd) = 1). At fwd-depth z
/// it is at eye + w z + off (1 - z / f), within lens_radius |1 - z / f| of
/// the pinhole ray; every point of a sphere of radius r at depth cz has z
/// in [cz - r, cz + r]. So the ray can meet the sphere only if the pinhole
/// line passes within r + delta of its centre, delta = lens_radius * the
/// larger |1 - z / f| at the two depths. The pixel jitter moves u by at
/// most half a pixel from the column centre, which moves the line by at
/// most 0.5 u_step z at depth z <= cz + r': that is added to the radius
/// (0.75 for margin). The rows then come from the quadratic in v at the
/// column centre (trace.zig's sphere_span_at in camera coordinates), padded
/// a row each side.
const Proj = struct {
    mode: enum(u8) { never, always, span },
    cx: f32 = 0.0,
    cy: f32 = 0.0,
    cz: f32 = 0.0,
    /// |c|^2 - R^2 for the grown radius R.
    k: f32 = 0.0,
};

fn proj_of(c: Vec3, r: f32, present: bool) Proj {
    if (!present) return .{ .mode = .never };
    const rel = c - fz.eye;
    const cz = dot(rel, fz.fwd);
    // Every primary ray has a positive fwd component from the lens plane.
    if (cz + r <= 0.0) return .{ .mode = .never };
    const f = fz.focus;
    const delta = if (dof) lens_radius * @max(@abs(1.0 - (cz - r) / f), @abs(1.0 - (cz + r) / f)) else 0.0;
    const r1 = r + delta;
    const rr = (r1 + 0.75 * u_step * (cz + r1)) * 1.01 + 0.01;
    if (cz - rr <= 0.05) return .{ .mode = .always };
    return .{
        .mode = .span,
        .cx = dot(rel, fz.right),
        .cy = dot(rel, fz.up),
        .cz = cz,
        .k = dot(rel, rel) - rr * rr,
    };
}

/// Rows [lo, hi) of column centre u whose primary rays may meet the object.
fn rows_of(pj: *const Proj, u: f32) [2]u32 {
    switch (pj.mode) {
        .never => return .{ 0, 0 },
        .always => return .{ 0, height },
        .span => {},
    }
    // (w.c)^2 >= k |w|^2, w = (u, v, 1): a v^2 + b v + c >= 0 with a < 0
    // (the eye is outside the grown sphere's cylinder along up, as cz > R).
    const a = pj.cy * pj.cy - pj.k;
    if (!(a < 0.0)) return .{ 0, height };
    const m = u * pj.cx + pj.cz;
    const b = 2.0 * pj.cy * m;
    const c = m * m - pj.k * (u * u + 1.0);
    const disc = b * b - 4.0 * a * c;
    if (!(disc >= 0.0)) return .{ 0, 0 };
    const sq = @sqrt(disc);
    const inv = 0.5 / a; // < 0
    const v_hi = (-b - sq) * inv;
    const v_lo = (-b + sq) * inv;
    // py = 64 - v / u_step; rows y with [y, y + 1) meeting the interval.
    const y0 = @floor(64.0 - v_hi * (1.0 / u_step)) - 1.0;
    const y1 = @floor(64.0 - v_lo * (1.0 / u_step)) + 2.0;
    const lo: u32 = @intFromFloat(@min(@max(y0, 0.0), @as(f32, height)));
    const hi: u32 = @intFromFloat(@min(@max(y1, 0.0), @as(f32, height)));
    return .{ lo, @max(lo, hi) };
}

// Test masks of a primary ray (bit per object in fz.proj order).
const m_chrome: u8 = 1;
const m_slot2: u8 = 2;
const m_small: u8 = 4;
const m_logo: u8 = 8;
const m_all: u8 = 15;

// ---------------------------------------------------------------- geometry

const no_hit = math.inf_f32;
const t_eps: f32 = 1e-3;
const max_water_t: f32 = 1e5;

/// Nearest t > 1e-3 of the sphere (c, r) for a unit d from an origin
/// outside it, or no_hit. The discriminant as r^2 - |oc - b d|^2 (no
/// cancellation of two ~|oc|^2 terms; trace.zig's stable form).
inline fn hit_sphere(o: Vec3, d: Vec3, c: Vec3, comptime r: f32) f32 {
    const oc = o - c;
    const b = dot(oc, d);
    // Outside and moving away: both roots behind.
    if (b >= 0.0) return no_hit;
    const q = oc - d * splat(b);
    const disc = r * r - dot(q, q);
    if (disc < 0.0) return no_hit;
    const sq = @sqrt(disc);
    const t0 = -b - sq;
    if (t0 > t_eps) return t0;
    const t1 = -b + sq;
    if (t1 > t_eps) return t1;
    return no_hit;
}

/// Whether the ray from p (outside the sphere) along unit l meets it.
inline fn blocks(p: Vec3, l: Vec3, c: Vec3, comptime r: f32) bool {
    const oc = c - p;
    const b = dot(oc, l);
    if (b <= 0.0) return false;
    const q = oc - l * splat(b);
    return dot(q, q) <= r * r;
}

/// Shore colour along (o, d), or null (trace.zig's shore(), general
/// origin).
inline fn shore(o: Vec3, d: Vec3) ?Vec3 {
    if (!(d[2] > 0.0)) return null;
    const dz = scene.shore_z - o[2];
    const yn = o[1] * d[2] + d[1] * dz;
    if (!(yn >= 0.0 and yn < scene.shore_height * d[2])) return null;
    const xn = o[0] * d[2] + d[0] * dz;
    if (!(xn > -scene.shore_half_width * d[2] and xn <= scene.shore_half_width * d[2])) return null;
    const ts = dz / d[2];
    const xs = o[0] + d[0] * ts;
    const ys = o[1] + d[1] * ts;
    const u = @min(@max((scene.shore_half_width - xs) * scene.shore_texels_per_unit, 0.0), 255.0);
    const v = @min(@max((scene.shore_height - ys) * scene.shore_texels_per_unit, 0.0), @as(f32, @floatFromInt(scene.shore_rows - 1)));
    return scene.shore_texel(&fz.sc, @intFromFloat(u), @intFromFloat(v));
}

/// The logo's mask samples along the chord (PLAN.md M2.2 "Hit", K = 4
/// whatever the variant's iris_samples).
const logo_samples = 4;
const logo_inv_s: f32 = 1.0 / iris.half_size;
/// i / (K - 1) as iris.hit rounds them.
const logo_fracs: [logo_samples]f32 = blk: {
    var t: [logo_samples]f32 = undefined;
    for (&t, 0..) |*f, i| f.* = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(logo_samples - 1));
    break :blk t;
};

/// The logo along (o, d) nearer than t_near: its colour (M2.2 face and side
/// shading), or null. `shadow`: only whether it is hit (the colour is not
/// used).
inline fn logo(o: Vec3, d: Vec3, t_near: f32, comptime shadow: bool) ?Vec3 {
    // Moving away from the bounding sphere's z range (integer sign tests on
    // d.z: most rays head for -z, the sun's side).
    const dz: i32 = @bitCast(d[2]);
    if (dz <= 0 and o[2] < comptime iris.centre[2] - iris.radius) return null;
    if (dz >= 0 and o[2] > comptime iris.centre[2] + iris.radius) return null;
    const oc = o - iris.centre;
    const b = dot(oc, d);
    const c = dot(oc, oc) - iris.radius * iris.radius;
    // Outside the bounding sphere and moving away.
    if (b >= 0.0 and c > 0.0) return null;
    const disc = b * b - c;
    if (!(disc >= 0.0)) return null;
    const sq = @sqrt(disc);
    const t_min = @max(-b - sq, t_eps);
    const t_max = @min(-b + sq, t_near);
    if (!(t_min < t_max)) return null;
    return logo_slab(oc, d, t_min, t_max, shadow);
}

/// iris.mask_fast out of line: the four samples share one copy.
noinline fn mask_at(u: f32, v: f32) bool {
    return iris.mask_fast(u, v);
}

/// iris.hit with K = logo_samples. Not inlined: only rays through the
/// bounding sphere get here.
noinline fn logo_slab(oc: Vec3, d: Vec3, t_min: f32, t_max: f32, shadow: bool) ?Vec3 {
    const fr = &fz.ir;
    const h = iris.half_thickness;
    const wo = dot(oc, fr.n);
    const wd = dot(d, fr.n);
    var ta: f32 = -math.inf_f32;
    var tb: f32 = math.inf_f32;
    if (@abs(wd) > 1e-6) {
        const inv = 1.0 / wd;
        const t_neg = (-h - wo) * inv;
        const t_pos = (h - wo) * inv;
        ta = @min(t_neg, t_pos);
        tb = @max(t_neg, t_pos);
    } else if (@abs(wo) > h) return null;
    const t0 = @max(ta, t_min);
    const t1 = @min(tb, t_max);
    if (!(t0 < t1)) return null;
    const uo = dot(oc, fr.eu);
    const ud = dot(d, fr.eu);
    const vo = oc[1] * logo_inv_s;
    const vd = d[1] * logo_inv_s;
    const dt = t1 - t0;
    for (logo_fracs, 0..) |frac, i| {
        const t = t0 + dt * frac;
        if (mask_at(uo + ud * t, vo + vd * t)) {
            if (shadow) return fr.side_col;
            if (i == 0 and ta >= t_min) {
                var spec = @max(0.0, dot(d, fz.sc.sun_dir) - wd * fr.nl2);
                inline for (0..5) |_| spec *= spec; // ^32
                const lit = if (wd < 0.0) fr.front_col else fr.back_col;
                return lit + fz.sc.sun_col * splat(0.6 * spec);
            }
            return fr.side_col;
        }
    }
    return null;
}

/// Which convex object a ray has just left (it cannot meet it again).
const Obj = enum(u8) { none, chrome, slot2, small };

/// Glass shadow transmission (M2 opacity 0.55).
const glass_vis: f32 = 1.0 - scene.glass_opacity;

/// vis(p, Ls): 0 behind the chrome, matte or small sphere or the logo,
/// 0.45 behind the glass only, else 1. `skip`: the matte sphere the point
/// lies on.
noinline fn vis(p: Vec3, l: Vec3, skip_slot2: bool) f32 {
    if (blocks(p, l, fz.c_chrome, scene.chrome.r)) return 0.0;
    if (fz.third and blocks(p, l, fz.c_small, scene.small.r)) return 0.0;
    const slot2_hit = !skip_slot2 and fz.slot2 != .none and blocks(p, l, fz.c_slot2, scene.slot2.r);
    if (slot2_hit and fz.slot2 == .matte) return 0.0;
    if (logo(p, l, no_hit, true) != null) return 0.0;
    return if (slot2_hit) glass_vis else 1.0;
}

// ---------------------------------------------------------------- shading helpers

/// tan(sun_radius), folded in f64.
const tan_sun: f32 = @floatCast(@tan(@as(f64, sun_radius) * (std.math.pi / 180.0)));

/// A direction on the sun disc: normalize(L + tan(sun_radius) sqrt(ua)
/// (cos(2 pi ub) e1 + sin(2 pi ub) e2)).
inline fn sun_sample(ua: f32, ub: f32) Vec3 {
    const rr = tan_sun * @sqrt(ua);
    const cs = math.sin_turns(ub + 0.25);
    const sn = math.sin_turns(ub);
    // e1, e2 and L are orthonormal, so |L + offset|^2 = 1 + x, x = rr^2 <=
    // tan^2(sun_radius) < 1e-3: 1 / sqrt(1 + x) = 1 - x / 2 + 3 x^2 / 8 to
    // within x^3 / 3 < 4e-10, below f32 rounding.
    const x = tan_sun * tan_sun * ua;
    const sc = 1.0 - x * (0.5 - 0.375 * x);
    return (fz.sc.sun_dir + fz.e1 * splat(rr * cs) + fz.e2 * splat(rr * sn)) * splat(sc);
}

/// sky(d) (d.y >= 0), with the disc or, after a diffuse bounce, without:
/// grad + sun_col 0.4 glow.
inline fn sky(d: Vec3, disc_on: bool) Vec3 {
    const sc = &fz.sc;
    const h = d[1];
    const grad = if (h < 0.3)
        sc.grad_lo_a + sc.grad_lo_b * splat(h)
    else
        sc.grad_hi_a + sc.grad_hi_b * splat(h);
    const s = dot(d, sc.sun_dir);
    if (s <= sc.sky_cut) return grad;
    var glow = scene.smoothstep_k(0.90, 1.00, s);
    glow = glow * glow;
    const g = grad + sc.sun_glow_col * splat(glow);
    if (!disc_on) return g;
    return g + sc.sun_disc_col * splat(scene.smoothstep_k(0.9950, 0.9995, s));
}

/// env(d): the shore if the ray meets it, else sky(d) with the disc.
inline fn env(o: Vec3, d: Vec3) Vec3 {
    if (shore(o, d)) |c| return c;
    return sky(d, true);
}

const steps: f32 = math.sin_table_len;

/// Ripple normal at water point p, unnormalised, (nx, 1, nz, |n|): the
/// three waves (preset scale) and the rings, times the distance fade.
inline fn water_normal(p: Vec3, fade: f32) @Vector(4, f32) {
    const wf = &fz.wf;
    var dx: f32 = 0.0;
    var dz: f32 = 0.0;
    inline for (water.waves, 0..) |wv, i| {
        const c = math.sin_steps((wv.kx * steps) * p[0] + (wv.kz * steps) * p[2] + wf.ph[i]);
        dx += wf.gx[i] * c;
        dz += wf.gz[i] * c;
    }
    const two_pi_k: f32 = 2.0 * std.math.pi * water.ring_k;
    const two_over_r: f32 = 2.0 / water.ring_r;
    var i: u32 = 0;
    while (i < wf.n_rings) : (i += 1) {
        const ex = p[0] - wf.rx[i];
        const ez = p[2] - wf.rz[i];
        if (!(@abs(ex) < water.ring_r and @abs(ez) < water.ring_r)) continue;
        const d2 = ex * ex + ez * ez;
        if (!(d2 < water.ring_r * water.ring_r and d2 > 1e-12)) continue;
        const inv = 1.0 / @sqrt(d2);
        const d = d2 * inv;
        const ph = (water.ring_k * steps) * d - wf.ring_ph;
        const sn = math.sin_steps(ph);
        const cs = math.sin_steps(ph + 0.25 * steps);
        const q = 1.0 - d * (1.0 / water.ring_r);
        const coef = water.ring_a * q * (two_pi_k * cs * q - two_over_r * sn) * inv;
        dx += coef * ex;
        dz += coef * ez;
    }
    const nx = -fade * dx;
    const nz = -fade * dz;
    return .{ nx, 1.0, nz, @sqrt(nx * nx + 1.0 + nz * nz) };
}

fn water_normal_f(p: Vec3, fade: f32) @Vector(4, f32) {
    return water_normal(p, fade);
}
fn vis_f(p: Vec3, l: Vec3, skip_slot2: bool) f32 {
    return vis(p, l, skip_slot2);
}
fn logo_f(o: Vec3, d: Vec3, t_near: f32) ?Vec3 {
    return logo(o, d, t_near, false);
}

inline fn max3(v: Vec3) f32 {
    return @reduce(.Max, v);
}

const eta_in: f32 = 1.0 / scene.glass_ior;
const inv_glass_r: f32 = 1.0 / scene.slot2.r;
const inv_small_r: f32 = 1.0 / scene.small.r;

// ---------------------------------------------------------------- the path

/// One path from (o, d), |d| = 1; pk is the pixel's RNG key for this pass.
fn radiance(o_in: Vec3, d_in: Vec3, pk: u32, eye_mask: u8) Vec3 {
    var o = o_in;
    var d = d_in;
    var lsum: Vec3 = splat(0.0);
    var thr: Vec3 = splat(1.0);
    var diffuse = false;
    var skip: Obj = .none;
    var inside = false;
    // The primary vertex tests only the objects its row may meet.
    var mask = eye_mask;
    var b: u32 = 0;
    while (true) : (b += 1) {
        if (b > 0 and max3(thr) < 1.0 / 1024.0) break;
        const terminal = b == max_bounces;
        // Dimensions 4 + 4b .. 7 + 4b.
        const dk = pk +% (4 + 4 * b) *% dim_stride;

        if (inside) {
            // The far side of the glass.
            const oc = o - fz.c_slot2;
            const bb = dot(oc, d);
            const cc = dot(oc, oc) - scene.slot2.r * scene.slot2.r;
            const t = -bb + @sqrt(@max(0.0, bb * bb - cc));
            const p = o + d * splat(t);
            const n = (p - fz.c_slot2) * splat(inv_glass_r);
            if (terminal) {
                lsum += thr * fz.sc.glass_far;
                break;
            }
            // Leaving: eta 1.5, normal -n, c = dot(d, n).
            const c = @max(0.0, dot(d, n));
            const k = 1.0 - scene.glass_ior * scene.glass_ior * (1.0 - c * c);
            const sk = @sqrt(@max(0.0, k));
            const f: f32 = if (k < 0.0) 1.0 else math.schlick(sk, scene.glass_f0);
            if (k < 0.0 or to_unit(lowbias32(dk +% 2 *% dim_stride)) < f) {
                d = math.reflect(d, n);
            } else {
                d = d * splat(scene.glass_ior) - n * splat(scene.glass_ior * c - sk);
                inside = false;
                skip = .slot2;
            }
            o = p;
            continue;
        }

        // Nearest sphere.
        var tn: f32 = no_hit;
        var which: Obj = .none;
        if (mask & m_chrome != 0 and skip != .chrome) {
            const t = hit_sphere(o, d, fz.c_chrome, scene.chrome.r);
            if (t < tn) {
                tn = t;
                which = .chrome;
            }
        }
        if (mask & m_slot2 != 0 and fz.slot2 != .none and skip != .slot2) {
            const t = hit_sphere(o, d, fz.c_slot2, scene.slot2.r);
            if (t < tn) {
                tn = t;
                which = .slot2;
            }
        }
        if (mask & m_small != 0 and fz.third and skip != .small) {
            const t = hit_sphere(o, d, fz.c_small, scene.small.r);
            if (t < tn) {
                tn = t;
                which = .small;
            }
        }
        // The logo: only a sphere can be nearer.
        if (mask & m_logo != 0) {
            if (@call(split, logo_f, .{ o, d, tn })) |c| {
                lsum += thr * c;
                break;
            }
        }
        mask = m_all;

        if (which != .none) {
            const p = o + d * splat(tn);
            switch (which) {
                .chrome, .small => {
                    // No stripes (Adrian dropped them, M3.1). Chrome radius 1.
                    const n = if (which == .chrome) p - fz.c_chrome else (p - fz.c_small) * splat(inv_small_r);
                    const f = scene.sphere_tint;
                    if (terminal) {
                        const lambert = 0.25 + 0.75 * @max(0.0, dot(n, fz.sc.sun_dir));
                        lsum += thr * f * fz.sc.sun_col * splat(lambert);
                        break;
                    }
                    thr *= f;
                    d = math.reflect(d, n);
                    skip = which;
                },
                .slot2 => {
                    const n = (p - fz.c_slot2) * splat(inv_glass_r);
                    if (fz.slot2 == .glass) {
                        if (terminal) {
                            lsum += thr * fz.sc.glass_far;
                            break;
                        }
                        // Entering: eta 1 / 1.5, normal n; k > 0 always.
                        const c = @max(0.0, -dot(d, n));
                        const f = math.schlick(c, scene.glass_f0);
                        if (to_unit(lowbias32(dk +% 2 *% dim_stride)) < f) {
                            d = math.reflect(d, n);
                            skip = .slot2;
                        } else {
                            const k = 1.0 - eta_in * eta_in * (1.0 - c * c);
                            d = d * splat(eta_in) + n * splat(eta_in * c - @sqrt(@max(0.0, k)));
                            thr *= scene.glass_tint;
                            inside = true;
                            skip = .none;
                        }
                    } else {
                        // Matte: the sun through its disc, then a cosine
                        // bounce.
                        const ls = sun_sample(to_unit(lowbias32(dk)), to_unit(lowbias32(dk +% dim_stride)));
                        const ndl = dot(n, ls);
                        if (ndl > 0.0) {
                            const v = @call(split, vis_f, .{ p, ls, true });
                            lsum += thr * fz.sc.matte_sun * splat(ndl * v);
                        }
                        if (terminal) break;
                        const ua6 = to_unit(lowbias32(dk +% 2 *% dim_stride));
                        const ua7 = to_unit(lowbias32(dk +% 3 *% dim_stride));
                        const ra = @sqrt(ua6);
                        const e = onb(n);
                        const rc = ra * math.sin_turns(ua7 + 0.25);
                        const rs = ra * math.sin_turns(ua7);
                        d = e[0] * splat(rc) + n * splat(@sqrt(@max(0.0, 1.0 - ua6))) + e[1] * splat(rs);
                        thr *= scene.matte_albedo * splat(sky_fill);
                        diffuse = true;
                        skip = .slot2;
                    }
                },
                .none => unreachable,
            }
            o = p;
            continue;
        }

        if (shore(o, d)) |c| {
            lsum += thr * c;
            break;
        }

        if (!(d[1] < 0.0)) {
            lsum += thr * sky(d, !diffuse);
            break;
        }

        // Water: distance from this ray's origin is tw (|d| = 1).
        // tw = -o.y / d.y and g = 1 / (1 + fade_k tw) = d.y / kk with kk =
        // d.y - fade_k o.y, from one reciprocal of d.y kk (trace.zig).
        const kk = d[1] - water.fade_k * o[1];
        const winv = 1.0 / (d[1] * kk);
        const tw = @min(-o[1] * kk * winv, max_water_t);
        const p = vec3(o[0] + d[0] * tw, 0.0, o[2] + d[2] * tw);
        const g = d[1] * d[1] * winv;
        const n0 = @call(split, water_normal_f, .{ p, g * g });
        const ua6 = to_unit(lowbias32(dk +% 2 *% dim_stride));
        const ua7 = to_unit(lowbias32(dk +% 3 *% dim_stride));
        const rr = water_roughness * @sqrt(ua6);
        // normalize(normalize(n0) + t) = normalize(n0 + t |n0|).
        const rl = rr * n0[3];
        const n = math.normalize(vec3(n0[0], n0[1], n0[2]) + vec3(rl * math.sin_turns(ua7 + 0.25), 0.0, rl * math.sin_turns(ua7)));
        var r = math.reflect(d, n);
        if (r[1] < scene.min_reflect_y) {
            r[1] = scene.min_reflect_y;
            r = math.normalize(r);
        }
        const f = math.schlick(@max(0.0, -dot(d, n)), scene.water_f0);
        const ls = sun_sample(to_unit(lowbias32(dk)), to_unit(lowbias32(dk +% dim_stride)));
        const v = @call(split, vis_f, .{ p, ls, false });
        const base = fz.sc.water_deep + fz.sc.water_scatter * splat(v);
        var spec = @max(0.0, dot(r, ls));
        inline for (0..6) |_| spec *= spec; // ^64
        lsum += thr * (base * splat(1.0 - f) + fz.sc.water_spec_col * splat(spec * v));
        if (terminal) {
            lsum += thr * env(p, r) * splat(f);
            break;
        }
        thr *= splat(f);
        d = r;
        o = p;
        skip = .none;
    }
    return lsum;
}

// ---------------------------------------------------------------- columns

const u_step: f32 = camera.tan_h / 80.0;

/// One sample for every pixel of column `cursor`, then the next column.
noinline fn trace_column() void {
    const x: u32 = cursor;
    const n = n_col[x];
    const inv: f32 = 1.0 / @as(f32, @floatFromInt(n + 1));
    const na0 = n *% r2_a0;
    const na1 = n *% r2_a1;
    const fx: f32 = @floatFromInt(x);
    const col = arena.words[x * height ..][0..height];
    const pk_col = n *% (64 * dim_stride) +% x;
    const uc_col = (fx + 0.5 - 80.0) * u_step;
    var spans: [4][2]u32 = undefined;
    for (&spans, &fz.proj) |*sp, *pj| sp.* = rows_of(pj, uc_col);
    for (col, 0..) |*w, yi| {
        const y: u32 = @intCast(yi);
        var mask: u8 = 0;
        inline for (spans, 0..) |sp, i| {
            // lo <= y < hi as one unsigned compare, no branch.
            mask |= @as(u8, @intFromBool(y -% sp[0] < sp[1] -% sp[0])) << i;
        }
        const pk = pk_col +% y * width;
        const bn0 = @as(u32, bluenoise[(y & 63) * 64 + (x & 63)]) << 24;
        const bn1 = @as(u32, bluenoise[((y + 32) & 63) * 64 + ((x + 32) & 63)]) << 24;
        const px = fx + to_unit(bn0 +% na0);
        const py = @as(f32, @floatFromInt(y)) + to_unit(bn0 +% na1);
        const su = (px - 80.0) * u_step;
        const sv = -(py - 64.0) * u_step;
        const wdir = fz.fwd + fz.right * splat(su) + fz.up * splat(sv);
        var o = fz.eye;
        var d: Vec3 = undefined;
        if (dof) {
            const rl = lens_radius * @sqrt(to_unit(bn1 +% na0));
            const a = to_unit(bn1 +% na1);
            const off = fz.right * splat(rl * math.sin_turns(a + 0.25)) + fz.up * splat(rl * math.sin_turns(a));
            // P - eye = w f / dot(w, fwd) = w f (the basis is orthonormal:
            // dot(w, fwd) = 1 to f32 rounding); P - o = that - off.
            const pe = wdir * splat(fz.focus);
            o = fz.eye + off;
            d = math.normalize(pe - off);
        } else {
            d = math.normalize(wdir);
        }
        const s = @min(@call(split, radiance, .{ o, d, pk, mask }), splat(sample_clamp));

        const dec = decode(w.*);
        const m = dec + (s - dec) * splat(inv);
        const h = hash(pk, 63);
        const uc = vec3(
            @as(f32, @floatFromInt(h >> 21)) * (1.0 / 2048.0),
            @as(f32, @floatFromInt((h >> 10) & 2047)) * (1.0 / 2048.0),
            @as(f32, @floatFromInt(h & 1023)) * (1.0 / 1024.0),
        );
        // Non-negative, so truncation is the floor.
        const q = @min(max_q, m * q_scale + uc);
        const qr: u32 = @intFromFloat(q[0]);
        const qg: u32 = @intFromFloat(q[1]);
        const qb: u32 = @intFromFloat(q[2]);
        w.* = qr | (qg << 11) | (qb << 22);
    }
    n_col[x] = n + 1;
    cursor = if (x + 1 == width) 0 else x + 1;
}
