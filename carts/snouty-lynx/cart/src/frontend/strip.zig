//! The band above the picture, badge rows 0..25 (SPEC.md section 6,
//! PLAN.md "M8 Marquee"): the arcade marquee (frontend/marquee.zig) and
//! what sits over it. Until M8 this was the status strip under the
//! picture (rows 102..127); its ROM origin and CRC lines went to About,
//! which already had them. A file of its own since M3 so the time
//! scrubber (frontend/rewind.zig) can redraw the whole screen of a parked
//! state: the running game draws the band after every frame, `rewind.show`
//! after every scrub step. main.zig draws the play hints, the cable notes
//! (both on `note_y`) and the `>>2x` indicator (top right corner) over it
//! afterwards; the menu's scrub bar sits in it too (frontend/menu.zig).
const cart = @import("cart-api");
const core = @import("core");
const video = @import("video.zig");
const marquee = @import("marquee.zig");
const text = @import("text.zig");
const debug = @import("debug.zig");
const romsrc = @import("romsrc.zig");
const menu = @import("menu.zig");
const audio = @import("audio.zig");
const hint = @import("hint");

pub const bg: cart.DisplayColor = .rgb(0x101828);
pub const ink: cart.DisplayColor = .rgb(0xF0F0E8);
pub const accent: cart.DisplayColor = .rgb(0xFFC020);
pub const dim: cart.DisplayColor = .rgb(0x98A8C8);
pub const warn: cart.DisplayColor = .rgb(0xFF6040);
pub const cols = cart.screen_width / 8;

/// Top of the band's bottom 10 rows (16..25): the boot error here, the
/// play hints and the cable notes (main.zig, `hint.draw_strip`) over it.
pub const note_y = marquee.h - hint.strip_h;
/// The debug overlay's first line (rows 1..8; then 9..16 and 17..24).
const overlay_y = 1;

comptime {
    if (marquee.h != video.top) @compileError("the marquee fills the rows above the picture");
    if (overlay_y + 24 > marquee.h) @compileError("the overlay's three lines leave the band");
    // The boot error and the overlay's third line share a row, so the
    // error replaces that line as it did in the strip.
    if (note_y + 1 != overlay_y + 16) @compileError("boot error off the overlay's third line");
}

/// Rows 0..25: the marquee, then over it with the debug overlay on three
/// 8 px lines on `bg`: "SNOUTY LYNX" and the ROM name (header title, else
/// file name; with sound playing, the audio queue and underruns "q1470/0"
/// instead), the step times, then instructions and Suzy pixels. The core's
/// boot error, if any, is a red line on the band's bottom 10 rows
/// (`note_y`, in place of the overlay's third line).
/// Out of line: the game frame and `rewind.show` share one copy.
pub noinline fn draw(l: *const core.Lynx) void {
    marquee.draw();
    var buf: [32]u8 = undefined;

    if (debug.enabled) {
        const y0 = overlay_y;
        text.draw(menu.title, 0, y0, accent, bg);
        const name_x = menu.title.len + 1;
        if (audio.enabled) {
            // The audio queue and underruns instead of the name (M5).
            const a = debug.audio_line(&buf, audio.queued(), audio.underruns);
            text.draw(fit(&buf, a, cols - name_x), name_x * 8, y0, accent, bg);
        } else {
            text.draw(fit(&buf, romsrc.title_name(), cols - name_x), name_x * 8, y0, ink, bg);
        }
        text.draw(debug.line(&buf), 0, y0 + 8, ink, bg);
        if (l.boot_error == null) text.draw(debug.line2(&buf), 0, y0 + 16, accent, bg);
    }

    if (menu.boot_error_text(l)) |s| {
        video.fill_rows(note_y, hint.strip_h, bg);
        var n = debug.put(&buf, "boot error: ");
        n += debug.put(buf[n..cols], s);
        text.draw(buf[0..n], 0, note_y + 1, warn, bg);
    }
}

/// `s` cut to `n` characters, the last one '~' when cut (`buf` may hold
/// `s` itself).
fn fit(buf: []u8, s: []const u8, n: usize) []const u8 {
    if (s.len <= n) return s;
    if (buf.ptr != s.ptr) @memcpy(buf[0 .. n - 1], s[0 .. n - 1]);
    buf[n - 1] = '~';
    return buf[0..n];
}
