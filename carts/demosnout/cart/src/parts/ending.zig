//! Part 10, Ending (8 bars, 16 s): the Iris mark rises over a night sea
//! and is reflected in rippling water while the credits fade in and out
//! one card at a time; then it holds alone and the whole picture
//! cross-fades into the Intro's first frame, so the loop closes without a
//! cut.
//!
//! The sky is the top `horizon` rows: a deep blue-black gradient with a
//! thin pale glow at the horizon (one column built at init()), a soft
//! salmon halo around the mark (per pixel a squared distance, a per-frame
//! 256-entry level table and a [row][level] palette built at init(), only
//! inside the halo's box; outside it the plain column is copied), a few
//! dozen stars that twinkle on slow sines (positions and phases from
//! rng.zig with a constant seed, at init()), and the 24x24 mark from
//! lib/iris_mark.zig at 2x in the Antithesis salmon with a two-ring darker
//! outline, rising out of the sea over the first four seconds.
//!
//! The water is the classic 2D demoscene reflection: every water row k
//! samples sky row `horizon - 1 - k` (plus a small vertical ripple) of the
//! frame already drawn, shifted sideways by a sine whose amplitude grows
//! and whose wavelength stretches with depth (perspective), its phase
//! moving with t. The per-row source row, offset, darkening and blue tint
//! are computed once per frame (47 entries); per pixel it is one load, a
//! multiply on the 0x07E0F81F-spread RGB565 value (as fx.fade does), an
//! add of the row's tint and one store. The darkening also has a slow
//! banded shimmer so the swell reads. Columns are the framebuffer's fast
//! axis, so each water column reads from its (shifted) sky column.
//!
//! Credits are seven cards in the 8x8 font above the mark, each about 96
//! frames with a 15-frame fade done by mixing the text colour into the sky
//! (not fx.fade, which would dim everything). The last `crossfade` frames
//! mix every pixel towards the Intro's background gradient and blend the
//! Intro's frame-0 stars in (`intro.first_frame_stars`); the timeline's
//! seamless cut then starts the Intro with no fade, so the Ending's last
//! frame and the Intro's first are the same picture.
//!
//! Everything is a pure function of t (no state beyond init()'s tables).
const std = @import("std");
const cart = @import("cart-api");
const math = @import("../math.zig");
const palette = @import("../palette.zig");
const fx = @import("../fx.zig");
const rng = @import("../rng.zig");
const text = @import("../text.zig");
const iris = @import("iris_mark");
const intro = @import("intro.zig");

pub const name: []const u8 = "Ending";

/// Part length in frames (8 bars); must match the timeline entry.
pub const length = 8 * 120;

/// First water row: the sky is rows 0..horizon-1, the sea the other 47.
pub const horizon = 81;
const water_rows = fx.height - horizon;

// --- the mark -------------------------------------------------------------

const scale = 2;
const mark_px = iris.size * scale; // 48
/// Two rings of outline around the 2x mark.
const border = 2;
const box = mark_px + 2 * border; // 52
const mark_x = 80 - mark_px / 2; // 56
/// Top row of the mark once risen (bottom row 77, three rows above the sea).
const mark_rest_y = 30;
/// The mark rises from fully below the horizon over the first `rise` frames.
const rise = 240;

var mark_fill: [box]u64 = undefined;
var mark_ring1: [box]u64 = undefined;
var mark_ring2: [box]u64 = undefined;
var mark_rows: [box]cart.Pixel = undefined;
var ring1_px: cart.Pixel = undefined;
var ring2_px: cart.Pixel = undefined;
/// Glint colours by depth band: brightest near the horizon, dimmer close
/// up, where the dashes are longer.
var glint_px: [8]cart.Pixel = undefined;

// --- sky, halo, stars -------------------------------------------------------

const sky_top: u32 = intro.bg_top;
const sky_mid: u32 = 0x050a22;
const sky_low: u32 = 0x10204c;
const sky_glow: u32 = 0x5a6c9c;

