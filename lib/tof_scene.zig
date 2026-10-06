//! The virtual TMF8820's SPAD-level scene (lib/tof_virtual.zig, docs/TOF.md
//! M2): what each SPAD of the 18x12 array sees, and the zone results a
//! user SPAD mask (spad_map_id 14) makes of it. The pre-defined maps keep
//! the M0 zone-level scene (tof_virtual.scene); only user masks look here.
//!
//! - Geometry: SPAD (x, y) of the array looks along 2.4 deg per column and
//!   5.6 deg per row from the optical centre (DS000693 7.4.1: one SPAD is
//!   2.4 x 5.6 deg). Rays as tangents in Q10 from tables (no float).
//!   Physical rows 0..11; an 18x10 mask without offset uses rows 1..10.
//!   +y is down.
//! - Each SPAD is sampled at two points (upper and lower half, 2.8 deg
//!   apart), so a SPAD on an edge returns two depths.
//! - Scene: a wall at ~1150 mm, tilted (farther to the right), a floor
//!   330 mm below the sensor, a box face at 700 mm on the right, and a
//!   ball of radius 100 mm (the "hand") drifting slowly at 360..510 mm
//!   (slow enough for a photo of a few seconds; what moves during a scan
//!   smears like a rolling shutter).
//! - Signal per sample: reflectivity x (1 m / distance)^2. A zone's
//!   returns are split at the nearest depth + `split_mm`: the near group
//!   is the first object, the rest (if strong enough) the second, each the
//!   signal-weighted mean depth, confidence from its signal.
//! - Dead SPADs ("screamers", disabled in production test, DS000693 6.1
//!   note 1) return nothing; a zone made only of dead SPADs reports no
//!   object.
const std = @import("std");
const types = @import("tof_types.zig");
const spad = @import("tof_spad.zig");

pub const phys_cols = spad.cols;
pub const phys_rows = spad.span_rows;

/// tan((x - 8.5) * 2.4 deg) in Q10 per column.
pub const tan_col = [phys_cols]i32{ -381, -333, -286, -240, -195, -151, -108, -64, -21, 21, 64, 108, 151, 195, 240, 286, 333, 381 };
/// tan((s - 11.5) * 2.8 deg) in Q10 per half row (two per SPAD row).
pub const tan_half_row = [2 * phys_rows]i32{ -645, -577, -513, -452, -393, -337, -282, -229, -177, -126, -75, -25, 25, 75, 126, 177, 229, 282, 337, 393, 452, 513, 577, 645 };

/// Dead SPADs (physical column, row). (6,4) and (7,4) together make a
/// coarse pair with no signal at all: a hole in the depth photo.
pub const dead = [_][2]u8{ .{ 6, 4 }, .{ 7, 4 }, .{ 11, 6 }, .{ 3, 9 }, .{ 14, 2 } };

pub const wall_mm: i64 = 1150;
pub const floor_mm: i64 = 330;
pub const box_mm: i64 = 700;
/// The box face, mm at its depth: x from .. to, y from .. to (+y down).
pub const box_x = [2]i64{ 150, 420 };
pub const box_y = [2]i64{ -60, 330 };
pub const ball_r: i64 = 100;
/// Depth split between a zone's first and second object.
pub const split_mm: u32 = 120;
/// No return beyond this.
pub const max_mm: i64 = 4000;

pub const Surface = enum(u8) { none, wall, floor, box, ball };
const refl = [5]u32{ 0, 140, 90, 200, 170 };

pub const Hit = struct {
    mm: u16 = 0,
    surface: Surface = .none,

    pub fn signal(h: Hit) u32 {
        if (h.surface == .none) return 0;
        // u32 throughout (refl <= 200, mm <= 4000): no 64-bit division
        // on the badge, where -Dtof-fake=true builds run this per SPAD.
        const d: u32 = @max(h.mm, 50);
        return @min(refl[@backingInt(h.surface)] * 1_000_000 / (d * d), 1_000_000);
    }
};

pub fn is_dead(x: i32, y: i32) bool {
    for (dead) |d| if (d[0] == x and d[1] == y) return true;
    return false;
}

/// The ball's centre at `t_us` (mm).
pub fn ball(t_us: u64) [3]i64 {
    return .{
        -240 + @as(i64, tri(t_us, 16_000_000, 480)),
        -110 + @as(i64, tri(t_us + 3_000_000, 11_000_000, 220)),
        360 + @as(i64, tri(t_us, 13_000_000, 150)),
    };
}

