//! The spinning Iris logo (PLAN.md M2.2 "Iris logo"): the mark M(U, V)
//! extruded into a slab of half-thickness h, standing on the water in front
//! of the shore and turning about its vertical axis. This module has the
//! per-frame axes, the mask, the slab-and-samples hit and the shading;
//! trace.zig decides which rays get here (bounding sphere, per-frame bounds)
//! and clips the chord.
const math = @import("math.zig");
const camera = @import("camera.zig");
const scene = @import("scene.zig");
const Vec3 = math.Vec3;
const vec3 = math.vec3;
const splat = math.splat;

/// M3.1: x = -15.5 (was -13.5), right of Harbour Centre as seen from the
/// lake, so the mark stands clear of the towers instead of in front of them.
pub const centre = vec3(-15.5, 1.8, 12.0);
/// Half-size S: the mark's unit square spans U, V in [-1, 1].
pub const half_size: f32 = 1.5;
/// Half-thickness h of the slab, world units.
pub const half_thickness: f32 = 0.12;
/// Bounding sphere radius: mark radius 1.042 S plus h.
pub const radius: f32 = 1.57;
/// Turns per orbit (30 s): 5 s per turn at every frame rate.
const spin_turns = 6;

/// Linear of sRGB (255, 159, 145).
const col = vec3(1.0, 0.3467, 0.2831);
const side_col = col * splat(0.18);
const inv_s: f32 = 1.0 / half_size;

/// Per-frame axes and face colours.
pub const Frame = struct {
    /// Slab normal n = (-sin phi, 0, -cos phi): faces the lake at phi = 0.
    n: Vec3,
    /// e_u / S = (-cos phi, 0, sin phi) / S, so U = dot(q, eu).
    eu: Vec3,
    /// Lit face colour seen from the side n points to (dot(d, n) < 0) and
    /// from the other side: iris * (0.30 + 0.70 * max(0, dot(N, L))).
    front_col: Vec3,
    back_col: Vec3,
    /// 2 dot(n, L): dot(reflect(d, N), L) = dot(d, L) - dot(d, n) * nl2 for
    /// either sign of N.
    nl2: f32,
    /// The side colour, faded.
    side_col: Vec3,
};

/// phi = (6 t mod orbit_frames) / orbit_frames turns (t the scene time in
/// frames), from the camera's orbit sin/cos table (the same angles, rounded
/// once from f64). `sf` gives the sun and the fade.
pub fn at_frame(t: u32, sf: *const scene.Frame, fade: f32) Frame {
    const nf = camera.orbit_frames;
    const sc = camera.orbit_sincos[(spin_turns * (t % nf)) % nf];
    const s = sc[0];
    const c = sc[1];
    const n = vec3(-s, 0.0, -c);
    const nl = math.dot(n, sf.sun_dir);
    const f = splat(fade);
    return .{
        .n = n,
        .eu = vec3(-c, 0.0, s) * splat(inv_s),
        .front_col = col * splat(0.30 + 0.70 * @max(0.0, nl)) * f,
        .back_col = col * splat(0.30 + 0.70 * @max(0.0, -nl)) * f,
        .nl2 = 2.0 * nl,
        .side_col = side_col * f,
    };
}

/// The top-left bracket (the small inner fillets dropped).
inline fn bracket(u: f32, v: f32) bool {
    return u <= 0.293 and v >= -0.293 and u >= -1.0 and v <= 1.0 and
        !(u > -0.65 and v < 0.65) and
        (u >= 0.0 or v <= 0.0 or u * u + v * v <= 1.0);
}

/// M(U, V) = diamond or TL or BR, BR(U, V) = TL(-U, -V).
pub inline fn mask(u: f32, v: f32) bool {
    return @abs(u) + @abs(v) <= 0.414 or bracket(u, v) or bracket(-u, -v);
}

// The mask through a lookup grid: cells of 1/16 over [-17/16, 17/16]^2,
// which holds every sample (samples lie in the bounding sphere, so |U|,
// |V| <= radius / S < 1.047). A cell is `in` or `out` only if every atomic
// test of M has one value over the whole cell grown by grid_eps, so the
// lookup gives exactly what mask() gives in f32 (a sample that rounds into
// a neighbouring cell is still inside that cell's grown box, where no test
// is within reach of f32 rounding); `edge` cells run mask().
const grid_n = 34;
const grid_scale: f32 = 16.0;
const grid_offset: f32 = 17.0;
const grid_eps: f64 = 1e-3;
const Cell = enum(u8) { out, in, edge };

/// Three-valued truth of a test over a box.
const Tri = enum { no, yes, maybe };

fn tri_not(a: Tri) Tri {
    return switch (a) {
        .no => .yes,
        .yes => .no,
        .maybe => .maybe,
    };
}

fn tri_and(list: []const Tri) Tri {
    var r: Tri = .yes;
    for (list) |a| {
        if (a == .no) return .no;
        if (a == .maybe) r = .maybe;
    }
    return r;
}

fn tri_or(list: []const Tri) Tri {
    var r: Tri = .no;
    for (list) |a| {
        if (a == .yes) return .yes;
        if (a == .maybe) r = .maybe;
    }
    return r;
}

