//! Boot splash (SPEC.md section 12), Snouty Gear's recoloured: for
//! `frames` frames (1.2 s) the Iris mark (lib/iris_mark.zig, the emulator
//! splash convention of Snouty Boy, Gear and Genesis) and "SNOUTY LYNX"
//! scroll down from above the screen to the centre, on a dark background
//! with a light mark, "LYNX" in an accent colour and a thin accent bar
//! under the title. Any button skips it.
//!
//! No chime in M0: the cart makes no sound yet. When M2 adds one it goes
//! through frontend/audio.zig behind the Sound toggle, silent at boot
//! unless built with -Dsound=true (docs/SOUND.md at the repository root).
const cart = @import("cart-api");
const video = @import("video.zig");
const iris = @import("iris");

/// Splash length in frames (1.2 s at 60 Hz).
pub const frames = 72;
/// Frame on which the logo reaches its resting place.
pub const land_frame = 48;

const bg: cart.DisplayColor = .rgb(0x201008);
const ink: cart.DisplayColor = .rgb(0xF0F0E8);
const accent: cart.DisplayColor = .rgb(0xFFC020);

const mark_scale = 2;
const mark_px: i32 = iris.size * mark_scale;
const title = "SNOUTY LYNX";
/// "LYNX" starts at this character of `title`.
const accent_at = 7;
const gap = 6;
const bar_gap = 2;
const bar_h = 2;
const block_h: i32 = mark_px + gap + 8 + bar_gap + bar_h;
const rest_y: i32 = @divTrunc(@as(i32, cart.screen_height) - block_h, 2);
const start_y: i32 = -block_h;

comptime {
    if (title.len * 8 > cart.screen_width) @compileError("splash title wider than the screen");
}

var frame: u32 = 0;

/// One splash frame. True when the splash is over (finished or skipped);
/// the caller then shows the next screen in the same frame.
pub fn update(skip: bool) bool {
    if (skip or frame >= frames) return true;
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
    video.blank(bg);
    const x0: i32 = @divTrunc(@as(i32, cart.screen_width) - mark_px, 2);
    iris.draw(cart, x0, y, mark_scale, ink);
    const tw: i32 = title.len * 8;
    const tx = @divTrunc(@as(i32, cart.screen_width) - tw, 2);
    const ty = y + mark_px + gap;
    cart.text(.{ .str = title[0..accent_at], .x = tx, .y = ty, .text_color = ink });
    cart.text(.{ .str = title[accent_at..], .x = tx + accent_at * 8, .y = ty, .text_color = accent });
    cart.rect(.{ .x = tx, .y = ty + 8 + bar_gap, .width = @intCast(tw), .height = bar_h, .fill_color = accent });
}
