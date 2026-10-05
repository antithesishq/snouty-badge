//! LAVA: metaballs with palette-cycled iso-bands (SPEC.md section 2.3).
//! Seven blobs wander on Lissajous paths; with a hand there they are
//! pulled toward it (harder the nearer it is) and a punch blows them
//! apart. The field itself is added to the potential as one more blob, so
//! the hand is lava too and the blobs merge into it. Falloff (1 - d^2/R^2)^3:
//! no divide per pixel, and the squared distances are per-column and
//! per-row tables. Param: speed.
const std = @import("std");
const field = @import("../field.zig");
const math = @import("../math.zig");
const palette = @import("../palette.zig");
const surface = @import("../surface.zig");
const U = @import("../uniforms.zig").U;

pub const name = "LAVA";
pub const param_name = "SPEED";
pub const default_palette = 1;

const blobs = 7;
/// Radius of influence (pixels) per blob.
const radius = [blobs]f32{ 19, 16, 22, 14, 18, 15, 21 };
/// The field's part of the potential: (field - floor) * gain (Q12 per
/// field unit), the floor at least field_floor and 80 % of the field's
/// mean, so a near hand is lava but a big hand covering every zone (a
/// uniform field) only warms the background instead of flooding it.
const field_floor = 100;
const field_gain = 20;
/// Potential (Q12 >> 5) where the surface begins (iso level).
const level = 56;
/// Spring toward the path / the hand, and damping (per tick).
const k_path: f32 = 0.004;
const k_hand: f32 = 0.010;
const damping: f32 = 0.93;
const punch_kick: f32 = 3.2;

const Blob = struct { x: f32, y: f32, vx: f32 = 0, vy: f32 = 0 };
var b: [blobs]Blob = undefined;
var clock: f32 = 0;
var lut: palette.Lut = undefined;

pub fn init() void {}

pub fn enter() void {
    clock = 0;
    for (&b, 0..) |*o, i| {
        const p = path(i, 0);
        o.* = .{ .x = p[0], .y = p[1] };
    }
}

fn path(i: usize, t: f32) [2]f32 {
    const fi: f32 = @floatFromInt(i);
    return .{
        40.0 + 30.0 * math.sin_turns(t * (0.031 + 0.007 * fi) + fi * 0.37),
        32.0 + 22.0 * math.sin_turns(t * (0.043 - 0.004 * fi) + fi * 0.61 + 0.2),
    };
}

pub fn render(u: *const U, pal: *const palette.Cosine, out: *surface.Surface) void {
    const speed = 0.25 + 0.25 * @as(f32, @floatFromInt(u.param));
    clock += speed / 60.0 * 6.0;
    const hd = u.hand;
    const pull = if (hd.present) k_hand * (0.3 + 0.7 * hd.z) else 0;
    for (&b, 0..) |*o, i| {
        const p = path(i, clock);
        o.vx += (p[0] - o.x) * k_path * speed;
        o.vy += (p[1] - o.y) * k_path * speed;
        if (pull > 0) {
            // Each blob aims at a slightly different spot around the hand.
            const fi: f32 = @floatFromInt(i);
            const tx = u.hx + 9.0 * math.cos_turns(fi / blobs + u.t * 0.2);
            const ty = u.hy + 7.0 * math.sin_turns(fi / blobs + u.t * 0.2);
            o.vx += (tx - o.x) * pull;
            o.vy += (ty - o.y) * pull;
        }
        if (u.punch_age == 0) {
            const dx = o.x - u.punch_x;
            const dy = o.y - u.punch_y;
            const d = @sqrt(dx * dx + dy * dy) + 1.0;
            o.vx += dx / d * punch_kick;
            o.vy += dy / d * punch_kick;
        }
        o.vx *= damping;
        o.vy *= damping;
        o.x += o.vx;
        o.y += o.vy;
    }

    // Per blob: squared, radius-normalised distances per column and row (Q12).
    var dx2: [blobs][surface.w]i32 = undefined;
    var dy2: [blobs][surface.h]i32 = undefined;
    for (0..blobs) |i| {
        const inv = 1.0 / (radius[i] * radius[i]) * 4096.0;
        for (0..surface.w) |x| {
            const d = @as(f32, @floatFromInt(x)) - b[i].x;
            dx2[i][x] = @intFromFloat(@min(d * d * inv, 8192.0));
        }
        for (0..surface.h) |y| {
            const d = @as(f32, @floatFromInt(y)) - b[i].y;
            dy2[i][y] = @intFromFloat(@min(d * d * inv, 8192.0));
        }
    }

    // LUT: dark glow below the iso level, a hot rim, then moving bands.
    for (&lut, 0..) |*e, i| {
        const fi: f32 = @floatFromInt(i);
        if (i < level) {
            const g = fi / level;
            e.* = palette.pack(palette.at(pal, 0.05 + u.kick), 0.05 + 0.30 * g * g * g, u.flash);
        } else {
            const k = (fi - level) / (256.0 - level);
            const band = 0.5 + 0.5 * math.cos_turns(k * 5.0 - u.t * 0.6);
            const rim = @max(0.0, 1.0 - (fi - level) / 10.0);
            const c = palette.at(pal, k * 0.8 + 0.1 + u.t * 0.03 + u.kick);
            e.* = palette.pack(c, 0.55 + 0.6 * band + 0.9 * rim, u.flash);
        }
    }

    const floor: i32 = @max(field_floor, @as(i32, @intFromFloat(u.total * 255.0 * 0.8)));
    for (0..surface.w) |x| {
        // The blobs that reach this column.
        var act: [blobs]usize = undefined;
        var n: usize = 0;
        for (0..blobs) |i| {
            if (dx2[i][x] < 4096) {
                act[n] = i;
                n += 1;
            }
        }
        const col = &out[x];
        const fcol = &field.f[x];
        for (0..surface.h) |y| {
            var acc: i32 = @max(0, @as(i32, fcol[y]) - floor) * field_gain;
            for (act[0..n]) |i| {
                const s = dx2[i][x] + dy2[i][y];
                if (s < 4096) {
                    const t = 4096 - s;
                    const t2 = (t * t) >> 12;
                    acc += (t2 * t) >> 12;
                }
            }
            var v = acc >> 5;
            if (v > 255) v = fold(v);
            const idx: usize = @intCast(v);
            col[y] = lut[idx];
        }
    }
}

/// Past the top of the LUT, fold back and forth between 255 and level + 40
/// (a triangle wave), so hot cores keep their bands instead of going flat.
fn fold(v: i32) i32 {
    const span = 255 - (level + 40);
    const k = @mod(v - 255, 2 * span);
    return if (k < span) 255 - k else 255 - 2 * span + k;
}
