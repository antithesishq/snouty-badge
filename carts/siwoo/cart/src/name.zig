//! The name across the bottom of the screen in 20 px capitals
//! (gen/name_font.zig), drawn as 80s chrome: each letter has a sky half
//! and a ground half split by a hard horizon line, a one-pixel dark rim, and
//! a three-pixel extrusion down and to the right. Everything is integer
//! pixel work over the glyphs' column bit masks, which suits the
//! column-major framebuffer.
//!
//! Motion, on the head's 120 BPM frame clock (30 frames a beat, 120 a bar):
//!   * intro: the letters drop in one by one from above the screen and
//!     bounce to rest while the head flies in;
//!   * always: a slow sine wave rolls along the letters;
//!   * every 8 bars (`cycle`): a diagonal shine sweeps across (bars 0 and
//!     4), the letters hop in a ripple (bar 2), and they spin once about
//!     their vertical axes in a wave, showing their darker backs (bar 6);
//!   * sparkles: four-point glints that pop on the letters' top edges.
//! The scheduled spin also moves the colours on to the next theme: each
//! letter takes the new colours halfway through its spin, while it shows
//! its back, so the change rolls along the name. `flip`, `hop` and `shine`
//! start a move on demand (buttons), `pick_theme` spins to the next theme
//! and keeps it (no more automatic changes until `auto`).
const std = @import("std");
const cart = @import("cart-api");
const math = @import("math.zig");
const palette = @import("palette.zig");
const rng = @import("rng.zig");
const font = @import("gen/name_font.zig");
const head = @import("head.zig");

/// What the badge says. Capitals and spaces only; `init` checks that it
/// fits the 160 px screen.
pub const text = "SIWOO YOON";

// ---------------------------------------------------------------------------
// Tunables.

/// Pixels between two letters' ink, and the width of a space.
const gap = 3;
const space_width = 7;
/// Row of the cap tops at rest. The Tufty's crop scale shows rows 4..123,
/// so the extrusion's bottom (top_y + 20 + 3) and the wave stay inside.
const top_y = 90;
/// Depth of the extrusion in pixels (diagonal, down-right).
const extrude = 3;
/// Rows of sky above the horizon (the rest of the 20 rows are ground).
const horizon = 10;

/// Intro: the first letter starts dropping at `intro_at`, each next one
/// `intro_step` frames later, every drop takes `drop_frames` and starts
/// `drop_height` px above the rest position.
const intro_at = 40;
const intro_step = 6;
const drop_frames = 42;
const drop_height: f32 = 110.0;
/// When the show cycle starts: once the last letter has landed.
pub const show_at = intro_at + intro_step * (text.len - 1) + drop_frames;

/// The idle wave: amplitude (px), period (frames), phase step per letter
/// (turns).
const wave_amp: f32 = 1.6;
const wave_period: f32 = 150.0;
const wave_phase: f32 = 0.09;

/// The show cycle and where its moves fall in it (frames).
const cycle = 960;
const shine_moments = [_]u32{ 0, 480 };
const hop_moment = 240;
const flip_moment = 720;
/// Shine: frames to cross the name, band widths.
const shine_frames = 54;
/// Hop: height (px), frames per letter, delay between letters.
const hop_height: f32 = 6.0;
const hop_frames = 16;
const hop_step = 3;
/// Flip: frames per letter, delay between letters.
const flip_frames = 40;
const flip_step = 4;

/// Peak strength of the background glow behind the name (of 256).
const glow_strength = 44;

const sparkle_count = 6;
const sparkle_every = 9;
const sparkle_life = 22;

// ---------------------------------------------------------------------------
// Themes.

pub const Theme = struct {
    name: []const u8,
    /// Chrome keys: the sky half from top to horizon, the ground half from
    /// horizon to the bottom (dark to light: the reflected ground).
    sky_top: u32,
    sky_low: u32,
    ground_top: u32,
    ground_low: u32,
    /// The rim and the extrusion (far end, near end).
    rim: u32,
    side_far: u32,
    side_near: u32,
    /// Ignore the keys and derive them per letter from a hue that drifts
    /// along the name.
    rainbow: bool = false,
};

