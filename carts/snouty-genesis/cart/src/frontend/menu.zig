//! Emulator menu (SPEC.md sections 5 and 12), adapted from Snouty Gear's
//! frontend/menu.zig: the Genesis rows (Buttons is a six-way remap, Pick
//! ROM for a drive with several files), 8 px rows so nine of them and a footer fit,
//! and the header facts on About. Opened by holding Select for 500 ms
//! (frontend/input.zig), drawn over the frozen game frame. The core is not
//! stepped while it is open. One update is 1/30 s, as everywhere in this
//! cart.
//!
//! Frozen frame. The cart runs in `.no_copy_full_frame` mode: after every
//! present the buffers swap and nothing is copied, so the new back buffer
//! holds the frame from two presents ago, not the frozen one. `open` copies
//! the last presented frame (`cart.frontbuffer`) into the back buffer once
//! (40 KB memcpy, no extra RAM) and switches to `.copy_forward`, in which the
//! OS copies each presented frame into the next back buffer (about 0.1 ms,
//! only while the menu is open). The band and the panel are opaque and
//! redrawn every update, so nothing compounds. `close` switches back before
//! the next game frame is presented. In wasm nothing is ever presented and
//! `framebuffer` never changes, so the frozen frame is simply still there.
//!
//! Keys: Up/Down move (wrapping), A chooses, B or a Select tap (a press that
//! began inside the menu) resumes. Left/Right or A cycle a setting row
//! (Buttons, Scale, Smooth H40, Sound, Debug overlay). A Scale or Smooth
//! H40 change takes effect on the first frame after resuming (app.zig
//! calls `video.apply` whenever the menu closes) or on the next scrub step,
//! which redraws the whole screen.
//!
//! RAM cart (PLAN.md M5): no Sound row (`audio.available`), no scrub line
//! and no scrubbing (`rewind.available`); the rest as in the XIP cart.
//!
//! Time scrubber (SPEC.md 5 and 10, frontend/rewind.zig), Gear's UI. On
//! every row that is not a setting (Resume, where the menu opens, Reset,
//! Pick ROM, About) Left/Right step time back/forward one record (0.5 s),
//! repeating 4 times a second while held; a Left/Right held over from the
//! game does nothing (app.zig suppresses held buttons on open, and the
//! repeat only starts from a press). The panel's bottom line
//! (`scrub_line_y`) reads "Scrub: live / 3.5s" or "Scrub: -1.5 / 3.5s"
//! (position behind live / history held), dim while there is no history,
//! "Scrub: no memory" when the arena had no room; on Resume at the live
//! position it names the action instead, "Left/Right: rewind" or "Rewind:
//! no history", and a footer reads "B: back to game" (lib/hint.zig,
//! review 2026-10-01 UX-05), taking turns every 2 s with "2x Sel+hold:
//! fast" (the fast-forward double tap, frontend/input.zig) and, where the
//! scrubber exists, "then Left: rewind" (the chorded rewind, which shows
//! only this menu's scrub bar: `draw_scrub_bar`). Resuming from a scrubbed position plays on from there and drops the future. After a scrub step
//! the panel gives way to that line in a bar at the bottom (`scrub_view`)
//! so the restored frame, drawn by `rewind.step`, is visible; Left/Right
//! keep scrubbing, B or a Select tap resume, and Up/Down/A bring the full
//! menu back. The bar lies inside the panel's rectangle, so the panel
//! covers it completely when it comes back. Reset and Pick ROM forget the
//! history (`rewind.reset` here, and in app.zig's `begin`).
//!
//! Colours: Gear's fixed scheme, a navy title band with white and yellow
//! text, a black panel with a blue frame, white rows and a yellow cursor
//! bar with black text (high contrast on the 160x128 LCD).
const std = @import("std");
const cart = @import("cart-api");
const core = @import("core");
const video = @import("video");
const debug = @import("debug.zig");
const input = @import("input.zig");
const audio = @import("audio.zig");
const romsrc = @import("romsrc.zig");
const text = @import("text.zig");
const rewind = @import("rewind.zig");
const hint = @import("hint");

pub const version = "0.4.0-m4";

