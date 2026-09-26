//! Boot splash (SPEC.md section 12): for `frames` frames (1.2 s) the Snouty
//! mark and "SNOUTY BOY" scroll down from above the screen to the centre,
//! like the DMG boot logo, on shade 0 of the current palette. Any button
//! press skips it. The two-note chime belongs to frontend/audio.zig: this
//! module only raises `request_chime` once, the frame the logo lands.
const cart = @import("cart-api");
const video = @import("video.zig");

/// Splash length in frames (1.2 s at 60 Hz).
pub const frames = 72;
/// Frame on which the logo reaches its resting place.
pub const land_frame = 48;

/// Set to true once when the logo lands. The audio module (wired by the
/// integrator) plays the chime and clears it.
pub var request_chime: bool = false;

/// 16x16 Snouty mark, one u16 per row, MSB = leftmost pixel: a pig face
/// with ears, eyes and a big two-nostril snout. 32 bytes.
const mark = [16]u16{
    0b0000000000000000,
    0b0011000000001100,
    0b0100100000010010,
    0b0100011111100010,
    0b0010000000000100,
    0b0100000000000010,
    0b1000110000110001,
    0b1000110000110001,
    0b1000000000000001,
    0b1000111111110001,
    0b1001000000001001,
    0b1001011001101001,
    0b1001000000001001,
    0b0100111111110010,
    0b0010000000000100,
    0b0001111111111000,
};
const mark_scale = 3;
const mark_px: i32 = 16 * mark_scale;
const title = "SNOUTY BOY";
const title_scale = 1;
const gap = 6;
const block_h: i32 = mark_px + gap + 8 * title_scale;
const rest_y: i32 = @divTrunc(@as(i32, cart.screen_height) - block_h, 2);
const start_y: i32 = -block_h;

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
    video.blank(0);
    const ink = video.shade_color(3);
    const x0: i32 = @divTrunc(@as(i32, cart.screen_width) - mark_px, 2);
    for (mark, 0..) |row, r| {
        // Merge runs of set pixels into one rect each.
        var c: u5 = 0;
        while (c < 16) {
            if (row & (@as(u16, 0x8000) >> @intCast(c)) == 0) {
                c += 1;
                continue;
            }
            const run_start = c;
            while (c < 16 and row & (@as(u16, 0x8000) >> @intCast(c)) != 0) c += 1;
            cart.rect(.{
                .x = x0 + @as(i32, run_start) * mark_scale,
                .y = y + @as(i32, @intCast(r)) * mark_scale,
                .width = @as(u32, c - run_start) * mark_scale,
                .height = mark_scale,
                .fill_color = ink,
            });
        }
    }
    const tw: i32 = title.len * 8 * title_scale;
    cart.text(.{
        .str = title,
        .x = @divTrunc(@as(i32, cart.screen_width) - tw, 2),
        .y = y + mark_px + gap,
        .scale = title_scale,
        .text_color = ink,
    });
}
