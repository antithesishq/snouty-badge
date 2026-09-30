//! Part 4, Twister (4 bars, 8 s): a square column with four faces (amber,
//! orange, red, plum) twisting about its vertical axis over a slowly
//! drifting dark gradient, standing on a dim reflecting floor.
//!
//! Per screen row y the twist angle is
//!   a(y, t) = spin * t + twist(t) * y + amp(t) * sin(wave * y + drift * t)
//! (a u32 phase, 65536 per turn, sampled through math.isin), and the four
//! corners project to x_i = cx(y, t) + R * sin(a + i/4 turn), with cx
//! swaying around the centre. Face i (corner i to corner i+1) is visible
//! when x_i < x_{i+1}; walking from the leftmost corner along increasing x
//! gives the one or two visible faces as horizontal spans (`row_spans`).
//! Each face is lit by a Lambert term from a light a little left of the
//! viewer (cos of its normal angle minus the light angle, one isin per face
//! per row) picking one of 64 precomputed shades of its hue, the top shades
//! running to a whitish highlight. A 1 px near-black line marks every face
//! boundary and both silhouette edges so the twist reads.
//!
//! Rendering: the background (sky gradient whose two key colours drift on
//! slow sines, a thin horizon glow, then the floor) is one 128-pixel column
//! built per frame and copied into all 160 columns, which writes every
//! pixel; then each row's spans (at most ~52 px) are stored over it. The
//! bottom `floor_rows` rows are the reflection: row 107 - 1.5 * k mirrored,
//! shifted by a small per-row ripple, in darker shades that fade out with
//! depth. On every beat (30 frames) the twist amplitude gets a kick that
//! decays quadratically over 15 frames. Everything per pixel is integer.
const cart = @import("cart-api");
const math = @import("../math.zig");
const palette = @import("../palette.zig");

pub const name: []const u8 = "Twister";

const width = 160;
const height = 128;

// Tuning knobs.
pub const floor_rows = 20;
pub const column_rows = height - floor_rows; // rows 0..107 hold the column
pub const radius: i32 = 36; // corner distance from the axis, px
const levels = 64; // shades per face
const spin: u32 = 230; // phase units per frame (65536 = one turn)
const wave: u32 = 380; // phase of the wobble per row
const drift: u32 = 520; // phase of the wobble per frame
const amp_base: i32 = 7000; // wobble amplitude, phase units
const amp_kick: i32 = 9000; // extra amplitude at a beat, decays over 15 frames
const light: u32 = 65536 - 5000; // light direction, a little left of the viewer
const frames_per_beat = 30;
const kick_frames = 15;

const hue_rgb = [4]u32{ 0xffb428, 0xff6a14, 0xe0283a, 0x9c3094 };
const edge_rgb: u32 = 0x0c0408;
const floor_top_rgb: u32 = 0x1a1030;
const floor_bottom_rgb: u32 = 0x040208;

var shade: [4][levels]cart.Pixel = undefined;
var refl: [4][levels]cart.Pixel = undefined;
var edge_px: cart.Pixel = undefined;
var bg_column: [height]cart.Pixel = undefined;

/// One visible face on one row: pixels x0 .. x1-1, face index, shade level.
pub const Span = struct { x0: i16, x1: i16, face: u8, level: u8 };
/// The visible faces of one row, left to right.
pub const Spans = struct { n: u8 = 0, s: [3]Span = undefined };

var rows: [column_rows]Spans = undefined;

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

pub fn init() void {
    edge_px = palette.pixel(edge_rgb);
    const fr = channel(floor_top_rgb, 16);
    const fg = channel(floor_top_rgb, 8);
    const fb_ = channel(floor_top_rgb, 0);
    for (0..4) |f| {
        const hr = channel(hue_rgb[f], 16);
        const hg = channel(hue_rgb[f], 8);
        const hb = channel(hue_rgb[f], 0);
        for (0..levels) |l| {
            const b: f32 = @as(f32, @floatFromInt(l)) / (levels - 1);
            // Dark-hue ambient to full hue, then a highlight towards white.
            const k = 0.10 + 0.90 * b;
            const w = @max(0.0, b - 0.86) * 2.4;
            const r = hr * k + (1.0 - hr * k) * w;
            const g = hg * k + (1.0 - hg * k) * w;
            const bl = hb * k + (1.0 - hb * k) * w;
            shade[f][l] = .from_color(to_color(r, g, bl));
            refl[f][l] = .from_color(to_color(fr + (r - fr) * 0.45, fg + (g - fg) * 0.45, fb_ + (bl - fb_) * 0.45));
        }
    }
}

