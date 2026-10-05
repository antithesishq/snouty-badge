//! ECHO: Milkdrop-style feedback (SPEC.md section 2.4). Each frame resamples
//! the previous one (RGB888, 80x64) bilinearly through a zoom about the
//! hand (nearer = faster zoom), a rotation (yaw, roll, swirl) and a drift
//! (hand velocity), plus a gentle sine warp; decays it; and lets the
//! field inject colour that cycles through the palette. Three orbiting
//! sparks keep it alive without a hand; a punch draws an expanding ring.
//! Param: trail length (the decay).
//!
//! Pixels are 0x00RRGGBB: red and blue are blended together under the
//! 0x00FF00FF mask and green under 0x0000FF00, four weights summing to
//! 256, so bilinear filtering is eight multiplies per pixel.
const std = @import("std");
const field = @import("../field.zig");
const math = @import("../math.zig");
const palette = @import("../palette.zig");
const surface = @import("../surface.zig");
const U = @import("../uniforms.zig").U;
const arena = @import("arena.zig");

pub const name = "ECHO";
pub const param_name = "TRAIL";
pub const default_palette = 7;

const w = surface.w;
const h = surface.h;
const Buf = [w][h]u32;

/// Zoom per frame at rest and at hand z = 1 (source scale = 1 - zoom).
const zoom_rest: f32 = 0.018;
const zoom_near: f32 = 0.040;
/// Rotation (turns per frame) from the hand's angles and motion.
const spin_base: f32 = 0.0025;
const spin_yaw: f32 = 0.006;
const spin_roll: f32 = 0.004;
const spin_swirl: f32 = 0.003;
/// Drift (pixels per frame per unit/s of hand velocity).
const drift: f32 = 0.9;
/// Sine warp amplitude (pixels).
const warp_amp: f32 = 0.6;
/// Decay (/256) at param 0 and per step.
const decay_base = 226;
const decay_step = 3;
/// Injection: the field's contour lines (every contour_mask + 1 field
/// units, contour_width wide, above contour_min), moving outward.
const contour_mask = 63;
const contour_width = 7;
const contour_min = 24;
const contour_speed = 2;

var cur: u1 = 0;

pub fn init() void {}

pub fn enter() void {
    clear();
}

/// The two frame buffers, in the shared arena.
fn bufs() *[2]Buf {
    return arena.as([2]Buf);
}

fn clear() void {
    for (bufs()) |*bf| bf.* = @splat(@splat(0));
}

fn rgb888(c: palette.Rgb, bright: f32) u32 {
    var out: u32 = 0;
    for (0..3) |i| {
        const v: u32 = @intFromFloat(math.clamp01(c[i] * bright) * 255.0);
        out |= v << @intCast(16 - 8 * i);
    }
    return out;
}

inline fn add_sat(a: u32, b: u32) u32 {
    // Red and blue lanes, then green, each with its carry spread into a mask.
    var rb = (a & 0x00FF00FF) + (b & 0x00FF00FF);
    const crb = rb & 0x01000100;
    rb = (rb | (crb - (crb >> 8))) & 0x00FF00FF;
    var g = (a & 0x0000FF00) + (b & 0x0000FF00);
    const cg = g & 0x00010000;
    g = (g | (cg - (cg >> 8))) & 0x0000FF00;
    return rb | g;
}

inline fn scale888(c: u32, f: u32) u32 {
    const rb = (((c & 0x00FF00FF) * f) >> 8) & 0x00FF00FF;
    const g = (((c & 0x0000FF00) * f) >> 8) & 0x0000FF00;
    return rb | g;
}

fn splat_dot(dst: *Buf, x: f32, y: f32, c: u32) void {
    const ix = math.iround(x);
    const iy = math.iround(y);
    var dy: i32 = -1;
    while (dy <= 1) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            const px = ix + dx;
            const py = iy + dy;
            if (px < 0 or py < 0 or px >= w or py >= h) continue;
            const k: u32 = if (dx == 0 and dy == 0) 256 else if (dx == 0 or dy == 0) 140 else 70;
            const p = &dst[@intCast(px)][@intCast(py)];
            p.* = add_sat(p.*, scale888(c, k));
        }
    }
}

