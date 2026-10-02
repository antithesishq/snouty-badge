//! Control hints for the emulator carts (Snouty Boy, Gear, Genesis and
//! Lynx; review 2026-10-01 finding UX-05). The emulator menu opens on a
//! 500 ms Select hold, Left/Right on its Resume row step time back, and
//! B leaves it; none of that shows in the picture, so a person handed the
//! badge finds none of it. The four carts share these hints:
//!
//! - the splash: `hold_select` centred on the bottom line (`splash_y`);
//! - the first `play_seconds` of play after the splash or the ROM picker:
//!   the same line in a strip over the picture (`Overlay`), gone at the
//!   first fresh button press, never drawn in the menu or a scrub view;
//! - the menu: on the Resume row the panel's bottom line is `resume_line`
//!   (the rewind action, or that there is no history yet) instead of the
//!   live scrub readout, and a footer names the back control (`back`).
//!
//! The gesture, its duration and the button mapping are the carts' own
//! (frontend/input.zig in each) and unchanged. The cost is one short
//! string per frame through the cart's text call plus one 10-row rect,
//! only while a hint shows. No `cart-api` import: the drawing functions
//! take the cart module as a comptime type (as lib/iris_mark.zig does), so
//! this file stays host-testable (`lib/tests.zig`).

/// The splash line and the in-play strip.
pub const hold_select = "Hold Select: menu";
/// The menu's bottom line on the Resume row, at the live position, with
/// history to step back through.
pub const rewind_ready = "Left/Right: rewind";
/// The same before the first keyframe or record exists.
pub const rewind_empty = "Rewind: no history";
/// The menu footer: B (or a Select tap) resumes in all four carts.
pub const back = "B: back to game";

/// Every hint string, for the width test.
pub const all = [_][]const u8{ hold_select, rewind_ready, rewind_empty, back };

/// One set of the hints above, for a cart that names other buttons. The
/// constants above are the SYCL badge's and stay what Boy, Gear and Lynx
/// draw; a cart built for another badge picks its own set at comptime
/// (`tufty_genesis`) and draws it through the `_in` / `_line` variants
/// below, which take the strings as an argument.
pub const Strings = struct {
    hold_select: []const u8,
    rewind_ready: []const u8,
    rewind_empty: []const u8,
    back: []const u8,
};

/// The SYCL badge's set (the constants above).
pub const sycl: Strings = .{
    .hold_select = hold_select,
    .rewind_ready = rewind_ready,
    .rewind_empty = rewind_empty,
    .back = back,
};

/// snouty-genesis built with -Dbadge=tufty (snouty-tufty's
/// `controls_map.snouty_genesis`): UP+DOWN held is Select held, so the
/// menu opens after holding both for ~0.8 s; A and B are Left and Right;
/// A+B is the cart's B.
pub const tufty_genesis: Strings = .{
    .hold_select = "Hold UP+DOWN: menu",
    .rewind_ready = "A/B: rewind",
    .rewind_empty = rewind_empty,
    .back = "A+B: back to game",
};

/// Glyphs across the 160 px screen in the 8x8 OS font.
pub const screen_cols = 20;
/// Glyphs inside the menu panels at their row indent (Boy, Gear, Genesis
/// and Lynx all have 18): every hint must fit there.
pub const panel_cols = 18;

/// Height of the in-play strip; the text sits 1 px below its top.
pub const strip_h = 10;
/// Top of the splash line: the bottom of the screen, under the Iris mark
/// and title block (which rest at y 31..97 on the 128-row screen).
pub const splash_y = 116;

/// How long the in-play hint shows, in seconds.
pub const play_seconds = 3;