var sky_rgb: [horizon]u32 = undefined;
var sky_col: [horizon]cart.Pixel = undefined;

const glow_levels = 16;
/// Halo colour at full strength, added to the sky.
const glow_rgb: u32 = 0x4c1c34;
var glow_pal: [horizon][glow_levels]cart.Pixel = undefined;
/// Halo radius in pixels; the level table is indexed by d2 >> 4.
const glow_r = 62;
var glow_lvl: [256]u8 = undefined;

const star_count = 44;
const Star = struct { x: u8, y: u8, phase: u16, rate: u8, base: u8 };
var stars: [star_count]Star = undefined;
const star_shades = 16;
var star_px: [star_shades]cart.Pixel = undefined;

// --- the intro's background, for the closing cross-fade --------------------

var intro_col: [fx.height]u32 = undefined; // spread RGB565 per row

/// Frames at the end spent cross-fading into the Intro's frame 0.
const crossfade = 96;

// --- credits ----------------------------------------------------------------

/// A card's lines; the first `label_lines` are drawn in the label colour.
const Card = struct { lines: []const []const u8, label_lines: u8 = 1 };
const cards = [_]Card{
    .{ .lines = &.{"DEMOSNOUT"} },
    .{ .lines = &.{ "CODE + ART", "CLAUDE" } },
    .{ .lines = &.{ "PROMPTING +", "HUMANING", "ADRIAN" }, .label_lines = 2 },
    .{ .lines = &.{ "MUSIC", "SILENT", "(THE BADGE SPEAKER)" } },
    .{ .lines = &.{ "GREETINGS", "SYCL  ZIG", "ANTITHESIS" } },
    .{ .lines = &.{ "SPECIAL THANKS", "THE DEMOSCENE" } },
    .{ .lines = &.{ "2026", "SOFTWARE YOU", "CAN LOVE" } },
};
const card_start = 96;
const card_len = 96;
const card_fade = 15;
const line_pitch = 9;
const text_top = 1;
const label_rgb: u32 = 0xff9f91;
const value_rgb: u32 = 0xd8e0f4;

pub fn init() void {
    // Sky column: blue-black to deep blue, then a thin pale glow in the
    // last rows before the sea.
    for (&sky_rgb, 0..) |*c, y| {
        const glow_from = horizon - 7;
        if (y < 44) {
            c.* = palette.mix_rgb(sky_top, sky_mid, @intCast((y * 256) / 44));
        } else if (y < glow_from) {
            c.* = palette.mix_rgb(sky_mid, sky_low, @intCast(((y - 44) * 256) / (glow_from - 44)));
        } else {
            const k: u32 = @intCast(y - glow_from + 1); // 1..7
            c.* = palette.mix_rgb(sky_low, sky_glow, (k * k * 256) / 49);
        }
    }
    for (&sky_col, sky_rgb) |*p, c| p.* = palette.pixel(c);
    for (&glow_pal, sky_rgb) |*row, c| {
        for (row, 0..) |*p, l| p.* = palette.pixel(add_rgb(c, palette.mix_rgb(0, glow_rgb, @intCast((l * 256) / (glow_levels - 1)))));
    }

    build_mark();
    for (&mark_rows, 0..) |*p, r| {
        const f: u32 = @intCast((r * 256) / (box - 1));
        p.* = palette.pixel(palette.mix_rgb(0xffb8aa, 0xf38a7e, f));
    }
    ring1_px = palette.pixel(0x9a4a54);
    ring2_px = palette.pixel(0x3c1c34);
    for (&glint_px, 0..) |*p, i| p.* = palette.pixel(palette.mix_rgb(0xffd8cc, 0x8a6a8c, @intCast(i * 30)));

    var r = rng.Xorshift.init(0x57a25);
    for (&stars) |*s| {
        s.x = @intCast(r.below(160));
        s.y = @intCast(r.below(horizon - 10));
        s.phase = @intCast(r.below(1024));
        s.rate = @intCast(2 + r.below(6));
        // Brighter high up, fainter towards the horizon haze.
        const top_bias: u32 = ((horizon - 10 - @as(u32, s.y)) * 6) / (horizon - 10);
        s.base = @intCast(@min(3 + r.below(8) + top_bias, star_shades - 1));
    }
    for (&star_px, 0..) |*p, i| p.* = palette.pixel(palette.mix_rgb(0x182448, 0xf0f4ff, @intCast((i * 256) / (star_shades - 1))));

    for (&intro_col, 0..) |*c, y| {
        const px = palette.pixel(palette.mix_rgb(intro.bg_top, intro.bg_bottom, @intCast((y * 256) / (fx.height - 1))));
        c.* = spread(px);
    }
}