pub fn enter() void {}

/// Given the four corner x positions of a row (px, any order of the
/// square's corners 0..3 as they turn), the visible faces as spans from
/// the leftmost corner to the rightmost, zero-width faces skipped. The
/// level of each span is left 0 for the caller.
pub fn row_spans(xs: [4]i32) Spans {
    var lo: u32 = 0;
    for (1..4) |i| {
        if (xs[i] < xs[lo]) lo = @intCast(i);
    }
    var out: Spans = .{};
    var cur = lo;
    for (0..3) |_| {
        const nxt = (cur + 1) & 3;
        if (xs[nxt] > xs[cur]) {
            out.s[out.n] = .{ .x0 = @intCast(xs[cur]), .x1 = @intCast(xs[nxt]), .face = @intCast(cur), .level = 0 };
            out.n += 1;
        } else if (xs[nxt] < xs[cur]) break;
        cur = nxt;
    }
    return out;
}

/// Beat envelope of the twist amplitude at frame t, phase units.
pub fn amplitude(t: u32) i32 {
    const b: i32 = @intCast(t % frames_per_beat);
    if (b >= kick_frames) return amp_base;
    const d = kick_frames - b;
    return amp_base + @divTrunc(amp_kick * d * d, kick_frames * kick_frames);
}

/// Q15 sine of a 65536-per-turn phase.
inline fn sin16(p: u32) i32 {
    return math.isin(p >> 6);
}

fn build_rows(t: u32) void {
    const amp = amplitude(t);
    // Base twist per row swings between winding and unwinding.
    const twist: i32 = 60 + ((330 * sin16(t *% 150)) >> 15);
    const sway: i32 = (28 * sin16(t *% 190 +% 9000)) >> 7; // Q8 px
    const spin_t: u32 = t *% spin;
    for (0..column_rows) |yi| {
        const y: i32 = @intCast(yi);
        const yu: u32 = @intCast(yi);
        const wob = (amp * sin16(yu *% wave +% t *% drift)) >> 15;
        const a: u32 = spin_t +% @as(u32, @bitCast(twist * y + wob));
        // Gentle bend: the axis leans with a slower wave down the column.
        const bend = 10 * sin16(yu *% 300 +% t *% 260) >> 7; // Q8 px
        const cx: i32 = (80 << 8) + sway + bend;
        var xs: [4]i32 = undefined;
        inline for (0..4) |i| {
            xs[i] = (cx + ((radius * sin16(a +% i * 16384)) >> 7) + 128) >> 8;
        }
        var sp = row_spans(xs);
        for (sp.s[0..sp.n]) |*s| {
            // Face normal half way between its corners; x = sin, z = cos.
            const n = a +% @as(u32, s.face) * 16384 +% 8192;
            const d = sin16(n -% light +% 16384); // cos(n - light)
            const lit: i32 = @max(0, d);
            s.level = @intCast((lit * (levels - 1) + 16384) >> 15);
        }
        rows[yi] = sp;
    }
}

fn build_background(t: u32) void {
    // Sky keys drift between deep blue and deep violet (top) and teal and
    // wine (just above the horizon).
    const u: u32 = @intCast((sin16(t *% 110) + 32768) >> 8); // 0..256
    const v: u32 = @intCast((sin16(t *% 70 +% 20000) + 32768) >> 8);
    const top = palette.mix_rgb(0x02061c, 0x12031e, u);
    const bottom = palette.mix_rgb(0x103048, 0x3a1030, v);
    for (0..column_rows) |y| {
        const f: u32 = @intCast((y * 256) / (column_rows - 1));
        bg_column[y] = palette.pixel(palette.mix_rgb(top, bottom, (f * f) >> 8));
    }
    bg_column[column_rows - 1] = palette.pixel(palette.mix_rgb(bottom, 0xffffff, 60));
    for (0..floor_rows) |k| {
        const f: u32 = @intCast((k * 256) / (floor_rows - 1));
        bg_column[column_rows + k] = palette.pixel(palette.mix_rgb(floor_top_rgb, floor_bottom_rgb, f));
    }
}

