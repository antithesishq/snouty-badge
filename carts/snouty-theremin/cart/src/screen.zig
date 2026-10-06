//! The screen (SPEC section 6), redrawn whole every update
//! (.no_copy_full_frame): status bar, note name and cents meter, Snouty,
//! the zone grid, the scope, the hand bars, the settings line and a
//! rotating hint line; the settings menu on top when open.
const std = @import("std");
const gfx = @import("gfx.zig");
const pitch = @import("pitch.zig");
const play = @import("play.zig");
const hands = @import("hands.zig");
const voice = @import("voice.zig");
const input = @import("input.zig");

pub const View = struct {
    settings: play.Settings,
    out: play.Output,
    v: *const voice.Voice,
    hands: hands.Hands,
    /// One-hand: where the hand is over the grid (the highlight).
    track: hands.Track,
    source: input.Source,
    muted: bool,
    /// The stick's stand-in pitch-hand height (mm), for the bar.
    stick_mm: u16,
    menu_open: bool,
    menu_row: u8,
    tick: u32,
};

// Palette.
const bg = 0x0B0F1A;
const bar_bg = 0x1A2238;
const ink = 0xE8ECF4;
const dim = 0x6A7488;
const faint = 0x2A3346;
const amber = 0xFFB040;
const green = 0x50E890;
const red = 0xF04848;
const cyan = 0x40E0FF;
const magenta = 0xFF50C0;
const scope_bg = 0x06221C;
const scope_grid = 0x0F3A30;
const scope_ink = 0x5CFFB0;

const c_body = 0x7C6A5C;
const c_dark = 0x3A2E28;
const c_light = 0xC8B8A4;
const c_snout = 0x9A8676;

pub fn draw(w: View) void {
    gfx.clear(gfx.rgb(bg));
    status_bar(w);
    note_panel(w);
    snouty(w);
    zone_grid(w);
    scope(w);
    hand_bars(w);
    settings_line(w);
    hint_line(w);
    if (w.menu_open) menu(w);
}

fn sounding(w: View) bool {
    return w.v.level > 2048;
}

fn status_bar(w: View) void {
    gfx.fill(0, 0, gfx.W, 10, gfx.rgb(bar_bg));
    switch (w.source) {
        .sensor => {
            gfx.fill(1, 1, 41, 8, gfx.rgb(0x1E5A3A));
            _ = gfx.text("SENSOR", 3, 1, gfx.rgb(green));
            _ = gfx.text(w.settings.layout.label(), 48, 1, gfx.rgb(ink));
        },
        .stick => {
            gfx.fill(1, 1, 35, 8, gfx.rgb(0x5A4214));
            _ = gfx.text("STICK", 3, 1, gfx.rgb(amber));
            _ = gfx.text("NO SENSOR", 42, 1, gfx.rgb(dim));
        },
    }
    if (w.muted) {
        gfx.fill(124, 1, 35, 8, gfx.rgb(red));
        _ = gfx.text("MUTED", 127, 1, gfx.rgb(0xFFFFFF));
    } else {
        // A little speaker with waves while sounding.
        const c = gfx.rgb(green);
        gfx.fill(118, 4, 2, 3, c);
        gfx.vline(120, 3, 5, c);
        gfx.vline(121, 2, 7, c);
        if (sounding(w)) {
            gfx.vline(123, 4, 3, c);
            gfx.vline(125, 3, 5, c);
        }
        _ = gfx.text("SOUND", 128, 1, gfx.rgb(ink));
    }
}

fn note_panel(w: View) void {
    const n = pitch.nearest(w.out.cents);
    var buf: [4]u8 = undefined;
    const name = pitch.note_name(n.midi, &buf);
    const on = sounding(w);
    gfx.text_big(name, 4, 13, 2, gfx.rgb(if (on) ink else faint));

    // Cents meter: +-50 across 55 px, the needle green when in tune.
    const x0: i32 = 4;
    const y0: i32 = 33;
    const mid: i32 = x0 + 27;
    gfx.fill(x0, y0, 55, 7, gfx.rgb(0x141A28));
    gfx.vline(mid, y0 - 1, 9, gfx.rgb(dim));
    gfx.vline(x0 + 13, y0 + 5, 2, gfx.rgb(faint));
    gfx.vline(x0 + 41, y0 + 5, 2, gfx.rgb(faint));
    if (on) {
        const off = n.cents;
        const col: u32 = if (@abs(off) <= 8) green else if (@abs(off) <= 25) amber else red;
        const nx = mid + @divTrunc(off * 27, 50);
        gfx.fill(nx - 1, y0, 3, 7, gfx.rgb(col));
    }
    // Cents and frequency.
    var tb: [8]u8 = undefined;
    _ = gfx.text(fmt_cents(n.cents, &tb), 4, 42, gfx.rgb(if (on) dim else faint));
    var hb: [8]u8 = undefined;
    const hz = pitch.hz_of(pitch.inc_for(w.out.cents));
    const hs = fmt_uint(hz, &hb);
    const x = gfx.text(hs, 30, 42, gfx.rgb(if (on) dim else faint));
    _ = gfx.text("Hz", x, 42, gfx.rgb(faint));
}