pub fn render(u: *const U, pal: *const palette.Cosine, out: *surface.Surface) void {
    const src = &bufs()[cur];
    const dst = &bufs()[cur ^ 1];
    cur ^= 1;
    const hd = u.hand;
    const t = u.t;

    // The transform: dst(p) = src(c + s R (p - c) + d) + warp.
    const present: f32 = if (hd.present) 1 else 0;
    const zoom = zoom_rest + (zoom_near - zoom_rest) * hd.z * present;
    const s = 1.0 - zoom;
    const ang = spin_base + present * (hd.yaw * spin_yaw + hd.roll * spin_roll + hd.swirl * spin_swirl + hd.vyaw * 0.002);
    const ca = math.cos_turns(ang) * s;
    const sa = math.sin_turns(ang) * s;
    const centre_x = if (hd.present) u.hx else 40.0 + 6.0 * math.sin_turns(t * 0.05);
    const centre_y = if (hd.present) u.hy else 32.0 + 5.0 * math.sin_turns(t * 0.07);
    const dxp = -hd.vx * drift * present;
    const dyp = hd.vy * drift * present;
    // u(x, y) = m00 x + m01 y + u_base ; v(x, y) = m10 x + m11 y + v_base (Q16).
    const m00 = q16(ca);
    const m01 = q16(-sa);
    const m10 = q16(sa);
    const m11 = q16(ca);
    const u_base = q16(centre_x - ca * centre_x + sa * centre_y + dxp);
    const v_base = q16(centre_y - sa * centre_x - ca * centre_y + dyp);
    var warp_u: [h]i32 = undefined;
    var warp_v: [w]i32 = undefined;
    for (0..h) |y| warp_u[y] = q16(warp_amp * math.sin_turns(@as(f32, @floatFromInt(y)) / 23.0 + t * 0.21));
    for (0..w) |x| warp_v[x] = q16(warp_amp * math.sin_turns(@as(f32, @floatFromInt(x)) / 29.0 - t * 0.17));

    const decay: u32 = decay_base + decay_step * @as(u32, u.param);
    // The injected colour cycles through the palette; nearer is brighter.
    const inj = rgb888(palette.at(pal, t * 0.08 + u.kick), 0.6 + 0.6 * hd.z);
    const inj_px = scale888(inj, 150);
    const band_shift: u32 = (u.tick *% contour_speed) & 255;
    const max_u: i32 = (w - 1) << 16;
    const max_v: i32 = (h - 1) << 16;

    for (0..w) |x| {
        const xi: i32 = @intCast(x);
        var uu = m00 * xi + u_base;
        var vv = m10 * xi + v_base + warp_v[x];
        const dcol = &dst[x];
        const fcol = &field.f[x];
        for (0..h) |y| {
            const su = std.math.clamp(uu + warp_u[y], 0, max_u - 1);
            const sv = std.math.clamp(vv, 0, max_v - 1);
            uu += m01;
            vv += m11;
            const x0: usize = @intCast(su >> 16);
            const y0: usize = @intCast(sv >> 16);
            const fx: u32 = @intCast((su >> 8) & 255);
            const fy: u32 = @intCast((sv >> 8) & 255);
            const w11 = (fx * fy) >> 8;
            const w10 = fx - w11;
            const w01 = fy - w11;
            const w00 = 256 + w11 - fx - fy;
            const a = src[x0][y0];
            const b = src[x0 + 1][y0];
            const c = src[x0][y0 + 1];
            const d = src[x0 + 1][y0 + 1];
            var rb = ((a & 0x00FF00FF) * w00 + (b & 0x00FF00FF) * w10 + (c & 0x00FF00FF) * w01 + (d & 0x00FF00FF) * w11) >> 8;
            var g = ((a & 0x0000FF00) * w00 + (b & 0x0000FF00) * w10 + (c & 0x0000FF00) * w01 + (d & 0x0000FF00) * w11) >> 8;
            rb = (((rb & 0x00FF00FF) * decay) >> 8) & 0x00FF00FF;
            g = (((g & 0x0000FF00) * decay) >> 8) & 0x0000FF00;
            var p = rb | g;
            // The field's contours, running outward: rings that the
            // zoom and spin smear into spirals.
            const fv: u32 = fcol[y];
            if (fv > contour_min and ((fv +% band_shift) & contour_mask) < contour_width) p = add_sat(p, inj_px);
            dcol[y] = p;
        }
    }

    // Sparks: three dots on Lissajous orbits, colours a third of the palette apart.
    for (0..3) |i| {
        const fi: f32 = @floatFromInt(i);
        const sx = 40.0 + 30.0 * math.sin_turns(t * (0.11 + 0.03 * fi) + fi / 3.0);
        const sy = 32.0 + 24.0 * math.sin_turns(t * (0.17 - 0.02 * fi) + fi * 0.21);
        splat_dot(dst, sx, sy, rgb888(palette.at(pal, t * 0.1 + fi / 3.0 + u.kick), 1.4));
    }
    // A punch: an expanding ring of dots for half a second.
    if (u.punch_age < 30) {
        const r = 3.0 + @as(f32, @floatFromInt(u.punch_age)) * 2.2;
        const ring = rgb888(palette.at(pal, u.kick + 0.5), 1.3);
        const dots: u32 = 48;
        for (0..dots) |k| {
            const a = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(dots));
            splat_dot(dst, u.punch_x + r * math.cos_turns(a), u.punch_y + r * math.sin_turns(a), ring);
        }
    }

    // To the spread RGB565 surface.
    for (0..w) |x| {
        const dcol = &dst[x];
        const ocol = &out[x];
        for (0..h) |y| {
            const p = dcol[y];
            ocol[y] = surface.spread_rgb((p >> 16) & 255, (p >> 8) & 255, p & 255);
        }
    }
}

inline fn q16(v: f32) i32 {
    return @intFromFloat(v * 65536.0);
}
