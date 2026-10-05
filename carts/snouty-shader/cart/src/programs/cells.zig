//! CELLS: Voronoi cells (SPEC.md section 2.5). Sixteen seeds sit on springs
//! around a jittered 4x4 grid and wander; the hand pulls the seeds it covers
//! into a gravity well (harder the nearer it is), drags them with its
//! motion and a punch scatters them. Cells under the hand light up; edges
//! are dark where the nearest two seeds are almost equally near. The LUT
//! is 16 cells x 16 shades, rebuilt per frame. Param: speed.
const std = @import("std");
const field = @import("../field.zig");
const math = @import("../math.zig");
const palette = @import("../palette.zig");
const surface = @import("../surface.zig");
const U = @import("../uniforms.zig").U;

pub const name = "CELLS";
pub const param_name = "SPEED";
pub const default_palette = 4;

const seeds = 16;
/// Edge: the squared-distance gap (Q8 px^2) per shade step, as a shift
/// (2^12: seeds 20 px apart shade up over ~6 px from the edge).
const edge_shift = 12;
/// Springs: to the rest spot, toward the hand, drag, damping.
const k_rest: f32 = 0.006;
const k_hand: f32 = 0.030;
const drag: f32 = 0.35;
const damping: f32 = 0.90;
const punch_kick: f32 = 4.0;

const Seed = struct { rx: f32, ry: f32, x: f32, y: f32, vx: f32 = 0, vy: f32 = 0, glow: f32 = 0 };
var s: [seeds]Seed = undefined;
var clock: f32 = 0;
var lut: palette.Lut = undefined;

pub fn init() void {}

pub fn enter() void {
    clock = 0;
    var rng: u32 = 0x9e3779b9;
    for (&s, 0..) |*o, i| {
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        const jx = @as(f32, @floatFromInt(rng & 255)) / 255.0 - 0.5;
        const jy = @as(f32, @floatFromInt((rng >> 8) & 255)) / 255.0 - 0.5;
        const gx: f32 = @floatFromInt(i % 4);
        const gy: f32 = @floatFromInt(i / 4);
        const rx = 10.0 + gx * 20.0 + jx * 12.0;
        const ry = 8.0 + gy * 16.0 + jy * 10.0;
        o.* = .{ .rx = rx, .ry = ry, .x = rx, .y = ry };
    }
}

pub fn render(u: *const U, pal: *const palette.Cosine, out: *surface.Surface) void {
    const speed = 0.3 + 0.2 * @as(f32, @floatFromInt(u.param));
    clock += speed / 60.0;
    const hd = u.hand;
    for (&s, 0..) |*o, i| {
        const fi: f32 = @floatFromInt(i);
        // Wander around the rest spot.
        const tx = o.rx + 7.0 * math.sin_turns(clock * (0.21 + 0.013 * fi) + fi * 0.31);
        const ty = o.ry + 6.0 * math.sin_turns(clock * (0.17 + 0.011 * fi) + fi * 0.57);
        o.vx += (tx - o.x) * k_rest * 4.0;
        o.vy += (ty - o.y) * k_rest * 4.0;
        const cx: usize = @intFromFloat(math.clampf(o.x, 0, surface.w - 1));
        const cy: usize = @intFromFloat(math.clampf(o.y, 0, surface.h - 1));
        const fv = @as(f32, @floatFromInt(field.f[cx][cy])) / 255.0;
        o.glow += (fv - o.glow) * 0.2;
        if (hd.present and fv > 0.02) {
            o.vx += (u.hx - o.x) * k_hand * fv;
            o.vy += (u.hy - o.y) * k_hand * fv;
            o.vx += hd.vx * drag * fv;
            o.vy -= hd.vy * drag * fv;
        }
        if (u.punch_age == 0) {
            const dx = o.x - u.punch_x;
            const dy = o.y - u.punch_y;
            const d = @sqrt(dx * dx + dy * dy) + 1.0;
            o.vx += dx / d * punch_kick * (1.0 + 20.0 / d);
            o.vy += dy / d * punch_kick * (1.0 + 20.0 / d);
        }
        o.vx *= damping;
        o.vy *= damping;
        o.x = math.clampf(o.x + o.vx, -10, surface.w + 10);
        o.y = math.clampf(o.y + o.vy, -10, surface.h + 10);
    }

    // LUT: cell colour in the high nibble, shade in the low.
    for (0..seeds) |i| {
        const fi: f32 = @floatFromInt(i);
        const c = palette.at(pal, fi * 0.137 + u.t * 0.02 + u.kick + s[i].glow * 0.25);
        const lit = 0.55 + 0.9 * s[i].glow;
        for (0..16) |k| {
            const fk = @as(f32, @floatFromInt(k)) / 15.0;
            lut[i * 16 + k] = palette.pack(c, lit * fk * (2.0 - fk), u.flash);
        }
    }

    // Seeds in Q4 pixels; squared row distances per seed (Q8).
    var sx: [seeds]i32 = undefined;
    var dyy: [seeds][surface.h]i32 = undefined;
    for (0..seeds) |i| {
        sx[i] = @intFromFloat(s[i].x * 16.0);
        const sy: i32 = @intFromFloat(s[i].y * 16.0);
        for (0..surface.h) |y| {
            const d = @as(i32, @intCast(y * 16 + 8)) - sy;
            dyy[i][y] = d * d;
        }
    }
    for (0..surface.w) |x| {
        // Seeds sorted by their column distance: once that alone is past
        // the second-nearest distance found, no later seed can matter.
        var dxx: [seeds]i32 = undefined;
        var order: [seeds]u8 = undefined;
        for (0..seeds) |i| {
            const d = @as(i32, @intCast(x * 16 + 8)) - sx[i];
            const v = d * d;
            var j = i;
            while (j > 0 and dxx[j - 1] > v) : (j -= 1) {
                dxx[j] = dxx[j - 1];
                order[j] = order[j - 1];
            }
            dxx[j] = v;
            order[j] = @intCast(i);
        }
        const col = &out[x];
        for (0..surface.h) |y| {
            var d1: i32 = std.math.maxInt(i32);
            var d2: i32 = std.math.maxInt(i32);
            var id: u32 = 0;
            for (0..seeds) |j| {
                const dx = dxx[j];
                if (dx >= d2) break;
                const i = order[j];
                const d = dx + dyy[i][y];
                if (d < d2) {
                    if (d < d1) {
                        d2 = d1;
                        d1 = d;
                        id = i;
                    } else d2 = d;
                }
            }
            const gap: u32 = @intCast(@min((d2 - d1) >> edge_shift, 15));
            col[y] = lut[id * 16 + gap];
        }
    }
}
