//! The moving demo backdrops (SPEC.md section 4), one per mesh, each a
//! full-frame redraw that reacts to the hand and flashes on a punch:
//!
//! - copper (KNOT): horizontal copper bars on sine paths, back bars
//!   dimmer, over a dark gradient, with parallax stars between them. One
//!   column is built and copied to all 160 (the framebuffer is
//!   column-major); bars follow the hand's height.
//! - ice (IRIS): the same idea turned sideways, vertical bars in cool
//!   colours (one memset per column under a bar).
//! - stars (SNOUTY): demosnout's dithered gradient and a 3D starfield that
//!   warps toward the viewer as the hand approaches.
//! - plasma (BOING): an 80x64 sum of four separable sine terms through a
//!   dim cycling palette, upscaled 2x.
const std = @import("std");
const cart = @import("cart-api");
const config = @import("config.zig");
const math = @import("math.zig");
const mesh = @import("mesh.zig");
const palette = @import("palette.zig");

pub const width = 160;
pub const height = 128;

pub const React = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    vz: f32 = 0,
    vx: f32 = 0,
    /// 0..1, the punch flash.
    flash: f32 = 0,
};

const Column = [height]cart.Pixel;

pub fn init() void {
    init_stars();
    plasma_base = palette.gradient(&.{
        .{ .pos = 0, .rgb = 0x0a0418 },
        .{ .pos = 64, .rgb = 0x2a0c48 },
        .{ .pos = 128, .rgb = 0x08283c },
        .{ .pos = 192, .rgb = 0x301040 },
        .{ .pos = 255, .rgb = 0x0a0418 },
    });
}

pub fn draw(fb: *cart.Framebuffer, kind: mesh.Backdrop, t: u32, r: React) void {
    switch (kind) {
        .copper => copper(fb, t, r, &copper_rgb, 0x020010, 0x12041e),
        .ice => ice(fb, t, r),
        .stars => starfield(fb, t, r),
        .plasma => plasma(fb, t, r),
    }
}

inline fn flashed(rgb: u32, f: f32) cart.Pixel {
    if (f <= 0.004) return palette.pixel(rgb);
    return palette.pixel(palette.mix_rgb(rgb, 0xffffff, @intFromFloat(@min(1.0, f) * 200.0)));
}

// ---------------------------------------------------------------------------
// Copper bars.

const bar_count = 7;
const bar_half = 7;
const copper_rgb = [bar_count]u32{ 0xff2840, 0xff8020, 0xffd830, 0x40e060, 0x30b0ff, 0x7050ff, 0xe040e0 };
const ice_rgb = [bar_count]u32{ 0x60f0ff, 0x3080ff, 0xc0f8ff, 0x4048e0, 0x80c0ff, 0x9060ff, 0x20c0d0 };

const Bar = struct { pos: i32, z: f32, rgb: u32 };

fn bars(t: u32, r: React, rgb: *const [bar_count]u32, span: f32, centre: f32, follow: f32) [bar_count]Bar {
    var out: [bar_count]Bar = undefined;
    const tf: f32 = @floatFromInt(t);
    for (&out, 0..) |*b, i| {
        const ph = tf / 280.0 + @as(f32, @floatFromInt(i)) * 0.085;
        b.* = .{
            .pos = @intFromFloat(centre + span * math.sin_turns(ph) + follow * r.y),
            .z = math.cos_turns(ph),
            .rgb = rgb[i],
        };
    }
    // Back to front.
    std.mem.sortUnstable(Bar, &out, {}, struct {
        fn lt(_: void, a: Bar, b: Bar) bool {
            return a.z < b.z;
        }
    }.lt);
    return out;
}

/// A bar's colour `k` pixels from its centre, dimmer when it is at the back.
fn bar_colour(b: Bar, k: i32) u32 {
    const d: u32 = @intCast(@abs(k));
    const depth: u32 = @intFromFloat(170.0 + 86.0 * b.z);
    const shade = (256 - d * 256 / (bar_half + 1)) * depth / 256;
    var c = palette.mix_rgb(0, b.rgb, shade);
    if (d == 0) c = palette.mix_rgb(c, 0xffffff, 110);
    return c;
}

