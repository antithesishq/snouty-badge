//! Emulator menu (SPEC.md sections 5 and 12): opened by holding Select for
//! 500 ms (frontend/input.zig), drawn with cart.text/cart.rect over the
//! frozen game frame. The core is not stepped while it is open.
//!
//! Frozen frame. The cart runs in `.no_copy_full_frame` mode: after every
//! present the buffers swap and nothing is copied, so the new back buffer
//! holds the frame from two presents ago, not the frozen one. `open` copies
//! the last presented frame (`cart.frontbuffer`) into the back buffer once
//! (40 KB memcpy, no extra RAM) and switches to `.copy_forward`, in which the
//! OS copies each presented frame into the next back buffer (about 0.1 ms,
//! only while the menu is open). The panel is opaque and redrawn every
//! frame, so nothing compounds. `close` switches back before the next game
//! frame is presented. In wasm nothing is ever presented and `framebuffer`
//! never changes, so the frozen frame is simply still there.
//!
//! A palette change while paused recolors the frozen frame in place
//! (`video.remap_palette`), so the preview matches what resuming will show.
//! A scale change takes effect on the first frame after resuming.
//!
//! Game Boy Color (SPEC.md 19.2): in CGB mode the Palette row is
//! "Color: LCD/Raw" (the colour-correction builder, `video.ColorMode`); the
//! frozen frame keeps its colours until the next rendered frame (a scrub
//! step or resuming), since a CGB frame has 64 colours and no shade to remap.
//! The title band reads "SNOUTY BOY COLOR" and the menu is black on white.
//!
//! Time scrubber (SPEC.md 5 and 10, frontend/rewind.zig). Left/Right on a
//! setting row (Palette, Scale, Sound, Debug overlay) cycle that setting as
//! before; on every other row (Resume, where the menu opens, Reset, About)
//! they step time back/forward 0.5 s, repeating 4 times a second while held.
//! The bottom line reads "Scrub: live / 3.5s" or "Scrub: -1.5 / 3.5s"
//! (position behind live / history in the ring); on Resume at the live
//! position it names the action instead, "Left/Right: rewind" or
//! "Rewind: no history", and a footer under it reads "B: back to game"
//! (lib/hint.zig, review 2026-10-01 UX-05). Resuming from a scrubbed
//! position plays on from there and drops the future. After a scrub step the
//! menu collapses to that line in a bar at the bottom so the restored frame
//! is visible; Left/Right keep scrubbing, B or a Select tap resume, and
//! Up/Down/A bring the full menu back. A neopixel history meter (one LED per
//! fifth) is dormant behind -Dneopixels=true (docs/NEOPIXELS.md).
const std = @import("std");
const cart = @import("cart-api");
const core = @import("core");
const build_options = @import("build_options");
const video = @import("video.zig");
const debug = @import("debug.zig");
const input = @import("input.zig");
const rewind = @import("rewind.zig");
const romsrc = @import("romsrc.zig");
const hint = @import("hint");

pub const version = "0.6.0-m6";

/// Sound approximation on/off (SPEC.md 18 item 6). Read by frontend/audio.zig
/// through the integrator; keep the name. Starts as `-Dsound` says (off by
/// default, docs/SOUND.md).
pub var sound_enabled: bool = build_options.sound;

pub const Result = enum { stay, resume_game };

const Item = enum { resume_game, palette, scale, sound, debug, reset, about };
const item_count = @typeInfo(Item).@"enum".field_names.len;

var cursor: Item = .resume_game;
var showing_about: bool = false;
/// After a scrub step the panel would hide the restored frame, so only the
/// scrub bar is drawn (`draw_scrub_bar`) until Up/Down/A.
var scrub_view: bool = false;
/// A Select press began inside the menu; its release resumes. The release
/// of the hold that opened the menu does not count.
var select_armed: bool = false;

/// Scrub auto-repeat (SPEC.md 5: 4 steps per second while held).
const repeat_frames = 15;
/// Direction of the held scrub key, 0 when none.
var repeat_dir: i2 = 0;
var repeat_left: u8 = 0;

