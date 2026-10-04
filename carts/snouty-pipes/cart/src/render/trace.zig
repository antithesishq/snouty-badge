//! Track A: ray vs the pipe primitives (SPEC.md section 4), solved per pixel
//! with f32 only. Every function returns the FRONT entry of a closed solid:
//! a capped cylinder, a sphere, or a slice of a quarter torus closed by flat
//! caps. Because each piece is a closed solid, drawing a path in consecutive
//! s slices gives the same nearest hit per pixel as drawing it in one go: the
//! first entry into a union is the nearest of the first entries into its
//! parts, and the seam caps always lie behind the tube wall.
//!
//! Rays are `o + t * d` with `o` the eye relative to the primitive and `d`
//! the camera ray (component along the view axis 1, so t = view depth).
//! Normals are unit length and face the ray.
const std = @import("std");
const math = @import("../math.zig");

const Vec3 = math.Vec3;

pub const Hit = struct {
    t: f32,
    n: Vec3,
};

/// Capped cylinder of radius `r` around the world axis `axis` through the
/// origin, spanning axial coordinates [lo, hi]. `o` is the eye relative to a
/// point on the axis whose axial coordinate is 0. 2D circle quadratic on the
/// two other axes; when the wall entry falls outside [lo, hi] the ray may
/// still enter through the end disc it faces.
pub inline fn cylinder(comptime axis: u2, o: Vec3, d: Vec3, r: f32, lo: f32, hi: f32) ?Hit {
    const b_ax = (@as(u32, axis) + 1) % 3;
    const c_ax = (@as(u32, axis) + 2) % 3;
    // Loop invariant for a fixed primitive: hoisted out of the pixel loop.
    const c = o[b_ax] * o[b_ax] + o[c_ax] * o[c_ax] - r * r;
    const a = d[b_ax] * d[b_ax] + d[c_ax] * d[c_ax];
    const hb = o[b_ax] * d[b_ax] + o[c_ax] * d[c_ax];
    const disc = hb * hb - a * c;
    if (disc < 0) return null;
    // Where the ray is first inside the infinite tube: its wall entry, or
    // the eye itself when the eye is lined up with the axis (c < 0; the eye
    // is never inside the solid, so then only a cap can be hit).
    var t_in: f32 = 0;
    if (c >= 0) {
        if (a < 1e-12) return null;
        t_in = (-hb - @sqrt(disc)) / a;
    }
    const z = o[axis] + t_in * d[axis];
    if (z >= lo and z <= hi) {
        if (c < 0 or t_in <= 0) return null;
        var n: Vec3 = (o + d * math.splat(t_in)) * math.splat(1.0 / r);
        n[axis] = 0;
        return .{ .t = t_in, .n = n };
    }
    // Cap: the ray reached the tube below lo heading up, or above hi heading
    // down; it enters the solid where it crosses that end plane, if the
    // crossing is still inside the radius.
    const plane = if (z < lo) lo else hi;
    if ((z < lo) == (d[axis] <= 0)) return null;
    const t_cap = (plane - o[axis]) / d[axis];
    if (t_cap <= 0) return null;
    const pb = o[b_ax] + t_cap * d[b_ax];
    const pc = o[c_ax] + t_cap * d[c_ax];
    if (pb * pb + pc * pc > r * r) return null;
    var n: Vec3 = @splat(0);
    n[axis] = if (d[axis] > 0) -1.0 else 1.0;
    return .{ .t = t_cap, .n = n };
}

/// Sphere of radius `r` centred at the origin; `o` is the eye relative to
/// the centre.
pub inline fn sphere(o: Vec3, d: Vec3, r: f32) ?Hit {
    const c = math.dot(o, o) - r * r;
    const hb = math.dot(o, d);
    const a = math.dot(d, d);
    const disc = hb * hb - a * c;
    if (disc < 0) return null;
    const t = (-hb - @sqrt(disc)) / a;
    if (t <= 0) return null;
    return .{ .t = t, .n = (o + d * math.splat(t)) * math.splat(1.0 / r) };
}

/// Sphere-tracing step limit for the elbow (SPEC: at most 24).
pub const elbow_max_steps = 24;
/// The march stops this close to the surface (world units, ~1/80 px at
/// the usual 13 px per cell) and then snaps exactly onto it.
const elbow_eps: f32 = 1e-3;

