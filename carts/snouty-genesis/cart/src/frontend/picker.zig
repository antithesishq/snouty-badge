//! ROM picker (SPEC.md section 11, PLAN.md M2 Track B): Snouty Boy's
//! picker at 30 updates a second with the menu's colours. Shown after the
//! splash when the badge drive holds two or more playable Genesis ROMs, and
//! from the menu's "Pick ROM" row. One row per `.gen`/`.md`/`.bin` file
//! found (at most `drive.max_candidates`): the file name and its size;
//! unplayable files are listed dimmed so the user sees why a copied file
//! does not run. Under the list, the selected file's header name, or the
//! reason it is refused. Up/Down move (wrapping), A plays the selected file
//! (playable rows only), B runs the embedded test ROM instead. Full redraw
//! every update. Drive builds only: main.zig reaches it behind
//! `romsrc.use_drive`.
const cart = @import("cart-api");
const input = @import("input.zig");
const video = @import("video.zig");
const text = @import("text.zig");
const romsrc = @import("romsrc.zig");
const help = @import("help.zig");

var cursor: usize = 0;

/// Put the cursor on the first playable file (the first row when none is).
/// Call before entering the picker.
pub fn reset() void {
    cursor = 0;
    for (romsrc.candidates(), 0..) |*c, i| {
        if (c.playable()) {
            cursor = i;
            return;
        }
    }
}

/// One picker update. Returns null to stay, or the choice: a candidate
/// index, or null inside for the embedded ROM.
pub fn update(e: input.Edge) ??usize {
    const list = romsrc.candidates();
    const n = list.len;
    if (n == 0) return @as(?usize, null);
    if (cursor >= n) reset();
    if (e.pressed(.up)) cursor = (cursor + n - 1) % n;
    if (e.pressed(.down)) cursor = (cursor + 1) % n;
    if (e.pressed(.b)) return @as(?usize, null);
    if (e.pressed(.a) and list[cursor].playable()) return cursor;
    draw();
    return null;
}

const band_h = 11;
const row_h = 10;
const first_row_y = 14;
/// Characters of the file name left of the size column.
const name_cols = 14;
/// The selected file's note: up to three lines above the key hints.
const note_y = 96;
const note_lines = 3;
const hint_y = cart.screen_height - 8;

const cursor_color = help.accent_color;
const cursor_text_color = help.black;

fn draw() void {
    const list = romsrc.candidates();
    video.blank(0);
    cart.rect(.{ .x = 0, .y = 0, .width = cart.screen_width, .height = band_h, .fill_color = help.band_color });
    const title = "Pick a ROM";
    text.draw(title, (cart.screen_width - title.len * 8) / 2, 2, help.title_color, help.band_color);

    var name_buf: [name_cols]u8 = undefined;
    var kb_buf: [8]u8 = undefined;
    for (list, 0..) |*c, i| {
        const y: i32 = first_row_y + @as(i32, @intCast(i)) * row_h;
        var fg = if (c.playable()) help.row_color else help.dim_color;
        var bg = help.black;
        if (i == cursor) {
            cart.rect(.{ .x = 0, .y = y - 1, .width = cart.screen_width, .height = row_h, .fill_color = cursor_color });
            fg = cursor_text_color;
            bg = cursor_color;
        }
        text.draw(fit(&name_buf, c.file_name()), 2, y, fg, bg);
        const kb = kb_label(&kb_buf, c.size);
        text.draw(kb, @as(i32, cart.screen_width) - 2 - @as(i32, @intCast(kb.len * 8)), y, fg, bg);
    }

    const sel = &list[cursor];
    const ok = sel.playable();
    var lines: [note_lines][]const u8 = undefined;
    const k = help.wrap(sel.note(), help.cols, &lines);
    for (lines[0..k], 0..) |l, j| {
        text.draw(l, 0, note_y + @as(i32, @intCast(j)) * 8, if (ok) help.accent_color else help.dim_color, help.black);
    }
    // "A: play  B: test ROM", exactly the 20 columns.
    text.draw("A: play", 0, hint_y, if (ok) help.row_color else help.dim_color, help.black);
    text.draw("B: test ROM", 9 * 8, hint_y, help.row_color, help.black);
}

/// `s` cut to `name_cols` characters, the last one '~' when cut.
fn fit(buf: *[name_cols]u8, s: []const u8) []const u8 {
    if (s.len <= name_cols) return s;
    @memcpy(buf[0 .. name_cols - 1], s[0 .. name_cols - 1]);
    buf[name_cols - 1] = '~';
    return buf;
}

/// "512K": the size rounded up to whole KB (the drive holds 1280 KB, so at
/// most 4 digits).
fn kb_label(buf: *[8]u8, bytes: u32) []const u8 {
    var v: u32 = @min((bytes + 1023) / 1024, 9999);
    var tmp: [4]u8 = undefined;
    var n: usize = 0;
    while (true) {
        tmp[n] = '0' + @as(u8, @intCast(v % 10));
        n += 1;
        v /= 10;
        if (v == 0) break;
    }
    for (0..n) |j| buf[j] = tmp[n - 1 - j];
    buf[n] = 'K';
    return buf[0 .. n + 1];
}

comptime {
    if (first_row_y + 8 * row_h > note_y) @compileError("picker rows overlap the note");
    if (note_y + 8 * note_lines > hint_y) @compileError("picker note overlaps the hints");
}