/// What the ray with tangents (tx, ty) in Q10 hits first at `t_us`.
pub fn trace(t_us: u64, tx: i32, ty: i32) Hit {
    var best: Hit = .{};
    var best_mm: i64 = max_mm + 1;
    // Wall: z = wall + 0.2 x  ->  z = wall / (1 - 0.2 tx).
    {
        const den: i64 = 1024 - @divTrunc(@as(i64, tx), 5);
        const z = @divTrunc(wall_mm * 1024, den);
        if (z < best_mm) {
            best_mm = z;
            best = .{ .mm = @intCast(z), .surface = .wall };
        }
    }
    // Floor: y = floor  ->  z = floor / ty.
    if (ty > 0) {
        const z = @divTrunc(floor_mm * 1024, ty);
        if (z < best_mm) {
            best_mm = z;
            best = .{ .mm = @intCast(z), .surface = .floor };
        }
    }
    // Box face at z = box.
    {
        const x = @divTrunc(box_mm * tx, 1024);
        const y = @divTrunc(box_mm * ty, 1024);
        if (x >= box_x[0] and x <= box_x[1] and y >= box_y[0] and y <= box_y[1] and box_mm < best_mm) {
            best_mm = box_mm;
            best = .{ .mm = @intCast(box_mm), .surface = .box };
        }
    }
    // Ball: |s D / 1024 - C| = r with D = (tx, ty, 1024); s is the depth.
    {
        const c = ball(t_us);
        const a: i64 = @as(i64, tx) * tx + @as(i64, ty) * ty + 1024 * 1024;
        const b: i64 = c[0] * tx + c[1] * ty + c[2] * 1024;
        const cc: i64 = c[0] * c[0] + c[1] * c[1] + c[2] * c[2] - ball_r * ball_r;
        const disc: i64 = b * b - a * cc;
        if (disc >= 0 and b > 0) {
            const z = @divTrunc((b - @as(i64, @intCast(isqrt(@intCast(disc))))) * 1024, a);
            if (z > 0 and z < best_mm) {
                best_mm = z;
                best = .{ .mm = @intCast(z), .surface = .ball };
            }
        }
    }
    if (best_mm > max_mm) return .{};
    return best;
}

/// Which scene the SPADs see: the room (the depth photo's, the default) or
/// the hand (docs/TOF.md M5: the carts' `-Dtof-fake=true` builds under the
/// STRIPES mask; the same wandering hand as tof_virtual's 3x3 scene).
pub const Kind = enum(u8) { room, hand };

/// The hand scene: a flat disc `hand_r_q10` (tangent, Q10) in radius at
/// 300..450 mm in front of a wall at `tof_virtual.wall_mm` (900), in view
/// 6.5 s of every 8, on tof_virtual.scene's path: its 1/256-zone
/// positions over map 6's 41 x 52 deg field, as tangents.
pub const hand_r_q10: i32 = 190;
pub const hand_wall_mm: i32 = 900;

pub fn hand_at(t_us: u64) ?[3]i64 {
    if (t_us % 8_000_000 >= 6_500_000) return null;
    const hx: i64 = 51 + @as(i64, tri(t_us, 4_000_000, 666));
    const hy: i64 = 90 + @as(i64, tri(t_us + 700_000, 2_700_000, 588));
    const mm: i64 = 300 + @as(i64, tri(t_us, 3_100_000, 150));
    // 768 = three zones: tan(20.5 deg) = 0.374 (383 in Q10) at the
    // edges across, tan(26 deg) = 0.488 (499) down.
    return .{ @divTrunc((hx - 384) * 383, 384), @divTrunc((hy - 384) * 499, 384), mm };
}

pub fn trace_hand(t_us: u64, tx: i32, ty: i32) Hit {
    return trace_hand_at(hand_at(t_us), tx, ty);
}

/// `trace_hand` for a hand position already worked out (once per
/// measurement): 32-bit only, cheap enough for every SPAD sample.
pub fn trace_hand_at(hand: ?[3]i64, tx: i32, ty: i32) Hit {
    const len: i32 = @intCast(isqrt32(@intCast(tx * tx + ty * ty + 1024 * 1024)));
    if (hand) |h| {
        const dx = tx - @as(i32, @intCast(h[0]));
        const dy = ty - @as(i32, @intCast(h[1]));
        if (dx * dx + dy * dy <= hand_r_q10 * hand_r_q10) {
            return .{ .mm = @intCast((@as(i32, @intCast(h[2])) * len) >> 10), .surface = .ball };
        }
    }
    return .{ .mm = @intCast((@as(i32, hand_wall_mm) * len) >> 10), .surface = .wall };
}