/// A slice of a quarter torus: the tube of radius `r_minor` around the arc
/// of radius `r_major` about `centre`, from direction `u` (angle 0) towards
/// `v` (angle 90 degrees), cut to angles [s0, s1] * 90 degrees by two flat
/// caps through the torus axis `w = u x v`. Built once per primitive; `hit`
/// is the per-pixel part.
pub const Elbow = struct {
    /// Eye in the local (u, v, w) frame.
    o: Vec3,
    u: Vec3,
    v: Vec3,
    w: Vec3,
    r_major: f32,
    r_minor: f32,
    /// Cap planes through the axis: in-plane unit normals (u, v components),
    /// pointing into the slice. `dot(p.uv, n0) >= 0` past the start cap,
    /// `dot(p.uv, n1) >= 0` before the end cap.
    n0: [2]f32,
    n1: [2]f32,
    /// Bounding sphere of the slice (local centre, squared radius).
    bc: Vec3,
    br2: f32,
    /// Quadratic constant of the bounding sphere: |o - bc|^2 - br^2.
    bcc: f32,

    pub fn init(eye: Vec3, centre: Vec3, u: Vec3, v: Vec3, r_major: f32, r_minor: f32, s0: f32, s1: f32) Elbow {
        const w = math.cross(u, v);
        const rel = eye - centre;
        const o = math.vec3(math.dot(rel, u), math.dot(rel, v), math.dot(rel, w));
        // Same s gives the same angle in neighbouring slices: shared seams.
        const c0 = math.cos_turns(s0 * 0.25);
        const sn0 = math.sin_turns(s0 * 0.25);
        const c1 = math.cos_turns(s1 * 0.25);
        const sn1 = math.sin_turns(s1 * 0.25);
        // Arc ends; the chord midpoint plus half the chord bounds the arc
        // (slice angle <= 90 degrees), and the tube adds r_minor.
        const a0 = math.vec3(c0 * r_major, sn0 * r_major, 0);
        const a1 = math.vec3(c1 * r_major, sn1 * r_major, 0);
        const bc = (a0 + a1) * math.splat(0.5);
        const br = math.length(a1 - a0) * 0.5 + r_minor + 1e-3;
        const ob = o - bc;
        return .{
            .o = o,
            .u = u,
            .v = v,
            .w = w,
            .r_major = r_major,
            .r_minor = r_minor,
            .n0 = .{ -sn0, c0 },
            .n1 = .{ sn1, -c1 },
            .bc = bc,
            .br2 = br * br,
            .bcc = math.dot(ob, ob) - br * br,
        };
    }

    /// Signed distance bound of the slice at local point p, and which
    /// surface is nearest: 0 tube, 1 start cap, 2 end cap.
    inline fn sdf(e: *const Elbow, p: Vec3) struct { f32, u2 } {
        const rho = @sqrt(p[0] * p[0] + p[1] * p[1]);
        const q = rho - e.r_major;
        const dt = @sqrt(q * q + p[2] * p[2]) - e.r_minor;
        const d0 = -(p[0] * e.n0[0] + p[1] * e.n0[1]);
        const d1 = -(p[0] * e.n1[0] + p[1] * e.n1[1]);
        if (dt >= d0 and dt >= d1) return .{ dt, 0 };
        return if (d0 >= d1) .{ d0, 1 } else .{ d1, 2 };
    }

    pub inline fn hit(e: *const Elbow, d_world: Vec3) ?Hit {
        const d = math.vec3(math.dot(d_world, e.u), math.dot(d_world, e.v), math.dot(d_world, e.w));
        // Bounding sphere: rejects most of the screen rect cheaply and gives
        // the march its start and end.
        const ob = e.o - e.bc;
        const hb = math.dot(ob, d);
        const a = math.dot(d, d);
        const disc = hb * hb - a * e.bcc;
        if (disc < 0) return null;
        const sq = @sqrt(disc);
        const inv_a = 1.0 / a;
        var t = @max(0, (-hb - sq) * inv_a);
        var t_end = (-hb + sq) * inv_a;
        // The tube also lies in the slab |w| <= r_minor: seen face-on that
        // leaves the march only a short stretch to cover.
        if (@abs(d[2]) > 1e-6) {
            const inv_w = 1.0 / d[2];
            const ta = (-e.r_minor - e.o[2]) * inv_w;
            const tb = (e.r_minor - e.o[2]) * inv_w;
            t = @max(t, @min(ta, tb));
            t_end = @min(t_end, @max(ta, tb));
            if (t > t_end) return null;
        }
        // SDF distances are in world units; t advances per |d|.
        const inv_len = 1.0 / @sqrt(a);
        var which: u2 = 0;
        var dist: f32 = math.inf_f32;
        var i: u32 = 0;
        while (i < elbow_max_steps) : (i += 1) {
            const r = e.sdf(e.o + d * math.splat(t));
            dist = r[0];
            which = r[1];
            if (dist < elbow_eps) break;
            t += dist * inv_len;
            if (t > t_end) return null;
        }
        // A grazing march that ran out of steps still counts when close.
        if (dist > 4e-3) return null;
        switch (which) {
            0 => {
                // Two Newton steps on the tube distance along the ray land on
                // the exact surface, so every slice agrees on t.
                var n: Vec3 = undefined;
                for (0..2) |_| {
                    const p = e.o + d * math.splat(t);
                    const rho = @sqrt(p[0] * p[0] + p[1] * p[1]);
                    const k = 1.0 - e.r_major / rho;
                    const g = math.vec3(p[0] * k, p[1] * k, p[2]);
                    const gl = @sqrt(math.dot(g, g));
                    n = g * math.splat(1.0 / gl);
                    const dn = math.dot(n, d);
                    if (dn > -1e-4) break;
                    t -= (gl - e.r_minor) / dn;
                }
                const p = e.o + d * math.splat(t);
                const rho = @sqrt(p[0] * p[0] + p[1] * p[1]);
                const k = 1.0 - e.r_major / rho;
                const nl = math.normalize(math.vec3(p[0] * k, p[1] * k, p[2]));
                return .{ .t = t, .n = e.to_world(nl) };
            },
            else => {
                // Exact ray vs cap plane (through the axis).
                const nc = if (which == 1) e.n0 else e.n1;
                const dd = d[0] * nc[0] + d[1] * nc[1];
                if (dd <= 1e-6) return null;
                const tc = -(e.o[0] * nc[0] + e.o[1] * nc[1]) / dd;
                if (tc <= 0) return null;
                return .{ .t = tc, .n = e.to_world(math.vec3(-nc[0], -nc[1], 0)) };
            },
        }
    }

    inline fn to_world(e: *const Elbow, n: Vec3) Vec3 {
        return e.u * math.splat(n[0]) + e.v * math.splat(n[1]) + e.w * math.splat(n[2]);
    }

    /// Point-in-solid test (host tests only).
    pub fn inside_local(e: *const Elbow, p: Vec3) bool {
        return e.sdf(p)[0] <= 0;
    }
};