/// The in-play hint's timer. One per cart, a static; `start` it when play
/// begins after the splash or the picker, `update_and_draw` once per game
/// update after the frame is drawn, `stop` when the menu opens.
pub const Overlay = struct {
    /// Updates the hint still shows; 0 = not showing.
    left: u16 = 0,

    /// Show the hint for the next `updates` game updates (180 at 60 Hz,
    /// 90 for Genesis's 30 updates a second: `play_seconds` either way).
    pub fn start(o: *Overlay, updates: u16) void {
        o.left = updates;
    }

    /// Hide it at once (the menu opened, a reset, a new ROM).
    pub fn stop(o: *Overlay) void {
        o.left = 0;
    }

    pub fn showing(o: Overlay) bool {
        return o.left != 0;
    }

    /// One game update: true when the hint is to be drawn this update. A
    /// fresh button press (`pressed`: went down this update and is not a
    /// press held over from the previous screen) dismisses it for good.
    pub fn tick(o: *Overlay, pressed: bool) bool {
        if (o.left == 0) return false;
        if (pressed) {
            o.left = 0;
            return false;
        }
        o.left -= 1;
        return true;
    }

    /// `tick`, then draw `hold_select` on a full-width strip at rows
    /// `y .. y + strip_h - 1` while it shows. `text` is the cart's fast
    /// text call with both colours (`fn (str, x, y, fg, bg)`, the
    /// `frontend/text.zig` drop-in of Gear, Genesis and Lynx) or `null`
    /// for `Cart.text`.
    pub fn update_and_draw(
        o: *Overlay,
        comptime Cart: type,
        comptime text: anytype,
        pressed: bool,
        y: i32,
        fg: Cart.DisplayColor,
        bg: Cart.DisplayColor,
    ) void {
        if (o.tick(pressed)) draw_strip(Cart, text, hold_select, y, fg, bg);
    }

    /// `update_and_draw` with the line given (`Strings.hold_select` of
    /// the cart's set).
    pub fn update_and_draw_line(
        o: *Overlay,
        comptime Cart: type,
        comptime text: anytype,
        line: []const u8,
        pressed: bool,
        y: i32,
        fg: Cart.DisplayColor,
        bg: Cart.DisplayColor,
    ) void {
        if (o.tick(pressed)) draw_strip(Cart, text, line, y, fg, bg);
    }
};

/// x that centres `len` glyphs across `width` px (0 when wider).
pub fn centre_x(len: usize, width: u32) i32 {
    const w: usize = len * 8;
    if (w >= width) return 0;
    return @intCast((width - w) / 2);
}

/// `s` centred at row `y` in `color` over whatever is there (the splash).
pub fn draw_centred(comptime Cart: type, s: []const u8, y: i32, color: Cart.DisplayColor) void {
    Cart.text(.{ .str = s, .x = centre_x(s.len, Cart.screen_width), .y = y, .text_color = color });
}

/// `s` centred on a full-width `bg` strip at rows `y .. y + strip_h - 1`.
pub fn draw_strip(
    comptime Cart: type,
    comptime text: anytype,
    s: []const u8,
    y: i32,
    fg: Cart.DisplayColor,
    bg: Cart.DisplayColor,
) void {
    Cart.rect(.{ .x = 0, .y = y, .width = Cart.screen_width, .height = strip_h, .fill_color = bg });
    const x = centre_x(s.len, Cart.screen_width);
    if (@TypeOf(text) == @TypeOf(null)) {
        Cart.text(.{ .str = s, .x = x, .y = y + 1, .text_color = fg, .background_color = bg });
    } else {
        text(s, x, y + 1, fg, bg);
    }
}

/// The menu's bottom line while the cursor is on Resume: the rewind hint
/// at the live position (`depth` 0), `rewind_empty` with no history yet.
/// Null when the cart's own scrub readout belongs there instead: another
/// row, a position parked in the past (the readout says how far), or a
/// scrubber without memory ("Scrub: no memory").
pub fn resume_line(on_resume: bool, has_memory: bool, depth: u32, history: u32) ?[]const u8 {
    if (!on_resume or !has_memory or depth != 0) return null;
    return if (history != 0) rewind_ready else rewind_empty;
}

/// `resume_line` with the strings of the set `s`.
pub fn resume_line_in(s: Strings, on_resume: bool, has_memory: bool, depth: u32, history: u32) ?[]const u8 {
    if (!on_resume or !has_memory or depth != 0) return null;
    return if (history != 0) s.rewind_ready else s.rewind_empty;
}