/// What app.zig does after a menu update.
pub const Result = enum {
    stay,
    /// Close, suppress held buttons, apply the scale, run a game update.
    resume_game,
    /// Close, suppress held buttons, `picker.reset()`, enter the picker.
    pick_rom,
    /// Close and show the link screen (docs/LINK_PLAY.md).
    link,
    /// Leave the running link race; the game goes on locally.
    leave_link,
};

/// A link race drives the console (app.zig sets it): Reset and Pick ROM
/// hide, the scrubber is off, the Link row leaves the race.
pub var link_racing: bool = false;

const Item = enum { resume_game, link, buttons, scale, smooth, sound, debug, reset, pick_rom, about };
const item_count = @typeInfo(Item).@"enum".field_names.len;

/// The Pick ROM row exists only for a drive build that found candidates;
/// otherwise it is skipped (not greyed) by `move` and `draw`.
fn pick_available() bool {
    return romsrc.use_drive and romsrc.candidate_count > 0;
}

fn visible(item: Item) bool {
    return switch (item) {
        .pick_rom => pick_available() and !link_racing,
        .reset => !link_racing,
        // The tenth row takes the scrub line's place: the RAM cart has no
        // scrubber; with one (XIP cart, simulator) only while Pick ROM hides.
        .link => !rewind.available or !pick_available() or link_racing,
        // The RAM cart has no sound (no Z80) and no scrubber (PLAN.md M5).
        .sound => audio.available,
        else => true,
    };
}

var cursor: Item = .resume_game;
var showing_about: bool = false;
/// After a scrub step the panel would hide the restored frame, so only the
/// scrub bar is drawn until Up/Down/A.
var scrub_view: bool = false;
/// A Select press began inside the menu; its release resumes. The release
/// of the hold that opened the menu does not count.
var select_armed: bool = false;

/// Scrub auto-repeat (SPEC.md 5: 4 steps per second while held; one update
/// is 1/30 s here), shared with the chorded rewind (`input.Repeat`).
var repeat: input.Repeat = .{};

/// The fast-forward double tap's hint (input.zig `GameInput.fast`): the
/// in-play strip's second line (app.zig), and a footer turn.
pub const fast_hint = "2x Sel+hold: fast";
/// The chorded rewind's hint, the footer turn after `fast_hint` where the
/// scrubber exists (`input.chord_rewind`).
pub const rewind_hint = "then Left: rewind";
/// The footer's turns: how to leave, fast forward, chorded rewind.
const footers = if (input.chord_rewind)
    [_][]const u8{ hint.back, fast_hint, rewind_hint }
else
    [_][]const u8{ hint.back, fast_hint };
/// Menu updates each footer line stays (2 s).
const footer_turn = 60;
/// Menu updates since `open`, for the footer's turns.
var updates_open: u32 = 0;

/// Enter the menu. Called in the update the Select hold threshold is
/// reached, before anything is drawn; the caller then calls `update` once
/// in the same update.
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

/// Leave the menu (or the chorded rewind); the caller steps the game (or
/// draws the picker) in the same update.
pub fn close() void {
    cart.set_double_buffer_mode(.no_copy_full_frame);
}

/// One menu update: handle input, then draw over the frozen game frame.
pub fn update(md: *core.Md, e: input.Edge) Result {
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
        } else left_right(md, e);
    } else {
        if (e.pressed(.b) or select_tap) return .resume_game;
        if (e.pressed(.up)) move(-1);
        if (e.pressed(.down)) move(1);
        left_right(md, e);
        if (e.pressed(.a)) {
            switch (cursor) {
                .resume_game => return .resume_game,
                .reset => {
                    // `Md.reset` writes the memories directly, past the
                    // undo hooks: forget the history. app.zig re-applies
                    // the scale on resume too (Vdp.reset puts line_mode
                    // back to squeeze).
                    md.reset();
                    rewind.reset(md);
                    video.apply(md);
                    return .resume_game;
                },
                .pick_rom => return .pick_rom,
                .link => return if (link_racing) .leave_link else .link,
                .about => showing_about = true,
                else => adjust(1),
            }
        }
    }
    draw(md);
    return .stay;
}

/// Next or previous visible row, wrapping.
fn move(d: i2) void {
    var i: usize = @backingInt(cursor);
    while (true) {
        i = if (d < 0) (i + item_count - 1) % item_count else (i + 1) % item_count;
        const item: Item = @fromBackingInt(@intCast(i));
        if (visible(item)) break;
    }
    cursor = @fromBackingInt(@intCast(i));
}