// ---------------------------------------------------------------------------
// Host tests: every intersection against brute-force sampling along the ray.

const Lcg = struct {
    s: u32,
    fn next(self: *Lcg) f32 {
        self.s = self.s *% 1664525 +% 1013904223;
        return @as(f32, @floatFromInt(self.s >> 8)) * (1.0 / 16777216.0);
    }
    fn range(self: *Lcg, lo: f32, hi: f32) f32 {
        return lo + (hi - lo) * self.next();
    }
};

/// First t in (0, t_max] where `inside(o + t d)` holds, by stepping `dt`.
fn brute(o: Vec3, d: Vec3, t_max: f32, dt: f32, ctx: anytype) ?f32 {
    var t: f32 = dt;
    while (t < t_max) : (t += dt) {
        if (ctx.inside(o + d * math.splat(t))) return t;
    }
    return null;
}

/// Random eye at distance ~[8, 14] and a ray aimed near `aim`.
fn random_ray(rng: *Lcg, aim: Vec3, spread: f32) struct { Vec3, Vec3 } {
    const eye = math.normalize(math.vec3(rng.range(-1, 1), rng.range(-1, 1), rng.range(-1, 1))) * math.splat(rng.range(8, 14));
    const target = aim + math.vec3(rng.range(-spread, spread), rng.range(-spread, spread), rng.range(-spread, spread));
    // Scale like a camera ray: length in [1, 1.3].
    const d = math.normalize(target - eye) * math.splat(rng.range(1.0, 1.3));
    return .{ eye, d };
}

fn expect_agree(analytic: ?Hit, reference: ?f32, d: Vec3, dt: f32, misses: *u32) !void {
    if (analytic) |h| {
        if (reference) |tr| {
            try std.testing.expect(@abs(h.t - tr) <= dt * 1.5 + 1e-3);
            try std.testing.expectApproxEqAbs(@as(f32, 1.0), math.length(h.n), 1e-3);
            try std.testing.expect(math.dot(h.n, d) < 1e-3);
        } else misses.* += 1;
    } else if (reference != null) misses.* += 1;
}