/// Neopixel color for one lit fifth of history; every channel at most 10.
const led_on: cart.NeopixelColor = .{ .g = 10, .r = 4, .b = 0 };
const led_off: cart.NeopixelColor = .{ .g = 0, .r = 0, .b = 0 };
comptime {
    if (@max(led_on.r, led_on.g, led_on.b) > 10) @compileError("neopixel channels must stay <= 10");
}

/// Enter the menu. Call in the frame the hold threshold is reached, before
/// drawing anything.
pub fn open() void {
    showing_about = false;
    scrub_view = false;
    select_armed = false;
    repeat_dir = 0;
    cursor = .resume_game;
    if (!cart.is_wasm) {
        const n = cart.screen_width * cart.screen_height / 2;
        const src: *const [n]u32 = @ptrCast(cart.frontbuffer);
        const dst: *[n]u32 = @ptrCast(cart.framebuffer);
        @memcpy(dst, src);
    }
    cart.set_double_buffer_mode(.copy_forward);
}

/// Leave the menu; the caller steps the game in the same frame.
pub fn close() void {
    cart.set_double_buffer_mode(.no_copy_full_frame);
    set_leds(0);
}

/// Time scrubber step (SPEC.md section 10): Left = back 0.5 s, Right =
/// forward. Restores the keyframe into `gb` and redraws the frozen frame.
fn on_scrub(gb: *core.Gb, dir: i2) void {
    if (rewind.step(gb, dir)) scrub_view = true;
}

/// Light the first `lit` of the five neopixels. Compiled out unless built
/// with -Dneopixels=true (docs/NEOPIXELS.md): the badge LEDs are painfully bright.
fn set_leds(lit: u8) void {
    if (!build_options.neopixels) return; // the OS zeroes the strip at cart start
    for (0..cart.neopixels.len) |i| cart.neopixels[i] = if (i < lit) led_on else led_off;
}

fn is_setting(item: Item) bool {
    return switch (item) {
        .palette, .scale, .sound, .debug => true,
        .resume_game, .reset, .about => false,
    };
}

/// Left/Right: cycle a setting on a setting row, else scrub with auto-repeat.
fn left_right(gb: *core.Gb, e: input.Edge) void {
    const d: i2 = if (e.pressed(.left)) -1 else if (e.pressed(.right)) 1 else 0;
    if (d != 0) {
        repeat_dir = 0;
        if (is_setting(cursor)) {
            adjust(d);
        } else {
            on_scrub(gb, d);
            repeat_dir = d;
            repeat_left = repeat_frames;
        }
        return;
    }
    if (repeat_dir == 0) return;
    const still = if (repeat_dir < 0) e.held(.left) else e.held(.right);
    if (!still or is_setting(cursor)) {
        repeat_dir = 0;
        return;
    }
    repeat_left -= 1;
    if (repeat_left == 0) {
        on_scrub(gb, repeat_dir);
        repeat_left = repeat_frames;
    }
}

/// One menu frame: handle input, then draw. Returns `.resume_game` when the
/// game should run again (the caller calls `close`).
pub fn update(gb: *core.Gb, e: input.Edge) Result {
    if (e.pressed(.select)) select_armed = true;
    const select_tap = select_armed and e.released(.select);
    if (select_tap) select_armed = false;

    if (showing_about) {
        if (e.pressed(.a) or e.pressed(.b) or select_tap) showing_about = false;
    } else if (scrub_view) {
        if (e.pressed(.b) or select_tap) return .resume_game;
        // Up/Down/A bring the full menu back without acting.
        if (e.pressed(.up) or e.pressed(.down) or e.pressed(.a)) {
            scrub_view = false;
            repeat_dir = 0;
        } else left_right(gb, e);
    } else {
        if (e.pressed(.b) or select_tap) return .resume_game;
        if (e.pressed(.up)) move(-1);
        if (e.pressed(.down)) move(1);
        left_right(gb, e);
        if (e.pressed(.a)) {
            switch (cursor) {
                .resume_game => return .resume_game,
                .reset => {
                    gb.reset();
                    rewind.reset(gb);
                    return .resume_game;
                },
                .about => showing_about = true,
                else => adjust(1),
            }
        }
    }
    set_leds(rewind.history_fraction());
    draw(gb);
    return .stay;
}

fn move(d: i2) void {
    const i: usize = @backingInt(cursor);
    const n: usize = if (d < 0) (i + item_count - 1) % item_count else (i + 1) % item_count;
    cursor = @fromBackingInt(@intCast(n));
}

