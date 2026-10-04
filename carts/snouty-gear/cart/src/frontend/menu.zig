//! Emulator menu (SPEC.md sections 5 and 12), adapted from Snouty Boy's
//! frontend/menu.zig minus the palette row, the picker and CGB. Opened by holding Select for 500 ms
//! (frontend/input.zig), drawn with cart.text/cart.rect over the frozen game
//! frame. The core is not stepped while it is open.
//!
//! Frozen frame. The cart runs in `.no_copy_full_frame` mode: after every
//! present the buffers swap and nothing is copied, so the new back buffer
//! holds the frame from two presents ago, not the frozen one. `open` copies
//! the last presented frame (`cart.frontbuffer`) into the back buffer once
//! (40 KB memcpy, no extra RAM) and switches to `.copy_forward`, in which the
//! OS copies each presented frame into the next back buffer (about 0.1 ms,
//! only while the menu is open). The band and the panel are opaque and
//! redrawn every frame, so nothing compounds. `close` switches back before
//! the next game frame is presented. In wasm nothing is ever presented and
//! `framebuffer` never changes, so the frozen frame is simply still there.
//!
//! Keys: Up/Down move (wrapping), A chooses, B or a Select tap (a press that
//! began inside the menu) resumes. Left/Right or A cycle a setting row
//! (Buttons, Scale, Sound, Debug overlay). A scale change takes effect on
//! the first frame after resuming (or the next scrub step), which redraws
//! the whole screen.
//!
//! Time scrubber (SPEC.md 5 and 10, frontend/rewind.zig). On every row that
//! is not a setting (Resume, where the menu opens, Reset, About) Left/Right
//! step time back/forward 0.5 s, repeating 4 times a second while held. The
//! panel's bottom line (`scrub_line_y`) reads "Scrub: live / 3.5s" or
//! "Scrub: -1.5 / 3.5s" (position behind live / history held), dim while
//! there is no history, "Scrub: no memory" when the arena had no room.
//! On Resume at the live position it names the action instead,
//! "Left/Right: rewind" or "Rewind: no history", and a footer under it
//! reads "B: back to game" (lib/hint.zig, review 2026-10-01 UX-05),
//! taking turns every 2 s with "2x Sel+hold: fast" (fast forward, main.zig)
//! and "then Left: rewind" (the chorded rewind, which shows only this
//! menu's scrub bar: `draw_scrub_bar`).
//! Resuming from a scrubbed position plays on from there and drops the
//! future. After a scrub step the panel gives way to that line in a bar at
//! the bottom (`scrub_view`) so the restored frame, drawn by `rewind.step`,
//! is visible; Left/Right keep scrubbing, B or a Select tap resume, and
//! Up/Down/A bring the full menu back. The bar lies inside the panel's
//! rectangle, so the panel covers it completely when it comes back.
//!
//! The Game Gear has no palette to borrow, so the menu uses the fixed
//! scheme below: a navy title band with white and yellow text, a black
//! panel with a blue frame, white rows and a yellow cursor bar with black
//! text (high contrast on the 160x128 LCD).
const std = @import("std");
const cart = @import("cart-api");
const core = @import("core");
const build_options = @import("build_options");
const video = @import("video.zig");
const debug = @import("debug.zig");
const input = @import("input.zig");
const romsrc = @import("romsrc.zig");
const rewind = @import("rewind.zig");
const hint = @import("hint");

pub const version = "0.3.0-m3";

/// Sound approximation on/off (SPEC.md section 9): main.zig copies it into
/// `audio.enabled` every frame. Keep the name. Starts as `-Dsound` says
/// (off by default, docs/SOUND.md).
pub var sound_enabled: bool = build_options.sound;

pub const Result = enum { stay, resume_game };

const Item = enum { resume_game, buttons, scale, sound, debug, reset, about };
const item_count = @typeInfo(Item).@"enum".field_names.len;

var cursor: Item = .resume_game;
var showing_about: bool = false;
/// After a scrub step the panel would hide the restored frame, so only the
/// scrub bar is drawn until Up/Down/A.
var scrub_view: bool = false;
/// A Select press began inside the menu; its release resumes. The release
/// of the hold that opened the menu does not count.
var select_armed: bool = false;

/// Scrub auto-repeat (SPEC.md 5: 4 steps per second while held), shared
/// with the chorded rewind.
var repeat: input.Repeat = .{};