const std = @import("std");

test "hint: every string fits the menu panel and the screen" {
    for (all) |s| try std.testing.expect(s.len <= panel_cols and s.len <= screen_cols);
    try std.testing.expect(splash_y + 8 <= 128);
    try std.testing.expectEqual(@as(i32, 12), centre_x(hold_select.len, 160));
}

test "hint: every set fits the menu panel and the screen" {
    for ([_]Strings{ sycl, tufty_genesis }) |set| {
        for ([_][]const u8{ set.hold_select, set.rewind_ready, set.rewind_empty, set.back }) |s|
            try std.testing.expect(s.len <= panel_cols and s.len <= screen_cols);
    }
    try std.testing.expectEqualStrings(hold_select, sycl.hold_select);
    try std.testing.expectEqualStrings(
        tufty_genesis.rewind_ready,
        resume_line_in(tufty_genesis, true, true, 0, 30).?,
    );
    try std.testing.expect(resume_line_in(tufty_genesis, true, true, 60, 120) == null);
}

test "hint: the overlay shows for its time, then never again" {
    var o: Overlay = .{};
    try std.testing.expect(!o.tick(false));
    o.start(180);
    var shown: u32 = 0;
    for (0..400) |_| {
        if (o.tick(false)) shown += 1;
    }
    try std.testing.expectEqual(@as(u32, 180), shown);
    try std.testing.expect(!o.showing());
}

test "hint: a fresh press dismisses the overlay for good" {
    var o: Overlay = .{};
    o.start(180);
    try std.testing.expect(o.tick(false));
    try std.testing.expect(!o.tick(true));
    for (0..200) |_| try std.testing.expect(!o.tick(false));
    o.start(180);
    o.stop();
    try std.testing.expect(!o.tick(false));
}

test "hint: the Resume line names the rewind only where it applies" {
    try std.testing.expectEqualStrings(rewind_ready, resume_line(true, true, 0, 30).?);
    try std.testing.expectEqualStrings(rewind_empty, resume_line(true, true, 0, 0).?);
    // Parked in the past, another row, no memory: the cart's scrub readout.
    try std.testing.expect(resume_line(true, true, 60, 120) == null);
    try std.testing.expect(resume_line(false, true, 0, 30) == null);
    try std.testing.expect(resume_line(true, false, 0, 0) == null);
}

/// A stand-in for the cart-api module: counts what the hints draw.
const FakeCart = struct {
    const DisplayColor = u32;
    const screen_width: u32 = 160;
    var rects: u32 = 0;
    var texts: u32 = 0;
    var last_x: i32 = 0;
    fn rect(o: struct { x: i32, y: i32, width: u32, height: u32, fill_color: DisplayColor }) void {
        std.debug.assert(o.x >= 0 and o.x + @as(i32, @intCast(o.width)) <= screen_width);
        rects += 1;
    }
    fn text(o: struct { str: []const u8, x: i32, y: i32, text_color: DisplayColor, background_color: ?DisplayColor = null }) void {
        std.debug.assert(o.x + @as(i32, @intCast(o.str.len * 8)) <= screen_width);
        last_x = o.x;
        texts += 1;
    }
};

test "hint: the strip is drawn only while the overlay shows" {
    var o: Overlay = .{};
    o.start(3);
    for (0..10) |_| o.update_and_draw(FakeCart, null, false, 118, 1, 0);
    try std.testing.expectEqual(@as(u32, 3), FakeCart.texts);
    try std.testing.expectEqual(@as(u32, 3), FakeCart.rects);
    o.start(3);
    o.update_and_draw(FakeCart, null, true, 118, 1, 0);
    try std.testing.expectEqual(@as(u32, 3), FakeCart.texts);
    draw_centred(FakeCart, hold_select, splash_y, 1);
    try std.testing.expectEqual(centre_x(hold_select.len, 160), FakeCart.last_x);
}