/// Left/Right (or A) on a setting cycles it. Other rows: nothing (their
/// Left/Right scrub, see `left_right`).
fn adjust(d: i2) void {
    switch (cursor) {
        .palette => if (video.cgb) video.next_color_mode() else {
            const old = video.palette_index;
            const new = if (d < 0) old + video.palettes.len - 1 else old + 1;
            video.set_palette_index(new);
            video.remap_palette(old, video.palette_index);
            // Recolored in place: the strips beside the panel reach the
            // screen only when marked (.copy_forward).
            cart.mark_dirty_rect(0, 0, cart.screen_width, cart.screen_height);
        },
        .scale => video.set_scale(if (video.scale == .squeeze) .crop else .squeeze),
        .sound => sound_enabled = !sound_enabled,
        .debug => debug.enabled = !debug.enabled,
        .resume_game, .reset, .about => {},
    }
}

// ---- Drawing ----

const band_h = 36;
const panel_x = 4;
/// The panel starts right under the band and runs to the bottom edge (it
/// was y 40, 86 px, until the footer needed the 4 px: review 2026-10-01
/// UX-05), rows 10 px as before.
const panel_y = band_h;
const panel_w = cart.screen_width - 2 * panel_x;
const panel_h = cart.screen_height - panel_y;
const row_h = 10;
const text_x = panel_x + 4;
const first_row_y = panel_y + 3;
/// The panel's bottom line (y 109): the scrub readout, or on Resume the
/// rewind hint (`hint.resume_line`); "B: back" on About.
const scrub_line_y = first_row_y + item_count * row_h;
/// The footer under it (y 119): how to leave the menu (`hint.back`).
const footer_y = scrub_line_y + row_h;

comptime {
    if (footer_y + 8 > panel_y + panel_h - 1) @compileError("menu footer outside the panel");
    if (hint.panel_cols != (panel_w - (text_x - panel_x) - 2) / 8) @compileError("hint.panel_cols does not match this panel");
}

/// ROM title from the cartridge header (0x134..0x143): up to the first
/// non-printable byte, trailing spaces trimmed.
pub fn rom_title(rom: []const u8) []const u8 {
    if (rom.len < 0x144) return "?";
    const raw = rom[0x134..0x144];
    var n: usize = 0;
    while (n < raw.len and raw[n] >= 0x20 and raw[n] < 0x7F) n += 1;
    while (n > 0 and raw[n - 1] == ' ') n -= 1;
    return if (n == 0) "?" else raw[0..n];
}

/// The header bytes of the running ROM (`core.Rom` reads by byte), for
/// `rom_title`. One static buffer; the menu draws one title at a time.
var header_buf: [0x144]u8 = @splat(0);
fn header(rom: *const core.Rom) []const u8 {
    for (header_buf[0x134..0x144], 0x134..) |*b, off| b.* = rom.read(@intCast(off));
    return &header_buf;
}

fn centered(s: []const u8, y: i32, color: cart.DisplayColor) void {
    const w: i32 = @intCast(@as(usize, @min(s.len, 20)) * 8); // @min(usize, 20) is a u5
    cart.text(.{ .str = s, .x = @divTrunc(@as(i32, cart.screen_width) - w, 2), .y = y, .text_color = color });
}