fn fmt_uint(v: u32, buf: *[8]u8) []const u8 {
    var tmp: [10]u8 = undefined;
    var n = v;
    var i: usize = 0;
    while (true) {
        tmp[i] = '0' + @as(u8, @intCast(n % 10));
        i += 1;
        n /= 10;
        if (n == 0 or i == 8) break;
    }
    for (0..i) |k| buf[k] = tmp[i - 1 - k];
    return buf[0..i];
}

fn fmt_cents(c: i32, buf: *[8]u8) []const u8 {
    buf[0] = if (c < 0) '-' else '+';
    var nb: [8]u8 = undefined;
    const digits = fmt_uint(@intCast(@abs(c)), &nb);
    @memcpy(buf[1 .. 1 + digits.len], digits);
    buf[1 + digits.len] = 'c';
    return buf[0 .. 2 + digits.len];
}

/// Snouty the anteater, side view facing the sensor grid: the snout
/// tilts up with pitch, the ear perks with volume, notes float from the
/// snout tip while sounding, and the eye shuts when muted.
fn snouty(w: View) void {
    const low = w.settings.low();
    const pn: i32 = @min(@max(@divTrunc((w.out.cents - low) * 256, 3600), 0), 256); // pitch 0..256
    const vn: i32 = @divTrunc(w.v.level, 256); // level 0..256
    const t: i32 = @intCast(w.tick % 100000);

    // Tail: a bushy plume that sways slowly.
    const sway: i32 = if (@mod(@divTrunc(t, 20), 2) == 0) 0 else 1;
    gfx.ellipse(68, 33 + sway, 6, 10, gfx.rgb(c_dark));
    gfx.ellipse(69, 33 + sway, 5, 9, gfx.rgb(c_body));
    // Legs.
    for ([_]i32{ 74, 78, 86, 90 }) |lx| gfx.fill(lx, 44, 3, 7, gfx.rgb(c_dark));
    // Body and the anteater's shoulder band.
    gfx.ellipse(82, 39, 13, 7, gfx.rgb(c_body));
    gfx.ellipse(88, 37, 4, 5, gfx.rgb(c_dark));
    gfx.ellipse(87, 37, 2, 4, gfx.rgb(c_light));
    // Head.
    gfx.ellipse(96, 33, 5, 4, gfx.rgb(c_body));
    // Ear: taller when louder.
    const ear: i32 = 2 + @divTrunc(vn * 4, 256);
    var k: i32 = 0;
    while (k < ear) : (k += 1) gfx.hline(93, 29 - k, 3 - @divTrunc(k * 2, @max(ear, 1)), gfx.rgb(c_dark));
    // Snout: from the head to a tip that rises with pitch.
    const tip_x: i32 = 112;
    const tip_y: i32 = 37 - @divTrunc(pn * 12, 256);
    gfx.line(100, 32, tip_x, tip_y, gfx.rgb(c_snout));
    gfx.line(100, 33, tip_x, tip_y + 1, gfx.rgb(c_snout));
    gfx.line(100, 34, tip_x - 3, tip_y + 1, gfx.rgb(c_dark));
    gfx.set(tip_x, tip_y, gfx.rgb(c_dark));
    // Eye.
    if (w.muted) {
        gfx.hline(96, 32, 2, gfx.rgb(c_dark));
        if (@mod(@divTrunc(t, 30), 2) == 0) _ = gfx.text("z", 100, 18, gfx.rgb(dim));
    } else {
        gfx.fill(96, 31, 2, 2, gfx.rgb(0x101010));
        gfx.set(97, 31, gfx.rgb(0xFFFFFF));
    }
    // Notes rising from the snout tip while sounding.
    if (sounding(w) and !w.muted) {
        for (0..3) |i| {
            const life: i32 = @mod(t + @as(i32, @intCast(i)) * 13, 40);
            const nx = tip_x - 6 + @divTrunc(life, 6) + @as(i32, @intCast(i)) * 2;
            const ny = tip_y - 4 - @divTrunc(life * 3, 8);
            if (ny < 12) continue;
            const c = gfx.mix(0xFFE080, bg, life * 6);
            gfx.fill(nx, ny + 3, 2, 2, c);
            gfx.vline(nx + 1, ny, 3, c);
            gfx.set(nx + 2, ny, c);
        }
    }
}