pub fn enter() void {}

fn add_rgb(a: u32, b: u32) u32 {
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |sh| out |= @as(u32, @min(((a >> sh) & 0xff) + ((b >> sh) & 0xff), 255)) << sh;
    return out;
}

/// Column bitmasks (bit r = row r of the box) of the 2x mark and its two
/// outline rings (8-neighbour dilations).
fn build_mark() void {
    for (&mark_fill, 0..) |*m, c| {
        m.* = 0;
        if (c < border or c >= border + mark_px) continue;
        const mx = (c - border) / scale;
        for (0..mark_px) |r| {
            if (iris.pixel(mx, r / scale)) m.* |= @as(u64, 1) << @intCast(r + border);
        }
    }
    var d1: [box]u64 = undefined;
    dilate(&mark_fill, &d1);
    var d2: [box]u64 = undefined;
    dilate(&d1, &d2);
    for (&mark_ring1, &mark_ring2, mark_fill, d1, d2) |*a, *b, f, x1, x2| {
        a.* = x1 & ~f;
        b.* = x2 & ~x1;
    }
}

fn dilate(src: *const [box]u64, dst: *[box]u64) void {
    for (dst, 0..) |*d, c| {
        var v: u64 = 0;
        const lo = if (c == 0) 0 else c - 1;
        const hi = @min(c + 1, box - 1);
        for (lo..hi + 1) |k| v |= src[k] | (src[k] << 1) | (src[k] >> 1);
        d.* = v;
    }
}

/// Top row of the mark at frame t: rises from below the horizon with an
/// ease-out, then rests.
pub fn mark_y(t: u32) i32 {
    if (t >= rise) return mark_rest_y;
    const u: u32 = rise - t; // rise..1
    const drop: u32 = (u * u * (horizon + 2 - mark_rest_y)) / (rise * rise);
    return mark_rest_y + @as(i32, @intCast(drop));
}

// --- RGB565 in the 0x07E0F81F spread form (fx.fade's trick) ------------------

inline fn spread(px: cart.Pixel) u32 {
    var c: u32 = @as(u16, @bitCast(px));
    if (cart.is_wasm) c = @byteSwap(@as(u16, @intCast(c)));
    return (c | (c << 16)) & 0x07E0F81F;
}

inline fn unspread(x: u32) cart.Pixel {
    var out: u16 = @truncate(x | (x >> 16));
    if (cart.is_wasm) out = @byteSwap(out);
    return @bitCast(out);
}

/// Spread form of an RGB tint of r5, g6, b5 channel units. DisplayColor is
/// a packed struct with `r` in the low bits, so the spread form has red at
/// bit 0, blue at bit 11 and green at bit 21.
fn spread_rgb(r: u32, g: u32, b: u32) u32 {
    return (g << 21) | (b << 11) | r;
}

// --- per frame ----------------------------------------------------------------

pub fn render(t: u32, fb: cart.FramebufferPtr) void {
    const my = mark_y(t);
    draw_sky(t, my, fb);
    draw_stars(t, fb);
    draw_mark(my, fb);
    draw_water(t, fb);
    draw_credits(t);
    if (t + crossfade >= length) close_loop(t, fb);
}

/// Halo strength 0..256: grows as the mark rises, breathes slowly after.
fn glow_strength(t: u32) u32 {
    const risen: u32 = if (t >= rise) 256 else (t * 256) / rise;
    const breathe: i32 = 216 + ((math.isin(t *% 3) * 40) >> 15); // 176..256
    return (risen * @as(u32, @intCast(breathe))) >> 8;
}