fn copper(fb: *cart.Framebuffer, t: u32, r: React, rgb: *const [bar_count]u32, top: u32, bottom: u32) void {
    var col: [height]u32 = undefined;
    for (&col, 0..) |*c, y| c.* = palette.mix_rgb(top, bottom, @intCast(y * 256 / height));
    const bs = bars(t, r, rgb, 46, 64, -14);
    for (bs) |b| {
        var k: i32 = -bar_half;
        while (k <= bar_half) : (k += 1) {
            const y = b.pos + k;
            if (y < 0 or y >= height) continue;
            col[@intCast(y)] = bar_colour(b, k);
        }
    }
    var px: Column align(4) = undefined;
    for (&px, col) |*p, c| p.* = flashed(c, r.flash);
    for (fb) |*c| c.* = px;
    // Stars in the gaps between bars, drifting left faster as the hand moves.
    const speed = 1.0 + @min(6.0, @abs(r.vx) * 3.0);
    star_shift += speed;
    if (star_shift > 1.0e6) star_shift -= 1.0e6;
    for (stars2d) |s| {
        const y: i32 = s.y;
        var free = true;
        for (bs) |b| free = free and (y < b.pos - bar_half or y > b.pos + bar_half);
        if (!free) continue;
        const travel: u32 = @intFromFloat(star_shift * @as(f32, @floatFromInt(s.speed)) * 0.25);
        const x = (s.x + width * 64 - (travel % (width * 64))) % (width * 64);
        fb[x >> 6][s.y] = star_px[s.bright];
    }
}

fn ice(fb: *cart.Framebuffer, t: u32, r: React) void {
    var grad: Column align(4) = undefined;
    for (&grad, 0..) |*p, y| p.* = flashed(palette.mix_rgb(0x000814, 0x061c30, @intCast(y * 256 / height)), r.flash);
    for (fb) |*c| c.* = grad;
    var rr = r;
    rr.y = -r.x; // the bars follow the hand sideways
    const bs = bars(t, rr, &ice_rgb, 62, 80, -20);
    for (bs) |b| {
        var k: i32 = -bar_half;
        while (k <= bar_half) : (k += 1) {
            const x = b.pos + k;
            if (x < 0 or x >= width) continue;
            @memset(&fb[@intCast(x)], flashed(bar_colour(b, k), r.flash));
        }
    }
}

// ---------------------------------------------------------------------------
// Stars.

const Star2 = struct { x: u32, y: u8, speed: u8, bright: u8 };
var stars2d: [40]Star2 = undefined;
var star_px: [8]cart.Pixel = undefined;
var star_shift: f32 = 0;

const Star3 = struct { x: f32, y: f32, z: f32 };
const star3_count = 72;
var stars3d: [star3_count]Star3 = undefined;
var star_rng: u32 = 0x2545F491;

fn rand01() f32 {
    star_rng ^= star_rng << 13;
    star_rng ^= star_rng >> 17;
    star_rng ^= star_rng << 5;
    return @as(f32, @floatFromInt(star_rng >> 8)) / 16777216.0;
}

fn init_stars() void {
    for (&stars2d) |*s| {
        s.* = .{
            .x = @intFromFloat(rand01() * width * 64),
            .y = @intFromFloat(rand01() * (height - 1)),
            .speed = @intFromFloat(4 + rand01() * 20),
            .bright = @intFromFloat(rand01() * 7.99),
        };
    }
    for (&star_px, 0..) |*p, i| {
        p.* = palette.pixel(palette.mix_rgb(0x0c0a1c, 0xd8d0ff, @intCast(40 + i * 30)));
    }
    for (&stars3d) |*s| s.* = .{ .x = rand01() * 2 - 1, .y = rand01() * 2 - 1, .z = 0.3 + rand01() * 7.7 };
}

/// 2x2 Bayer thresholds in quarters of a quantisation step.
const bayer2 = [4]u32{ 0, 2, 3, 1 };

fn dithered(rgb: u32, q: u32) cart.Pixel {
    const rr: u32 = @min(255, ((rgb >> 16) & 0xff) + 2 * q);
    const g: u32 = @min(255, ((rgb >> 8) & 0xff) + q);
    const b: u32 = @min(255, (rgb & 0xff) + 2 * q);
    return palette.pixel((rr << 16) | (g << 8) | b);
}

