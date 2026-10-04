//! Framebuffer primitives: fills, lines and the 5x7 font in 6x8 cells.
//!
//! Every frame redraws the whole screen (`.no_copy_full_frame`), so nothing
//! here tracks dirty rectangles. The framebuffer is column-major
//! (`cart.framebuffer[x][y]`); writes go through `cart.Pixel.from_color`,
//! which handles the wasm byte order.
const cart = @import("cart-api");
const font = @import("font.zig");

pub const width: i32 = cart.screen_width;
pub const height: i32 = cart.screen_height;

/// The look: the original's black on white, plus three greys.
pub const Color = enum(u3) {
    white,
    black,
    /// Disabled buttons' text, rules (the original's grey `disabled`).
    grey,
    /// Button faces (the browser's default button grey).
    face,
    /// Faint fills: progress bar tracks, the quantum chips' frames.
    faint,
    /// Disabled text on the cursor bar (black background).
    dim,
};

const rgb = [_]u32{ 0xFFFFFF, 0x000000, 0x8C8C8C, 0xE4E4E4, 0xC8C8C8, 0x7A7A7A };

var pixels: [rgb.len]cart.Pixel = undefined;

/// Call once from start(): converts the palette to framebuffer pixels.
pub fn init() void {
    for (rgb, 0..) |c, i| pixels[i] = pixel_of(c);
}

pub fn pixel_of(c: u32) cart.Pixel {
    return cart.Pixel.from_color(cart.DisplayColor.rgb(c));
}

pub inline fn px(c: Color) cart.Pixel {
    return pixels[@intFromEnum(c)];
}

pub fn clear(c: Color) void {
    const p = px(c);
    for (cart.framebuffer) |*col| @memset(col, p);
}

pub fn fill_rect(x0: i32, y0: i32, w: i32, h: i32, c: Color) void {
    fill_rect_px(x0, y0, w, h, px(c));
}

pub fn fill_rect_px(x0: i32, y0: i32, w: i32, h: i32, p: cart.Pixel) void {
    const xa = @max(0, x0);
    const ya = @max(0, y0);
    const xb = @min(width, x0 + w);
    const yb = @min(height, y0 + h);
    if (xa >= xb or ya >= yb) return;
    var x = xa;
    while (x < xb) : (x += 1) {
        const col = &cart.framebuffer[@intCast(x)];
        @memset(col[@intCast(ya)..@intCast(yb)], p);
    }
}

pub fn hline(x0: i32, y: i32, w: i32, c: Color) void {
    fill_rect(x0, y, w, 1, c);
}

pub fn vline(x: i32, y0: i32, h: i32, c: Color) void {
    fill_rect(x, y0, 1, h, c);
}

pub fn frame(x0: i32, y0: i32, w: i32, h: i32, c: Color) void {
    hline(x0, y0, w, c);
    hline(x0, y0 + h - 1, w, c);
    vline(x0, y0, h, c);
    vline(x0 + w - 1, y0, h, c);
}

pub inline fn plot(x: i32, y: i32, p: cart.Pixel) void {
    if (x < 0 or y < 0 or x >= width or y >= height) return;
    cart.framebuffer[@intCast(x)][@intCast(y)] = p;
}

/// Text in the 5x7 font, 6 px per character; clipped at `max_x` (exclusive).
/// Returns the x after the last character drawn.
pub fn text_clip(str: []const u8, x0: i32, y: i32, max_x: i32, c: Color) i32 {
    return text_px(str, x0, y, max_x, px(c), 1);
}

pub fn text(str: []const u8, x0: i32, y: i32, c: Color) i32 {
    return text_px(str, x0, y, width, px(c), 1);
}

/// Twice the size (12x16 cells), for the stage 1 clip count.
pub fn text2(str: []const u8, x0: i32, y: i32, c: Color) i32 {
    return text_px(str, x0, y, width, px(c), 2);
}

/// Right-aligned so the text ends at `right` (exclusive, minus the cell's
/// trailing blank column).
pub fn text_right(str: []const u8, right: i32, y: i32, c: Color) i32 {
    const x0 = right - @as(i32, @intCast(str.len)) * font.cell_w + 1;
    _ = text_px(str, x0, y, width, px(c), 1);
    return x0;
}

pub fn text_center(str: []const u8, y: i32, c: Color) void {
    const w = @as(i32, @intCast(str.len)) * font.cell_w - 1;
    _ = text(str, @divTrunc(width - w, 2), y, c);
}

pub fn text_px(str: []const u8, x0: i32, y0: i32, max_x: i32, p: cart.Pixel, scale: i32) i32 {
    var x = x0;
    const step = font.cell_w * scale;
    if (y0 >= height or y0 + 8 * scale <= 0) return x0 + @as(i32, @intCast(str.len)) * step;
    for (str) |ch| {
        if (x + 5 * scale > max_x) break;
        if (x >= 0 and ch != ' ') glyph(ch, x, y0, p, scale);
        x += step;
    }
    return x;
}

fn glyph(ch: u8, x0: i32, y0: i32, p: cart.Pixel, scale: i32) void {
    const cols = font.columns(ch);
    for (cols, 0..) |bits0, i| {
        if (bits0 == 0) continue;
        const gx = x0 + @as(i32, @intCast(i)) * scale;
        if (scale == 1) {
            if (gx < 0 or gx >= width) continue;
            const col = &cart.framebuffer[@intCast(gx)];
            var bits = bits0;
            var y = y0;
            while (bits != 0) : ({
                bits >>= 1;
                y += 1;
            }) {
                if (bits & 1 != 0 and y >= 0 and y < height) col[@intCast(y)] = p;
            }
        } else {
            var bits = bits0;
            var y = y0;
            while (bits != 0) : ({
                bits >>= 1;
                y += scale;
            }) {
                if (bits & 1 != 0) fill_rect_px(gx, y, scale, scale, p);
            }
        }
    }
}