fn draw_sky(t: u32, my: i32, fb: cart.FramebufferPtr) void {
    // Level table for this frame: smooth falloff (1 - r/R)^2 by d2 >> 4.
    const g = glow_strength(t);
    for (&glow_lvl, 0..) |*l, i| {
        const d = std.math.sqrt(@as(u32, @intCast(i)) << 4);
        const lin: u32 = if (d >= glow_r) 0 else ((glow_r - d) * 256) / glow_r;
        l.* = @intCast(@min(((lin * lin >> 8) * g * (glow_levels - 1)) >> 16, glow_levels - 1));
    }
    const gcy: i32 = my + mark_px / 2;
    var dy2: [horizon]u32 = undefined;
    for (&dy2, 0..) |*d, y| {
        const dy: i32 = @as(i32, @intCast(y)) - gcy;
        d.* = @intCast(dy * dy);
    }
    const r2: u32 = glow_r * glow_r;
    for (fb, 0..) |*col, x| {
        const dx: i32 = @as(i32, @intCast(x)) - 80;
        const dx2: u32 = @intCast(dx * dx);
        if (dx2 >= r2 or g == 0) {
            @memcpy(col[0..horizon], &sky_col);
            continue;
        }
        for (0..horizon) |y| {
            const d2 = dx2 + dy2[y];
            const lvl = if (d2 >= r2) 0 else glow_lvl[d2 >> 4];
            col[y] = glow_pal[y][lvl];
        }
    }
}

fn draw_stars(t: u32, fb: cart.FramebufferPtr) void {
    for (stars) |s| {
        const tw = (math.isin(@as(u32, s.phase) +% t *% s.rate) * 5) >> 15; // -5..5
        const b: i32 = @as(i32, s.base) + tw;
        if (b <= 0) continue;
        const i: usize = @intCast(@min(b, star_shades - 1));
        fb[s.x][s.y] = star_px[i];
        // The brightest stars get a faint cross at their peak.
        if (i >= 12 and s.x > 0 and s.x < 159 and s.y > 0) {
            const h = star_px[i - 8];
            fb[s.x - 1][s.y] = h;
            fb[s.x + 1][s.y] = h;
            fb[s.x][s.y - 1] = h;
            fb[s.x][s.y + 1] = h;
        }
    }
}

fn draw_mark(my: i32, fb: cart.FramebufferPtr) void {
    const oy: i32 = my - border;
    for (0..box) |c| {
        const f = mark_fill[c];
        const r1 = mark_ring1[c];
        const r2 = mark_ring2[c];
        if (f | r1 | r2 == 0) continue;
        const col = &fb[mark_x - border + c];
        for (0..box) |r| {
            const y = oy + @as(i32, @intCast(r));
            if (y < 0) continue;
            if (y >= horizon) break;
            const bit = @as(u64, 1) << @intCast(r);
            const yy: usize = @intCast(y);
            if (f & bit != 0) {
                col[yy] = mark_rows[r];
            } else if (r1 & bit != 0) {
                col[yy] = ring1_px;
            } else if (r2 & bit != 0) {
                col[yy] = ring2_px;
            }
        }
    }
}

const Row = struct { src: u8, off: i8, mul: u8, tint: u32 };

