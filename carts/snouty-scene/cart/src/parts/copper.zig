//! Part 2, "Copper + scroller": six copper bars bobbing on sines behind a
//! 16-row sine scroller of greetings.
//!
//! The bars are horizontal, so every column of the screen is the same:
//! render() builds one 128-pixel column (background, then the six bars,
//! later bars over earlier ones) and copies it to all 160 columns, which is
//! a straight 256-byte copy per column in the framebuffer's column-major
//! layout (cheaper than 128 strided row fills). That writes every pixel.
//!
//! The scroller text is laid out once at init() into a strip of glyph
//! column words (`strip_cols`, bit 0 = top row) with the glyph index of each
//! strip column (`strip_glyph`), so per screen column the lookup is one
//! index. The strip enters from the right edge at 2 px per frame and then
//! wraps modulo its own width; the text ends in "*  " so the join is
//! seamless. Each column is drawn at y0 = 56 + round(24 * sin), shadow
//! (+2, +2) in black first, colour cycling by glyph index and time.
const cart = @import("cart-api");
const math = @import("../math.zig");
const font = @import("../gen/scroller_font.zig");

pub const name: []const u8 = "Copper";

pub const text = "SNOUTY SCENE  *  ANTITHESIS PRESENTS A SYCL BADGE PRODUCTION  *  " ++
    "GREETINGS TO THE SYCL CREW, THE ZIG COMMUNITY AND EVERYONE AT THE BOOTH  *  ";

const width = 160;
const height = 128;

// Tuning knobs.
pub const scroll_speed: u32 = 2; // px per frame
pub const wave_base: i32 = 56; // top row of the glyphs at sin = 0
pub const wave_amp: i32 = 24;
pub const wave_x_step: u32 = 3; // isin units per screen column
pub const wave_t_step: u32 = 5; // isin units per frame
const shadow_dx = 2;
const shadow_dy = 2;
const bar_h = 14;
const bar_count = 6;
const bg_rgb: u32 = 0x06061a;
const hue_count = 64;

const bar_rgb = [bar_count]u32{ 0xff2020, 0xff8010, 0xffe020, 0x30ff40, 0x20e0ff, 0xff30e0 };
// Per bar: primary and secondary sine speeds (isin units per frame), phases.
const bar_s1 = [bar_count]u32{ 5, 6, 7, 5, 6, 4 };
const bar_s2 = [bar_count]u32{ 11, 9, 13, 15, 8, 12 };
const bar_ph = [bar_count]u32{ 0, 170, 340, 512, 682, 852 };

/// Strip of the whole string, one entry per pixel column.
pub const strip_max = 2048;
var strip_cols: [strip_max]u16 = @splat(0);
var strip_glyph: [strip_max]u8 = @splat(0);
var strip_len: u32 = 0;

var bg_px: cart.Pixel = undefined;
var black_px: cart.Pixel = undefined;
var bar_ramp: [bar_count][bar_h]cart.Pixel = undefined;
var hues: [hue_count]cart.Pixel = undefined;
var column: [height]cart.Pixel = undefined;

fn to_color(r: f32, g: f32, b: f32) cart.DisplayColor {
    return .{
        .r = @intFromFloat(@min(31.0, @max(0.0, r * 31.0 + 0.5))),
        .g = @intFromFloat(@min(63.0, @max(0.0, g * 63.0 + 0.5))),
        .b = @intFromFloat(@min(31.0, @max(0.0, b * 31.0 + 0.5))),
    };
}

fn channel(rgb: u32, shift: u5) f32 {
    return @as(f32, @floatFromInt((rgb >> shift) & 0xff)) / 255.0;
}

/// Lays the string out into the strip. Returns the strip width in pixels.
pub fn layout(str: []const u8, cols: []u16, glyph_of: []u8) u32 {
    var n: u32 = 0;
    for (str, 0..) |c, gi| {
        const g = font.glyph(c);
        for (g.columns) |w| {
            if (n >= cols.len) return n;
            cols[n] = w;
            glyph_of[n] = @truncate(gi);
            n += 1;
        }
    }
    return n;
}

/// Strip column under screen column `x` at frame `t`, or null when the
/// text has not reached it yet (only during the first 80 frames).
pub fn strip_pos(x: u32, t: u32, len: u32) ?u32 {
    const p = x + t * scroll_speed;
    if (p < width) return null;
    return (p - width) % len;
}

/// Top row of the glyph column at screen column `x`, frame `t`.
pub fn wave_y(x: u32, t: u32) i32 {
    const s = math.isin(x *% wave_x_step +% t *% wave_t_step);
    return wave_base + ((wave_amp * s + 16384) >> 15);
}

