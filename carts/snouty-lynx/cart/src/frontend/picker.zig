//! ROM picker (SPEC.md 18.6, PLAN.md "M2 Frontend"): Snouty Genesis's
//! frontend/picker.zig at 60 updates a second with the menu's colours.
//! Shown after the splash when the badge drive holds two or more playable
//! Lynx files, and from the menu's "Pick ROM" row. One row per `.lnx`/`.lyx`
//! file found (at most `drive.max_candidates`): the file name and its size;
//! refused files are listed dimmed, and under the list the selected file's
//! header title (playable) or the reason it is refused. Up/Down move
//! (wrapping), A plays the selected file (playable rows only), B leaves
//! without a choice: main.zig keeps the cart that runs, which after the
//! splash is the first playable file. Full redraw every update. Drive
//! builds only: main.zig reaches it behind `romsrc.use_drive`.
const cart = @import("cart-api");
const input = @import("input.zig");
const video = @import("video.zig");
const text = @import("text.zig");
const romsrc = @import("romsrc.zig");

var cursor: usize = 0;
/// Entered from the menu (B goes back to the game) rather than after the
/// splash (B runs the first file); only changes the hint.
pub var from_menu: bool = false;

/// Put the cursor on the running drive file, else on the first playable
/// file (the first row when none is). Call before entering the picker.
pub fn reset() void {
    if (romsrc.chosen_index()) |i| {
        cursor = i;
        return;
    }
    cursor = 0;
    for (romsrc.candidates(), 0..) |*c, i| {
        if (c.playable()) {
            cursor = i;
            return;
        }
    }
}

/// One picker update. Returns null to stay, or the choice: a candidate
/// index, or null inside when B leaves without one.
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
const cols = cart.screen_width / 8;
const note_y = 100;
const hint_y = cart.screen_height - 8;

const band_color: cart.DisplayColor = .rgb(0x0A1A50);
const title_color: cart.DisplayColor = .rgb(0xFFFFFF);
const accent_color: cart.DisplayColor = .rgb(0xFFD040);
const row_color: cart.DisplayColor = .rgb(0xFFFFFF);
const dim_color: cart.DisplayColor = .rgb(0x8898C0);
const black: cart.DisplayColor = .rgb(0x000000);

fn draw() void {
    const list = romsrc.candidates();
    video.blank(black);
    cart.rect(.{ .x = 0, .y = 0, .width = cart.screen_width, .height = band_h, .fill_color = band_color });
    const title = "Pick a ROM";
    text.draw(title, (cart.screen_width - title.len * 8) / 2, 2, title_color, band_color);

    var name_buf: [cols]u8 = undefined;
    var kb_buf: [8]u8 = undefined;
    for (list, 0..) |*c, i| {
        const y: i32 = first_row_y + @as(i32, @intCast(i)) * row_h;
        var fg = if (c.playable()) row_color else dim_color;
        var bg = black;
        if (i == cursor) {
            cart.rect(.{ .x = 0, .y = y - 1, .width = cart.screen_width, .height = row_h, .fill_color = accent_color });
            fg = black;
            bg = accent_color;
        }
        text.draw(fit(&name_buf, c.file_name(), name_cols), 2, y, fg, bg);
        const kb = kb_label(&kb_buf, c.entry.size);
        text.draw(kb, @as(i32, cart.screen_width) - 2 - @as(i32, @intCast(kb.len * 8)), y, fg, bg);
    }

    const sel = &list[cursor];
    const ok = sel.playable();
    const t = sel.layout.title();
    const note = if (!ok) sel.note() else if (t.len > 0) t else "no header title";
    text.draw(fit(&name_buf, note, cols), 0, note_y, if (ok) accent_color else dim_color, black);
    text.draw("A: play", 0, hint_y, if (ok) row_color else dim_color, black);
    text.draw(if (from_menu) "B: back" else "B: first", 10 * 8, hint_y, row_color, black);
}

/// `s` cut to `n` characters, the last one '~' when cut.
fn fit(buf: *[cols]u8, s: []const u8, n: usize) []const u8 {
    if (s.len <= n) return s;
    @memcpy(buf[0 .. n - 1], s[0 .. n - 1]);
    buf[n - 1] = '~';
    return buf[0..n];
}

/// "128K": the size rounded up to whole KB (the drive holds 1280 KB, so at
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
    // drive.max_candidates (8) rows above the note line.
    if (first_row_y + 8 * row_h > note_y) @compileError("picker rows overlap the note");
    if (note_y + 8 > hint_y) @compileError("picker note overlaps the hints");
}
