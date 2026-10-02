//! No-ROM help screen (SPEC.md section 12, PLAN.md M2 Track B): shown
//! after the splash when the badge drive has a volume but no playable
//! Genesis ROM. It says how to add one, lists up to four of the files that
//! were found and refused (`NAME: reason`, dimmed) and offers the embedded
//! ROM, which in a badge build is always the shipped test ROM. A or B
//! leaves. Drive builds only: main.zig reaches it behind `romsrc.use_drive`.
//! Full redraw every update, colours as the menu's (Snouty Gear's scheme).
const cart = @import("cart-api");
const input = @import("input.zig");
const video = @import("video.zig");
const text = @import("text.zig");
const romsrc = @import("romsrc.zig");

pub const band_color: cart.DisplayColor = .rgb(0x0A1A50);
pub const title_color: cart.DisplayColor = .rgb(0xFFFFFF);
pub const accent_color: cart.DisplayColor = .rgb(0xFFD040);
pub const row_color: cart.DisplayColor = .rgb(0xFFFFFF);
pub const dim_color: cart.DisplayColor = .rgb(0x8898C0);
pub const black: cart.DisplayColor = .rgb(0x000000);

/// Characters of the 8 px font across the screen.
pub const cols = cart.screen_width / 8;

const headline = "No Genesis ROM found";
/// The Tufty has no USB drive: snouty-tufty writes the drive into the UF2
/// from its -Dgenesis_rom option (4 lines either way).
const advice = if (input.tufty)
    "Build with -Dgenesis_rom=FILE (.gen, .md or .bin), flash the UF2."
else
    "Copy a .gen, .md or .bin file to the SYCLBADGE drive, eject, restart.";
/// C is badge A on the Tufty.
const hint = if (input.tufty) "C: run test ROM" else "A: run test ROM";

const band_h = 12;
const advice_y = 16;
const line_h = 9;
/// First line of the skipped-file list and the last row it may use.
const list_y = 56;
const list_last_y = 110;
const hint_y = cart.screen_height - 8;

/// One update. True when the user leaves (A or B): main.zig then runs the
/// embedded ROM.
pub fn update(e: input.Edge) bool {
    if (e.pressed(.a) or e.pressed(.b)) return true;
    draw();
    return false;
}

fn draw() void {
    video.blank(0);
    cart.rect(.{ .x = 0, .y = 0, .width = cart.screen_width, .height = band_h, .fill_color = band_color });
    text.draw(headline, 0, 2, accent_color, band_color);

    var lines: [6][]const u8 = undefined;
    const n = wrap(advice, cols, &lines);
    for (lines[0..n], 0..) |l, k| text.draw(l, 0, advice_y + @as(i32, @intCast(k)) * line_h, row_color, black);

    // Refused files, each wrapped to whole lines, while they fit.
    var y: i32 = list_y;
    var shown: usize = 0;
    var buf: [96]u8 = undefined;
    for (romsrc.candidates()) |*c| {
        if (shown == 4) break;
        const s = join(&buf, c.file_name(), c.note());
        const k = wrap(s, cols, &lines);
        if (k == 0) continue;
        if (y + @as(i32, @intCast(k - 1)) * 8 > list_last_y) break;
        for (lines[0..k]) |l| {
            text.draw(l, 0, y, dim_color, black);
            y += 8;
        }
        y += 2;
        shown += 1;
    }
    text.draw(hint, 0, hint_y, row_color, black);
}

/// "NAME: reason" into `buf` (cut at its end).
fn join(buf: []u8, name: []const u8, reason: []const u8) []const u8 {
    var n: usize = 0;
    for ([_][]const u8{ name, ": ", reason }) |part| {
        const k = @min(part.len, buf.len - n);
        @memcpy(buf[n..][0..k], part[0..k]);
        n += k;
    }
    return buf[0..n];
}

/// Word-wrap `s` into lines of at most `width` characters (a word longer
/// than a line is cut), at most `out.len` lines. Returns the line count.
pub fn wrap(s: []const u8, width: usize, out: [][]const u8) usize {
    var lines: usize = 0;
    var i: usize = 0;
    while (lines < out.len) {
        while (i < s.len and s[i] == ' ') i += 1;
        if (i >= s.len) break;
        const start = i;
        var end = @min(s.len, start + width);
        if (end < s.len and s[end] != ' ') {
            var j = end;
            while (j > start and s[j - 1] != ' ') j -= 1;
            if (j > start) end = j;
        }
        var trimmed = end;
        while (trimmed > start and s[trimmed - 1] == ' ') trimmed -= 1;
        out[lines] = s[start..trimmed];
        lines += 1;
        i = end;
    }
    return lines;
}

comptime {
    if (headline.len > cols or hint.len > cols) @compileError("help line too wide");
}
