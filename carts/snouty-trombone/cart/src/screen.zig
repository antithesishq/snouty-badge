//! The screen (SPEC section 1), redrawn whole every update
//! (.no_copy_full_frame): status bar, the pixel-art trombone with the
//! slide where the hand is (tools/gen_art.py), the bell glowing with the
//! level and notes floating out of it, the plunger, the slide-position
//! ruler, the note and its tuning, the partial ladder with the lip marker,
//! and a rotating hint line; the settings menu on top when open.
const gfx = @import("gfx.zig");
const art = @import("gen/art.zig");
const horn = @import("horn.zig");
const play = @import("play.zig");
const voice = @import("voice.zig");
const input = @import("input.zig");
const hand = @import("hand.zig");

pub const View = struct {
    settings: play.Settings,
    out: play.Output,
    v: *const voice.Voice,
    reading: hand.Reading,
    source: input.Source,
    demo: bool,
    muted: bool,
    menu_open: bool,
    menu_row: u8,
    tick: u32,
};

// Palette.
const bg = 0x0B0F1A;
const stage = 0x111827;
const bar_bg = 0x1A2238;
const ink = 0xE8ECF4;
const dim = 0x6A7488;
const faint = 0x2A3346;
const amber = 0xFFB040;
const green = 0x50E890;
const red = 0xF04848;
const cyan = 0x40E0FF;
const brass = 0xF2C94C;
const brass_dark = 0x7A5414;
const plunger_red = 0x9A2E1E;
const plunger_hi = 0xD0584A;

pub fn draw(w: View) void {
    gfx.clear(gfx.rgb(bg));
    gfx.fill(0, 61, gfx.W, 12, gfx.rgb(stage));
    status_bar(w);
    trombone(w);
    ruler(w);
    note_panel(w);
    ladder(w);
    hint_line(w);
    if (w.menu_open) menu(w);
}

fn sounding(w: View) bool {
    return w.v.level > 2048;
}