fn draw(gb: *const core.Gb) void {
    const bg = video.shade_color(0);
    const fg = video.shade_color(3);
    const dim = video.shade_color(2);
    var buf: [24]u8 = undefined;

    if (scrub_view) {
        // Only a bar at the bottom: the rest is the restored frame, redrawn
        // in full by every scrub step (frontend/rewind.zig).
        cart.rect(.{ .x = 0, .y = cart.screen_height - 10, .width = cart.screen_width, .height = 10, .fill_color = fg });
        centered(scrub_label(&buf, rewind.depth_frames(), rewind.history_frames()), cart.screen_height - 9, bg);
        return;
    }

    // Title band: SPEC.md 12 and 18 item 9.
    cart.rect(.{ .x = 0, .y = 0, .width = cart.screen_width, .height = band_h, .fill_color = fg });
    centered(if (video.cgb) "SNOUTY BOY COLOR" else "SNOUTY BOY", 1, bg);
    centered(rom_title(header(&gb.rom)), 10, video.shade_color(1));
    centered("verified by", 19, bg);
    centered("deterministic replay", 27, bg);

    cart.rect(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h, .fill_color = bg, .stroke_color = fg });

    if (showing_about) {
        draw_about(gb, fg, dim);
        return;
    }

    for (0..item_count) |i| {
        const item: Item = @fromBackingInt(@intCast(i));
        const y: i32 = first_row_y + @as(i32, @intCast(i)) * row_h;
        const label: []const u8 = switch (item) {
            .resume_game => "Resume",
            .palette => if (video.cgb)
                cat(&buf, "Color: ", video.color_mode_name())
            else
                cat(&buf, "Palette: ", video.palette_name()),
            .scale => if (video.scale == .squeeze) "Scale: Squeeze" else "Scale: Crop",
            .sound => if (sound_enabled) "Sound: On" else "Sound: Off",
            .debug => if (debug.enabled) "Debug overlay: On" else "Debug overlay: Off",
            .reset => "Reset",
            .about => "About",
        };
        var color = fg;
        if (item == cursor) {
            cart.rect(.{ .x = panel_x + 2, .y = y - 1, .width = panel_w - 4, .height = row_h, .fill_color = fg });
            color = bg;
        }
        cart.text(.{ .str = label, .x = text_x, .y = y, .text_color = color });
    }
    const history = rewind.history_frames();
    const depth = rewind.depth_frames();
    if (hint.resume_line(cursor == .resume_game, true, depth, history)) |s| {
        cart.text(.{ .str = s, .x = text_x, .y = scrub_line_y, .text_color = if (history == 0) dim else fg });
    } else {
        cart.text(.{ .str = scrub_label(&buf, depth, history), .x = text_x, .y = scrub_line_y, .text_color = if (history == 0) dim else fg });
    }
    cart.text(.{ .str = hint.back, .x = text_x, .y = footer_y, .text_color = dim });
}

/// Characters that fit inside the panel at the About text indent.
const about_cols = (panel_w - (text_x - panel_x) - 2) / 8;

/// About (SPEC.md 5, PLAN.md M5): version, header title, mapper and size,
/// where the ROM came from and its file name, CRC32 and the model the
/// console runs as (DMG or CGB, SPEC.md 19), and the fragmented-bank count
/// (drive).
fn draw_about(gb: *const core.Gb, fg: cart.DisplayColor, dim: cart.DisplayColor) void {
    const info = &romsrc.info;
    var b0: [24]u8 = undefined;
    var b1: [24]u8 = undefined;
    var b2: [24]u8 = undefined;
    var b3: [24]u8 = undefined;
    var b4: [24]u8 = undefined;

    var w: Line = .{ .buf = &b1 };
    w.put(mbc_name(gb.mbc.kind));
    w.put(", ");
    w.num((info.size + 1023) / 1024);
    w.put(" KB");
    const mbc_size = w.done();

    w = .{ .buf = &b2 };
    w.put("CRC ");
    w.hex32(info.crc);
    w.put(if (gb.is_cgb()) " CGB" else " DMG");
    const crc = w.done();

    w = .{ .buf = &b3 };
    if (info.source == .drive and info.fragmented != 0) {
        w.put("fragmented: ");
        w.num(info.fragmented);
        w.put(if (info.fragmented == 1) " bank" else " banks");
    }
    const last = w.done();

    const lines = [_][]const u8{
        cat(&b0, "Version ", version),
        rom_title(header(&gb.rom)),
        mbc_size,
        if (info.source == .drive) "Source: drive" else "Source: embedded",
        fit(&b4, info.name()),
        crc,
        last,
    };
    var y: i32 = first_row_y;
    for (lines) |l| {
        cart.text(.{ .str = l, .x = text_x, .y = y, .text_color = fg });
        y += row_h;
    }
    cart.text(.{ .str = "B: back", .x = text_x, .y = scrub_line_y, .text_color = dim });
}

/// `s` cut to `about_cols` characters, the last one replaced by '~' when
/// something was cut (drive names can be 64 bytes long).
fn fit(buf: *[24]u8, s: []const u8) []const u8 {
    if (s.len <= about_cols) return s;
    @memcpy(buf[0 .. about_cols - 1], s[0 .. about_cols - 1]);
    buf[about_cols - 1] = '~';
    return buf[0..about_cols];
}

