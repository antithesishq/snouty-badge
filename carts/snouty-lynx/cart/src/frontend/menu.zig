//! Emulator menu (SPEC.md sections 5 and 12, PLAN.md "M2 Frontend"),
//! copied from Snouty Genesis's frontend/menu.zig (itself Snouty Gear's)
//! with the Lynx rows: Resume, Buttons (A/B swap), Sound (M5; not in the
//! wasm build), Press Option 2, Restart (Pause + Option 1), Debug overlay,
//! Reset, Pick ROM (a drive with several playable files), Link cable (the
//! LINK screen, frontend/cable_screen.zig; "Leave link" while linked; not
//! in the wasm build) and About; 8 px rows as Genesis M4 (nine rows, the
//! bottom line and the footer: when Sound, Pick ROM and Link cable all
//! show, the Debug overlay row gives way). Gear's
//! M5 shared frontend has not landed: this is a copy, to be extracted with
//! the others. Opened by holding Select for 500 ms (frontend/input.zig),
//! drawn over the frozen game frame; the core is not stepped while it is
//! open. One update is 1/60 s here.
//!
//! Frozen frame. The cart runs in `.no_copy_full_frame` mode: after every
//! present the buffers swap and nothing is copied, so the new back buffer
//! holds the frame from two presents ago, not the frozen one. `open` copies
//! the last presented frame (`cart.frontbuffer`) into the back buffer once
//! (40 KB memcpy, no extra RAM) and switches to `.copy_forward`, in which
//! the OS copies each presented frame into the next back buffer (only while
//! the menu is open). The band and the panel are opaque and redrawn every
//! update, so nothing compounds. `close` switches back before the next game
//! frame is presented. In wasm nothing is ever presented and `framebuffer`
//! never changes, so the frozen frame is simply still there.
//!
//! Keys: Up/Down move (wrapping), A chooses, B or a Select tap (a press that
//! began inside the menu) resumes. Left/Right or A cycle a setting row
//! (Buttons, Sound, Debug overlay). Sound (frontend/audio.zig; off at
//! boot, `-Dsound=true` starts it on) Off stops the stream (a ramp to
//! silence) and clears `l.audio_render` so the core skips filling
//! `audio_out`.
//!
//! Time scrubber (SPEC.md 5 and 10, frontend/rewind.zig), Genesis's UI. On
//! every row that is not a setting (Resume, where the menu opens, Press
//! Option 2, Restart, Reset, Pick ROM, About) Left/Right step time
//! back/forward one record (`undo.frames_per_record` frames: 60, 1 s), repeating 4 times a second
//! while held; a Left/Right held over from the game does nothing (main.zig
//! suppresses held buttons on open, and the repeat only starts from a
//! press). The panel's bottom line (`scrub_line_y`) reads "Scrub: live /
//! 3.5s" or "Scrub: -1.5 / 3.5s" (position behind live / history held),
//! dim while there is no history, "Scrub: no memory" when the arena had no
//! room; on Resume at the live position it names the action instead,
//! "Left/Right: rewind" or "Rewind: no history", and a footer in the free
//! line under it takes turns every 2 s between "B: back to game"
//! (lib/hint.zig, review 2026-10-01 UX-05), `fast_hint`, the fast-forward
//! double tap, and `rewind_hint`, the chorded rewind (Left during that
//! hold, docs/FAST_FORWARD.md at the root), which shows only this menu's
//! scrub bar (`draw_scrub_bar`) over the frozen frame (`freeze_frame`). Resuming
//! from a scrubbed position plays on from there and drops the future
//! (main.zig, `rewind.resume_if_parked`). After a scrub step the panel
//! gives way to that line in a bar in the marquee band above the picture
//! (`scrub_view`) so the restored frame, drawn by `rewind.step`, shows
//! whole; Left/Right keep scrubbing, B or a Select tap resume, and
//! Up/Down/A bring the full menu back. The bar lies inside the title
//! band's rectangle, so the band covers it completely when it comes back.
//! Reset and Pick ROM forget the history: both boot through main.zig's
//! `boot` (`rewind.reset` after the boot, then `marquee.load`).
//!
//! The Lynx's Option 2 and its restart chord have no badge button (SPEC.md
//! 5, 18.4): their rows resume the game with `hold_pad` held for
//! `hold_frames_left` frames (main.zig ORs it into the pad).
//!
//! Colours: Gear's fixed scheme, a navy title band with white and yellow
//! text, a black panel with a blue frame, white rows and a yellow cursor
//! bar with black text (high contrast on the 160x128 LCD).
const std = @import("std");
const cart = @import("cart-api");
const core = @import("core");
const debug = @import("debug.zig");
const input = @import("input.zig");
const romsrc = @import("romsrc.zig");
const text = @import("text.zig");
const rewind = @import("rewind.zig");
const cable = @import("cable.zig");
const audio = @import("audio.zig");
const video = @import("video.zig");
const marquee = @import("marquee.zig");
const hint = @import("hint");

