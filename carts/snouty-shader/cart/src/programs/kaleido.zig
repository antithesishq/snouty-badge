//! KALEIDO: a kaleidoscopic tunnel (SPEC.md section 2.6). Angle and depth
//! tables twice the surface's size (built at init) let the tunnel's centre
//! follow the hand by offsetting the lookup. The angle is twisted by depth
//! (roll, swirl), turned (pitch, yaw speed) and folded into mirrored
//! segments (the param, plus turning the hand), the depth flies forward
//! faster as the hand comes closer, and the noise texture is the wall,
//! fogged to black down the tunnel. Punch: a speed burst. Param: segments.
const std = @import("std");
const atan2 = @import("tof").pose.atan2;
const math = @import("../math.zig");
const noise = @import("../noise.zig");
const palette = @import("../palette.zig");
const surface = @import("../surface.zig");
const U = @import("../uniforms.zig").U;
const arena = @import("arena.zig");

pub const name = "KALEIDO";
pub const param_name = "MIRRORS";
pub const default_palette = 5;

/// How far the centre follows the hand (pixels at x, y = +-1), and the
/// table size that covers the surface from every centre.
const follow_x: f32 = 22;
const follow_y: f32 = 18;
const reach_x = 24;
const reach_y = 20;
const tw = surface.w + 2 * reach_x;
const th = surface.h + 2 * reach_y;
/// Depth = depth_k / radius (pixels), clamped to 255.
const depth_k: f32 = 700;
/// Flight speed (texels per frame) at rest and at hand z = 1.
const speed_rest: f32 = 0.5;
const speed_near: f32 = 2.6;
const punch_speed: f32 = 9.0;

/// Angle (256 per turn) and depth per table pixel, in the shared arena.
const Tables = struct { ang: [tw][th]u8, dep: [tw][th]u8 };
var tab: *Tables = undefined;
var fog: [256]u8 = undefined;
var fold: [256]u8 = undefined;
var travel: f32 = 0;
var spin: f32 = 0;
var boost: f32 = 0;
var cx: f32 = 40;
var cy: f32 = 32;
var lut: palette.Lut = undefined;

pub fn init() void {
    for (&fog, 0..) |*f, d| {
        const k = 1.0 - @as(f32, @floatFromInt(d)) / 255.0;
        f.* = @intFromFloat(32.0 * math.clamp01(k * k * 1.6));
    }
}

pub fn enter() void {
    travel = 0;
    spin = 0;
    boost = 0;
    cx = 40;
    cy = 32;
    tab = arena.as(Tables);
    // One quadrant (dx, dy > 0) and its mirror images: a quarter of the
    // atan2 / sqrt / divide work, so switching here costs ~4 ms, not 16.
    const hx = tw / 2;
    const hy = th / 2;
    for (hx..tw) |x| for (hy..th) |y| {
        const dx = @as(f32, @floatFromInt(x - hx)) + 0.5;
        const dy = @as(f32, @floatFromInt(y - hy)) + 0.5;
        const a: u8 = @truncate(@as(u32, @bitCast(math.iround(atan2(dy, dx) / (2.0 * std.math.pi) * 256.0))));
        const r = @sqrt(dx * dx + dy * dy);
        const d: u8 = @intFromFloat(@min(255.0, depth_k / @max(r, 0.5)));
        const mx = tw - 1 - x;
        const my = th - 1 - y;
        tab.ang[x][y] = a;
        tab.ang[mx][y] = 128 -% a;
        tab.ang[x][my] = 0 -% a;
        tab.ang[mx][my] = 128 +% a;
        tab.dep[x][y] = d;
        tab.dep[mx][y] = d;
        tab.dep[x][my] = d;
        tab.dep[mx][my] = d;
    };
}

pub fn render(u: *const U, pal: *const palette.Cosine, out: *surface.Surface) void {
    const hd = u.hand;
    const t = u.t;
    if (u.punch_age == 0) boost = punch_speed;
    boost *= 0.93;
    const present: f32 = if (hd.present) 1 else 0;
    travel += speed_rest + (speed_near - speed_rest) * hd.z * present + boost;
    if (travel > 1024) travel -= 1024;
    spin += 0.0015 + present * (hd.pitch * 0.008 + hd.vyaw * 0.004);
    spin -= @floor(spin);

    // The centre glides after the hand (or wanders without one).
    const tx = if (hd.present) 40.0 + hd.x * follow_x else 40.0 + 8.0 * math.sin_turns(t * 0.05);
    const ty = if (hd.present) 32.0 - hd.y * follow_y else 32.0 + 6.0 * math.sin_turns(t * 0.037);
    cx += (math.clampf(tx, 40 - reach_x, 40 + reach_x) - cx) * 0.15;
    cy += (math.clampf(ty, 32 - reach_y, 32 + reach_y) - cy) * 0.15;

    // Mirrors: an even count (an odd one would tear where the angle wraps).
    const pairs = std.math.clamp(1 + @divTrunc(@as(i32, u.param) + 1, 2) + math.iround(hd.yaw * 1.5 * present), 1, 7);
    const segs: f32 = @floatFromInt(pairs * 2);
    const seg = 256.0 / segs;
    for (&fold, 0..) |*f, i| {
        const a = @as(f32, @floatFromInt(i)) + spin * 256.0;
        const k = a / seg;
        const n = @floor(k);
        var local = k - n;
        const odd = @as(i32, @intFromFloat(n)) & 1 == 1;
        if (odd) local = 1.0 - local;
        f.* = @intFromFloat(local * 63.0);
    }
    const twist: i32 = math.iround((hd.roll * 1.6 + hd.swirl * 0.4) * present * 256.0 + 40.0 * math.sin_turns(t * 0.03));

    for (&lut, 0..) |*e, i| {
        const f = @as(f32, @floatFromInt(i)) / 256.0;
        e.* = palette.pack(palette.at(pal, f + t * 0.025 + u.kick), 1.15, u.flash);
    }

    const ox: usize = @intFromFloat(math.clampf(tw / 2 - cx, 0, 2 * reach_x));
    const oy: usize = @intFromFloat(math.clampf(th / 2 - cy, 0, 2 * reach_y));
    const vt: u32 = @intFromFloat(travel);
    for (0..surface.w) |x| {
        const acol = &tab.ang[x + ox];
        const dcol = &tab.dep[x + ox];
        const col = &out[x];
        for (0..surface.h) |y| {
            const d: i32 = dcol[y + oy];
            const a: i32 = acol[y + oy];
            const a2: u32 = @bitCast(a + ((d * twist) >> 8));
            const uu: u32 = fold[a2 & 255];
            const vv: u32 = @as(u32, @intCast(d)) + vt;
            const tex: u32 = noise.at(uu, vv);
            const idx = (tex + (vv << 1)) & 255;
            col[y] = surface.scale(lut[idx], fog[@intCast(d)]);
        }
    }
}
