//! Cell blitter for the 4-bit `gfx` sheets (HUD icons, portrait, weapon,
//! title). Palette index 0 is transparent; clipped to the screen. Texels
//! are read straight from `sheet.indices.bytes` (never
//! `PackedIntSlice.get` per pixel): index `i` lives in `bytes[i >> 1]`,
//! low nibble for even `i` (little-endian PackedIntSlice, asserted below).
const cart = @import("cart-api");
const gfx = @import("gfx");

pub const Opts = struct {
    /// Half-brightness palette (missing keys).
    dim: bool = false,
    /// Every opaque texel Anti-White (flash).
    white: bool = false,
};

const sw: i32 = @intCast(cart.screen_width);
const sh: i32 = @intCast(cart.screen_height);
const white_pixel: cart.Pixel = .from_color(.rgb(0xFCFBF9));

/// Normal and dim `[16]Pixel` palettes for `sheet`, built at comptime.
fn palettes(comptime sheet: type) [2][16]cart.Pixel {
    var out: [2][16]cart.Pixel = undefined;
    for (0..16) |i| {
        const c = if (i < sheet.colors.len) sheet.colors[i] else sheet.colors[0];
        out[0][i] = .from_color(c);
        out[1][i] = .from_color(.{ .r = c.r >> 1, .g = c.g >> 1, .b = c.b >> 1 });
    }
    return out;
}

/// Nibble `i` of a packed u4 sheet, the way the hot loop reads it.
inline fn nibble(bytes: []const u8, i: usize) u4 {
    const b = bytes[i >> 1];
    return @truncate(if (i & 1 == 0) b else b >> 4);
}

// Verify the nibble order once against PackedIntSlice.get.
comptime {
    @setEvalBranchQuota(20000);
    const s = gfx.face;
    for (0..2 * 216) |i| {
        if (nibble(s.indices.bytes, i) != s.indices.get(i))
            @compileError("gfx nibble order is not low-nibble-first");
    }
}

/// Draws cell `index` (`cw` x `ch`, source x = index * cw) of a horizontal
/// strip with its top-left at (x, y).
pub fn cell(comptime sheet: type, comptime cw: u32, comptime ch: u32, index: u32, x: i32, y: i32, opts: Opts) void {
    comptime {
        if (sheet.height != ch) @compileError("cell height does not match the sheet");
        if (sheet.width % cw != 0) @compileError("cell width does not divide the sheet");
        if (sheet.colors.len > 16) @compileError("sheet has more than 16 colors");
    }
    const pals = comptime palettes(sheet);
    const pal = &pals[@intFromBool(opts.dim)];
    const bytes = sheet.indices.bytes;
    const w: i32 = @intCast(cw);
    const h: i32 = @intCast(ch);
    const c0: i32 = @max(0, -x);
    const c1: i32 = @min(w, sw - x);
    const r0: i32 = @max(0, -y);
    const r1: i32 = @min(h, sh - y);
    if (c0 >= c1 or r0 >= r1) return;
    const src_x0: usize = @as(usize, index) * cw;
    var col = c0;
    while (col < c1) : (col += 1) {
        const column = &cart.framebuffer[@intCast(x + col)];
        var i: usize = @as(usize, @intCast(r0)) * sheet.width + src_x0 + @as(usize, @intCast(col));
        var dy: usize = @intCast(y + r0);
        const end: usize = @intCast(y + r1);
        while (dy < end) : ({
            dy += 1;
            i += sheet.width;
        }) {
            const idx = nibble(bytes, i);
            if (idx == 0) continue;
            column[dy] = if (opts.white) white_pixel else pal[idx];
        }
    }
}