pub const themes = [_]Theme{
    // Supabase green, for the Supabase Select badge: the default.
    .{ .name = "SUPABASE", .sky_top = 0xeafff4, .sky_low = 0x3ecf8e, .ground_top = 0x0b4f33, .ground_low = 0x9cf5c8, .rim = 0x02120b, .side_far = 0x07301f, .side_near = 0x15704a },
    .{ .name = "SUNSET", .sky_top = 0xffffff, .sky_low = 0x38b8ff, .ground_top = 0x4a1460, .ground_low = 0xffb040, .rim = 0x10031a, .side_far = 0x300842, .side_near = 0x8a2a8a },
    .{ .name = "GOLD", .sky_top = 0xfffbe0, .sky_low = 0xf0b020, .ground_top = 0x5a3000, .ground_low = 0xffe070, .rim = 0x180c00, .side_far = 0x3c2000, .side_near = 0x9a6010 },
    .{ .name = "RAINBOW", .sky_top = 0, .sky_low = 0, .ground_top = 0, .ground_low = 0, .rim = 0, .side_far = 0, .side_near = 0, .rainbow = true },
};

/// The theme the name shows, and the one a running spin wave is turning
/// it to (committed once the wave is over).
pub var theme: usize = 0;
var theme_to: ?usize = null;
/// The scheduled spin changes the theme until `pick_theme` chooses one.
pub var auto_themes = true;

/// The background glow behind the name for this frame: the theme's sky
/// colour (a drifting hue in RAINBOW) centred on the horizon line,
/// swelling a little on every beat, blended toward the next theme as the
/// letters take it.
pub fn glow(t: u32) head.Glow {
    var rgb = glow_rgb(themes[theme], t);
    if (theme_to) |to| {
        var n: u32 = 0;
        for (letters[0..letter_count]) |l| n += @intFromBool(switched(t, l.index));
        rgb = palette.mix_rgb(rgb, glow_rgb(themes[to], t), @intCast((n * 256) / letter_count));
    }
    const beat = t % 30;
    const swell: u32 = if (beat < 12) (12 - beat) * 3 else 0;
    return .{ .rgb = rgb, .y = top_y + horizon, .half = 26, .strength = glow_strength + swell };
}

fn glow_rgb(th: Theme, t: u32) u32 {
    if (th.rainbow) return palette.hue(math.fract(@as(f32, @floatFromInt(t)) / 360.0 + 0.3));
    return th.sky_low;
}

/// Spins the letters to the next theme and keeps it there (the B button).
/// During a spin the wave's target moves on instead: letters that already
/// took the old target jump to the new one.
pub fn pick_theme(t: u32) void {
    if (t < show_at) return;
    auto_themes = false;
    const to = ((theme_to orelse theme) + 1) % themes.len;
    if (flip_running(t)) {
        theme_to = to;
    } else {
        flip_at = t;
        theme_to = to;
    }
}

/// The theme the name is showing or turning to.
pub fn pending_theme() usize {
    return theme_to orelse theme;
}

/// Lets the scheduled spins change the theme again (the UP button).
pub fn auto() void {
    auto_themes = true;
}

/// The theme a pending change has shown on letter `index` by frame `t`.
fn switched(t: u32, index: u8) bool {
    if (theme_to == null) return false;
    const f = flip_at orelse return false;
    return t >= f + flip_step * @as(u32, index) + flip_frames / 2;
}

fn flip_running(t: u32) bool {
    const f = flip_at orelse return false;
    return t -% f < flip_step * (text.len - 1) + flip_frames;
}

// ---------------------------------------------------------------------------
// Layout and state.

const rows = font.height;
const max_cols = 32;

const Letter = struct {
    /// Index into `text`.
    index: u8,
    /// Leftmost ink column at rest.
    x: i32,
    cols: []const u32,
    /// The glyph dilated by one pixel (8-neighbour), cols.len + 2 columns,
    /// its origin one pixel up and left of the glyph's.
    rim: [max_cols]u32,
};

var letters: [text.len]Letter = undefined;
var letter_count: usize = 0;