fn closeness_color(mm: u16) gfx.Color {
    const t: i32 = @divTrunc((650 - @as(i32, @min(mm, 650))) * 256, 600);
    return gfx.mix(0x1C2A5A, 0xFFB040, t);
}

/// The zones as the screen sees them: the 3x3 grid, or the 8 stripes
/// (GRID / STRIPES, docs/TOF.md M5), in a 41 px square; each in the
/// layout of the frame it came from.
fn zone_grid(w: View) void {
    const x0: i32 = 116;
    const y0: i32 = 12;
    const size: i32 = 42; // pitch x cells, gaps included
    const sensed = w.source == .sensor;
    const cols: i32 = if (sensed) w.hands.cols else 3;
    const rows: i32 = if (sensed) w.hands.rows else 3;
    const pw = @divTrunc(size, cols);
    const ph = @divTrunc(size, rows);
    var r: i32 = 0;
    while (r < rows) : (r += 1) {
        var c: i32 = 0;
        while (c < cols) : (c += 1) {
            const x = x0 + c * pw;
            const y = y0 + r * ph;
            const i: usize = @intCast(r * cols + c);
            if (sensed) {
                if (w.hands.grid[i]) |mm| gfx.fill(x, y, pw - 1, ph - 1, closeness_color(mm)) else gfx.fill(x, y, pw - 1, ph - 1, gfx.rgb(0x141820));
            } else {
                gfx.fill(x, y, pw - 1, ph - 1, gfx.rgb(0x10131C));
            }
        }
    }
    if (!sensed) {
        _ = gfx.text("NO", x0 + 14, y0 + 12, gfx.rgb(dim));
        _ = gfx.text("TOF", x0 + 11, y0 + 21, gfx.rgb(dim));
        return;
    }
    switch (w.settings.layout) {
        .one_hand => if (w.track.cell) |tc| {
            // The track is from the pose, in the pose's layout: draw it only
            // over a picture of the same layout (not for the frame or two
            // in flight around a ZONES switch).
            if (w.track.layout != w.hands.layout) return;
            const tcol: i32 = @intCast(tc % @as(u4, @intCast(cols)));
            const trow: i32 = @intCast(tc / @as(u4, @intCast(cols)));
            gfx.frame(x0 + tcol * pw - 1, y0 + trow * ph - 1, pw + 1, ph + 1, gfx.rgb(cyan));
            // The centroid itself, between zone centres as the hand moves
            // (GRID: up to 0.4 cell past the outer centres).
            const lo: f32 = if (cols == 3) -0.4 else 0;
            const lo_r: f32 = if (rows == 3) -0.4 else 0;
            const fc = std.math.clamp(w.track.fc, lo, @as(f32, @floatFromInt(cols - 1)) - lo);
            const fr = std.math.clamp(w.track.fr, lo_r, @as(f32, @floatFromInt(rows - 1)) - lo_r);
            const px = x0 + @as(i32, @intFromFloat((fc + 0.5) * @as(f32, @floatFromInt(pw)) + 0.5)) - 2;
            const py = y0 + @as(i32, @intFromFloat((fr + 0.5) * @as(f32, @floatFromInt(ph)) + 0.5)) - 2;
            gfx.fill(px, py, 3, 3, gfx.rgb(ink));
        },
        .two_hand => {
            // The pitch and volume sides: columns (or, transposed, rows).
            const g: i32 = w.hands.group;
            if (cols > 1) {
                gfx.frame(x0 + @as(i32, w.hands.pitch_col) * pw - 1, y0 - 1, g * pw + 1, rows * ph + 1, gfx.rgb(cyan));
                gfx.frame(x0 + @as(i32, w.hands.volume_col) * pw - 1, y0 - 1, g * pw + 1, rows * ph + 1, gfx.rgb(magenta));
            } else {
                gfx.frame(x0 - 1, y0 + @as(i32, w.hands.pitch_col) * ph - 1, cols * pw + 1, g * ph + 1, gfx.rgb(cyan));
                gfx.frame(x0 - 1, y0 + @as(i32, w.hands.volume_col) * ph - 1, cols * pw + 1, g * ph + 1, gfx.rgb(magenta));
            }
        },
    }
}