fn status_bar(w: View) void {
    gfx.fill(0, 0, gfx.W, 10, gfx.rgb(bar_bg));
    if (w.demo) {
        gfx.fill(1, 1, 29, 8, gfx.rgb(0x14506A));
        _ = gfx.text("DEMO", 4, 1, gfx.rgb(cyan));
    } else switch (w.source) {
        .sensor => {
            gfx.fill(1, 1, 41, 8, gfx.rgb(0x1E5A3A));
            _ = gfx.text("SENSOR", 3, 1, gfx.rgb(green));
        },
        .stick => {
            gfx.fill(1, 1, 35, 8, gfx.rgb(0x5A4214));
            _ = gfx.text("STICK", 3, 1, gfx.rgb(amber));
        },
    }
    // How the horn is blown.
    const blow: []const u8 = if (w.source == .stick or w.settings.blow == .a) "HOLD A" else "AUTO";
    _ = gfx.text(blow, 46, 1, gfx.rgb(if (sounding(w)) ink else dim));
    // The plunger, while it is shut.
    if (w.v.mute > 16384) _ = gfx.text("WAH", 90, 1, gfx.rgb(plunger_hi));
    if (w.muted) {
        gfx.fill(124, 1, 35, 8, gfx.rgb(red));
        _ = gfx.text("MUTED", 127, 1, gfx.rgb(0xFFFFFF));
    } else {
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

// ---- The trombone ----

/// Palette characters to palette index (0xFF: clear), built on first use.
var lut: [128]u8 = @splat(0xFF);
var lut_ready = false;

fn build_lut() void {
    for (art.palette_chars, 0..) |ch, i| lut[ch] = @intCast(i);
    lut_ready = true;
}

/// Draw `s` at an x offset with `colors` (one per palette entry); rim
/// pixels ('r') shift right by `rim_dx` (the bell rim vibrating).
fn sprite(s: art.Sprite, dx: i32, colors: *const [art.palette.len]gfx.Color, rim_dx: i32) void {
    for (s.rows, 0..) |row, j| {
        const y = s.y + @as(i32, @intCast(j));
        for (row, 0..) |ch, i| {
            if (ch == '.') continue;
            const k = lut[ch & 0x7F];
            if (k == 0xFF) continue;
            const x = s.x + dx + @as(i32, @intCast(i));
            gfx.set(if (ch == 'r') x + rim_dx else x, y, colors[k]);
        }
    }
}

fn trombone(w: View) void {
    if (!lut_ready) build_lut();
    // The bell glows with what is sounding (the voice's recent peak).
    const glow: i32 = if (w.muted) 0 else @min(w.v.peak * 3, 256);
    var colors: [art.palette.len]gfx.Color = undefined;
    for (art.palette, 0..) |c, i| colors[i] = gfx.rgb(c);
    colors[art_index('r')] = gfx.mix(0xFFE08A, 0xFFFFFF, glow);
    colors[art_index('k')] = gfx.mix(0x3A2408, 0xFF8A20, @divTrunc(glow * 3, 4));
    const loud = glow > 180;
    const rim_dx: i32 = if (loud and w.tick % 2 == 1) 1 else 0;

    sound_waves(w, glow);
    sprite(art.horn, 0, &colors, rim_dx);
    const e = slide_px(w.out.slide);
    sprite(art.slide, e, &colors, 0);
    plunger(w);
    bell_notes(w);
}

fn art_index(ch: u8) usize {
    for (art.palette_chars, 0..) |c, i| {
        if (c == ch) return i;
    }
    return 0;
}

fn slide_px(slide: i32) i32 {
    return @divTrunc(@min(@max(slide, 0), horn.slide_max) * art.slide_px_per_position + horn.position_cents / 2, horn.position_cents);
}

/// Arcs of sound to the right of the bell, longer when louder.
fn sound_waves(w: View, glow: i32) void {
    if (glow < 24) return;
    const t: i32 = @intCast(w.tick % 12);
    for (0..3) |i| {
        const k: i32 = @intCast(i);
        const x = art.bell_x + 7 + k * 6 + @divTrunc(t, 4);
        const h = @divTrunc(glow * (10 - k * 2), 256) + 2;
        const col = gfx.mix(0xFFE08A, bg, 90 + k * 50);
        gfx.vline(x, art.bell_y - h, 2 * h + 1, col);
        gfx.set(x - 1, art.bell_y - h - 1, col);
        gfx.set(x - 1, art.bell_y + h + 1, col);
    }
}

/// The plunger cup: against the bell when shut, swung away as it opens.
fn plunger(w: View) void {
    const m = w.v.mute; // 0 open .. 32768 shut
    if (m < 600) return;
    const away = @divTrunc((32768 - m) * 14, 32768);
    const cx = art.bell_x + 5 + away;
    const cy = art.bell_y + @divTrunc(away, 3);
    gfx.ellipse(cx, cy, 3, art.bell_r - 1, gfx.rgb(plunger_red));
    gfx.vline(cx - 2, cy - art.bell_r + 4, 2 * art.bell_r - 8, gfx.rgb(plunger_hi));
    gfx.fill(cx + 3, cy - 1, 3, 3, gfx.rgb(0x5A1A10));
}

/// Notes floating up and away from the bell while it sounds.
fn bell_notes(w: View) void {
    if (!sounding(w) or w.muted) return;
    const t: i32 = @intCast(w.tick % 100000);
    for (0..3) |i| {
        const life: i32 = @mod(t + @as(i32, @intCast(i)) * 17, 50);
        const nx = art.bell_x + 8 + @divTrunc(life * 3, 5) + @as(i32, @intCast(i)) * 3;
        const ny = art.bell_y - 6 - @divTrunc(life * 2, 5);
        if (ny < 11 or nx > gfx.W - 4) continue;
        const c = gfx.mix(0xFFE080, bg, life * 5);
        gfx.fill(nx, ny + 3, 2, 2, c);
        gfx.vline(nx + 1, ny, 3, c);
        gfx.set(nx + 2, ny, c);
    }
}

/// Slide positions 1..7 under the crook, the crook's place marked.
fn ruler(w: View) void {
    const y: i32 = 62;
    const pos = horn.position_x100(w.out.slide); // 100..700
    const near_pos = @divTrunc(pos + 50, 100);
    const on = @abs(pos - near_pos * 100) <= 12;
    for (1..8) |p| {
        const pi: i32 = @intCast(p);
        const x = art.crook_x + (pi - 1) * art.slide_px_per_position;
        const here = pi == near_pos;
        const col: u32 = if (here and on) green else if (here) ink else dim;
        gfx.vline(x, y, 2, gfx.rgb(col));
        var b: [1]u8 = .{'0' + @as(u8, @intCast(p))};
        _ = gfx.text(&b, x - 2, y + 3, gfx.rgb(col));
    }
    // The crook's right edge, live.
    const cx = art.crook_x + slide_px(w.out.slide);
    gfx.fill(cx - 1, y - 1, 3, 1, gfx.rgb(cyan));
    _ = gfx.text("POS", 2, y + 3, gfx.rgb(faint));
}

fn note_panel(w: View) void {
    const on = sounding(w);
    const n = horn.nearest(w.out.cents);
    var buf: [4]u8 = undefined;
    const name = horn.note_name(n.midi, &buf);
    gfx.text_big(name, 4, 75, 2, gfx.rgb(if (on) ink else faint));

    const x0: i32 = 62;
    // Partial and slide position.
    var line: [16]u8 = undefined;
    var k: usize = 0;
    k = put(&line, k, "P");
    k = put_uint(&line, k, w.out.partial);
    k = put(&line, k, " POS ");
    const pos = horn.position_x100(w.out.slide);
    k = put_uint(&line, k, @intCast(@divTrunc(pos, 100)));
    k = put(&line, k, ".");
    k = put_uint(&line, k, @intCast(@divTrunc(@mod(pos, 100), 10)));
    _ = gfx.text(line[0..k], x0, 75, gfx.rgb(if (on) brass else dim));
    // Cents and Hz.
    k = 0;
    k = put(&line, k, if (n.cents < 0) "-" else "+");
    k = put_uint(&line, k, @intCast(@abs(n.cents)));
    k = put(&line, k, "c ");
    k = put_uint(&line, k, horn.hz_of(horn.inc_for(w.out.cents)));
    k = put(&line, k, "Hz");
    _ = gfx.text(line[0..k], x0, 84, gfx.rgb(if (on) dim else faint));
    // Tuning needle: +-50 cents, green within 8.
    const mx: i32 = x0;
    const mw: i32 = 66;
    const mid = mx + @divTrunc(mw, 2);
    gfx.fill(mx, 93, mw, 3, gfx.rgb(0x141A28));
    gfx.vline(mid, 92, 5, gfx.rgb(dim));
    if (on) {
        const col: u32 = if (@abs(n.cents) <= 8) green else if (@abs(n.cents) <= 25) amber else red;
        gfx.fill(mid + @divTrunc(n.cents * (mw / 2 - 1), 50) - 1, 92, 3, 5, gfx.rgb(col));
    }
    // Level meter: seven segments, brass to red.
    var seg: i32 = 0;
    const lit = @divTrunc(@min(w.v.peak, 112) * 7 + 56, 112);
    while (seg < 7) : (seg += 1) {
        const sy = 93 - seg * 3;
        const col = if (seg < lit) gfx.mix(brass, red, @max(seg * 60 - 180, 0)) else gfx.rgb(0x1A2030);
        gfx.fill(148, sy, 8, 2, col);
    }
}

fn put(buf: *[16]u8, at: usize, s: []const u8) usize {
    const n = @min(s.len, buf.len - at);
    @memcpy(buf[at .. at + n], s[0..n]);
    return at + n;
}

fn put_uint(buf: *[16]u8, at: usize, v: u32) usize {
    var tmp: [10]u8 = undefined;
    var n = v;
    var i: usize = 0;
    while (true) {
        tmp[i] = '0' + @as(u8, @intCast(n % 10));
        i += 1;
        n /= 10;
        if (n == 0) break;
    }
    var k = at;
    while (i > 0 and k < buf.len) {
        i -= 1;
        buf[k] = tmp[i];
        k += 1;
    }
    return k;
}

/// The partials the lip can reach, each with the note it plays at the
/// current slide; the sounding one lit, the lip marker above.
fn ladder(w: View) void {
    const lo = horn.lowest_partial(w.settings.pedal);
    const count: i32 = @as(i32, horn.top_partial) - lo + 1;
    const x0: i32 = 3;
    const total: i32 = gfx.W - 6;
    const y: i32 = 101;
    const h: i32 = 11;
    const slide = w.out.slide;
    const on = sounding(w);
    var n: u4 = lo;
    while (n <= horn.top_partial) : (n += 1) {
        const k: i32 = @as(i32, n) - lo;
        const cx0 = x0 + @divTrunc(k * total, count);
        const cx1 = x0 + @divTrunc((k + 1) * total, count) - 1;
        const lit = n == w.out.partial;
        const fill: u32 = if (lit and on) brass else if (lit) brass_dark else 0x161C2C;
        gfx.fill(cx0, y, cx1 - cx0, h, gfx.rgb(fill));
        var buf: [4]u8 = undefined;
        const name = horn.note_name(horn.nearest(horn.pitch(n, slide, 0)).midi, &buf);
        const tx = cx0 + @divTrunc(cx1 - cx0 - gfx.text_width(name), 2);
        _ = gfx.text(name, tx, y + 2, gfx.rgb(if (lit and on) 0x241806 else if (lit) ink else dim));
    }
    // The lip: where between the partials the embouchure sits.
    const lip0 = @as(i32, lo) * horn.lip_one - horn.lip_one / 2;
    const lx = x0 + @divTrunc(@min(@max(w.out.lip - lip0, 0), count * horn.lip_one) * total, count * horn.lip_one);
    const lc = gfx.rgb(if (on) cyan else dim);
    gfx.fill(lx - 2, y - 4, 5, 1, lc);
    gfx.fill(lx - 1, y - 3, 3, 1, lc);
    gfx.set(lx, y - 2, lc);
}

const hints_stick = [_][]const u8{ "HOLD A: BLOW  B: PLUNGER", "UP/DN: SLIDE  L/R: LIP", "START: MENU  SELECT: MUTE" };
const hints_auto = [_][]const u8{ "HAND UP/DOWN: SLIDE", "HAND LEFT/RIGHT: LIP", "B: PLUNGER  A: TONGUE", "START: MENU  SELECT: MUTE" };
const hints_hold_a = [_][]const u8{ "HAND UP/DOWN: SLIDE", "HAND LEFT/RIGHT: LIP", "HOLD A: BLOW  B: PLUNGER", "START: MENU  SELECT: MUTE" };
const hints_demo = [_][]const u8{ "THE DEMO HAND PLAYS", "START: MENU (DEMO OFF)" };
const hints_menu = [_][]const u8{ "UP/DN: ROW  L/R/A: CHANGE", "B OR START: CLOSE" };

fn hint_line(w: View) void {
    gfx.hline(2, 115, gfx.W - 4, gfx.rgb(faint));
    const list: []const []const u8 = if (w.menu_open)
        &hints_menu
    else if (w.demo)
        &hints_demo
    else if (w.source == .stick)
        &hints_stick
    else if (w.settings.blow == .a)
        &hints_hold_a
    else
        &hints_auto;
    const s = list[(w.tick / 150) % list.len];
    _ = gfx.text(s, @divTrunc(gfx.W - gfx.text_width(s), 2), 119, gfx.rgb(dim));
}

pub const menu_rows = [_][]const u8{ "BLOW", "SNAP", "MIRROR", "PEDAL", "TONE", "DEMO" };

fn menu(w: View) void {
    const x0: i32 = 14;
    const y0: i32 = 18;
    const mw: i32 = 132;
    const mh: i32 = 90;
    gfx.fill(x0, y0, mw, mh, gfx.rgb(0x101626));
    gfx.frame(x0, y0, mw, mh, gfx.rgb(brass));
    _ = gfx.text("SETTINGS", x0 + 42, y0 + 4, gfx.rgb(brass));
    const s = w.settings;
    for (menu_rows, 0..) |label, i| {
        const y = y0 + 17 + @as(i32, @intCast(i)) * 11;
        const sel = i == w.menu_row;
        if (sel) gfx.fill(x0 + 3, y - 2, mw - 6, 11, gfx.rgb(0x2A2414));
        _ = gfx.text(label, x0 + 8, y, gfx.rgb(if (sel) ink else dim));
        const val: []const u8 = switch (i) {
            0 => s.blow.label(),
            1 => s.snap.label(),
            2 => if (s.mirror) "ON" else "OFF",
            3 => if (s.pedal) "ON" else "OFF",
            4 => s.tone.label(),
            else => if (s.demo) "ON" else "OFF",
        };
        const vx = x0 + mw - 12 - gfx.text_width(val);
        _ = gfx.text(val, vx, y, gfx.rgb(if (sel) amber else ink));
        if (sel) {
            _ = gfx.text("<", vx - 9, y, gfx.rgb(amber));
            _ = gfx.text(">", x0 + mw - 9, y, gfx.rgb(amber));
        }
    }
}