fn is_setting(item: Item) bool {
    return switch (item) {
        .buttons, .scale, .smooth, .sound, .debug => true,
        .resume_game, .link, .reset, .pick_rom, .about => false,
    };
}

/// Time scrubber step (SPEC.md section 10): Left = back 0.5 s, Right =
/// forward. Swaps the record into `md` and redraws the frozen frame.
fn on_scrub(md: *core.Md, dir: i2) void {
    if (rewind.step(md, dir)) scrub_view = true;
}

/// Left/Right: cycle a setting on a setting row, else scrub with
/// auto-repeat. The repeat starts only from a press in the menu.
fn left_right(md: *core.Md, e: input.Edge) void {
    if (is_setting(cursor)) {
        repeat.stop();
        if (e.pressed(.left)) adjust(-1) else if (e.pressed(.right)) adjust(1);
        return;
    }
    if (!rewind.available or link_racing) return;
    const d = repeat.step(e);
    if (d != 0) on_scrub(md, d);
}

/// Left/Right (or A, forwards) on a setting row cycles it. Other rows
/// scrub (`left_right`).
fn adjust(d: i2) void {
    switch (cursor) {
        .buttons => input.layout = input.layout.step(d),
        .scale => video.scale = if (video.scale == .squeeze) .crop else .squeeze,
        .smooth => video.smooth = !video.smooth,
        .sound => audio.enabled = !audio.enabled,
        .debug => debug.enabled = !debug.enabled,
        .resume_game, .link, .reset, .pick_rom, .about => {},
    }
}

// ---- Drawing ----

const band_h = 36;
const panel_x = 4;
/// M4: the panel starts right under the band and runs to the bottom edge,
/// rows 2 px below its frame, so nine rows and the bottom line fit (M3:
/// y 40, 86 px, rows 3 px in, eight rows). Rows are 8 px apart since the
/// footer (review 2026-10-01 UX-05) took the last 9.
const panel_y = band_h;
const panel_w = cart.screen_width - 2 * panel_x;
const panel_h = cart.screen_height - panel_y;
/// 8 px rows, the font's own line pitch (Gear: 10, M4: 9), so nine rows,
/// the bottom line and the footer fit the panel. The cursor bar is one
/// pixel taller (`bar_rows`), from a pixel above the row's glyphs to its
/// descenders.
const row_h = 8;
const bar_rows = row_h + 1;
const text_x = panel_x + 4;
const first_row_y = panel_y + 2;
/// The panel's bottom line (y 110): "B: back" on About, "Scrub: ..." on
/// the rows, or on Resume the rewind hint (`hint.resume_line`). Fixed
/// below the ninth row even when Pick ROM is hidden.
pub const scrub_line_y = first_row_y + base_rows * row_h;
/// Rows above the scrub line: every row but one (Link and Pick ROM never
/// show together where the line exists, `visible`).
const base_rows = item_count - 1;
/// The footer (y 119): how to leave the menu (`hint.back`), taking turns
/// every 2 s with how to fast forward (`fast_hint`) and to rewind from it
/// (`rewind_hint`, scrubber builds).
const footer_y = scrub_line_y + 9;
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
const title = "SNOUTY GENESIS";
const tagline_1 = "verified by";
const tagline_2 = "deterministic replay";
const back_hint = "B: back";

fn label(item: Item) []const u8 {
    return switch (item) {
        .resume_game => "Resume",
        .link => if (link_racing) "Link: leave" else "Link: 2 players",
        .buttons => input.layout.label(),
        .scale => if (video.scale == .squeeze) "Scale: Squeeze" else "Scale: Crop",
        .smooth => if (video.smooth) "Smooth H40: On" else "Smooth H40: Off",
        .sound => if (audio.enabled) "Sound: On" else "Sound: Off",
        .debug => if (debug.enabled) "Debug overlay: On" else "Debug overlay: Off",
        .reset => "Reset",
        .pick_rom => "Pick ROM",
        .about => "About",
    };
}

fn centered(s: []const u8, y: i32, color: cart.DisplayColor) void {
    // @min against a comptime bound narrows to a u5, so widen before * 8.
    const n: usize = @min(s.len, screen_cols);
    const w: i32 = @intCast(n * 8);
    text.draw(s[0..n], @divTrunc(@as(i32, cart.screen_width) - w, 2), y, color, band_color);
}