fn scope(w: View) void {
    const x0: i32 = 2;
    const y0: i32 = 56;
    const sw: i32 = 111;
    const sh: i32 = 45;
    const mid = y0 + sh / 2;
    gfx.fill(x0, y0, sw, sh, gfx.rgb(scope_bg));
    gfx.hline(x0, mid, sw, gfx.rgb(scope_grid));
    var gx: i32 = x0 + 18;
    while (gx < x0 + sw) : (gx += 18) gfx.vline(gx, y0, sh, gfx.rgb(scope_grid));

    // Two cycles of what was just rendered, triggered on a rising
    // crossing of the centre so the trace stands still.
    const hist = &w.v.hist;
    const n = voice.hist_len;
    const inc = @max(w.v.inc, 1);
    const period: u32 = @intCast(@min((@as(u64, 1) << 32) / inc, 400));
    const window: u32 = @min(@max(2 * period, 48), 360);
    const newest: u32 = (@as(u32, w.v.hist_pos) + n - 1) % n;
    // Search back from (newest - window) at most one period for the trigger.
    var start: u32 = (newest + n - window) % n;
    var k: u32 = 0;
    while (k < period and k + window + 2 < n) : (k += 1) {
        const i = (newest + 2 * n - window - k) % n;
        const prev = (i + n - 1) % n;
        if (hist[prev] < 128 and hist[i] >= 128) {
            start = i;
            break;
        }
    }
    const col = gfx.rgb(if (w.muted) 0x40685A else scope_ink);
    var last_y: i32 = mid;
    var x: i32 = 0;
    while (x < sw) : (x += 1) {
        const idx = (start + @as(u32, @intCast(x)) * window / @as(u32, @intCast(sw))) % n;
        const s: i32 = @as(i32, hist[idx]) - 128;
        const y = mid - @divTrunc(s * (sh / 2 - 2), 128);
        if (x == 0) last_y = y;
        const top = @min(y, last_y);
        const bot = @max(y, last_y);
        gfx.vline(x0 + x, top, bot - top + 1, col);
        last_y = y;
    }
    _ = gfx.text(w.settings.wave.label(), x0 + 2, y0 + 2, gfx.rgb(0x2E8A68));
}

fn hand_bars(w: View) void {
    const y0: i32 = 58;
    const bh: i32 = 32;
    const max_mm: i32 = 650;
    // Pitch: the pitch hand's height (the stick's stand-in without a sensor).
    const pmm: ?u16 = if (w.source == .sensor) w.hands.pitch_mm else if (sounding(w)) w.stick_mm else null;
    bar(117, y0, bh, pmm, max_mm, cyan, "P");
    // Volume: the volume hand's height in the two-hand layout; else the level.
    if (w.source == .sensor and w.settings.layout == .two_hand) {
        bar(139, y0, bh, w.hands.volume_mm, max_mm, magenta, "V");
    } else {
        gfx.fill(139, y0, 18, bh, gfx.rgb(0x141820));
        const lv = @divTrunc(w.v.level * bh, voice.full);
        gfx.fill(139, y0 + bh - lv, 18, lv, gfx.rgb(0x7A3060));
        _ = gfx.text("V", 145, y0 + 1, gfx.rgb(if (lv > bh - 9) ink else magenta));
        _ = gfx.text("--", 142, y0 + bh + 3, gfx.rgb(faint));
    }
}

