//! Copied unchanged from Snouty Gear.
//!
//! Fast drop-in for `cart.text` at scale 1 with both colors given, the
//! only way this cart draws text (the overlay and the ROM report, every
//! frame). `cart.text` tests and stores one pixel at a time (about 2,500
//! cycles a character, 1.2 ms a frame for the four calls); this draws a
//! glyph column as four word stores.
//!
//! The OS font is not visible to carts (it belongs to the board module), so
//! `init` captures it at start-up: it draws the printable ASCII glyphs with
//! `cart.text` itself and reads the pixels back into column masks. The
//! output is therefore pixel-identical to `cart.text`; characters outside
//! 32..126 and cells not wholly on screen are handed to `cart.text`.
const cart = @import("cart-api");

const first: u8 = 32;
const last: u8 = 126;
const glyph_count = last - first + 1;
const fw = cart.font_width;
const fh = cart.font_height;

comptime {
    if (fw != 8 or fh != 8) @compileError("text.zig assumes the 8x8 OS font");
}

/// Glyph columns: bit r of `cols[g][c]` set = row r of column c is text
/// color. Filled by `init`.
var cols: [glyph_count][8]u8 = undefined;
var ready = false;

/// Capture the font. Call once from `start()`, before the first frame: it
/// draws into the back framebuffer (rows 0..39), which the first frame
/// overwrites.
pub fn init() void {
    const per_row = cart.screen_width / fw;
    const white: cart.DisplayColor = .rgb(0xFFFFFF);
    const fg = cart.Pixel.from_color(white).bits;
    var buf: [per_row]u8 = undefined;
    var g: usize = 0;
    var row: u32 = 0;
    while (g < glyph_count) : (row += 1) {
        const n = @min(per_row, glyph_count - g);
        for (buf[0..n], 0..) |*ch, k| ch.* = @intCast(first + g + k);
        cart.text(.{ .str = buf[0..n], .x = 0, .y = @intCast(row * fh), .text_color = white, .background_color = .rgb(0x000000) });
        for (0..n) |k| {
            for (0..8) |c| {
                const column = &cart.framebuffer[k * fw + c];
                var m: u8 = 0;
                for (0..8) |r| {
                    if (column[row * fh + r].bits == fg) m |= @as(u8, 1) << @intCast(r);
                }
                cols[g + k][c] = m;
            }
        }
        g += n;
    }
    ready = true;
}

/// `cart.text(.{ .str = str, .x = x, .y = y, .text_color = fg, .background_color = bg })`,
/// same pixels and dirty rectangle.
pub fn draw(str: []const u8, x: i32, y: i32, fg: cart.DisplayColor, bg: cart.DisplayColor) void {
    if (!ready) return cart.text(.{ .str = str, .x = x, .y = y, .text_color = fg, .background_color = bg });

    // Dirty rectangle exactly as cart.text computes it.
    var longest: i32 = 0;
    var current: i32 = 0;
    var line_count: i32 = 1;
    for (str) |ch| {
        if (ch == '\n') {
            longest = @max(longest, current);
            current = 0;
            line_count += 1;
        } else if (ch >= 32) current += 1;
    }
    longest = @max(longest, current);
    if (longest > 0) cart.mark_dirty_rect(x, y, longest * fw, line_count * fh);

    const fp = cart.Pixel.from_color(fg).bits;
    const bp = cart.Pixel.from_color(bg).bits;
    // Two vertically adjacent pixels per word, the upper one in the low half.
    const pair = [4]u32{
        @as(u32, bp) | @as(u32, bp) << 16,
        @as(u32, fp) | @as(u32, bp) << 16,
        @as(u32, bp) | @as(u32, fp) << 16,
        @as(u32, fp) | @as(u32, fp) << 16,
    };

    var cx = x;
    var cy = y;
    for (str) |ch| {
        if (ch == '\n') {
            cy += fh;
            cx = x;
            continue;
        }
        if (ch < 32) {
            cx += fw;
            continue;
        }
        const inside = cx >= 0 and cy >= 0 and cx + fw <= cart.screen_width and cy + fh <= cart.screen_height;
        if (ch > last or !inside) {
            cart.text(.{ .str = (&ch)[0..1], .x = cx, .y = cy, .text_color = fg, .background_color = bg });
        } else {
            glyph(&cols[ch - first], @intCast(cx), @intCast(cy), &pair, fp, bp);
        }
        cx += fw;
    }
}

inline fn glyph(g: *const [8]u8, x: u32, y: u32, pair: *const [4]u32, fp: u16, bp: u16) void {
    if (y & 1 == 0) {
        for (g, 0..) |m, c| {
            const w: *align(4) [4]u32 = @ptrCast(@alignCast(&cart.framebuffer[x + c][y]));
            w[0] = pair[m & 3];
            w[1] = pair[(m >> 2) & 3];
            w[2] = pair[(m >> 4) & 3];
            w[3] = pair[m >> 6];
        }
    } else {
        for (g, 0..) |m, c| {
            const column = &cart.framebuffer[x + c];
            for (0..8) |r| column[y + r].bits = if (m & (@as(u8, 1) << @intCast(r)) != 0) fp else bp;
        }
    }
}