const Sparkle = struct { x: i16, y: i16, age: u8 };
var sparkles: [sparkle_count]Sparkle = undefined;
var sparkle_rng: rng.Xorshift = undefined;

/// Frame each move last started (the scheduled ones and the A button's).
var flip_at: ?u32 = null;
var hop_at: ?u32 = null;
var shine_at: ?u32 = null;

/// Width of `str` laid out (ink to ink).
pub fn layout_width(str: []const u8) i32 {
    var w: i32 = 0;
    var first = true;
    for (str) |c| {
        if (c == ' ') {
            w += space_width;
            first = true;
            continue;
        }
        if (!first) w += gap;
        w += @intCast(font.glyph(c).len);
        first = false;
    }
    return w;
}

pub fn init() void {
    const total = layout_width(text);
    std.debug.assert(total + extrude + 2 <= 160);
    var x: i32 = @divTrunc(160 - total - extrude, 2);
    var first = true;
    letter_count = 0;
    for (text, 0..) |c, i| {
        if (c == ' ') {
            x += space_width;
            first = true;
            continue;
        }
        if (!first) x += gap;
        first = false;
        const cols = font.glyph(c);
        std.debug.assert(cols.len > 0 and cols.len + 2 <= max_cols);
        var l: Letter = .{ .index = @intCast(i), .x = x, .cols = cols, .rim = @splat(0) };
        dilate(cols, l.rim[0 .. cols.len + 2]);
        letters[letter_count] = l;
        letter_count += 1;
        x += @intCast(cols.len);
    }
}

pub fn enter() void {
    theme = 0;
    theme_to = null;
    auto_themes = true;
    flip_at = null;
    hop_at = null;
    shine_at = null;
    sparkle_rng = rng.Xorshift.init(0x51_700_0);
    for (&sparkles) |*s| s.* = .{ .x = 0, .y = 0, .age = sparkle_life };
}

/// Starts the spin wave now, unless one is still running (the A button,
/// and the cycle, which passes the next theme when `auto_themes`).
pub fn flip(t: u32, to: ?usize) void {
    if (t < show_at or flip_running(t)) return;
    flip_at = t;
    theme_to = to;
}

/// Starts the hop ripple now, unless one is still running (DOWN).
pub fn hop(t: u32) void {
    if (t < show_at) return;
    if (hop_at) |h| {
        if (t -% h < hop_step * (text.len - 1) + hop_frames) return;
    }
    hop_at = t;
}

/// Starts a shine sweep now (C / Select); a running one starts over.
pub fn shine(t: u32) void {
    if (t >= show_at) shine_at = t;
}

/// Out-of-place 8-neighbour dilation: `out` (glyph width + 2 columns) gets
/// every pixel within one of a glyph pixel, shifted one row down and one
/// column right so the frame's origin is the glyph's minus (1, 1).
pub fn dilate(cols: []const u32, out: []u32) void {
    std.debug.assert(out.len == cols.len + 2);
    for (out, 0..) |*o, fc| {
        var m: u32 = 0;
        // Frame column fc covers glyph columns fc-2 .. fc.
        var gc: usize = if (fc >= 2) fc - 2 else 0;
        while (gc <= fc and gc < cols.len) : (gc += 1) m |= cols[gc];
        const s = m << 1;
        o.* = s | (s << 1) | (s >> 1);
    }
}

// ---------------------------------------------------------------------------
// Per frame.

/// A letter's colours for this frame.
const Colours = struct {
    front: [rows]cart.Pixel,
    back: [rows]cart.Pixel,
    shine: [rows]cart.Pixel,
    rim: cart.Pixel,
    side: [extrude]cart.Pixel,
};

/// Where a letter is this frame: rest position plus offsets, and its
/// horizontal scale (1 = facing, -1 = its back after half a spin).
const Pose = struct { dy: i32, scale: f32, visible: bool };