fn bar(x: i32, y0: i32, bh: i32, mm: ?u16, max_mm: i32, color: u32, label: []const u8) void {
    gfx.fill(x, y0, 18, bh, gfx.rgb(0x141820));
    if (mm) |d| {
        const h = @divTrunc(@as(i32, @min(d, @as(u16, @intCast(max_mm)))) * bh, max_mm);
        gfx.fill(x, y0 + bh - h, 18, h, gfx.mix(color, bg, 110));
        gfx.hline(x, y0 + bh - h, 18, gfx.rgb(color));
        var b: [8]u8 = undefined;
        const s = fmt_uint(d / 10, &b);
        const tx = gfx.text(s, x + 9 - @divTrunc(gfx.text_width(s) + 12, 2), y0 + bh + 3, gfx.rgb(ink));
        _ = gfx.text("cm", tx, y0 + bh + 3, gfx.rgb(dim));
    } else {
        _ = gfx.text("--", x + 3, y0 + bh + 3, gfx.rgb(faint));
    }
    const full = if (mm) |d| @as(i32, d) * 4 > max_mm * 3 else false;
    _ = gfx.text(label, x + 6, y0 + 1, gfx.rgb(if (full) ink else color));
}

fn settings_line(w: View) void {
    const s = w.settings;
    const y: i32 = 104;
    var x = gfx.text(s.wave.label(), 2, y, gfx.rgb(cyan));
    x += 6;
    x = gfx.text(s.scale.label(), x, y, gfx.rgb(amber));
    if (s.scale != .off) {
        x += 3;
        x = gfx.text(if (s.snap == .soft) "~" else "#", x, y, gfx.rgb(amber));
    }
    x += 6;
    // The range: root and octave to three octaves up.
    var b: [4]u8 = undefined;
    x = gfx.text(pitch.note_name(@divTrunc(s.low(), 100), &b), x, y, gfx.rgb(ink));
    x = gfx.text("-", x, y, gfx.rgb(dim));
    _ = gfx.text(pitch.note_name(@divTrunc(s.low(), 100) + 36, &b), x, y, gfx.rgb(ink));
    gfx.hline(2, 113, gfx.W - 4, gfx.rgb(faint));
}

const hints_stick = [_][]const u8{ "UP/DN PLAY  L/R HOLD", "A:WAVE B:SCALE START:MENU", "SELECT: MUTE" };
const hints_sensor = [_][]const u8{ "HAND OVER THE SENSOR", "A:WAVE B:SCALE START:MENU", "UP/DN OCTAVE L/R LAYOUT", "SELECT: MUTE" };
const hints_menu = [_][]const u8{ "UP/DN ROW  L/R CHANGE", "B OR START: CLOSE" };

fn hint_line(w: View) void {
    const list: []const []const u8 = if (w.menu_open) &hints_menu else if (w.source == .sensor) &hints_sensor else &hints_stick;
    const s = list[(w.tick / 150) % list.len];
    _ = gfx.text(s, @divTrunc(gfx.W - gfx.text_width(s), 2), 118, gfx.rgb(dim));
}

pub const menu_rows = [_][]const u8{ "LAYOUT", "WAVE", "SCALE", "SNAP", "KEY", "OCTAVE", "PITCH HAND", "MIRROR", "ZONES" };

fn menu(w: View) void {
    const x0: i32 = 10;
    const y0: i32 = 16;
    const mw: i32 = 140;
    const mh: i32 = 106;
    gfx.fill(x0, y0, mw, mh, gfx.rgb(0x101626));
    gfx.frame(x0, y0, mw, mh, gfx.rgb(cyan));
    _ = gfx.text("SETTINGS", x0 + 46, y0 + 4, gfx.rgb(cyan));
    const s = w.settings;
    for (menu_rows, 0..) |label, i| {
        const y = y0 + 15 + @as(i32, @intCast(i)) * 10;
        const sel = i == w.menu_row;
        if (sel) gfx.fill(x0 + 3, y - 1, mw - 6, 10, gfx.rgb(0x22304E));
        _ = gfx.text(label, x0 + 8, y, gfx.rgb(if (sel) ink else dim));
        var b: [4]u8 = undefined;
        const val: []const u8 = switch (i) {
            0 => s.layout.label(),
            1 => s.wave.label(),
            2 => s.scale.label(),
            3 => s.snap.label(),
            4 => pitch.pitch_class_name(s.root),
            5 => pitch.note_name(@divTrunc(s.low(), 100), &b),
            6 => if (s.pitch_left) "LEFT" else "RIGHT",
            7 => if (s.mirror) "ON" else "OFF",
            else => s.zones.label(),
        };
        const vx = x0 + mw - 12 - gfx.text_width(val);
        _ = gfx.text(val, vx, y, gfx.rgb(if (sel) amber else ink));
        if (sel) {
            _ = gfx.text("<", vx - 9, y, gfx.rgb(amber));
            _ = gfx.text(">", x0 + mw - 9, y, gfx.rgb(amber));
        }
    }
}
