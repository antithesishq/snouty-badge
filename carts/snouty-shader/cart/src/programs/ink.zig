//! INK: domain-warped noise (SPEC.md section 2.1). Two octaves of the
//! noise texture sampled through a warp; the warp is two more noise
//! lookups, evaluated on a 4-pixel grid and bilinearly interpolated, plus
//! the hand: the field's gradient pulls the ink into a gravity well, its
//! curl (yaw, swirl) turns it into a vortex, the hand's velocity smears it,
//! and a punch sends a ring of displacement out. The hand also lights the
//! ink (a per-pixel brightness from the field). Param: warp strength.
const std = @import("std");
const field = @import("../field.zig");
const math = @import("../math.zig");
const noise = @import("../noise.zig");
const palette = @import("../palette.zig");
const surface = @import("../surface.zig");
const U = @import("../uniforms.zig").U;

pub const name = "INK";
pub const param_name = "WARP";
pub const default_palette = 0;

/// Warp grid spacing (pixels) and size.
const step = 4;
const gw = surface.w / step + 1;
const gh = surface.h / step + 1;
/// Texels per pixel of the visible layer (Q8) and of the warp noise.
const scale_q8 = 360;
const warp_scale: f32 = 1.1;
/// Warp amplitude (texels) at param 0 and per step.
const warp_base: f32 = 8.0;
const warp_step: f32 = 4.5;
/// Hand terms, texels per unit of field gradient (0..255 per 4 px).
const well: f32 = 0.30;
const vortex: f32 = 0.25;
const smear: f32 = 9.0;
/// Punch ring: speed (px/tick), half-width (px), push (texels), life (ticks).
const ring_speed: f32 = 1.4;
const ring_width: f32 = 7.0;
const ring_push: f32 = 26.0;
const ring_life: f32 = 70.0;
/// Brightness /32: base and the field's addition.
const glow_base = 22;
const glow_add = 10;

var wgx: [gw][gh]i32 = undefined;
var wgy: [gw][gh]i32 = undefined;
var ox: f32 = 0;
var oy: f32 = 0;
var lut: palette.Lut = undefined;

pub fn init() void {}

pub fn enter() void {
    ox = 0;
    oy = 0;
}

fn field_at(x: i32, y: i32) i32 {
    const cx: usize = @intCast(std.math.clamp(x, 0, surface.w - 1));
    const cy: usize = @intCast(std.math.clamp(y, 0, surface.h - 1));
    return field.f[cx][cy];
}

pub fn render(u: *const U, pal: *const palette.Cosine, out: *surface.Surface) void {
    const hd = u.hand;
    const t = u.t;
    // The whole sheet drifts, faster where the hand pushes it.
    ox += 0.10 + hd.vx * 0.5 * u.total;
    oy += 0.04 - hd.vy * 0.5 * u.total;
    if (ox > 4096) ox -= 4096;
    if (ox < -4096) ox += 4096;
    if (oy > 4096) oy -= 4096;
    if (oy < -4096) oy += 4096;

    const amp = warp_base + warp_step * @as(f32, @floatFromInt(u.param));
    const curl = std.math.clamp(hd.yaw * 0.8 + hd.vyaw * 0.3 + hd.swirl * 0.6, -1.5, 1.5);
    const age: f32 = @floatFromInt(@min(u.punch_age, 10_000));
    const ring_r = age * ring_speed;
    const ring_fade = 1.0 - age / ring_life;

    for (0..gw) |gi| for (0..gh) |gj| {
        const px: f32 = @floatFromInt(gi * step);
        const py: f32 = @floatFromInt(gj * step);
        const n1u = q8(px * warp_scale + t * 6.0 + 17.0);
        const n1v = q8(py * warp_scale - t * 3.5);
        const n2u = q8(px * warp_scale - t * 4.0 + 71.0);
        const n2v = q8(py * warp_scale + t * 5.0 + 33.0);
        var wx = @as(f32, @floatFromInt(noise.sample(n1u, n1v) - 128)) * (amp / 128.0);
        var wy = @as(f32, @floatFromInt(noise.sample(n2u, n2v) - 128)) * (amp / 128.0);
        // The hand: gravity well along the field's gradient, vortex across it.
        const ix: i32 = @intCast(gi * step);
        const iy: i32 = @intCast(gj * step);
        const fg_x: f32 = @floatFromInt(field_at(ix + 2, iy) - field_at(ix - 2, iy));
        const fg_y: f32 = @floatFromInt(field_at(ix, iy + 2) - field_at(ix, iy - 2));
        const fv: f32 = @floatFromInt(field_at(ix, iy));
        wx -= fg_x * well - fg_y * vortex * curl;
        wy -= fg_y * well + fg_x * vortex * curl;
        // Smear with the hand's motion where the hand is.
        wx -= hd.vx * smear * fv / 255.0;
        wy += hd.vy * smear * fv / 255.0;
        // The punch ring.
        if (ring_fade > 0) {
            const dx = px - u.punch_x;
            const dy = py - u.punch_y;
            const d = @sqrt(dx * dx + dy * dy) + 0.001;
            const k = (d - ring_r) / ring_width;
            if (k > -1 and k < 1) {
                const s = (1 - k * k) * (1 - k * k) * ring_push * ring_fade / d;
                wx += dx * s;
                wy += dy * s;
            }
        }
        wgx[gi][gj] = q8(wx);
        wgy[gi][gj] = q8(wy);
    };

    // LUT: the palette with two dark veins per cycle.
    for (&lut, 0..) |*e, i| {
        const f = @as(f32, @floatFromInt(i)) / 256.0;
        const vein = 0.5 + 0.5 * math.cos_turns(f * 2.0);
        e.* = palette.pack(palette.at(pal, f + t * 0.02 + u.kick), 0.45 + 0.85 * vein, u.flash);
    }

    const oxq = q8(ox);
    const oyq = q8(oy);
    var cwx: [gh]i32 = undefined;
    var cwy: [gh]i32 = undefined;
    for (0..surface.w) |x| {
        const gi = x / step;
        const fx: i32 = @intCast(x % step);
        for (0..gh) |gj| {
            cwx[gj] = wgx[gi][gj] + (((wgx[gi + 1][gj] - wgx[gi][gj]) * fx) >> 2);
            cwy[gj] = wgy[gi][gj] + (((wgy[gi + 1][gj] - wgy[gi][gj]) * fx) >> 2);
        }
        const ub: i32 = @as(i32, @intCast(x)) * scale_q8 + oxq;
        const col = &out[x];
        const fcol = &field.f[x];
        for (0..surface.h) |y| {
            const gj = y / step;
            const fy: i32 = @intCast(y % step);
            const wx = cwx[gj] + (((cwx[gj + 1] - cwx[gj]) * fy) >> 2);
            const wy = cwy[gj] + (((cwy[gj + 1] - cwy[gj]) * fy) >> 2);
            const uu = ub + wx;
            const vv = @as(i32, @intCast(y)) * scale_q8 + oyq + wy;
            const v1 = noise.sample(uu, vv);
            const v2 = noise.sample(uu * 2 + 0x3a00, vv * 2 + 0x1500);
            const fv: i32 = fcol[y];
            const idx: u32 = @bitCast(v1 + (v1 >> 1) + (v2 >> 2) + (fv >> 1));
            const glow: u32 = glow_base + ((@as(u32, @intCast(fv)) * glow_add) >> 8);
            col[y] = surface.scale(lut[idx & 255], glow);
        }
    }
}

inline fn q8(v: f32) i32 {
    return @intFromFloat(v * 256.0);
}