pub const version = "0.7.0-m7";

/// The title the menu band and the debug overlay show.
pub const title = "SNOUTY LYNX";

/// What main.zig does after a menu update.
pub const Result = enum {
    stay,
    /// Close, suppress held buttons, run a game frame (with `hold_pad`).
    resume_game,
    /// Reset: boot the same cart again (main.zig `boot`, which every boot
    /// goes through), then as `resume_game`.
    reset,
    /// Close, suppress held buttons, `picker.reset()`, enter the picker.
    pick_rom,
    /// Close and open the LINK screen (frontend/cable_screen.zig).
    link_cable,
};

/// Pad bits (`core.Pad`) main.zig ORs into the game pad while
/// `hold_frames_left > 0`, counting it down per game frame. Kept after the
/// count runs out (the `debug_hold_pad` export reads the last request).
pub var hold_pad: u16 = 0;
pub var hold_frames_left: u8 = 0;
/// Game frames a held-button row holds its buttons.
const hold_frames = 4;

/// The fast-forward gesture (frontend/input.zig): main.zig's in-play
/// hint after `hint.hold_select`, and a footer turn.
pub const fast_hint = "2x Sel+hold: fast";
/// The chorded rewind's hint: the footer turn after `fast_hint`, and the
/// in-play hint's third turn.
pub const rewind_hint = "then Left: rewind";
/// The footer's turns: how to leave, fast forward, chorded rewind.
const footers = [_][]const u8{ hint.back, fast_hint, rewind_hint };
/// Menu updates each footer line stays (2 s).
const footer_turn = 120;
/// Menu updates since `open`, for the footer's turns.
var updates_open: u32 = 0;

const Item = enum { resume_game, buttons, sound, opt2, restart, debug, reset, pick_rom, link_cable, about };
const item_count = @typeInfo(Item).@"enum".field_names.len;
/// Rows the panel holds: at most this many items are visible at once
/// (the Debug overlay row gives way in the one case all ten would show).
const panel_rows = 9;

/// The Pick ROM row exists only when the drive has more than one playable
/// file; otherwise it is skipped (not greyed) by `move` and `draw`.
fn pick_available() bool {
    return romsrc.use_drive and romsrc.playable_count() > 1;
}

fn visible(item: Item) bool {
    return switch (item) {
        .pick_rom => pick_available(),
        // The pinned simulator has no streaming audio.
        .sound => !cart.is_wasm,
        // The simulator has no link port.
        .link_cable => cable.available(),
        // Ten rows (Sound and Pick ROM and Link cable): the developer's row goes.
        .debug => cart.is_wasm or !pick_available() or !cable.available(),
        else => true,
    };
}

var cursor: Item = .resume_game;
var showing_about: bool = false;
/// A Select press began inside the menu; its release resumes. The release
/// of the hold that opened the menu does not count.
var select_armed: bool = false;
/// After a scrub step the panel would hide the restored frame, so only the
/// scrub bar is drawn until Up/Down/A.
var scrub_view: bool = false;

