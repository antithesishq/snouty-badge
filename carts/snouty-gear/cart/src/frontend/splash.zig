//! Boot splash (SPEC.md section 12). M2 stub with the frozen public shape
//! (PLAN.md M2 contract); Track B fills it in. The stub only counts frames
//! on a blank screen and raises the chime request once.
const cart = @import("cart-api");
const video = @import("video.zig");

/// Splash length in frames (1.2 s at 60 Hz).
pub const frames = 72;
/// Frame on which the logo reaches its resting place (the chime plays).
pub const land_frame = 48;

/// Set to true once, the frame the logo lands. main.zig plays the chime
/// through frontend/audio.zig and clears it.
pub var request_chime: bool = false;

var frame: u32 = 0;

/// One splash frame. Returns true when the splash is over (finished or
/// skipped); the caller then starts the game in the same frame, so nothing
/// is drawn in that case.
pub fn update(skip: bool) bool {
    if (skip or frame >= frames) return true;
    if (frame == land_frame) request_chime = true;
    video.blank(0);
    cart.text(.{ .str = "SNOUTY GEAR", .x = 36, .y = 60, .text_color = .rgb(0xFFFFFF) });
    frame += 1;
    return false;
}
