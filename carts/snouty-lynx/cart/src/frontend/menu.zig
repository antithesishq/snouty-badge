//! Emulator menu (SPEC.md sections 5 and 12, PLAN.md "M2 Frontend"),
//! copied from Snouty Genesis's frontend/menu.zig (itself Snouty Gear's)
//! with the Lynx rows: Resume, Buttons (A/B swap), Press Option 2,
//! Restart (Pause + Option 1), Debug overlay, Reset, Pick ROM (a drive
//! with several playable files) and About; 9 px rows as Genesis. Gear's
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
//! (Buttons, Debug overlay); on the other rows Left/Right do nothing in M2
//! (M3's time scrubber takes them, and the panel's bottom line,
//! `scrub_line_y`, is left free for its "Scrub: ..." text).
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

pub const version = "0.2.0-m2";

/// The title the menu band and the status strip show.
pub const title = "SNOUTY LYNX";

/// What main.zig does after a menu update.
pub const Result = enum {
    stay,
    /// Close, suppress held buttons, run a game frame (with `hold_pad`).
    resume_game,
    /// Close, suppress held buttons, `picker.reset()`, enter the picker.
    pick_rom,
};

/// Pad bits (`core.Pad`) main.zig ORs into the game pad while
/// `hold_frames_left > 0`, counting it down per game frame. Kept after the
/// count runs out (the `debug_hold_pad` export reads the last request).
pub var hold_pad: u16 = 0;
pub var hold_frames_left: u8 = 0;
/// Game frames a held-button row holds its buttons.
const hold_frames = 4;

const Item = enum { resume_game, buttons, opt2, restart, debug, reset, pick_rom, about };
const item_count = @typeInfo(Item).@"enum".field_names.len;

/// The Pick ROM row exists only when the drive has more than one playable
/// file; otherwise it is skipped (not greyed) by `move` and `draw`.
fn pick_available() bool {
    return romsrc.use_drive and romsrc.playable_count() > 1;
}

fn visible(item: Item) bool {
    return item != .pick_rom or pick_available();
}

var cursor: Item = .resume_game;
var showing_about: bool = false;
/// A Select press began inside the menu; its release resumes. The release
/// of the hold that opened the menu does not count.
var select_armed: bool = false;

/// Enter the menu. Called in the update the Select hold threshold is
/// reached, before anything is drawn; the caller then calls `update` once
/// in the same update.
pub fn open() void {
    showing_about = false;
    select_armed = false;
    cursor = .resume_game;
    if (!cart.is_wasm) {
        const n = cart.screen_width * cart.screen_height / 2;
        const src: *const [n]u32 = @ptrCast(cart.frontbuffer);
        const dst: *[n]u32 = @ptrCast(cart.framebuffer);
        @memcpy(dst, src);
    }
    cart.set_double_buffer_mode(.copy_forward);
}

/// Leave the menu; the caller steps the game (or draws the picker) in the
/// same update.
pub fn close() void {
    cart.set_double_buffer_mode(.no_copy_full_frame);
}