/// Scrub auto-repeat (SPEC.md 5: 4 steps per second while held; one update
/// is 1/60 s here), shared with the chorded rewind (`input.Repeat`).
var repeat: input.Repeat = .{};

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
    // The present of the frame drawn next still sends only marked rects
    // (badge-bench --lcd): without this the scrub bar, which the marquee
    // band repaints unmarked (`marquee.draw` marks nothing), stayed on the
    // LCD for that one update after a resume.
    cart.mark_dirty_rect(0, 0, cart.screen_width, cart.screen_height);
}

/// One menu update: handle input, then draw over the frozen game frame.
pub fn update(l: *core.Lynx, e: input.Edge) Result {
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
        } else left_right(l, e);
    } else {
        if (e.pressed(.b) or select_tap) return .resume_game;
        if (e.pressed(.up)) move(-1);
        if (e.pressed(.down)) move(1);
        left_right(l, e);
        if (e.pressed(.a)) {
            switch (cursor) {
                .resume_game => return .resume_game,
                .opt2 => return hold(core.Pad.opt2),
                .restart => return hold(core.Pad.pause | core.Pad.opt1),
                // Power on again: main.zig's `boot` with the same cart
                // reruns the boot (core/boot.zig), forgets the scrub
                // history and reloads the marquee.
                .reset => return .reset,
                .pick_rom => return .pick_rom,
                .link_cable => {
                    if (cable.linked) {
                        cable.close(l);
                        return .resume_game;
                    }
                    return .link_cable;
                },
                .about => showing_about = true,
                .buttons, .sound, .debug => adjust(l),
            }
        }
    }
    draw(l);
    return .stay;
}

fn hold(pad: u16) Result {
    hold_pad = pad;
    hold_frames_left = hold_frames;
    return .resume_game;
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
    return item == .buttons or item == .sound or item == .debug;
}

/// Time scrubber step (SPEC.md section 10): Left = back 0.5 s, Right =
/// forward. Swaps the record into `l` and redraws the frozen frame.
fn on_scrub(l: *core.Lynx, dir: i2) void {
    if (rewind.step(l, dir)) scrub_view = true;
}

/// Left/Right: flip a setting on a setting row, else scrub with
/// auto-repeat. The repeat starts only from a press in the menu. Out of
/// line: called from both the panel and the scrub view.
noinline fn left_right(l: *core.Lynx, e: input.Edge) void {
    if (is_setting(cursor)) {
        repeat.stop();
        if (e.pressed(.left) or e.pressed(.right)) adjust(l);
        return;
    }
    const d = repeat.step(e);
    if (d != 0) on_scrub(l, d);
}

/// Every setting has two values, so Left, Right and A all flip them.
fn adjust(l: *core.Lynx) void {
    switch (cursor) {
        .buttons => input.swap_ab = !input.swap_ab,
        .sound => {
            audio.enabled = !audio.enabled;
            l.audio_render = audio.enabled;
        },
        .debug => debug.enabled = !debug.enabled,
        else => {},
    }
}

// ---- Drawing ----

const band_h = 36;
const panel_x = 4;
/// The panel starts right under the band and runs to the bottom edge.
const panel_y = band_h;
const panel_w = cart.screen_width - 2 * panel_x;
const panel_h = cart.screen_height - panel_y;
/// 8 px rows, the font's own line pitch (M2-M4: 9), so nine rows (Sound
/// joined in M5), the bottom line and the footer fit the panel, as in
/// Genesis M4. The cursor bar is one pixel taller (`bar_rows`), from a
/// pixel above the row's glyphs to its descenders.
const row_h = 8;
const bar_rows = row_h + 1;
const text_x = panel_x + 4;
const first_row_y = panel_y + 2;
/// The panel's bottom line (y 110): "Scrub: ..." on the rows, About's
/// tenth line. Fixed below the ninth row even when Pick ROM or Sound is
/// hidden.
pub const scrub_line_y = first_row_y + panel_rows * row_h;
/// The footer under it (y 119): how to leave the menu (`hint.back`), in
/// turns with `fast_hint`; "B: back" on About.
const footer_y = scrub_line_y + 9;
/// The scrub bar shown after a step (`scrub_view`) and in the chorded
/// rewind: centred in the marquee band above the picture (y 8..17 of
/// 0..25), so the restored picture shows whole and the title band hides
/// the bar entirely when the full menu comes back.
const bar_h = 10;
const bar_y = (video.top - bar_h) / 2;
/// About lines: the nine rows' and the bottom line's (the footer holds
/// "B: back"), enough for About's worst case (`draw_about`).
const about_lines = panel_rows + 1;