pub fn render(t: u32, fb: cart.FramebufferPtr) void {
    schedule(t);
    if (theme_to) |to| {
        if (!flip_running(t)) {
            theme = to;
            theme_to = null;
        }
    }
    const beat = t % 30;

    var poses: [text.len]Pose = undefined;
    var colours: [text.len]Colours = undefined;
    for (letters[0..letter_count], 0..) |l, i| {
        poses[i] = pose(t, l.index);
        const th = if (switched(t, l.index)) themes[theme_to.?] else themes[theme];
        colours[i] = letter_colours(th, t, l.index, beat);
    }

    // Extrusion for every letter first, far to near, then every rim, then
    // every face: neighbours' sides never cover a face.
    var k: i32 = extrude;
    while (k >= 1) : (k -= 1) {
        for (letters[0..letter_count], poses[0..letter_count], colours[0..letter_count]) |*l, p, c| {
            if (!p.visible) continue;
            const w: i32 = @intCast(l.cols.len);
            draw_flat(fb, l.rim[0 .. l.cols.len + 2], l.x - 1 + k, top_y + p.dy - 1 + k, centre(l.x, w) + @as(f32, @floatFromInt(k)), p.scale, c.side[@intCast(extrude - k)]);
        }
    }
    for (letters[0..letter_count], poses[0..letter_count], colours[0..letter_count]) |*l, p, c| {
        if (!p.visible) continue;
        const w: i32 = @intCast(l.cols.len);
        draw_flat(fb, l.rim[0 .. l.cols.len + 2], l.x - 1, top_y + p.dy - 1, centre(l.x, w), p.scale, c.rim);
    }
    const shine_x = shine_position(t);
    for (letters[0..letter_count], poses[0..letter_count], colours[0..letter_count]) |*l, p, *c| {
        if (!p.visible) continue;
        const w: i32 = @intCast(l.cols.len);
        draw_face(fb, l.cols, l.x, top_y + p.dy, centre(l.x, w), p.scale, c, shine_x);
    }

    sparkle(t, fb, themes[theme_to orelse theme], poses[0..letter_count]);
}

fn centre(x: i32, w: i32) f32 {
    return @as(f32, @floatFromInt(x)) + @as(f32, @floatFromInt(w)) * 0.5;
}

/// Starts the cycle's moves on their frames.
fn schedule(t: u32) void {
    if (t < show_at) return;
    const c = (t - show_at) % cycle;
    for (shine_moments) |m| {
        if (c == m) shine(t);
    }
    if (c == hop_moment) hop(t);
    if (c == flip_moment) flip(t, if (auto_themes) (theme + 1) % themes.len else null);
}

fn pose(t: u32, index: u8) Pose {
    const i: u32 = index;
    const tf: f32 = @floatFromInt(t);
    var dy: f32 = wave_amp * math.sin_turns(tf / wave_period - @as(f32, @floatFromInt(i)) * wave_phase);

    // Intro drop.
    const drop_start = intro_at + intro_step * i;
    if (t < drop_start) return .{ .dy = 0, .scale = 1, .visible = false };
    if (t < drop_start + drop_frames) {
        const p = @as(f32, @floatFromInt(t - drop_start)) / drop_frames;
        dy -= (1.0 - bounce(p)) * drop_height;
    }

    if (hop_at) |h| {
        const start = h + hop_step * i;
        if (t >= start and t < start + hop_frames) {
            const q = @as(f32, @floatFromInt(t - start)) / hop_frames;
            dy -= hop_height * math.sin_turns(q * 0.5);
        }
    }

    var scale: f32 = 1;
    if (flip_at) |f| {
        const start = f + flip_step * i;
        if (t >= start and t < start + flip_frames) {
            const q = @as(f32, @floatFromInt(t - start)) / flip_frames;
            // Smoothstep so the spin eases in and out.
            scale = math.cos_turns(q * q * (3.0 - 2.0 * q));
        }
    }
    return .{ .dy = @intFromFloat(@round(dy)), .scale = scale, .visible = true };
}

/// Ease-out bounce, 0 -> 1 with three shrinking bounces at the end.
pub fn bounce(p: f32) f32 {
    const n: f32 = 7.5625;
    const d: f32 = 2.75;
    if (p < 1.0 / d) return n * p * p;
    if (p < 2.0 / d) {
        const q = p - 1.5 / d;
        return n * q * q + 0.75;
    }
    if (p < 2.5 / d) {
        const q = p - 2.25 / d;
        return n * q * q + 0.9375;
    }
    const q = p - 2.625 / d;
    return n * q * q + 0.984375;
}

