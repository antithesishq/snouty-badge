//! Boot splash (SPEC.md section 12), Snouty Gear's at 30 updates a second:
//! for `frames` updates (1.2 s) the Antithesis Iris mark and "SNOUTY
//! GENESIS" slide down from above the screen to the centre, on a dark navy
//! background with a light mark, "GENESIS" in a red accent and a thin
//! accent bar under the title. Any button press skips it. No chime: every
//! cart boots silent (docs/SOUND.md at the repository root) and audio gets
//! no further work. The cart has no palette, so the colours are fixed here.
const cart = @import("cart-api");
const video = @import("video.zig");
const iris = @import("iris");

/// Splash length in updates (1.2 s at 30 Hz).
pub const frames = 36;
/// Update on which the logo reaches its resting place.
pub const land_frame = 24;

/// Background as a 9-bit CRAM word (----BBB-GGG-RRR-): dark navy.
const bg_cram: u16 = 0x400;
/// Mark and "SNOUTY".
const ink: cart.DisplayColor = .rgb(0xF0F0E8);
/// "GENESIS" and the bar under the title.
const accent: cart.DisplayColor = .rgb(0xFF4838);

/// The Iris mark (lib/iris_mark.zig, 24x24) at 2x: 48 px.
const mark_scale = 2;
const mark_px: i32 = iris.size * mark_scale;
const title = "SNOUTY GENESIS";
/// "GENESIS" starts at this character of `title`.
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
    if (title[accent_at] != 'G') @compileError("accent_at must point at GENESIS");
}

var frame: u32 = 0;

/// One splash update. Returns true when the splash is over (finished or
/// skipped); the caller then leaves the state in the same update, so
/// nothing is drawn in that case.
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
    video.blank(bg_cram);
    const x0: i32 = @divTrunc(@as(i32, cart.screen_width) - mark_px, 2);
    iris.draw(cart, x0, y, mark_scale, ink);
    const tw: i32 = title.len * 8;
    const tx = @divTrunc(@as(i32, cart.screen_width) - tw, 2);
    const ty = y + mark_px + gap;
    cart.text(.{ .str = title[0..accent_at], .x = tx, .y = ty, .text_color = ink });
    cart.text(.{ .str = title[accent_at..], .x = tx + accent_at * 8, .y = ty, .text_color = accent });
    cart.rect(.{ .x = tx, .y = ty + 8 + bar_gap, .width = @intCast(tw), .height = bar_h, .fill_color = accent });
}
