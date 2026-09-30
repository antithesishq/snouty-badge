//! Title card and caption in the OS 8x8 font (SPEC.md 4). Scaffold stub:
//! plain text, no shadow or fade; Track A finishes it.
const cart = @import("cart-api");

const card_frames = 90;
const flash_frames = 20;

var card_title: []const u8 = "";
var card_gloss: []const u8 = "";
var card_left: u32 = 0;
var caption: []const u8 = "";
var flash_left: u32 = 0;

/// Show a title card for card_frames, replacing the current one.
pub fn show_card(title: []const u8, gloss: []const u8) void {
    card_title = title;
    card_gloss = gloss;
    card_left = card_frames;
}

pub fn set_caption(s: []const u8) void {
    caption = s;
}

pub fn flash_caption() void {
    flash_left = flash_frames;
}

/// Draw over the finished frame (after the terrain and the sprite).
pub fn draw(frame: u32) void {
    _ = frame;
    if (card_left > 0) {
        card_left -= 1;
        cart.text(.{ .str = card_title, .x = 4, .y = 4, .text_color = .{ .r = 31, .g = 44, .b = 8 } });
        cart.text(.{ .str = card_gloss, .x = 4, .y = 14, .text_color = .{ .r = 25, .g = 52, .b = 29 } });
    }
    if (caption.len > 0) {
        const bright = flash_left > 0;
        if (bright) flash_left -= 1;
        cart.text(.{
            .str = caption,
            .x = 4,
            .y = 119,
            .text_color = if (bright) .{ .r = 29, .g = 63, .b = 31 } else .{ .r = 16, .g = 36, .b = 22 },
        });
    }
}