fn draw(md: *const core.Md) void {
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
    centered(fit(&buf, romsrc.title_name(), screen_cols), 10, name_color);
    centered(tagline_1, 19, tagline_color);
    centered(tagline_2, 27, tagline_color);

    cart.rect(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h, .fill_color = panel_color, .stroke_color = frame_color });

    if (showing_about) {
        draw_about(md);
        return;
    }

    var y: i32 = first_row_y;
    for (0..item_count) |i| {
        const item: Item = @fromBackingInt(@intCast(i));
        if (!visible(item)) continue;
        if (item == cursor) {
            cart.rect(.{ .x = panel_x + 2, .y = y - 1, .width = panel_w - 4, .height = bar_rows, .fill_color = cursor_color });
            text.draw(label(item), text_x, y, cursor_text_color, cursor_color);
        } else {
            text.draw(label(item), text_x, y, row_color, panel_color);
        }
        y += row_h;
    }
    if (rewind.available and !link_racing) draw_scrub_line(&buf);
    const footer = footers[(updates_open -% 1) / footer_turn % footers.len];
    text.draw(footer, text_x, footer_y, dim_color, panel_color);
}

/// The scrub bar (the panel's bottom strip): the menu after a scrub step,
/// and the whole display of the chorded rewind (app.zig), which passes
/// `chord` so an empty history reads `hint.rewind_empty` rather than
/// "Scrub: live / 0.0s". It lies inside the panel's rectangle and covers
/// the fast-forward indicator (app.zig `draw_fast`), so a rewind entered
/// from fast forward never shows a stale `>>4x` on the frozen frame.
pub fn draw_scrub_bar(chord: bool) void {
    var buf: [24]u8 = undefined;
    const empty = chord and rewind.capacity_slots() != 0 and rewind.history_frames() == 0;
    cart.rect(.{ .x = panel_x, .y = bar_y, .width = panel_w, .height = bar_h, .fill_color = band_color, .stroke_color = frame_color });
    centered(if (empty) hint.rewind_empty else scrub_text(&buf), bar_y + 1, title_color);
}

/// The scrub bar's rectangle (app.zig keeps its `>>4x` inside it).
pub const bar_x = panel_x;
pub const bar_w = panel_w;
pub const bar_top = bar_y;
pub const bar_height = bar_h;

/// The panel's bottom line (scrubber builds only): the scrub position, or
/// on Resume at live the rewind hint.
fn draw_scrub_line(buf: *[24]u8) void {
    const has_memory = rewind.capacity_slots() != 0;
    const live = has_memory and rewind.history_frames() != 0;
    const bottom = hint.resume_line(cursor == .resume_game, has_memory, rewind.depth_frames(), rewind.history_frames()) orelse scrub_text(buf);
    text.draw(bottom, text_x, scrub_line_y, if (live) row_color else dim_color, panel_color);
}

/// The scrub line for the current position, or "Scrub: no memory" when
/// the scrubber found no room (frontend/rewind.zig `init`).
fn scrub_text(buf: *[24]u8) []const u8 {
    if (rewind.capacity_slots() == 0) return no_memory;
    return scrub_label(buf, rewind.depth_frames(), rewind.history_frames());
}

const no_memory = "Scrub: no memory";

/// "Scrub: live / 3.5s" or "Scrub: -1.5 / 3.5s"; from 10 s on whole
/// seconds ("Scrub: -12 / 32s"), so it stays within 18 characters (the
/// panel's width) for any history. Gear's.
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