fn letter_colours(base: Theme, t: u32, index: u8, beat: u32) Colours {
    var th = base;
    if (th.rainbow) {
        const h = palette.hue(math.fract(@as(f32, @floatFromInt(t)) / 360.0 + @as(f32, @floatFromInt(index)) / 14.0));
        th.sky_top = palette.mix_rgb(h, 0xffffff, 190);
        th.sky_low = h;
        th.ground_top = palette.mix_rgb(0, h, 80);
        th.ground_low = palette.mix_rgb(h, 0xffffff, 120);
        th.rim = palette.mix_rgb(0, h, 24);
        th.side_far = palette.mix_rgb(0, h, 60);
        th.side_near = palette.mix_rgb(0, h, 130);
    }
    var c: Colours = undefined;
    for (0..rows) |r| {
        const rgb = if (r < horizon)
            palette.mix_rgb(th.sky_top, th.sky_low, @intCast((r * 256) / (horizon - 1)))
        else
            palette.mix_rgb(th.ground_top, th.ground_low, @intCast(((r - horizon) * 256) / (rows - 1 - horizon)));
        c.front[r] = palette.pixel(rgb);
        c.back[r] = palette.pixel(palette.mix_rgb(rgb, th.side_far, 150));
        c.shine[r] = palette.pixel(palette.mix_rgb(rgb, 0xffffff, 210));
    }
    // The rim glows toward the sky colour on every beat, fading over 10 frames.
    const pulse: u32 = if (beat < 10) (10 - beat) * 12 else 0;
    c.rim = palette.pixel(palette.mix_rgb(th.rim, th.sky_low, pulse));
    for (0..extrude) |e| {
        c.side[e] = palette.pixel(palette.mix_rgb(th.side_far, th.side_near, @intCast((e * 256) / (extrude - 1))));
    }
    return c;
}

/// Screen x of the shine band's leading edge on row 0, or null when no
/// shine is crossing.
fn shine_position(t: u32) ?i32 {
    const s = shine_at orelse return null;
    if (t -% s >= shine_frames) return null;
    const travel: i32 = 160 + 40;
    return -20 + @divTrunc(travel * @as(i32, @intCast(t - s)), shine_frames);
}

/// Dest columns a mask of `w` columns with its left edge at `left` and its
/// centre at `cx` covers at horizontal scale `s`: the source column for
/// screen column dx is floor(cx - left + (dx + 0.5 - cx) / s).
const Span = struct { x0: i32, x1: i32, inv: f32, off: f32 };

fn span(left: i32, w: usize, cx: f32, s: f32) ?Span {
    const a = @abs(s);
    if (a < 0.04) return null;
    const half = @as(f32, @floatFromInt(w)) * 0.5 * a;
    return .{
        .x0 = @intFromFloat(@floor(cx - half)),
        .x1 = @intFromFloat(@ceil(cx + half)),
        .inv = 1.0 / s,
        .off = cx - @as(f32, @floatFromInt(left)),
    };
}

inline fn source_column(sp: Span, dx: i32, cx: f32) i32 {
    return @intFromFloat(@floor(sp.off + (@as(f32, @floatFromInt(dx)) + 0.5 - cx) * sp.inv));
}

/// Every set bit of `mask` (columns, bit 0 the top row at screen row
/// `top`) in one colour, scaled horizontally about `cx`. Clipped.
pub fn draw_flat(fb: cart.FramebufferPtr, mask: []const u32, left: i32, top: i32, cx: f32, s: f32, px: cart.Pixel) void {
    const sp = span(left, mask.len, cx, s) orelse return;
    var dx = @max(sp.x0, 0);
    while (dx < @min(sp.x1, 160)) : (dx += 1) {
        const sc = source_column(sp, dx, cx);
        if (sc < 0 or sc >= mask.len) continue;
        var bits = mask[@intCast(sc)];
        const col = &fb[@intCast(dx)];
        while (bits != 0) {
            const r: i32 = @ctz(bits);
            bits &= bits - 1;
            const y = top + r;
            if (y >= 0 and y < 128) col[@intCast(y)] = px;
        }
    }
}