inline fn clip(x: i32) usize {
    return @intCast(@min(@max(x, 0), width));
}

fn draw_row(fb: cart.FramebufferPtr, y: usize, sp: *const Spans, dx: i32, table: *const [4][levels]cart.Pixel, lvl_num: i32, edges: bool) void {
    for (sp.s[0..sp.n]) |s| {
        const lvl: usize = @intCast((@as(i32, s.level) * lvl_num) >> 5);
        const px = table[s.face][lvl];
        const x0 = clip(@as(i32, s.x0) + dx);
        const x1 = clip(@as(i32, s.x1) + dx);
        var x = x0;
        while (x < x1) : (x += 1) fb[x][y] = px;
    }
    if (!edges or sp.n == 0) return;
    for (sp.s[0..sp.n]) |s| {
        const x = @as(i32, s.x0) + dx;
        if (x >= 0 and x < width) fb[@intCast(x)][y] = edge_px;
    }
    const last = @as(i32, sp.s[sp.n - 1].x1) - 1 + dx;
    if (last >= 0 and last < width) fb[@intCast(last)][y] = edge_px;
}

pub fn render(t: u32, fb: cart.FramebufferPtr) void {
    build_background(t);
    for (fb) |*col| col.* = bg_column;
    build_rows(t);
    for (0..column_rows) |y| draw_row(fb, y, &rows[y], 0, &shade, 32, true);
    // Reflection: foreshortened mirror, rippled, fading with depth.
    for (0..floor_rows) |k| {
        const src = column_rows - 1 - (k * 3) / 2;
        const ku: u32 = @intCast(k);
        const dx = (@as(i32, 2 + @as(i32, @intCast(k / 6))) * sin16(ku *% 5200 +% t *% 1400) + 16384) >> 15;
        const fade: i32 = 32 - @as(i32, @intCast(k));
        draw_row(fb, column_rows + k, &rows[src], dx, &refl, fade, false);
    }
}

const std = @import("std");

test "twister: row spans pick the visible faces left to right" {
    // Face-on: corners 1 and 2 at the silhouette ... one face visible.
    const one = row_spans(.{ 50, 50, 110, 110 });
    try std.testing.expectEqual(@as(u8, 1), one.n);
    try std.testing.expectEqual(Span{ .x0 = 50, .x1 = 110, .face = 1, .level = 0 }, one.s[0]);
    // Two faces, chain wrapping from corner 3 to corner 0 to corner 1.
    const two = row_spans(.{ 70, 120, 90, 40 });
    try std.testing.expectEqual(@as(u8, 2), two.n);
    try std.testing.expectEqual(Span{ .x0 = 40, .x1 = 70, .face = 3, .level = 0 }, two.s[0]);
    try std.testing.expectEqual(Span{ .x0 = 70, .x1 = 120, .face = 0, .level = 0 }, two.s[1]);
    // Spans tile [min, max) without gaps.
    math.init_tables();
    var a: u32 = 0;
    while (a < 65536) : (a += 97) {
        var xs: [4]i32 = undefined;
        for (0..4) |i| xs[i] = 80 + ((radius * math.isin((a +% @as(u32, @intCast(i)) * 16384) >> 6)) >> 15);
        const sp = row_spans(xs);
        try std.testing.expect(sp.n >= 1 and sp.n <= 2);
        try std.testing.expectEqual(@min(@min(xs[0], xs[1]), @min(xs[2], xs[3])), sp.s[0].x0);
        try std.testing.expectEqual(@max(@max(xs[0], xs[1]), @max(xs[2], xs[3])), sp.s[sp.n - 1].x1);
        if (sp.n == 2) try std.testing.expectEqual(sp.s[0].x1, sp.s[1].x0);
    }
}

test "twister: beat kick decays back to the base amplitude" {
    try std.testing.expectEqual(amp_base + amp_kick, amplitude(0));
    try std.testing.expectEqual(amp_base + amp_kick, amplitude(60));
    try std.testing.expect(amplitude(5) < amplitude(4));
    try std.testing.expectEqual(amp_base, amplitude(15));
    try std.testing.expectEqual(amp_base, amplitude(29));
}