/// About (PLAN.md M2 Track A): version, file name, header name, size,
/// source, region letters and SRAM as the header declares them, then the
/// drive's CRC32 and "fragmented" (no direct flash pointer).
fn draw_about(md: *const core.Md) void {
    var b0: [24]u8 = undefined;
    var b1: [24]u8 = undefined;
    var b2: [24]u8 = undefined;
    var b3: [24]u8 = undefined;
    var b5: [24]u8 = undefined;
    var b6: [24]u8 = undefined;

    var w: Line = .{ .buf = &b0 };
    w.put("Version ");
    w.put(version);
    const ver = w.done();

    w = .{ .buf = &b1 };
    w.num((md.rom.size + 1023) / 1024);
    w.put(" KB");
    const size = w.done();

    const h = core.rom.parse_header(&md.rom);
    w = .{ .buf = &b2 };
    w.put("Region ");
    const region = core.rom.trim(&h.region);
    for (region) |c| w.put(&.{if (c > 32 and c < 127) c else '?'});
    if (region.len == 0) w.put("-");
    if (h.has_sram) w.put(" SRAM");
    const reg = w.done();

    const drive = romsrc.origin == .drive_contiguous or romsrc.origin == .drive_fragmented;
    var line7: []const u8 = "";
    var line8: []const u8 = "";
    if (drive) {
        w = .{ .buf = &b3 };
        w.put("CRC ");
        if (romsrc.crc_known) w.hex32(romsrc.crc) else w.put("....");
        line7 = w.done();
        if (romsrc.origin == .drive_fragmented) line8 = "fragmented";
    }

    const lines = [_][]const u8{
        ver,
        fit(&b5, romsrc.file_name(), panel_cols),
        fit(&b6, romsrc.title_name(), panel_cols),
        size,
        if (drive) "Source: drive" else "Source: embedded",
        reg,
        line7,
        line8,
    };
    var y: i32 = first_row_y;
    for (lines) |l| {
        text.draw(l, text_x, y, row_color, panel_color);
        y += row_h;
    }
    text.draw(back_hint, text_x, scrub_line_y, dim_color, panel_color);
}

/// `s` cut to `cols` characters, the last one replaced by '~' when
/// something was cut (header names are 48 bytes, drive names 64).
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

    fn hex32(w: *Line, v: u32) void {
        const digits = "0123456789ABCDEF";
        var tmp: [8]u8 = undefined;
        for (&tmp, 0..) |*c, i| c.* = digits[@as(u4, @truncate(v >> @intCast(4 * (7 - i))))];
        w.put(&tmp);
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
    if (panel_y + panel_h > cart.screen_height) @compileError("panel below the screen");
    if (band_h > panel_y) @compileError("band overlaps the panel");
    check_width(title, screen_cols);
    check_width(tagline_1, screen_cols);
    check_width(tagline_2, screen_cols);
    check_width("Btns B=B A=C S=A", panel_cols);
    check_width("Scale: Squeeze", panel_cols);
    check_width("Smooth H40: Off", panel_cols);
    check_width("Debug overlay: Off", panel_cols);
    check_width("Link: 2 players", panel_cols);
    check_width("Version " ++ version, panel_cols);
    check_width("Source: embedded", panel_cols);
    check_width("Region JUE SRAM", panel_cols);
    check_width("CRC 00000000", panel_cols);
    check_width("4096 KB", panel_cols);
    check_width(back_hint, panel_cols);
    check_width(fast_hint, panel_cols);
    check_width(rewind_hint, panel_cols);
    check_width(no_memory, panel_cols);
    check_width("Scrub: -9.9 / 9.9s", panel_cols);
    check_width("Scrub: live / 9.9s", panel_cols);
    check_width("Scrub: -99 / 99s", panel_cols);
    // The last row's cursor bar ends at scrub_line_y - 1.
    if (bar_y + 1 < scrub_line_y) @compileError("scrub bar overlaps the rows");
    if (first_row_y - 1 <= panel_y) @compileError("first cursor bar on the panel frame");
    if (bar_y + bar_h > panel_y + panel_h) @compileError("scrub bar outside the panel");
}

comptime {
    var buf: [24]u8 = undefined;
    if (!std.mem.eql(u8, fit(&buf, "snouty-test.bin", 18), "snouty-test.bin")) @compileError("fit short");
    if (!std.mem.eql(u8, fit(&buf, "Sonic the Hedgehog (World).md", 18), "Sonic the Hedgeho~")) @compileError("fit long");
    if (!std.mem.eql(u8, scrub_label(&buf, 0, 210), "Scrub: live / 3.5s")) @compileError("scrub_label live");
    if (!std.mem.eql(u8, scrub_label(&buf, 90, 239), "Scrub: -1.5 / 4.0s")) @compileError("scrub_label depth");
    if (!std.mem.eql(u8, scrub_label(&buf, 600, 1890), "Scrub: -10 / 31s")) @compileError("scrub_label long");
    if (scrub_label(&buf, 594, 594).len > panel_cols) @compileError("scrub_label too wide");
}