/// One menu update: handle input, then draw over the frozen game frame.
pub fn update(l: *core.Lynx, e: input.Edge) Result {
    if (e.pressed(.select)) select_armed = true;
    const select_tap = select_armed and e.released(.select);
    if (select_tap) select_armed = false;

    if (showing_about) {
        if (e.pressed(.a) or e.pressed(.b) or select_tap) showing_about = false;
    } else {
        if (e.pressed(.b) or select_tap) return .resume_game;
        if (e.pressed(.up)) move(-1);
        if (e.pressed(.down)) move(1);
        if (is_setting(cursor)) {
            if (e.pressed(.left)) adjust();
            if (e.pressed(.right)) adjust();
        }
        if (e.pressed(.a)) {
            switch (cursor) {
                .resume_game => return .resume_game,
                .opt2 => return hold(core.Pad.opt2),
                .restart => return hold(core.Pad.pause | core.Pad.opt1),
                .reset => {
                    // Power on again: the boot (core/boot.zig) reruns.
                    // `init_in_place` with the same cart is `reset`, and
                    // the out-of-line call shares main.zig's copy.
                    @call(.never_inline, core.Lynx.init_in_place, .{ l, l.cart });
                    return .resume_game;
                },
                .pick_rom => return .pick_rom,
                .about => showing_about = true,
                .buttons, .debug => adjust(),
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
    return item == .buttons or item == .debug;
}

/// Both settings have two values, so Left, Right and A all flip them.
fn adjust() void {
    switch (cursor) {
        .buttons => input.swap_ab = !input.swap_ab,
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
const row_h = 9;
const text_x = panel_x + 4;
const first_row_y = panel_y + 2;
/// The panel's bottom line (y 110): "B: back" on About; M3's scrub line on
/// the rows. Fixed below the last row even when Pick ROM is hidden.
pub const scrub_line_y = first_row_y + item_count * row_h;
/// About lines above the bottom line.
const about_lines = item_count;

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
        .opt2 => "Press Option 2",
        // "Restart: Pause+Opt1" is 19 columns, one more than the panel.
        .restart => "Restart Pause+Opt1",
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

fn draw(l: *const core.Lynx) void {
    var buf: [24]u8 = undefined;

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
            cart.rect(.{ .x = panel_x + 2, .y = y - 1, .width = panel_w - 4, .height = row_h, .fill_color = cursor_color });
            text.draw(label(item), text_x, y, cursor_text_color, cursor_color);
        } else {
            text.draw(label(item), text_x, y, row_color, panel_color);
        }
        y += row_h;
    }
}

/// The core's boot error as text, null when it booted.
pub fn boot_error_text(l: *const core.Lynx) ?[]const u8 {
    const e = l.boot_error orelse return null;
    return @errorName(e);
}

/// About (PLAN.md M2): version, file name, header title and manufacturer
/// (headered ROMs), size and block size, source, then while lines remain:
/// the core's boot error, why the drive was not used (embedded ROM), the
/// drive's CRC32, "fragmented", the EEPROM warning.
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
    lines[n] = if (drive) "Source: drive" else "Source: embedded";
    n += 1;

    if (boot_error_text(l)) |s| {
        w = .{ .buf = &bufs[n] };
        w.put("Boot: ");
        w.put(s);
        lines[n] = w.done();
        n += 1;
    }
    if (!drive) {
        if (romsrc.fallback) |why| {
            if (n + 2 <= about_lines) {
                lines[n] = "Drive not used:";
                lines[n + 1] = fit(&bufs[n + 1], why, panel_cols);
                n += 2;
            }
        }
    } else {
        if (n < about_lines) {
            w = .{ .buf = &bufs[n] };
            w.put("CRC ");
            var hex: [8]u8 = undefined;
            w.put(romsrc.hex8(&hex, romsrc.crc));
            lines[n] = w.done();
            n += 1;
        }
        if (romsrc.fragmented and n < about_lines) {
            lines[n] = "fragmented";
            n += 1;
        }
    }
    if (lay.warn_eeprom() and n < about_lines) {
        lines[n] = "EEPROM: not saved";
        n += 1;
    }

    var y: i32 = first_row_y;
    for (lines[0..n]) |s| {
        text.draw(s, text_x, y, row_color, panel_color);
        y += row_h;
    }
    text.draw(back_hint, text_x, scrub_line_y, dim_color, panel_color);
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
    if (scrub_line_y + row_h > panel_y + panel_h) @compileError("bottom line outside the panel");
    if (panel_y + panel_h > cart.screen_height) @compileError("panel below the screen");
    if (first_row_y - 1 <= panel_y) @compileError("first cursor bar on the panel frame");
    check_width(title, screen_cols);
    check_width(tagline_1, screen_cols);
    check_width(tagline_2, screen_cols);
    check_width("Buttons: A=B B=A", panel_cols);
    check_width("Restart Pause+Opt1", panel_cols);
    check_width("Debug overlay: Off", panel_cols);
    check_width("Version " ++ version, panel_cols);
    check_width("Source: embedded", panel_cols);
    check_width("Drive not used:", panel_cols);
    check_width("CRC 00000000", panel_cols);
    check_width("512 KB, 2048 B blk", panel_cols);
    check_width("Boot: BadCheckByte", panel_cols);
    check_width("EEPROM: not saved", panel_cols);
    check_width(back_hint, panel_cols);
}

comptime {
    var buf: [24]u8 = undefined;
    if (!std.mem.eql(u8, fit(&buf, "RAYCAST.LNX", 18), "RAYCAST.LNX")) @compileError("fit short");
    if (!std.mem.eql(u8, fit(&buf, "Hard Drivin' (USA, Europe).lnx", 18), "Hard Drivin' (USA~")) @compileError("fit long");
}