/// Characters of the 8 px font across the screen (title band).
const screen_cols = cart.screen_width / 8;
/// Characters that fit inside the panel at the row text indent.
const panel_cols = (panel_w - (text_x - panel_x) - 2) / 8;

const band_color: cart.DisplayColor = .rgb(0x0A1A50);
const title_color: cart.DisplayColor = .rgb(0xFFFFFF);
const name_color: cart.DisplayColor = .rgb(0xFFD040);
const tagline_color: cart.DisplayColor = .rgb(0xB8C8F0);
const panel_color: cart.DisplayColor = .rgb(0x000000);
const frame_color: cart.DisplayColor = .rgb(0x3060E0);
const row_color: cart.DisplayColor = .rgb(0xFFFFFF);
const cursor_color: cart.DisplayColor = .rgb(0xFFD040);
const cursor_text_color: cart.DisplayColor = .rgb(0x000000);
const dim_color: cart.DisplayColor = .rgb(0x8898C0);

// Fixed strings, width-checked below.
const tagline_1 = "verified by";
const tagline_2 = "deterministic replay";
const back_hint = "B: back";

fn label(item: Item) []const u8 {
    return switch (item) {
        .resume_game => "Resume",
        .buttons => if (input.swap_ab) "Buttons: A=B B=A" else "Buttons: A=A B=B",
        .sound => if (audio.enabled) "Sound: On" else "Sound: Off",
        .opt2 => "Press Option 2",
        // "Restart: Pause+Opt1" is 19 columns, one more than the panel.
        .restart => "Restart Pause+Opt1",
        .debug => if (debug.enabled) "Debug overlay: On" else "Debug overlay: Off",
        .reset => "Reset",
        .pick_rom => "Pick ROM",
        .link_cable => if (cable.linked) "Leave link" else "Link cable",
        .about => "About",
    };
}

fn centered(s: []const u8, y: i32, color: cart.DisplayColor) void {
    // @min against a comptime bound narrows to a u5, so widen before * 8.
    const n: usize = @min(s.len, screen_cols);
    const w: i32 = @intCast(n * 8);
    text.draw(s[0..n], @divTrunc(@as(i32, cart.screen_width) - w, 2), y, color, band_color);
}

