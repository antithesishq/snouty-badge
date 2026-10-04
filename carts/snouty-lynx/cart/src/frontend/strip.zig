//! The status strip, rows 102..127 under the picture (SPEC.md section 6,
//! PLAN.md "M2 Frontend"), moved out of main.zig in M3 so the time
//! scrubber (frontend/rewind.zig) can redraw the whole screen of a parked
//! state: the running game draws it after every frame, `rewind.show` after
//! every scrub step.
const cart = @import("cart-api");
const core = @import("core");
const video = @import("video.zig");
const text = @import("text.zig");
const debug = @import("debug.zig");
const romsrc = @import("romsrc.zig");
const menu = @import("menu.zig");
const audio = @import("audio.zig");

pub const bg: cart.DisplayColor = .rgb(0x101828);
pub const ink: cart.DisplayColor = .rgb(0xF0F0E8);
pub const accent: cart.DisplayColor = .rgb(0xFFC020);
pub const dim: cart.DisplayColor = .rgb(0x98A8C8);
pub const warn: cart.DisplayColor = .rgb(0xFF6040);
pub const cols = cart.screen_width / 8;

/// Rows 102..127, three 8 px lines: "SNOUTY LYNX" and the ROM name (header
/// title, else file name; with the overlay on and sound playing, the
/// audio queue and underruns "q1470/0" instead); the origin ("drive 128 KB", "embedded 27 KB")
/// or with the overlay on the step times; then the core's boot error if
/// any, else with the overlay on instructions and Suzy pixels, else the
/// detail (the drive CRC and flags, or why the drive was not used).
/// Out of line: the game frame and `rewind.show` share one copy.
pub noinline fn draw(l: *const core.Lynx) void {
    video.fill_rows(video.strip_y, video.strip_h, bg);
    const y0: i32 = video.strip_y + 1;
    var buf: [32]u8 = undefined;

    text.draw(menu.title, 0, y0, accent, bg);
    const name_x = menu.title.len + 1;
    if (debug.enabled and audio.enabled) {
        // The audio queue and underruns instead of the name (M5).
        const a = debug.audio_line(&buf, audio.queued(), audio.underruns);
        text.draw(fit(&buf, a, cols - name_x), name_x * 8, y0, accent, bg);
    } else {
        text.draw(fit(&buf, romsrc.title_name(), cols - name_x), name_x * 8, y0, ink, bg);
    }

    var b2: [32]u8 = undefined;
    if (debug.enabled) {
        text.draw(debug.line(&b2), 0, y0 + 8, ink, bg);
    } else {
        text.draw(romsrc.origin_line(b2[0..24]), 0, y0 + 8, dim, bg);
    }

    if (menu.boot_error_text(l)) |s| {
        var n = debug.put(&buf, "boot error: ");
        n += debug.put(buf[n..cols], s);
        text.draw(buf[0..n], 0, y0 + 16, warn, bg);
    } else if (debug.enabled) {
        text.draw(debug.line2(&buf), 0, y0 + 16, accent, bg);
    } else {
        text.draw(detail_line(&buf), 0, y0 + 16, dim, bg);
    }
}

/// "crc 1A2B3C4D frag raw" (drive) or "drive: NoVolume" (embedded with a
/// reason), cut to the strip's width; empty otherwise.
fn detail_line(buf: *[32]u8) []const u8 {
    var n: usize = 0;
    if (romsrc.origin == .drive) {
        n += debug.put(buf[n..], "crc ");
        var hex: [8]u8 = undefined;
        n += debug.put(buf[n..], romsrc.hex8(&hex, romsrc.crc));
        if (romsrc.fragmented) n += debug.put(buf[n..], " frag");
        if (!romsrc.layout.headered) n += debug.put(buf[n..], " raw");
        if (romsrc.layout.warn_eeprom()) n += debug.put(buf[n..], " no-EEP");
    } else if (romsrc.fallback) |why| {
        n += debug.put(buf[n..], "drive: ");
        n += debug.put(buf[n..], why);
    }
    return fit(buf[0..cols], buf[0..@min(n, buf.len)], cols);
}

/// `s` cut to `n` characters, the last one '~' when cut (`buf` may hold
/// `s` itself).
fn fit(buf: []u8, s: []const u8, n: usize) []const u8 {
    if (s.len <= n) return s;
    if (buf.ptr != s.ptr) @memcpy(buf[0 .. n - 1], s[0 .. n - 1]);
    buf[n - 1] = '~';
    return buf[0..n];
}