fn isqrt32(v: u32) u32 {
    var x: u32 = 0;
    var bit: u32 = 1 << 30;
    var n = v;
    while (bit > n) bit >>= 2;
    while (bit != 0) : (bit >>= 2) {
        if (n >= x + bit) {
            n -= x + bit;
            x = (x >> 1) + bit;
        } else x >>= 1;
    }
    return x;
}

pub fn trace_in(kind: Kind, t_us: u64, tx: i32, ty: i32) Hit {
    return switch (kind) {
        .room => trace(t_us, tx, ty),
        .hand => trace_hand(t_us, tx, ty),
    };
}

/// The two samples of physical SPAD (x, y).
pub fn spad_hits(t_us: u64, x: usize, y: usize) [2]Hit {
    return spad_hits_in(.room, t_us, x, y);
}

pub fn spad_hits_in(kind: Kind, t_us: u64, x: usize, y: usize) [2]Hit {
    return .{
        trace_in(kind, t_us, tan_col[x], tan_half_row[2 * y]),
        trace_in(kind, t_us, tan_col[x], tan_half_row[2 * y + 1]),
    };
}

fn spad_hits_hand(hand: ?[3]i64, x: usize, y: usize) [2]Hit {
    return .{
        trace_hand_at(hand, tan_col[x], tan_half_row[2 * y]),
        trace_hand_at(hand, tan_col[x], tan_half_row[2 * y + 1]),
    };
}

/// Zone results for a user mask at `t_us`: zone c - 1 from channel c's
/// enabled, live SPADs (zones without SPADs, or with only dead ones, are
/// empty).
pub fn zone_results(t_us: u64, m: *const spad.Mask, zones: *[types.zones]types.Zone) void {
    zone_results_in(.room, t_us, m, zones);
}

pub fn zone_results_in(kind: Kind, t_us: u64, m: *const spad.Mask, zones: *[types.zones]types.Zone) void {
    const hand = if (kind == .hand) hand_at(t_us) else null;
    // Every enabled live SPAD's two samples, tagged with their zone.
    var hits: [2 * spad.rows * spad.cols]Hit = undefined;
    var zone_of: [2 * spad.rows * spad.cols]u8 = undefined;
    var n: usize = 0;
    var near: [types.zones]u32 = @splat(std.math.maxInt(u32));
    for (0..m.ysize) |r| for (0..m.xsize) |x| {
        const c = m.ch[r][x];
        if (c == 0 or c > types.zones) continue;
        const px = m.phys_col(x);
        const py = m.phys_row(r);
        if (px < 0 or px >= phys_cols or py < 0 or py >= phys_rows) continue;
        if (is_dead(px, py)) continue;
        const pair = if (kind == .hand) spad_hits_hand(hand, @intCast(px), @intCast(py)) else spad_hits(t_us, @intCast(px), @intCast(py));
        for (pair) |h| {
            hits[n] = h;
            zone_of[n] = c - 1;
            n += 1;
            if (h.surface != .none) near[c - 1] = @min(near[c - 1], h.mm);
        }
    };
    var sa: [types.zones]u64 = @splat(0);
    var da: [types.zones]u64 = @splat(0);
    var sb: [types.zones]u64 = @splat(0);
    var db: [types.zones]u64 = @splat(0);
    for (hits[0..n], zone_of[0..n]) |h, z| {
        const s = h.signal();
        if (s == 0) continue;
        if (h.mm <= near[z] + split_mm) {
            sa[z] += s;
            da[z] += s * h.mm;
        } else {
            sb[z] += s;
            db[z] += s * h.mm;
        }
    }
    for (zones, 0..) |*zone, z| {
        zone.* = .{};
        if (sa[z] == 0) continue;
        zone.near = target(t_us, z, 0, da[z] / sa[z], sa[z]);
        if (sb[z] >= far_min_signal) zone.far = target(t_us, z, 1, db[z] / sb[z], sb[z]);
    }
}

/// Second-object signal below this is not reported.
pub const far_min_signal: u64 = 48;

fn target(t_us: u64, z: usize, which: u64, mm: u64, s: u64) types.Target {
    const conf: u32 = @intCast(@min(255, s / 3 + 1));
    // Jitter shrinks with signal: +-(1 + 400 / confidence) mm.
    const j: u32 = 1 + 400 / conf;
    const h = hash(t_us *% 2654435761 +% z * 31 + which);
    const noise: i64 = @as(i64, h % (2 * j + 1)) - j;
    const v: i64 = @as(i64, @intCast(mm)) + noise;
    return .{ .mm = @intCast(std.math.clamp(v, 1, 65535)), .confidence = @intCast(conf) };
}

fn tri(t: u64, period: u64, amp: u32) u32 {
    const ph = t % period;
    const half = period / 2;
    const x = if (ph < half) ph else period - ph;
    return @intCast(x * amp / half);
}

