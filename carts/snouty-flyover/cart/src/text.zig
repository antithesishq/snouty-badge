//! Title card and caption in the OS 8x8 font (SPEC.md 4, PLAN.md M1 "Text").
//! Every string is drawn twice through `cart.text` with no background:
//! black one pixel down-right first, then the colour, so it reads over
//! both the sky and bright terrain.
const cart = @import("cart-api");
const build_options = @import("build_options");

// --- Knobs ------------------------------------------------------------------

/// Card lifetime in frames, and the tail of it drawn in the dim colours.
const card_frames = 90;
const card_fade = 20;
/// Caption flash length in frames.
const flash_frames = 20;
/// Positions (top-left of the 8x8 cells); card lines are 10 rows apart.
const card_x = 4;
const card_y = 4;
const card_dy = 10;
const caption_x = 4;
const caption_y = 119;
/// Colours, 0xRRGGBB; dim = half of each channel.
const title_rgb: u32 = 0xFFB040;
const gloss_rgb: u32 = 0xC8D0E8;
const caption_rgb: u32 = 0x8090B0;
const flash_rgb: u32 = 0xE8FFFF;
const shadow_rgb: u32 = 0x000000;

/// Third boot-card line for this build's vsync lock (`show_card3`).
pub const fps_line = if (build_options.flyover_fps == 60) "at 60 fps" else "at 30 fps";

var card_title: []const u8 = "";
var card_gloss: []const u8 = "";
var card_line3: []const u8 = "";
var card_left: u32 = 0;
var caption: []const u8 = "";
var flash_left: u32 = 0;

/// Show a title card for card_frames, replacing the current one.
pub fn show_card(title: []const u8, gloss: []const u8) void {
    show_card3(title, gloss, "");
}

/// A card with a third line under the gloss (same colour), e.g. the boot
/// card: `show_card3("MEMORY LANE", "generated on badge", text.fps_line)`.
pub fn show_card3(title: []const u8, gloss: []const u8, line3: []const u8) void {
    card_title = title;
    card_gloss = gloss;
    card_line3 = line3;
    card_left = card_frames;
}

/// Persistent caption, bottom-left; an empty string hides it.
pub fn set_caption(s: []const u8) void {
    caption = s;
}

/// Draw the caption bright for flash_frames.
pub fn flash_caption() void {
    flash_left = flash_frames;
}

/// Draw over the finished frame (after the terrain and the sprite).
pub fn draw(frame: u32) void {
    _ = frame;
    if (card_left > 0) {
        card_left -= 1;
        const dim = card_left < card_fade;
        shadowed(card_title, card_x, card_y, colour(title_rgb, dim));
        const gloss = colour(gloss_rgb, dim);
        shadowed(card_gloss, card_x, card_y + card_dy, gloss);
        shadowed(card_line3, card_x, card_y + 2 * card_dy, gloss);
    }
    const bright = flash_left > 0;
    if (bright) flash_left -= 1;
    shadowed(caption, caption_x, caption_y, .rgb(if (bright) flash_rgb else caption_rgb));
}

fn shadowed(s: []const u8, x: i32, y: i32, c: cart.DisplayColor) void {
    if (s.len == 0) return;
    cart.text(.{ .str = s, .x = x + 1, .y = y + 1, .text_color = .rgb(shadow_rgb) });
    cart.text(.{ .str = s, .x = x, .y = y, .text_color = c });
}

/// rgb as a DisplayColor, halved per channel when `dim`.
fn colour(rgb: u32, dim: bool) cart.DisplayColor {
    return .rgb(if (dim) (rgb >> 1) & 0x7F7F7F else rgb);
}