/// The fast-forward double tap's hint (input.zig `GameInput.fast`): the
/// in-play strip's second line, and a footer turn.
pub const fast_hint = "2x Sel+hold: fast";
/// The chorded rewind's hint, the footer turn after `fast_hint`.
pub const rewind_hint = "then Left: rewind";
/// The footer's turns: how to leave, fast forward, chorded rewind.
const footers = [_][]const u8{ hint.back, fast_hint, rewind_hint };
/// Menu updates each footer line stays (2 s).
const footer_turn = 120;
/// Menu updates since `open`, for the footer's turns.
var updates_open: u32 = 0;

/// Enter the menu. Called in the frame the Select hold threshold is
/// reached, before anything is drawn; the caller then calls `update` once
/// in the same frame.
pub fn open() void {
    showing_about = false;
    scrub_view = false;
    select_armed = false;
    repeat.stop();
    cursor = .resume_game;
    updates_open = 0;
    freeze_frame();
}

/// Keep the last presented frame on screen while the game is paused (the
/// menu, the chorded rewind): copy it into the back buffer and switch to
/// `.copy_forward` (see the file comment). `close` switches back.
pub fn freeze_frame() void {
    if (!cart.is_wasm) {
        const n = cart.screen_width * cart.screen_height / 2;
        const src: *const [n]u32 = @ptrCast(cart.frontbuffer);
        const dst: *[n]u32 = @ptrCast(cart.framebuffer);
        @memcpy(dst, src);
    }
    cart.set_double_buffer_mode(.copy_forward);
}

/// Leave the menu (or the chorded rewind); the caller steps the game in
/// the same frame.
pub fn close() void {
    cart.set_double_buffer_mode(.no_copy_full_frame);
}

/// One menu frame: handle input, then draw over the frozen game frame.
/// Returns `.resume_game` when the game should run again (the caller calls
/// `close`, suppresses held buttons and runs a game frame).
pub fn update(gg: *core.Gg, e: input.Edge) Result {
    updates_open +%= 1;
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
            repeat.stop();
        } else left_right(gg, e);
    } else {
        if (e.pressed(.b) or select_tap) return .resume_game;
        if (e.pressed(.up)) move(-1);
        if (e.pressed(.down)) move(1);
        left_right(gg, e);
        if (e.pressed(.a)) {
            switch (cursor) {
                .resume_game => return .resume_game,
                .reset => {
                    gg.reset();
                    rewind.reset(gg);
                    return .resume_game;
                },
                .about => showing_about = true,
                else => adjust(),
            }
        }
    }
    draw(gg);
    return .stay;
}

fn move(d: i2) void {
    const i: usize = @backingInt(cursor);
    const n: usize = if (d < 0) (i + item_count - 1) % item_count else (i + 1) % item_count;
    cursor = @fromBackingInt(@intCast(n));
}

fn is_setting(item: Item) bool {
    return switch (item) {
        .buttons, .scale, .sound, .debug => true,
        .resume_game, .reset, .about => false,
    };
}

/// Time scrubber step (SPEC.md section 10): Left = back 0.5 s, Right =
/// forward. Restores the keyframe into `gg` and redraws the frozen frame.
fn on_scrub(gg: *core.Gg, dir: i2) void {
    if (rewind.step(gg, dir)) scrub_view = true;
}

/// Left/Right: flip a setting on a setting row, else scrub with auto-repeat.
fn left_right(gg: *core.Gg, e: input.Edge) void {
    if (is_setting(cursor)) {
        repeat.stop();
        if (e.pressed(.left) or e.pressed(.right)) adjust();
        return;
    }
    const d = repeat.step(e);
    if (d != 0) on_scrub(gg, d);
}

