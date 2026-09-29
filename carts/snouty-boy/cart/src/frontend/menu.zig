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
//! Time scrubber (SPEC.md 5 and 10, frontend/rewind.zig). Left/Right on a
//! setting row (Palette, Scale, Sound, Debug overlay) cycle that setting as
//! before; on every other row (Resume, where the menu opens, Reset, About)
//! they step time back/forward 0.5 s, repeating 4 times a second while held.
//! The bottom line reads "Scrub: live / 3.5s" or "Scrub: -1.5 / 3.5s"
//! (position behind live / history in the ring). Resuming from a scrubbed
//! position plays on from there and drops the future. After a scrub step the
//! menu collapses to that line in a bar at the bottom so the restored frame
//! is visible; Left/Right keep scrubbing, B or a Select tap resume, and
//! Up/Down/A bring the full menu back. While the menu is
//! open the five neopixels show how full the history is, one LED per fifth.
const std = @import("std");
const cart = @import("cart-api");
const core = @import("core");
const video = @import("video.zig");
const debug = @import("debug.zig");
const input = @import("input.zig");
const rewind = @import("rewind.zig");

pub const version = "0.4.0-m4";

/// Sound approximation on/off (SPEC.md 18 item 6). Read by frontend/audio.zig
/// through the integrator; keep the name.
pub var sound_enabled: bool = true;

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

/// Light the first `lit` of the five neopixels.
fn set_leds(lit: u8) void {
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
        .palette => {
            const old = video.palette_index;
            const new = if (d < 0) old + video.palettes.len - 1 else old + 1;
            video.set_palette_index(new);
            video.remap_palette(old, video.palette_index);
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
const panel_y = 40;
const panel_w = cart.screen_width - 2 * panel_x;
const panel_h = 86;
const row_h = 10;
const text_x = panel_x + 4;
const first_row_y = panel_y + 3;

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
    centered("SNOUTY BOY", 1, bg);
    centered(rom_title(header(&gb.rom)), 10, video.shade_color(1));
    centered("verified by", 19, bg);
    centered("deterministic replay", 27, bg);

    cart.rect(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h, .fill_color = bg, .stroke_color = fg });

    if (showing_about) {
        const lines = [_][]const u8{
            cat(&buf, "Version ", version),
            "ROM:",
            rom_title(header(&gb.rom)),
            mbc_name(gb.mbc.kind),
            "Built for",
            "Antithesis",
        };
        var y: i32 = first_row_y;
        for (lines, 0..) |l, i| {
            cart.text(.{ .str = l, .x = if (i == 2) text_x + 16 else text_x, .y = y, .text_color = fg });
            y += row_h;
        }
        cart.text(.{ .str = "B: back", .x = text_x, .y = first_row_y + 7 * row_h, .text_color = dim });
        return;
    }

    for (0..item_count) |i| {
        const item: Item = @fromBackingInt(@intCast(i));
        const y: i32 = first_row_y + @as(i32, @intCast(i)) * row_h;
        const label: []const u8 = switch (item) {
            .resume_game => "Resume",
            .palette => cat(&buf, "Palette: ", video.palette_name()),
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
    cart.text(.{ .str = scrub_label(&buf, rewind.depth_frames(), history), .x = text_x, .y = first_row_y + item_count * row_h, .text_color = if (history == 0) dim else fg });
}

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