/// x <= c for x in [lo, hi] (x >= c is -x <= -c).
fn tri_le(lo: f64, hi: f64, c: f64) Tri {
    if (hi <= c) return .yes;
    if (lo > c) return .no;
    return .maybe;
}

/// x < c for x in [lo, hi].
fn tri_lt(lo: f64, hi: f64, c: f64) Tri {
    if (hi < c) return .yes;
    if (lo >= c) return .no;
    return .maybe;
}

/// min and max of |x| over [lo, hi].
fn abs_range(lo: f64, hi: f64) [2]f64 {
    const a = @abs(lo);
    const b = @abs(hi);
    return .{ if (lo <= 0 and hi >= 0) 0 else @min(a, b), @max(a, b) };
}

/// bracket() over the box [ua, ub] x [va, vb].
fn bracket_box(ua: f64, ub: f64, va: f64, vb: f64) Tri {
    const au = abs_range(ua, ub);
    const av = abs_range(va, vb);
    const r2_lo = au[0] * au[0] + av[0] * av[0];
    const r2_hi = au[1] * au[1] + av[1] * av[1];
    return tri_and(&.{
        tri_le(ua, ub, 0.293),
        tri_le(-vb, -va, 0.293),
        tri_le(-ub, -ua, 1.0),
        tri_le(va, vb, 1.0),
        tri_not(tri_and(&.{ tri_lt(-ub, -ua, 0.65), tri_lt(va, vb, 0.65) })),
        tri_or(&.{ tri_le(-ub, -ua, 0.0), tri_le(va, vb, 0.0), tri_le(r2_lo, r2_hi, 1.0) }),
    });
}

const grid: [grid_n][grid_n]Cell = blk: {
    @setEvalBranchQuota(400000);
    var g: [grid_n][grid_n]Cell = undefined;
    for (0..grid_n) |j| {
        for (0..grid_n) |i| {
            const ua = (@as(f64, @floatFromInt(i)) - grid_offset) / grid_scale - grid_eps;
            const ub = (@as(f64, @floatFromInt(i + 1)) - grid_offset) / grid_scale + grid_eps;
            const va = (@as(f64, @floatFromInt(j)) - grid_offset) / grid_scale - grid_eps;
            const vb = (@as(f64, @floatFromInt(j + 1)) - grid_offset) / grid_scale + grid_eps;
            const au = abs_range(ua, ub);
            const av = abs_range(va, vb);
            const m = tri_or(&.{
                tri_le(au[0] + av[0], au[1] + av[1], 0.414),
                bracket_box(ua, ub, va, vb),
                bracket_box(-ub, -ua, -vb, -va),
            });
            g[j][i] = switch (m) {
                .no => .out,
                .yes => .in,
                .maybe => .edge,
            };
        }
    }
    break :blk g;
};

/// mask(u, v), from the grid where the cell decides it.
inline fn mask_fast(u: f32, v: f32) bool {
    const iu: u32 = @bitCast(@as(i32, @intFromFloat(@floor(u * grid_scale + grid_offset))));
    const iv: u32 = @bitCast(@as(i32, @intFromFloat(@floor(v * grid_scale + grid_offset))));
    if (iu >= grid_n or iv >= grid_n) return false;
    return switch (grid[iv][iu]) {
        .out => false,
        .in => true,
        .edge => mask(u, v),
    };
}

/// Colour of the ray (o, d) against the logo, or null. `oc` = o - centre,
/// (t_min, t_max) the bounding-sphere chord already clipped to t > 1e-3 and
/// to the nearer sphere hit, t_min < t_max. The slab |W| <= h along n cut
/// to the chord, sampled at K evenly spaced points from its entry t0 to its
/// exit t1; the first sample inside the mask is the hit. A hit at the first
/// sample where t0 is the slab entry is on a face (lambert and highlight),
/// any other on the side (flat). Not inlined: only rays whose chord is not
/// empty get here.
pub fn hit(oc: Vec3, d: Vec3, t_min: f32, t_max: f32, fr: *const Frame, sf: *const scene.Frame) ?Vec3 {
    const h = half_thickness;
    const wo = math.dot(oc, fr.n);
    const wd = math.dot(d, fr.n);
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
    const uo = math.dot(oc, fr.eu);
    const ud = math.dot(d, fr.eu);
    const vo = oc[1] * inv_s;
    const vd = d[1] * inv_s;
    const dt = t1 - t0;
    const k = scene.iris_samples;
    inline for (0..k) |i| {
        const frac: f32 = comptime @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(k - 1));
        const t = t0 + dt * frac;
        if (mask_fast(uo + ud * t, vo + vd * t)) {
            if (i == 0 and ta >= t_min) {
                var spec = @max(0.0, math.dot(d, sf.sun_dir) - wd * fr.nl2);
                inline for (0..5) |_| spec *= spec; // ^32
                const lit = if (wd < 0.0) fr.front_col else fr.back_col;
                return lit + sf.sun_col * splat(0.6 * spec);
            }
            return fr.side_col;
        }
    }
    return null;
}