/// The per-row reflection parameters of frame t (host-tested).
pub fn water_row(t: u32, k: u32) Row {
    // Depth 0 at the horizon, 256 at the bottom row.
    const depth: u32 = (k * 256) / (water_rows - 1);
    // Perspective phase k * C / (k + 20): its step per row is
    // 20 C / (k + 20)^2, short waves at the horizon, long ones up close.
    const persp: u32 = (k * 1800) / (k + 20);
    // Horizontal swell, two sines: 1 px at the horizon to 7 px deep.
    const amp: i32 = @intCast(256 + depth * 6); // in 1/256 px
    const swell = math.isin(persp +% t *% 7) + ((math.isin(persp *% 2 +% 300 -% t *% 11) * 2) >> 2);
    const off: i32 = std.math.clamp((swell * amp) >> 23, -9, 9);
    // Vertical ripple, 0.5 to 2.5 rows.
    const vamp: i32 = @intCast(128 + depth * 2);
    const v: i32 = (math.isin(k *% 37 +% t *% 11) * vamp) >> 23;
    const mirror: i32 = @as(i32, horizon - 1) - @as(i32, @intCast(k)) + v;
    const src: u8 = @intCast(std.math.clamp(mirror, 0, horizon - 1));
    // Darkening: 21/32 at the horizon to 11/32 deep, with wave bands
    // (troughs darker, crests lighter) rolling in towards the viewer.
    const band: i32 = (math.isin(persp *% 3 -% t *% 9) * 3) >> 15;
    const mul: i32 = 21 - @as(i32, @intCast((depth * 10) >> 8)) + band;
    // Blue tint growing with depth (fits the channel headroom: see draw_water).
    const tint = spread_rgb(depth >> 8, 1 + (depth * 5 >> 8), 2 + (depth * 5 >> 8));
    return .{ .src = src, .off = @intCast(off), .mul = @intCast(std.math.clamp(mul, 8, 24)), .tint = tint };
}

/// Moonlight glints: short pale dashes on some water rows, drifting about
/// under the mark. Row k's glint of frame t, or null.
pub fn glint(t: u32, k: u32) ?struct { x: i32, len: u32 } {
    const on = math.isin(k *% 173 +% t *% 5 +% (k * k) *% 7);
    if (on < 27000) return null;
    const spread_px: i32 = @intCast(10 + k / 2);
    const x: i32 = 80 + ((math.isin(k *% 211 +% t *% 3) * spread_px) >> 15);
    return .{ .x = x, .len = 1 + k / 12 };
}

fn draw_water(t: u32, fb: cart.FramebufferPtr) void {
    var rows: [water_rows]Row = undefined;
    for (&rows, 0..) |*r, k| r.* = water_row(t, @intCast(k));
    // mul <= 24/32 leaves every channel at most 23/31 (47/63 for green),
    // and the tint adds at most 1, 6 and 7: no carry between fields.
    for (0..fx.width) |x| {
        const col = &fb[x];
        const xi: i32 = @intCast(x);
        for (rows, horizon..) |r, y| {
            const sx: usize = @intCast(std.math.clamp(xi + r.off, 0, fx.width - 1));
            const s = spread(fb[sx][r.src]);
            col[y] = unspread((((s * r.mul) >> 5) & 0x07E0F81F) + r.tint);
        }
    }
    for (0..water_rows) |k| {
        const g = glint(t, @intCast(k)) orelse continue;
        const px = glint_px[@min(k / 6, glint_px.len - 1)];
        var x = g.x - @as(i32, @intCast(g.len / 2));
        const end = x + @as(i32, @intCast(g.len));
        while (x < end) : (x += 1) {
            if (x >= 0 and x < fx.width) fb[@intCast(x)][horizon + k] = px;
        }
    }
}

/// Card index and opacity (0..256) at frame t, or null between cards.
pub fn card_at(t: u32) ?struct { index: usize, alpha: u32 } {
    if (t < card_start) return null;
    const i = (t - card_start) / card_len;
    if (i >= cards.len) return null;
    const k = (t - card_start) % card_len;
    const left = card_len - 1 - k;
    const a_in: u32 = if (k < card_fade) (k * 256) / card_fade else 256;
    const a_out: u32 = if (left < card_fade) (left * 256) / card_fade else 256;
    return .{ .index = i, .alpha = @min(a_in, a_out) };
}

