//! Forked from snouty-zero/cart/src/font.zig at f8f6962.
//! Own 8x8 text blit (M4 fast path): the SDK font from assets/gen/font.bin
//! (tools/gen_font.py), one column loop per glyph writing only foreground
//! pixels, with an optional one-pixel drop shadow in the same pass. The
//! API's `cart.text` was 36% of a frame in the M3 bench.
const cart = @import("cart-api");
const assets = @import("assets");

const glyphs: *const [96 * 8]u8 = assets.font[0 .. 96 * 8];

/// Draws `str` with its top-left at (x, y). Glyph rows are bytes with bit 7
/// the left column, 1 = foreground. Clipped to the screen; characters
/// outside ' '..DEL draw as '?'.
/// noinline: ReleaseFast otherwise copies the unrolled glyph loops into
/// every HUD call site (about 40 KB of .text in M4's first build).
pub noinline fn draw(str: []const u8, x: i32, y: i32, color: cart.Pixel, shadow: ?cart.Pixel) void {
    var cx = x;
    for (str) |ch| {
        defer cx += 8;
        if (cx >= 160 or cx + 8 <= 0 or y >= 128 or y + 8 <= 0) continue;
        const code: usize = if (ch < 32 or ch > 127) '?' - 32 else ch - 32;
        const g = glyphs[code * 8 ..][0..8];
        if (ch == ' ') continue;
        // Shadow first (x+1, y+1), then the glyph over it.
        if (shadow) |sh| plot_glyph(g, cx + 1, y + 1, sh);
        plot_glyph(g, cx, y, color);
    }
}

noinline fn plot_glyph(g: *const [8]u8, x: i32, y: i32, color: cart.Pixel) void {
    // Wholly on screen (nearly always): no per-pixel clipping, the 8x8
    // loops unrolled at comptime (M3: the cart builds ReleaseSmall, which
    // would leave them rolled).
    if (x >= 0 and x <= 152 and y >= 0 and y <= 120) {
        const yy: usize = @intCast(y);
        inline for (0..8) |col| {
            const column = &cart.framebuffer[@as(usize, @intCast(x)) + col];
            const mask: u8 = @as(u8, 0x80) >> col;
            inline for (0..8) |row| {
                if ((g[row] & mask) != 0) column[yy + row] = color;
            }
        }
        return;
    }
    var col: u3 = 0;
    while (true) : (col += 1) {
        const sx = x + col;
        if (sx >= 0 and sx < 160) {
            const column = &cart.framebuffer[@intCast(sx)];
            const mask: u8 = @as(u8, 0x80) >> col;
            var row: u3 = 0;
            while (true) : (row += 1) {
                if ((g[row] & mask) != 0) {
                    const sy = y + row;
                    if (sy >= 0 and sy < 128) column[@intCast(sy)] = color;
                }
                if (row == 7) break;
            }
        }
        if (col == 7) break;
    }
}