test "cylinder matches brute force" {
    var rng: Lcg = .{ .s = 1 };
    var misses: u32 = 0;
    var hits: u32 = 0;
    const r: f32 = 0.18;
    inline for (0..3) |axis| {
        for (0..600) |_| {
            const lo = rng.range(-0.6, 0.2);
            const hi = lo + rng.range(0.05, 0.6);
            const ray = random_ray(&rng, math.splat(0), 0.5);
            const Ctx = struct {
                lo: f32,
                hi: f32,
                r: f32,
                fn inside(c: @This(), p: Vec3) bool {
                    const b = p[(axis + 1) % 3];
                    const cc = p[(axis + 2) % 3];
                    return b * b + cc * cc <= c.r * c.r and p[axis] >= c.lo and p[axis] <= c.hi;
                }
            };
            const dt: f32 = 2e-3;
            const ref = brute(ray[0], ray[1], 20, dt, Ctx{ .lo = lo, .hi = hi, .r = r });
            const h = cylinder(axis, ray[0], ray[1], r, lo, hi);
            if (h != null) hits += 1;
            try expect_agree(h, ref, ray[1], dt, &misses);
        }
    }
    try std.testing.expect(hits > 200);
    // Rays that only graze an edge may disagree with the sampler.
    try std.testing.expect(misses <= 4);
}

test "cylinder hits its cap when the eye is lined up with the axis" {
    const o = math.vec3(0.05, 0.02, 20);
    const d = math.vec3(0, 0, -1);
    const h = cylinder(2, o, d, 0.18, -0.5, 0.5).?;
    try std.testing.expectApproxEqAbs(@as(f32, 19.5), h.t, 1e-4);
    try std.testing.expectEqual(@as(f32, 1.0), h.n[2]);
}

test "sphere matches brute force" {
    var rng: Lcg = .{ .s = 7 };
    var misses: u32 = 0;
    for (0..1000) |_| {
        const ray = random_ray(&rng, math.splat(0), 0.4);
        const Ctx = struct {
            fn inside(_: @This(), p: Vec3) bool {
                return math.dot(p, p) <= 0.27 * 0.27;
            }
        };
        const dt: f32 = 2e-3;
        try expect_agree(sphere(ray[0], ray[1], 0.27), brute(ray[0], ray[1], 20, dt, Ctx{}), ray[1], dt, &misses);
    }
    try std.testing.expect(misses <= 2);
}

test "elbow slices match brute force" {
    var rng: Lcg = .{ .s = 99 };
    var misses: u32 = 0;
    var hits: u32 = 0;
    const centre = math.vec3(0.3, -0.2, 0.1);
    const frames = [_][2]Vec3{
        .{ math.vec3(1, 0, 0), math.vec3(0, 1, 0) },
        .{ math.vec3(0, 0, -1), math.vec3(1, 0, 0) },
        .{ math.vec3(0, -1, 0), math.vec3(0, 0, 1) },
    };
    const slices = [_][2]f32{ .{ 0, 1 }, .{ 0, 0.25 }, .{ 0.25, 0.5 }, .{ 0.6, 0.95 } };
    for (frames) |f| {
        for (slices) |sl| {
            for (0..150) |_| {
                const ray = random_ray(&rng, centre + (f[0] + f[1]) * math.splat(0.3), 0.4);
                const e = Elbow.init(ray[0], centre, f[0], f[1], 0.5, 0.18, sl[0], sl[1]);
                const Ctx = struct {
                    e: *const Elbow,
                    c: Vec3,
                    fn inside(ctx: @This(), p: Vec3) bool {
                        const rel = p - ctx.c;
                        return ctx.e.inside_local(math.vec3(math.dot(rel, ctx.e.u), math.dot(rel, ctx.e.v), math.dot(rel, ctx.e.w)));
                    }
                };
                const dt: f32 = 2e-3;
                const h = e.hit(ray[1]);
                if (h != null) hits += 1;
                try expect_agree(h, brute(ray[0], ray[1], 20, dt, Ctx{ .e = &e, .c = centre }), ray[1], dt, &misses);
            }
        }
    }
    try std.testing.expect(hits > 400);
    try std.testing.expect(misses <= 12);
}

test "elbow slices agree with the whole elbow on t" {
    // A ray that hits the tube wall in slice [0.25, 0.5] gives the same t
    // there as in the whole quarter.
    const centre = math.vec3(0, 0, 0);
    const u = math.vec3(1, 0, 0);
    const v = math.vec3(0, 1, 0);
    const eye = math.vec3(2, 3, 10);
    const p = math.vec3(0.5 * math.cos_turns(0.09), 0.5 * math.sin_turns(0.09), 0);
    const d = (p - eye) * math.splat(1.0 / 9.0);
    const whole = Elbow.init(eye, centre, u, v, 0.5, 0.18, 0, 1).hit(d).?;
    const part = Elbow.init(eye, centre, u, v, 0.5, 0.18, 0.25, 0.5).hit(d).?;
    try std.testing.expectApproxEqAbs(whole.t, part.t, 1e-5);
}