fn starfield(fb: *cart.Framebuffer, t: u32, r: React) void {
    const s = math.sin_turns(@as(f32, @floatFromInt(t)) / 900.0);
    var bottom = palette.mix_rgb(0x1c0a30, 0x081a34, @intFromFloat(128.0 + 127.0 * s));
    if (r.flash > 0.004) bottom = palette.mix_rgb(bottom, 0xb090ff, @intFromFloat(@min(1.0, r.flash) * 160.0));
    var cols: [2]Column align(4) = undefined;
    for (0..height) |y| {
        const c = palette.mix_rgb(0x010106, bottom, @intCast((y * 256) / (height - 1)));
        cols[0][y] = dithered(c, bayer2[y & 1]);
        cols[1][y] = dithered(c, bayer2[2 + (y & 1)]);
    }
    for (fb, 0..) |*col, x| col.* = cols[x & 1];
    // Warp: faster as the hand comes in, a burst on a punch.
    const speed = 0.035 + 0.05 * r.z + @max(0.0, r.vz) * 0.06 + r.flash * 0.25;
    for (&stars3d) |*st| {
        st.z -= speed;
        if (st.z < 0.25) st.* = .{ .x = rand01() * 2 - 1, .y = rand01() * 2 - 1, .z = 8.0 };
        const sx: i32 = @intFromFloat(80.0 + st.x * 90.0 / st.z);
        const sy: i32 = @intFromFloat(64.0 + st.y * 90.0 / st.z);
        if (sx < 0 or sx >= width - 1 or sy < 0 or sy >= height - 1) continue;
        const b: usize = @intFromFloat(@min(7.0, 9.0 - st.z));
        const x: usize = @intCast(sx);
        const y: usize = @intCast(sy);
        fb[x][y] = star_px[b];
        if (st.z < 1.6) {
            fb[x + 1][y] = star_px[b];
            fb[x][y + 1] = star_px[b];
            fb[x + 1][y + 1] = star_px[b];
        }
    }
}

// ---------------------------------------------------------------------------
// Plasma.

var plasma_base: palette.Palette = undefined;
var plasma_pal: palette.Palette = undefined;

fn plasma(fb: *cart.Framebuffer, t: u32, r: React) void {
    const tt: u32 = t;
    var a: [80]i32 = undefined;
    var b: [64]i32 = undefined;
    var c: [144]i32 = undefined;
    var d: [144]i32 = undefined;
    const sway: u32 = @intFromFloat(@max(0.0, 40.0 + 30.0 * r.x));
    for (&a, 0..) |*v, x| v.* = math.isin(@as(u32, @intCast(x)) * 11 +% tt *% 3 +% sway);
    for (&b, 0..) |*v, y| v.* = math.isin(@as(u32, @intCast(y)) * 13 -% tt *% 2);
    for (&c, 0..) |*v, i| v.* = math.isin(@as(u32, @intCast(i)) * 7 +% tt *% 5);
    for (&d, 0..) |*v, i| v.* = math.isin(@as(u32, @intCast(i)) * 5 -% tt *% 4);
    const shift: u8 = @truncate(t >> 1);
    const fl: u8 = @intFromFloat(@min(1.0, r.flash) * 200.0);
    for (&plasma_pal, 0..) |*p, i| {
        const base = plasma_base[(i + shift) & 255];
        p.* = if (fl == 0) base else blend_white(base, fl);
    }
    for (0..80) |x| {
        const dst: *align(4) Column = @alignCast(&fb[x * 2]);
        const w: *[height / 2]u32 = @ptrCast(dst);
        const ax = a[x];
        for (0..64) |y| {
            const v = ax + b[y] + c[x + y] + d[x + 63 - y];
            const idx: u8 = @truncate(@as(u32, @bitCast(v)) >> 8);
            const px: u32 = @as(u16, @bitCast(plasma_pal[idx]));
            w[y] = px | (px << 16);
        }
        fb[x * 2 + 1] = dst.*;
    }
}

fn blend_white(p: cart.Pixel, f: u8) cart.Pixel {
    const c = p.to_color();
    const w: u32 = f;
    return .from_color(.{
        .r = @intCast((@as(u32, c.r) * (255 - w) + 31 * w) / 255),
        .g = @intCast((@as(u32, c.g) * (255 - w) + 63 * w) / 255),
        .b = @intCast((@as(u32, c.b) * (255 - w) + 31 * w) / 255),
    });
}