pub fn init() void {
    bg_px = cart.Pixel.from_color(cart.DisplayColor.rgb(bg_rgb));
    black_px = cart.Pixel.from_color(.{ .r = 0, .g = 0, .b = 0 });
    const bgr = channel(bg_rgb, 16);
    const bgg = channel(bg_rgb, 8);
    const bgb = channel(bg_rgb, 0);
    for (0..bar_count) |b| {
        const cr = channel(bar_rgb[b], 16);
        const cg = channel(bar_rgb[b], 8);
        const cb = channel(bar_rgb[b], 0);
        for (0..bar_h) |i| {
            // d: 0 at the centre, 1 at the edge rows.
            const half: f32 = @as(f32, bar_h) / 2.0;
            const d = @abs(@as(f32, @floatFromInt(i)) + 0.5 - half) / half;
            const l = 1.0 - d * d; // wide bright body, dark edge rows
            const w = @max(0.0, 1.0 - d * 2.5) * 0.7; // white highlight in the core
            const r = bgr + (cr - bgr) * l;
            const g = bgg + (cg - bgg) * l;
            const bl = bgb + (cb - bgb) * l;
            bar_ramp[b][i] = cart.Pixel.from_color(to_color(r + (1.0 - r) * w, g + (1.0 - g) * w, bl + (1.0 - bl) * w));
        }
    }
    for (0..hue_count) |i| {
        const h: f32 = @as(f32, @floatFromInt(i)) / @as(f32, hue_count);
        const r = 0.6 + 0.4 * math.sin_turns(h);
        const g = 0.6 + 0.4 * math.sin_turns(h + 1.0 / 3.0);
        const b = 0.6 + 0.4 * math.sin_turns(h + 2.0 / 3.0);
        hues[i] = cart.Pixel.from_color(to_color(r, g, b));
    }
    strip_len = layout(text, &strip_cols, &strip_glyph);
}

pub fn enter() void {}

fn draw_bits(fb: cart.FramebufferPtr, x: u32, y0: i32, bits: u16, px: cart.Pixel) void {
    var w = bits;
    var y = y0;
    while (w != 0) : ({
        w >>= 1;
        y += 1;
    }) {
        if (w & 1 != 0 and y >= 0 and y < height) fb[x][@intCast(y)] = px;
    }
}

pub fn render(t: u32, fb: cart.FramebufferPtr) void {
    // Background column plus bars, then copy it to every column.
    column = @splat(bg_px);
    for (0..bar_count) |b| {
        const s = 40 * math.isin(t *% bar_s1[b] +% bar_ph[b]) +
            12 * math.isin(t *% bar_s2[b] +% bar_ph[b] *% 3);
        const top: i32 = 64 + (s >> 15) - bar_h / 2;
        for (0..bar_h) |i| {
            const y = top + @as(i32, @intCast(i));
            if (y >= 0 and y < height) column[@intCast(y)] = bar_ramp[b][i];
        }
    }
    for (fb) |*col| col.* = column;

    if (strip_len == 0) return;
    // Shadow pass, then the glyph pass, so no shadow covers a glyph.
    for (0..width - shadow_dx) |xi| {
        const x: u32 = @intCast(xi);
        const p = strip_pos(x, t, strip_len) orelse continue;
        draw_bits(fb, x + shadow_dx, wave_y(x, t) + shadow_dy, strip_cols[p], black_px);
    }
    for (0..width) |xi| {
        const x: u32 = @intCast(xi);
        const p = strip_pos(x, t, strip_len) orelse continue;
        const hue = (@as(u32, strip_glyph[p]) * 5 + t) % hue_count;
        draw_bits(fb, x, wave_y(x, t), strip_cols[p], hues[hue]);
    }
}

const std = @import("std");

test "copper: string fits the strip" {
    var cols: [strip_max]u16 = undefined;
    var gl: [strip_max]u8 = undefined;
    const n = layout(text, &cols, &gl);
    var expect: u32 = 0;
    for (text) |c| expect += font.glyph(c).width;
    try std.testing.expectEqual(expect, n);
    try std.testing.expect(n < strip_max);
    try std.testing.expect(n > width);
}

test "copper: scroll enters from the right and wraps seamlessly" {
    const len: u32 = 1000;
    try std.testing.expectEqual(@as(?u32, null), strip_pos(0, 0, len));
    try std.testing.expectEqual(@as(?u32, null), strip_pos(159, 0, len));
    try std.testing.expectEqual(@as(u32, 0), strip_pos(158, 1, len).?);
    try std.testing.expectEqual(@as(?u32, 0), strip_pos(0, 80, len));
    // Two px per frame, right to left.
    try std.testing.expectEqual(strip_pos(10, 100, len).? + 2, strip_pos(10, 101, len).?);
    // Wraps after len px: strip column len-2, then (2 px on) column 0.
    const t0: u32 = (len - 2 + width - 50) / 2;
    try std.testing.expectEqual(@as(u32, len - 2), strip_pos(50, t0, len).?);
    try std.testing.expectEqual(@as(u32, 0), strip_pos(50, t0 + 1, len).?);
}

test "copper: wave stays on screen" {
    math.init_tables();
    var t: u32 = 0;
    while (t < 2048) : (t += 7) {
        for (0..width) |x| {
            const y = wave_y(@intCast(x), t);
            try std.testing.expect(y >= wave_base - wave_amp and y <= wave_base + wave_amp);
            try std.testing.expect(y + font.height + shadow_dy <= height);
        }
    }
}