fn draw(l: *const core.Lynx) void {
    var buf: [24]u8 = undefined;

    if (scrub_view) {
        // Only the bar: the rest is the restored frame and the marquee
        // band, redrawn in full by every scrub step (frontend/rewind.zig
        // `show`).
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
        draw_about(l);
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
    const has_memory = rewind.capacity_slots() != 0;
    const live = has_memory and rewind.history_frames() != 0;
    // Linked (frontend/cable.zig) the scrubber's arena holds the port.
    const bottom = if (cable.linked) linked_line else hint.resume_line(cursor == .resume_game, has_memory, rewind.depth_frames(), rewind.history_frames()) orelse scrub_text(&buf);
    text.draw(bottom, text_x, scrub_line_y, if (live) row_color else dim_color, panel_color);
    // Linked, fast forward and the chorded rewind are off: no hints for them.
    const footer = if (cable.linked) hint.back else footers[(updates_open -% 1) / footer_turn % footers.len];
    text.draw(footer, text_x, footer_y, dim_color, panel_color);
}

/// The scrub bar (rows 8..17, in the marquee band above the picture): the
/// menu after a scrub step, and the whole display of the chorded rewind
/// (main.zig), which passes `chord` so an empty history reads
/// `hint.rewind_empty` rather than "Scrub: live / 0.0s".
/// Out of line: the menu and main.zig share one copy.
pub noinline fn draw_scrub_bar(chord: bool) void {
    var buf: [24]u8 = undefined;
    const empty = chord and rewind.capacity_slots() != 0 and rewind.history_frames() == 0;
    cart.rect(.{ .x = panel_x, .y = bar_y, .width = panel_w, .height = bar_h, .fill_color = band_color, .stroke_color = frame_color });
    centered(if (empty) hint.rewind_empty else scrub_text(&buf), bar_y + 1, title_color);
}

/// The scrub line for the current position, or "Scrub: no memory" when
/// the scrubber found no room (frontend/rewind.zig `init`).
fn scrub_text(buf: *[24]u8) []const u8 {
    if (rewind.capacity_slots() == 0) return no_memory;
    return scrub_label(buf, rewind.depth_frames(), rewind.history_frames());
}

const no_memory = "Scrub: no memory";
const linked_line = "Linked: no rewind";

/// "Scrub: live / 3.5s" or "Scrub: -1.5 / 3.5s"; from 10 s on whole
/// seconds ("Scrub: -12 / 32s"), so it stays within 18 characters (the
/// panel's width) for any history. Genesis's (Gear's).
pub noinline fn scrub_label(buf: *[24]u8, depth: u32, history: u32) []const u8 {
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

/// Lynx frames (60 Hz) as seconds: "3.5" (rounded to tenths) below 10 s,
/// else whole seconds "32" (capped at 99).
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

/// The core's boot error as text, null when it booted.
pub fn boot_error_text(l: *const core.Lynx) ?[]const u8 {
    const e = l.boot_error orelse return null;
    return @errorName(e);
}

/// About (PLAN.md M2, M8): version, file name, header title and
/// manufacturer (headered ROMs; "No header (raw)" otherwise), size and
/// block size, the source ("Source: embedded", or "Drive CRC 1A2B3C4D"
/// with the drive file's CRC32), then the core's boot error, "fragmented",
/// the EEPROM warning and the marquee's line (`marquee.about_line`). Ten
/// lines at most (two for the header, one each for the rest), all of
/// `about_lines`; the `n < about_lines` guards only keep a later line
/// from overflowing.
fn draw_about(l: *const core.Lynx) void {
    var bufs: [about_lines][24]u8 = undefined;
    var lines: [about_lines][]const u8 = undefined;
    var n: usize = 0;
    const lay = &romsrc.layout;

    var w: Line = .{ .buf = &bufs[n] };
    w.put("Version ");
    w.put(version);
    lines[n] = w.done();
    n += 1;
    lines[n] = fit(&bufs[n], romsrc.name(), panel_cols);
    n += 1;
    if (lay.headered) {
        lines[n] = fit(&bufs[n], romsrc.title_name(), panel_cols);
        n += 1;
        const m = core.cart.trim(&lay.manufacturer);
        if (m.len > 0) {
            lines[n] = fit(&bufs[n], m, panel_cols);
            n += 1;
        }
    } else {
        lines[n] = "No header (raw)";
        n += 1;
    }

    w = .{ .buf = &bufs[n] };
    w.n = romsrc.put_size(w.buf, romsrc.size);
    w.put(", ");
    w.num(lay.block_size);
    w.put(" B blk");
    lines[n] = w.done();
    n += 1;

    const drive = romsrc.origin == .drive;
    if (drive) {
        w = .{ .buf = &bufs[n] };
        w.put("Drive CRC ");
        var hex: [8]u8 = undefined;
        w.put(romsrc.hex8(&hex, romsrc.crc));
        lines[n] = w.done();
    } else {
        lines[n] = "Source: embedded";
    }
    n += 1;

    if (boot_error_text(l)) |s| {
        w = .{ .buf = &bufs[n] };
        w.put("Boot: ");
        w.put(s);
        lines[n] = w.done();
        n += 1;
    }
    if (drive and romsrc.fragmented and n < about_lines) {
        lines[n] = "fragmented";
        n += 1;
    }
    if (lay.warn_eeprom() and n < about_lines) {
        lines[n] = "EEPROM: not saved";
        n += 1;
    }
    if (n < about_lines) {
        var m: [24]u8 = undefined;
        lines[n] = fit(&bufs[n], marquee.about_line(&m), panel_cols);
        n += 1;
    }

    var y: i32 = first_row_y;
    for (lines[0..n]) |s| {
        text.draw(s, text_x, y, row_color, panel_color);
        y += row_h;
    }
    text.draw(back_hint, text_x, footer_y, dim_color, panel_color);
}

/// `s` cut to `cols` characters, the last one replaced by '~' when
/// something was cut (header names are 32 bytes, drive names 64).
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
        w.n += debug.put_num(w.buf[w.n..panel_cols], v);
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
    if (scrub_line_y != 110 or footer_y != 119) @compileError("bottom lines moved: recheck the layout");
    if (scrub_line_y + row_h > panel_y + panel_h) @compileError("bottom line outside the panel");
    if (footer_y + 8 > panel_y + panel_h - 1) @compileError("menu footer outside the panel");
    if (hint.panel_cols != panel_cols) @compileError("hint.panel_cols does not match this panel");
    if (panel_y + panel_h > cart.screen_height) @compileError("panel below the screen");
    if (first_row_y - 1 <= panel_y) @compileError("first cursor bar on the panel frame");
    check_width(title, screen_cols);
    check_width(tagline_1, screen_cols);
    check_width(tagline_2, screen_cols);
    check_width("Buttons: A=B B=A", panel_cols);
    check_width("Restart Pause+Opt1", panel_cols);
    check_width("Debug overlay: Off", panel_cols);
    check_width("Sound: Off", panel_cols);
    check_width("Version " ++ version, panel_cols);
    check_width("Source: embedded", panel_cols);
    check_width("Drive CRC 00000000", panel_cols);
    check_width("512 KB, 2048 B blk", panel_cols);
    check_width("Boot: BadCheckByte", panel_cols);
    check_width("EEPROM: not saved", panel_cols);
    check_width(back_hint, panel_cols);
    check_width(fast_hint, panel_cols);
    check_width(rewind_hint, panel_cols);
    check_width(no_memory, panel_cols);
    check_width(linked_line, panel_cols);
    check_width("Link cable", panel_cols);
    check_width("Leave link", panel_cols);
    check_width("Scrub: -9.9 / 9.9s", panel_cols);
    check_width("Scrub: live / 9.9s", panel_cols);
    check_width("Scrub: -99 / 99s", panel_cols);
    // About's ten lines end above the footer that holds "B: back".
    if (about_lines < 10) @compileError("About's worst case is ten lines");
    if (first_row_y + about_lines * row_h > footer_y) @compileError("About lines over the footer");
    // The scrub bar stays off the picture (rows video.top..127) and inside
    // the title band, which hides it when the full menu comes back.
    if (bar_y + bar_h > video.top) @compileError("scrub bar over the picture");
    if (bar_y + bar_h > band_h) @compileError("scrub bar outside the title band");
}

comptime {
    var buf: [24]u8 = undefined;
    if (!std.mem.eql(u8, fit(&buf, "RAYCAST.LNX", 18), "RAYCAST.LNX")) @compileError("fit short");
    if (!std.mem.eql(u8, fit(&buf, "Hard Drivin' (USA, Europe).lnx", 18), "Hard Drivin' (USA~")) @compileError("fit long");
    if (!std.mem.eql(u8, scrub_label(&buf, 0, 210), "Scrub: live / 3.5s")) @compileError("scrub_label live");
    if (!std.mem.eql(u8, scrub_label(&buf, 90, 239), "Scrub: -1.5 / 4.0s")) @compileError("scrub_label depth");
    if (!std.mem.eql(u8, scrub_label(&buf, 600, 1890), "Scrub: -10 / 31s")) @compileError("scrub_label long");
    if (scrub_label(&buf, 594, 594).len > panel_cols) @compileError("scrub_label too wide");
}