/// The chrome face: like draw_flat, coloured per glyph row, the back
/// colours while the letter shows its back (s < 0), and the shine band
/// (a 4 px stripe and a 1 px one, leaning right) where it crosses.
fn draw_face(fb: cart.FramebufferPtr, mask: []const u32, left: i32, top: i32, cx: f32, s: f32, c: *const Colours, shine_x: ?i32) void {
    const sp = span(left, mask.len, cx, s) orelse return;
    const face = if (s < 0) &c.back else &c.front;
    var dx = @max(sp.x0, 0);
    while (dx < @min(sp.x1, 160)) : (dx += 1) {
        const sc = source_column(sp, dx, cx);
        if (sc < 0 or sc >= mask.len) continue;
        var bits = mask[@intCast(sc)];
        const col = &fb[@intCast(dx)];
        while (bits != 0) {
            const r: usize = @ctz(bits);
            bits &= bits - 1;
            const y = top + @as(i32, @intCast(r));
            if (y < 0 or y >= 128) continue;
            var px = face[r];
            if (shine_x) |sx| {
                const d = dx + @as(i32, @intCast(r >> 1)) - sx;
                if ((d >= 0 and d < 4) or d == 6) px = c.shine[r];
            }
            col[@intCast(y)] = px;
        }
    }
}

/// Spawns a glint on a random letter's top edge every `sparkle_every`
/// frames once the show runs, and draws the live ones: a white centre and
/// four arms that grow and shrink over `sparkle_life` frames.
fn sparkle(t: u32, fb: cart.FramebufferPtr, th: Theme, poses: []const Pose) void {
    if (t >= show_at and (t - show_at) % sparkle_every == 0) {
        for (&sparkles) |*s| {
            if (s.age < sparkle_life) continue;
            const li = sparkle_rng.below(@intCast(letter_count));
            const l = &letters[li];
            const c = sparkle_rng.below(@intCast(l.cols.len));
            const col = l.cols[c];
            if (col == 0 or poses[li].scale < 0.9) break;
            s.* = .{
                .x = @intCast(l.x + @as(i32, @intCast(c))),
                .y = @intCast(top_y + poses[li].dy + @as(i32, @ctz(col))),
                .age = 0,
            };
            break;
        }
    }
    const arm_px = palette.pixel(if (th.rainbow) 0xfff0ff else palette.mix_rgb(th.sky_top, 0xffffff, 128));
    const tip_px = palette.pixel(if (th.rainbow) 0x8080c0 else palette.mix_rgb(th.sky_low, 0xffffff, 64));
    const white = palette.pixel(0xffffff);
    for (&sparkles) |*s| {
        if (s.age >= sparkle_life) continue;
        // Arm length 0, 1, 2, 3, 2, 1, 0 over the life.
        const half = sparkle_life / 2;
        const a: u32 = if (s.age < half) s.age else sparkle_life - 1 - s.age;
        const len: i32 = @intCast((a * 4) / half);
        plot(fb, s.x, s.y, white);
        var k: i32 = 1;
        while (k <= len) : (k += 1) {
            const px = if (k == len and len > 1) tip_px else arm_px;
            plot(fb, s.x + k, s.y, px);
            plot(fb, s.x - k, s.y, px);
            plot(fb, s.x, s.y + k, px);
            plot(fb, s.x, s.y - k, px);
        }
        if (len >= 3) {
            plot(fb, s.x + 1, s.y + 1, arm_px);
            plot(fb, s.x - 1, s.y + 1, arm_px);
            plot(fb, s.x + 1, s.y - 1, arm_px);
            plot(fb, s.x - 1, s.y - 1, arm_px);
        }
        s.age += 1;
    }
}

inline fn plot(fb: cart.FramebufferPtr, x: i32, y: i32, px: cart.Pixel) void {
    if (x < 0 or x >= 160 or y < 0 or y >= 128) return;
    fb[@intCast(x)][@intCast(y)] = px;
}

// ---------------------------------------------------------------------------
// Host tests.