fn hash(a: u64) u32 {
    var x = a *% 0x9E3779B97F4A7C15;
    x ^= x >> 31;
    x *%= 0xBF58476D1CE4E5B9;
    x ^= x >> 29;
    return @truncate(x);
}

fn isqrt(v: u64) u64 {
    if (v == 0) return 0;
    var x: u64 = 0;
    var bit: u64 = 1 << 62;
    var n = v;
    while (bit > n) bit >>= 2;
    while (bit != 0) : (bit >>= 2) {
        if (n >= x + bit) {
            n -= x + bit;
            x = (x >> 1) + bit;
        } else x >>= 1;
    }
    return x;
}

test "the scene: wall, floor, box and ball where they should be" {
    // Straight ahead (between the middle columns, mid rows): the wall, or
    // the ball when it is there.
    const h = trace(0, 0, 0);
    try std.testing.expect(h.surface == .wall or h.surface == .ball);
    // Bottom rows look at the floor, nearer than the wall.
    const f = trace(0, 0, tan_half_row[23]);
    try std.testing.expectEqual(Surface.floor, f.surface);
    try std.testing.expect(f.mm < 600);
    // The box on the right at 700 mm.
    const b = trace(0, 381, 100);
    try std.testing.expectEqual(Surface.box, b.surface);
    try std.testing.expectEqual(@as(u32, 700), b.mm);
    // The wall is farther to the right than to the left.
    try std.testing.expect(trace(0, 300, -400).mm > trace(0, -300, -400).mm);
    // The ball centre direction hits the ball at about centre depth - r.
    const c = ball(1_000_000);
    const tx: i32 = @intCast(@divTrunc(c[0] * 1024, c[2]));
    const ty: i32 = @intCast(@divTrunc(c[1] * 1024, c[2]));
    const hb = trace(1_000_000, tx, ty);
    try std.testing.expectEqual(Surface.ball, hb.surface);
    const dist: i64 = @intCast(isqrt(@intCast(c[0] * c[0] + c[1] * c[1] + c[2] * c[2])));
    const expect: i64 = @divTrunc((dist - ball_r) * c[2], dist);
    try std.testing.expect(@abs(@as(i64, hb.mm) - expect) < 20);
}

test "the hand scene under the stripes mask: the hand's stripes near, the rest the wall" {
    const m = spad.stripes();
    var zones: [9]types.Zone = undefined;
    // 1 s in: the hand is in view.
    const t: u64 = 1_000_000;
    const h = hand_at(t).?;
    zone_results_in(.hand, t, &m, &zones);
    try std.testing.expect(!zones[0].near.valid()); // channel 1 unused
    var hand_stripes: u32 = 0;
    for (zones[1..], 0..) |z, k| {
        try std.testing.expect(z.near.valid());
        // Stripe k's columns' tangents span the hand's centre +- radius?
        const lo = tan_col[spad.stripe_first[k]];
        const hi = tan_col[spad.stripe_first[k + 1] - 1];
        const over = hi >= h[0] - hand_r_q10 + 40 and lo <= h[0] + hand_r_q10 - 40;
        if (z.near.mm < 600) {
            hand_stripes += 1;
            try std.testing.expect(@abs(@as(i64, z.near.mm) - h[2]) < 40);
        } else try std.testing.expect(!over);
    }
    try std.testing.expect(hand_stripes >= 3 and hand_stripes <= 6);
    // Out of view (7 s into the 8 s cycle): the wall everywhere.
    zone_results_in(.hand, 7_000_000, &m, &zones);
    for (zones[1..]) |z| try std.testing.expect(z.near.mm >= 900);
}

test "a zone over an edge reports two objects; a dead pair reports none" {
    // Two SPADs straddling the box's left edge (box from x = 150 mm at
    // 700 mm: tan = 0.219, between columns 13 (0.190) and 14 (0.234)).
    var m: spad.Mask = .{};
    m.ch[6][13] = 1;
    m.ch[6][14] = 1;
    // A coarse pair made only of dead SPADs: physical row 4 = mask row 3.
    m.ch[3][6] = 2;
    m.ch[3][7] = 2;
    var zones: [9]types.Zone = undefined;
    zone_results(0, &m, &zones);
    const z = zones[0];
    try std.testing.expect(z.near.valid() and z.far.valid());
    try std.testing.expect(@abs(@as(i32, z.near.mm) - 700) < 30);
    try std.testing.expect(z.far.mm > 1100);
    try std.testing.expect(!zones[1].near.valid());
    try std.testing.expect(!zones[2].near.valid());
}
