//! Boot splash (SPEC.md section 12), Snouty Boy's recolored: for `frames`
//! frames (1.2 s) the Iris mark and "SNOUTY GEAR" scroll down from above
//! the screen to the centre, on a dark blue background with a light mark,
//! "GEAR" in an orange accent and a thin accent bar under the title. Any
//! button press skips it. The two-note chime belongs to frontend/audio.zig
//! (main.zig paces it): this module only raises `request_chime` once, the
//! frame the logo lands. The bottom line says how to open the emulator
//! menu (`hint.hold_select`, lib/hint.zig). The cart has no palette, so the colours are fixed
//! here.
//!
//! `draw_no_rom` is the screen the badge drive build shows instead of the
//! splash when the drive has no usable ROM (frontend/romsrc.zig): the same
//! background and title, what to do, and the reason. It stays up; the OS
//! menu (Start+Select) leaves the cart.
const cart = @import("cart-api");
const video = @import("video.zig");
const iris = @import("iris");
const hint = @import("hint");

/// Splash length in frames (1.2 s at 60 Hz).
pub const frames = 72;
/// Frame on which the logo reaches its resting place (the chime plays).
pub const land_frame = 48;

/// Set to true once, the frame the logo lands. main.zig plays the chime
/// through frontend/audio.zig and clears it.
pub var request_chime: bool = false;

/// Background as a 12-bit CRAM colour (----BBBBGGGGRRRR): dark navy.
const bg_cram: u16 = 0x410;
/// Mark and "SNOUTY".
const ink: cart.DisplayColor = .rgb(0xF0F0E8);
/// "GEAR" and the bar under the title.
const accent: cart.DisplayColor = .rgb(0xFF9020);
/// The no-ROM screen's headline and its reason lines.
const headline: cart.DisplayColor = .rgb(0xFFD040);
const dim: cart.DisplayColor = .rgb(0xB8C8F0);

/// The Antithesis Iris mark (lib/iris_mark.zig, 24x24) at 2x: 48 px.
const mark_scale = 2;
const mark_px: i32 = iris.size * mark_scale;
const title = "SNOUTY GEAR";
/// "GEAR" starts at this character of `title`.
const accent_at = 7;
const gap = 6;
/// Accent bar: 2 px high, 2 px under the title, as wide as the title.
const bar_gap = 2;
const bar_h = 2;
const block_h: i32 = mark_px + gap + 8 + bar_gap + bar_h;
const rest_y: i32 = @divTrunc(@as(i32, cart.screen_height) - block_h, 2);
const start_y: i32 = -block_h;

comptime {
    if (title.len * 8 > cart.screen_width) @compileError("splash title wider than the screen");
    if (rest_y + block_h > hint.splash_y) @compileError("the menu hint overlaps the title");
}

var frame: u32 = 0;

/// One splash frame. Returns true when the splash is over (finished or
/// skipped); the caller then starts the game in the same frame, so nothing
/// is drawn in that case.
pub fn update(skip: bool) bool {
    if (skip or frame >= frames) return true;
    if (frame == land_frame) request_chime = true;
    draw(logo_y(frame));
    frame += 1;
    return false;
}

fn logo_y(f: u32) i32 {
    if (f >= land_frame) return rest_y;
    const dist = rest_y - start_y;
    return start_y + @divTrunc(dist * @as(i32, @intCast(f)), land_frame);
}

fn draw(y: i32) void {
    video.blank(bg_cram);
    const x0: i32 = @divTrunc(@as(i32, cart.screen_width) - mark_px, 2);
    iris.draw(cart, x0, y, mark_scale, ink);
    const tw: i32 = title.len * 8;
    const tx = @divTrunc(@as(i32, cart.screen_width) - tw, 2);
    const ty = y + mark_px + gap;
    cart.text(.{ .str = title[0..accent_at], .x = tx, .y = ty, .text_color = ink });
    cart.text(.{ .str = title[accent_at..], .x = tx + accent_at * 8, .y = ty, .text_color = accent });
    cart.rect(.{ .x = tx, .y = ty + 8 + bar_gap, .width = @intCast(tw), .height = bar_h, .fill_color = accent });
    hint.draw_centred(cart, hint.hold_select, hint.splash_y, ink);
}

/// The no-ROM screen, 20 columns of the 8 px font each line.
const no_rom_head = [_][]const u8{ "No ROM on the", "badge drive" };
const no_rom_help = [_][]const u8{ "Copy a .gg or .sms", "Game Gear ROM to", "the badge drive,", "eject it, then", "start this cart." };

comptime {
    for (no_rom_head ++ no_rom_help) |l| {
        if (l.len * 8 > cart.screen_width) @compileError("no-ROM line wider than the screen");
    }
}

/// Draw the no-ROM screen; `why` is romsrc's `failure` (a romfs error
/// name or "no .gg/.sms file"), cut to the screen width. Redrawn every
/// frame (the cart runs in `.no_copy_full_frame`).
pub fn draw_no_rom(why: []const u8) void {
    video.blank(bg_cram);
    const tw: i32 = title.len * 8;
    const tx = @divTrunc(@as(i32, cart.screen_width) - tw, 2);
    const ty = 4;
    cart.text(.{ .str = title[0..accent_at], .x = tx, .y = ty, .text_color = ink });
    cart.text(.{ .str = title[accent_at..], .x = tx + accent_at * 8, .y = ty, .text_color = accent });
    cart.rect(.{ .x = tx, .y = ty + 8 + bar_gap, .width = @intCast(tw), .height = bar_h, .fill_color = accent });
    var y: i32 = 24;
    for (no_rom_head) |l| {
        centred(l, y, headline);
        y += 9;
    }
    y = 48;
    for (no_rom_help) |l| {
        centred(l, y, ink);
        y += 9;
    }
    centred("Reason:", 104, dim);
    centred(why[0..@min(why.len, cart.screen_width / 8)], 114, dim);
}

fn centred(s: []const u8, y: i32, color: cart.DisplayColor) void {
    const w: i32 = @intCast(s.len * 8);
    cart.text(.{ .str = s, .x = @divTrunc(@as(i32, cart.screen_width) - w, 2), .y = y, .text_color = color });
}