test "name: layout fits the screen with its extrusion" {
    init();
    try std.testing.expectEqual(@as(usize, 9), letter_count);
    const first = letters[0];
    const last = letters[letter_count - 1];
    try std.testing.expect(first.x - 1 >= 0);
    try std.testing.expect(last.x + @as(i32, @intCast(last.cols.len)) + 1 + extrude <= 160);
    // Rest position, wave and hop stay inside the Tufty's crop (rows 4..123).
    try std.testing.expect(top_y - 1 - @as(i32, @intFromFloat(@ceil(wave_amp + hop_height))) >= 4);
    try std.testing.expect(top_y + rows + extrude + @as(i32, @intFromFloat(@ceil(wave_amp))) <= 124);
    for (letters[0..letter_count]) |l| try std.testing.expect(l.cols.len > 0);
}

test "name: dilation grows by exactly one pixel" {
    const cols = [_]u32{0b100};
    var out: [3]u32 = undefined;
    dilate(&cols, &out);
    // The pixel at (0, row 2) moves to frame (1, row 3); the 3x3 around it.
    for (out) |o| try std.testing.expectEqual(@as(u32, 0b111 << 2), o);
    // A glyph's every pixel stays set in its rim (shifted by (1, 1)).
    init();
    for (letters[0..letter_count]) |l| {
        for (l.cols, 0..) |c, x| try std.testing.expectEqual(c << 1, l.rim[x + 1] & (c << 1));
    }
}

test "name: unscaled draw is a straight copy" {
    var fb: cart.Framebuffer align(cart.framebuffer_alignment) = undefined;
    const bg: cart.Pixel = .from_color(.{ .r = 0, .g = 0, .b = 0 });
    const ink: cart.Pixel = .from_color(.{ .r = 31, .g = 0, .b = 0 });
    for (&fb) |*col| @memset(col, bg);
    const g = font.glyph('W');
    const left = 30;
    const w: i32 = @intCast(g.len);
    draw_flat(&fb, g, left, 50, centre(left, w), 1.0, ink);
    for (0..160) |x| for (0..128) |y| {
        const inside = x >= left and x < left + g.len and y >= 50 and y < 50 + rows and
            (g[x - left] >> @intCast(y - 50)) & 1 == 1;
        try std.testing.expectEqual(if (inside) ink else bg, fb[x][y]);
    };
    // Mirrored (s = -1) is the same glyph flipped left to right.
    for (&fb) |*col| @memset(col, bg);
    draw_flat(&fb, g, left, 50, centre(left, w), -1.0, ink);
    for (0..g.len) |c| for (0..rows) |r| {
        const set = (g[g.len - 1 - c] >> @intCast(r)) & 1 == 1;
        try std.testing.expectEqual(if (set) ink else bg, fb[left + c][50 + r]);
    };
    // Off-screen positions clip.
    draw_flat(&fb, g, -10, -10, centre(-10, w), 1.0, ink);
    draw_flat(&fb, g, 150, 120, centre(150, w), 1.0, ink);
}

test "name: a spin carries the next theme along the letters" {
    init();
    enter();
    const t0 = show_at + 5;
    flip(t0, 2);
    try std.testing.expect(!switched(t0, 0));
    try std.testing.expect(switched(t0 + flip_frames / 2, 0));
    try std.testing.expect(!switched(t0 + flip_frames / 2, 9));
    // A second spin cannot start while one runs; B moves the target on.
    flip(t0 + 1, 3);
    try std.testing.expectEqual(@as(?usize, 2), theme_to);
    pick_theme(t0 + 2);
    try std.testing.expectEqual(@as(?usize, 3), theme_to);
    try std.testing.expect(!auto_themes);
    try std.testing.expect(!flip_running(t0 + flip_step * 9 + flip_frames));
    enter();
}

test "name: bounce lands at 1 and the show starts after the last drop" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), bounce(0.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), bounce(1.0), 1e-4);
    var p: f32 = 0;
    while (p <= 1.0) : (p += 0.01) try std.testing.expect(bounce(p) <= 1.0001);
    try std.testing.expectEqual(@as(u32, 40 + 6 * 9 + 42), show_at);
}