/// Fixed-buffer line builder; output past `about_cols` is dropped.
const Line = struct {
    buf: *[24]u8,
    n: usize = 0,

    fn put(w: *Line, s: []const u8) void {
        const k = @min(s.len, about_cols - @min(w.n, about_cols));
        @memcpy(w.buf[w.n..][0..k], s[0..k]);
        w.n += k;
    }

    fn num(w: *Line, v: u32) void {
        var tmp: [10]u8 = undefined;
        var n: usize = 0;
        var x = v;
        while (true) {
            tmp[9 - n] = '0' + @as(u8, @intCast(x % 10));
            n += 1;
            x /= 10;
            if (x == 0) break;
        }
        w.put(tmp[10 - n ..]);
    }

    fn hex32(w: *Line, v: u32) void {
        const digits = "0123456789ABCDEF";
        var tmp: [8]u8 = undefined;
        for (&tmp, 0..) |*c, i| c.* = digits[@as(u4, @truncate(v >> @intCast(28 - 4 * i)))];
        w.put(&tmp);
    }

    fn done(w: *const Line) []const u8 {
        return w.buf[0..w.n];
    }
};

/// "Scrub: live / 3.5s" or "Scrub: -1.5 / 3.5s": 18 characters at most for
/// up to 9.9 s, which fits the panel (18 x 8 px).
pub fn scrub_label(buf: *[24]u8, depth: u32, history: u32) []const u8 {
    var i: usize = 0;
    i += put(buf[i..], "Scrub: ");
    if (depth == 0) {
        i += put(buf[i..], "live");
    } else {
        i += put(buf[i..], "-");
        i += put_secs(buf[i..], depth);
    }
    i += put(buf[i..], " / ");
    i += put_secs(buf[i..], history);
    i += put(buf[i..], "s");
    return buf[0..i];
}

fn put(dst: []u8, s: []const u8) usize {
    @memcpy(dst[0..s.len], s);
    return s.len;
}

/// Frames at 60 Hz as seconds with one decimal ("3.5"), rounded, capped at
/// 99.9.
fn put_secs(dst: []u8, frames: u32) usize {
    const tenths = @min((frames + 3) / 6, 999);
    var i: usize = 0;
    if (tenths >= 100) {
        dst[i] = '0' + @as(u8, @intCast(tenths / 100));
        i += 1;
    }
    dst[i] = '0' + @as(u8, @intCast(tenths / 10 % 10));
    dst[i + 1] = '.';
    dst[i + 2] = '0' + @as(u8, @intCast(tenths % 10));
    return i + 3;
}

fn cat(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    const n = @min(a.len + b.len, buf.len);
    const na = @min(a.len, n);
    @memcpy(buf[0..na], a[0..na]);
    @memcpy(buf[na..n], b[0 .. n - na]);
    return buf[0..n];
}

fn mbc_name(k: core.mmu.MbcKind) []const u8 {
    return switch (k) {
        .none => "MBC: none",
        .mbc1 => "MBC: MBC1",
        .mbc3 => "MBC: MBC3",
        .mbc5 => "MBC: MBC5",
    };
}

comptime {
    const hdr = "2048-gb    XXXX\x00";
    var rom: [0x150]u8 = @splat(0);
    @memcpy(rom[0x134..0x144], hdr);
    if (!std.mem.eql(u8, rom_title(&rom), "2048-gb    XXXX")) @compileError("rom_title");
    @memcpy(rom[0x134..0x144], "TETRIS\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00");
    if (!std.mem.eql(u8, rom_title(&rom), "TETRIS")) @compileError("rom_title nul");
}

comptime {
    var buf: [24]u8 = undefined;
    if (!std.mem.eql(u8, scrub_label(&buf, 0, 210), "Scrub: live / 3.5s")) @compileError("scrub_label live");
    if (!std.mem.eql(u8, scrub_label(&buf, 90, 239), "Scrub: -1.5 / 4.0s")) @compileError("scrub_label depth");
    if (scrub_label(&buf, 594, 594).len > 18) @compileError("scrub_label too wide");
}