/// Left/Right (or A) on a setting row flips it: every setting has two
/// values, so both directions do the same. Other rows scrub (`left_right`).
fn adjust() void {
    switch (cursor) {
        .buttons => input.swap_ab = !input.swap_ab,
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
/// The panel's bottom line (y 109): "Scrub: ...", or on Resume the
/// rewind hint (`hint.resume_line`); "B: back" on About.
pub const scrub_line_y = first_row_y + item_count * row_h;
/// The footer under it (y 119): how to leave the menu (`hint.back`).
const footer_y = scrub_line_y + row_h;
/// The scrub bar shown after a step (`scrub_view`): the panel's bottom
/// strip, so the panel hides it entirely when it comes back.
const bar_h = 10;
const bar_y = panel_y + panel_h - bar_h;

/// Characters of the 8 px font across the screen (title band).
const screen_cols = cart.screen_width / 8;
/// Characters that fit inside the panel at the row text indent.
const panel_cols = (panel_w - (text_x - panel_x) - 2) / 8;

pub const band_color: cart.DisplayColor = .rgb(0x0A1A50);
pub const title_color: cart.DisplayColor = .rgb(0xFFFFFF);
const name_color: cart.DisplayColor = .rgb(0xFFD040);
const tagline_color: cart.DisplayColor = .rgb(0xB8C8F0);
const panel_color: cart.DisplayColor = .rgb(0x000000);
const frame_color: cart.DisplayColor = .rgb(0x3060E0);
const row_color: cart.DisplayColor = .rgb(0xFFFFFF);
const cursor_color: cart.DisplayColor = .rgb(0xFFD040);
const cursor_text_color: cart.DisplayColor = .rgb(0x000000);
const dim_color: cart.DisplayColor = .rgb(0x8898C0);

// Fixed strings, width-checked below.
const title = "SNOUTY GEAR";
const tagline_1 = "verified by";
const tagline_2 = "deterministic replay";
const back_hint = "B: back";

fn label(item: Item) []const u8 {
    return switch (item) {
        .resume_game => "Resume",
        .buttons => if (input.swap_ab) "Buttons: A=1 B=2" else "Buttons: B=1 A=2",
        .scale => if (video.scale == .squeeze) "Scale: Squeeze" else "Scale: Crop",
        .sound => if (sound_enabled) "Sound: On" else "Sound: Off",
        .debug => if (debug.enabled) "Debug overlay: On" else "Debug overlay: Off",
        .reset => "Reset",
        .about => "About",
    };
}

fn centered(s: []const u8, y: i32, color: cart.DisplayColor) void {
    // @min against a comptime bound narrows to a u5, so widen before * 8.
    const n: usize = @min(s.len, screen_cols);
    const w: i32 = @intCast(n * 8);
    cart.text(.{ .str = s, .x = @divTrunc(@as(i32, cart.screen_width) - w, 2), .y = y, .text_color = color });
}

fn draw(gg: *const core.Gg) void {
    var buf: [24]u8 = undefined;

    if (scrub_view) {
        // Only the bar: the rest is the restored frame, redrawn in full by
        // every scrub step (frontend/rewind.zig).
        draw_scrub_bar(false);
        return;
    }

    // Title band: SPEC.md 12.
    cart.rect(.{ .x = 0, .y = 0, .width = cart.screen_width, .height = band_h, .fill_color = band_color });
    centered(title, 1, title_color);
    centered(fit(&buf, romsrc.name(), screen_cols), 10, name_color);
    centered(tagline_1, 19, tagline_color);
    centered(tagline_2, 27, tagline_color);

    cart.rect(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h, .fill_color = panel_color, .stroke_color = frame_color });

    if (showing_about) {
        draw_about(gg);
        return;
    }

    for (0..item_count) |i| {
        const item: Item = @fromBackingInt(@intCast(i));
        const y: i32 = first_row_y + @as(i32, @intCast(i)) * row_h;
        var color = row_color;
        if (item == cursor) {
            cart.rect(.{ .x = panel_x + 2, .y = y - 1, .width = panel_w - 4, .height = row_h, .fill_color = cursor_color });
            color = cursor_text_color;
        }
        cart.text(.{ .str = label(item), .x = text_x, .y = y, .text_color = color });
    }
    const has_memory = rewind.keyframe_capacity() != 0;
    const live = has_memory and rewind.history_frames() != 0;
    const bottom = hint.resume_line(cursor == .resume_game, has_memory, rewind.depth_frames(), rewind.history_frames()) orelse scrub_text(&buf);
    cart.text(.{ .str = bottom, .x = text_x, .y = scrub_line_y, .text_color = if (live) row_color else dim_color });
    const footer = footers[(updates_open -% 1) / footer_turn % footers.len];
    cart.text(.{ .str = footer, .x = text_x, .y = footer_y, .text_color = dim_color });
}

/// The scrub bar (the panel's bottom strip): the menu after a scrub step,
/// and the whole display of the chorded rewind (main.zig), which passes
/// `chord` so an empty history reads `hint.rewind_empty` rather than
/// "Scrub: live / 0.0s". Lies inside the panel's rectangle and inside
/// the strip `main.draw_fast` uses, so it covers both.
pub fn draw_scrub_bar(chord: bool) void {
    var buf: [24]u8 = undefined;
    const empty = chord and rewind.keyframe_capacity() != 0 and rewind.history_frames() == 0;
    cart.rect(.{ .x = panel_x, .y = bar_y, .width = panel_w, .height = bar_h, .fill_color = band_color, .stroke_color = frame_color });
    centered(if (empty) hint.rewind_empty else scrub_text(&buf), bar_y + 1, title_color);
}

/// The scrub bar's rectangle (main.zig keeps its `>>4x` inside it).
pub const bar_x = panel_x;
pub const bar_w = panel_w;
pub const bar_top = bar_y;
pub const bar_height = bar_h;

/// The scrub line for the current position, or "Scrub: no memory" when
/// the scrubber found no room (frontend/rewind.zig `init`).
fn scrub_text(buf: *[24]u8) []const u8 {
    if (rewind.keyframe_capacity() == 0) return no_memory;
    return scrub_label(buf, rewind.depth_frames(), rewind.history_frames());
}

const no_memory = "Scrub: no memory";

/// "Scrub: live / 3.5s" or "Scrub: -1.5 / 3.5s"; from 10 s on whole
/// seconds ("Scrub: -12 / 32s"), so it stays within 18 characters (the
/// panel's width) for any history.
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

/// Frames at 60 Hz as seconds: "3.5" (rounded to tenths) below 10 s, else
/// whole seconds "32" (capped at 99).
fn put_secs(dst: []u8, frames: u32) usize {
    const tenths = (frames + 3) / 6;
    if (tenths < 100) {
        dst[0] = '0' + @as(u8, @intCast(tenths / 10));
        dst[1] = '.';
        dst[2] = '0' + @as(u8, @intCast(tenths % 10));
        return 3;
    }
    const secs = @min(tenths / 10, 99);
    dst[0] = '0' + @as(u8, @intCast(secs / 10));
    dst[1] = '0' + @as(u8, @intCast(secs % 10));
    return 2;
}

/// About (PLAN.md M2 Track A): version, ROM file name, size and bank
/// count, source, mapper slots as written, and then the drive's CRC32 and
/// "fragmented" (a bank without a direct flash pointer). The menu only
/// opens on a running ROM, so a drive build here always has a drive ROM.
fn draw_about(gg: *const core.Gg) void {
    var b0: [24]u8 = undefined;
    var b1: [24]u8 = undefined;
    var b2: [24]u8 = undefined;
    var b3: [24]u8 = undefined;
    var b4: [24]u8 = undefined;

    var w: Line = .{ .buf = &b0 };
    w.put("Version ");
    w.put(version);
    const ver = w.done();

    w = .{ .buf = &b1 };
    w.num((romsrc.size + 1023) / 1024);
    w.put(" KB, ");
    w.num(gg.rom.bank_count);
    w.put(if (gg.rom.bank_count == 1) " bank" else " banks");
    const size = w.done();

    const m = gg.mapper;
    w = .{ .buf = &b2 };
    w.put("Map ");
    w.hex8(m.slot[0]);
    w.put(" ");
    w.hex8(m.slot[1]);
    w.put(" ");
    w.hex8(m.slot[2]);
    w.put(" FC=");
    w.hex8(m.control);
    const map = w.done();

    var line6: []const u8 = "";
    var line7: []const u8 = "";
    if (romsrc.origin == .drive) {
        w = .{ .buf = &b3 };
        w.put("CRC ");
        w.hex32(romsrc.crc);
        line6 = w.done();
        if (!gg.rom.all_direct()) line7 = "fragmented";
    }

    const lines = [_][]const u8{
        ver,
        fit(&b4, romsrc.name(), panel_cols),
        size,
        if (romsrc.origin == .drive) "Source: drive" else "Source: embedded",
        map,
        line6,
        line7,
    };
    var y: i32 = first_row_y;
    for (lines) |l| {
        cart.text(.{ .str = l, .x = text_x, .y = y, .text_color = row_color });
        y += row_h;
    }
    cart.text(.{ .str = back_hint, .x = text_x, .y = scrub_line_y, .text_color = dim_color });
}

/// `s` cut to `cols` characters, the last one replaced by '~' when
/// something was cut (drive names can be 64 bytes long).
fn fit(buf: *[24]u8, s: []const u8, cols: usize) []const u8 {
    if (s.len <= cols) return s;
    @memcpy(buf[0 .. cols - 1], s[0 .. cols - 1]);
    buf[cols - 1] = '~';
    return buf[0..cols];
}

/// Fixed-buffer line builder; output past `panel_cols` is dropped.
const Line = struct {
    buf: *[24]u8,
    n: usize = 0,

    fn put(w: *Line, s: []const u8) void {
        const k = @min(s.len, panel_cols - @min(w.n, panel_cols));
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

    fn hex(w: *Line, v: u32, comptime digits_n: u5) void {
        const digits = "0123456789ABCDEF";
        var tmp: [digits_n]u8 = undefined;
        for (&tmp, 0..) |*c, i| c.* = digits[@as(u4, @truncate(v >> @intCast(4 * (digits_n - 1 - i))))];
        w.put(&tmp);
    }

    fn hex8(w: *Line, v: u8) void {
        w.hex(v, 2);
    }

    fn hex32(w: *Line, v: u32) void {
        w.hex(v, 8);
    }

    fn done(w: *const Line) []const u8 {
        return w.buf[0..w.n];
    }
};

// Width checks for the fixed strings (straight-line, no comptime loops:
// CLAUDE.md). Rows and About lines must fit the panel, band lines the
// screen; the longest variable lines are checked at their widest.
fn check_width(comptime s: []const u8, comptime cols: usize) void {
    if (s.len > cols) @compileError("too wide for the menu: \"" ++ s ++ "\"");
}

comptime {
    if (panel_cols != 18) @compileError("panel_cols changed: recheck the layout");
    if (scrub_line_y + row_h > panel_y + panel_h) @compileError("scrub line outside the panel");
    if (footer_y + 8 > panel_y + panel_h - 1) @compileError("menu footer outside the panel");
    if (hint.panel_cols != panel_cols) @compileError("hint.panel_cols does not match this panel");
    check_width(title, screen_cols);
    check_width(tagline_1, screen_cols);
    check_width(tagline_2, screen_cols);
    check_width("Buttons: B=1 A=2", panel_cols);
    check_width("Buttons: A=1 B=2", panel_cols);
    check_width("Scale: Squeeze", panel_cols);
    check_width("Debug overlay: Off", panel_cols);
    check_width("Version " ++ version, panel_cols);
    check_width("Source: embedded", panel_cols);
    check_width("Drive not used:", panel_cols);
    check_width("Map 00 01 02 FC=00", panel_cols);
    check_width("CRC 00000000", panel_cols);
    check_width("1024 KB, 64 banks", panel_cols);
    check_width(back_hint, panel_cols);
    check_width(fast_hint, panel_cols);
    check_width(rewind_hint, panel_cols);
    check_width(no_memory, panel_cols);
    check_width("Scrub: -9.9 / 9.9s", panel_cols);
    check_width("Scrub: live / 9.9s", panel_cols);
    check_width("Scrub: -99 / 99s", panel_cols);
    if (bar_y < scrub_line_y) @compileError("scrub bar overlaps the rows");
}

comptime {
    var buf: [24]u8 = undefined;
    if (!std.mem.eql(u8, fit(&buf, "waternet.gg", 18), "waternet.gg")) @compileError("fit short");
    if (!std.mem.eql(u8, fit(&buf, "Sonic the Hedgehog (World).gg", 18), "Sonic the Hedgeho~")) @compileError("fit long");
    if (!std.mem.eql(u8, scrub_label(&buf, 0, 210), "Scrub: live / 3.5s")) @compileError("scrub_label live");
    if (!std.mem.eql(u8, scrub_label(&buf, 90, 239), "Scrub: -1.5 / 4.0s")) @compileError("scrub_label depth");
    if (!std.mem.eql(u8, scrub_label(&buf, 600, 1890), "Scrub: -10 / 31s")) @compileError("scrub_label long");
    if (scrub_label(&buf, 594, 594).len > panel_cols) @compileError("scrub_label too wide");
}