fn draw_credits(t: u32) void {
    const c = card_at(t) orelse return;
    if (c.alpha == 0) return;
    const card = cards[c.index];
    const n: i32 = @intCast(card.lines.len);
    // Centre the card's lines in the three-line band.
    const y0: i32 = text_top + @divTrunc((3 - n) * line_pitch, 2);
    for (card.lines, 0..) |line, i| {
        const y = y0 + @as(i32, @intCast(i)) * line_pitch;
        const bg = sky_rgb[@intCast(@min(y + 4, horizon - 1))];
        const fg: u32 = if (i < card.label_lines) label_rgb else value_rgb;
        const x = text.centre_x(line, 1);
        cart.text(.{ .str = line, .x = x + 1, .y = y + 1, .text_color = .rgb(palette.mix_rgb(bg, 0x000000, c.alpha)) });
        cart.text(.{ .str = line, .x = x, .y = y, .text_color = .rgb(palette.mix_rgb(bg, fg, c.alpha)) });
    }
}

/// The last `crossfade` frames: mix everything towards the Intro's
/// background and blend its frame-0 stars in; the last frame is exactly the
/// Intro's frame 0.
fn close_loop(t: u32, fb: cart.FramebufferPtr) void {
    const k: u32 = t + crossfade + 1 - length; // 1..crossfade
    // Smoothstep so it starts and lands gently; 256 on the last frame.
    const u: u32 = (k * 256) / crossfade;
    const f: u32 = (u * u * (768 - 2 * u)) >> 16;
    if (f >= 256) {
        fx.vgradient(fb, intro.bg_top, intro.bg_bottom);
    } else {
        const a: u32 = f >> 3; // 0..31 in 1/32
        for (fb) |*col| {
            for (col, intro_col) |*px, g| {
                const s = spread(px.*);
                px.* = unspread(((s * (32 - a) + g * a) >> 5) & 0x07E0F81F);
            }
        }
    }
    intro.first_frame_stars(fb, f);
}

test "ending: mark rises from below the horizon and rests" {
    try std.testing.expect(mark_y(0) >= horizon);
    try std.testing.expectEqual(@as(i32, mark_rest_y), mark_y(rise));
    try std.testing.expectEqual(@as(i32, mark_rest_y), mark_y(length - 1));
    var prev = mark_y(0);
    for (1..rise + 1) |t| {
        const y = mark_y(@intCast(t));
        try std.testing.expect(y <= prev);
        prev = y;
    }
    try std.testing.expect(mark_rest_y + mark_px < horizon);
}

test "ending: credit cards fade in, hold and out, and fit the screen" {
    try std.testing.expect(card_at(0) == null);
    try std.testing.expectEqual(@as(u32, 0), card_at(card_start).?.alpha);
    try std.testing.expectEqual(@as(u32, 256), card_at(card_start + 40).?.alpha);
    try std.testing.expectEqual(@as(usize, 5), card_at(card_start + 5 * card_len + 40).?.index);
    try std.testing.expect(card_at(card_start + cards.len * card_len) == null);
    // The last card is gone before the mark's solo hold and the cross-fade.
    try std.testing.expect(card_start + cards.len * card_len + 60 <= length - crossfade);
    for (cards) |c| {
        try std.testing.expect(c.lines.len >= 1 and c.lines.len <= 3);
        for (c.lines) |l| try std.testing.expect(l.len * 8 + 2 <= 160); // a margin for the shadow
    }
    // The last line's glyphs and shadow end above the mark's outer ring.
    try std.testing.expect(text_top + 2 * line_pitch + 9 <= mark_rest_y - border);
}

test "ending: water rows stay in the sky and in range" {
    math.init_tables();
    for ([_]u32{ 0, 1, 77, 500, 839 }) |t| {
        for (0..water_rows) |k| {
            const r = water_row(t, @intCast(k));
            try std.testing.expect(r.src < horizon);
            try std.testing.expect(r.mul >= 8 and r.mul <= 24);
            try std.testing.expect(r.off >= -9 and r.off <= 9);
            // The tint leaves headroom in every field of the spread form.
            try std.testing.expect((r.tint & 0x1f) <= 1 and ((r.tint >> 11) & 0x1f) <= 7 and ((r.tint >> 21) & 0x3f) <= 6);
        }
    }
}
