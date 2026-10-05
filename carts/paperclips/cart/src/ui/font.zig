//! The 5x7 font (gen/font5x7.zig, written by tools/gen_font.py) in a 6x8
//! cell: 26 columns by 16 rows on the 160x128 screen.
const gen = @import("gen/font5x7.zig");

pub const cell_w: i32 = 6;
pub const cell_h: i32 = 8;
pub const cols: usize = 26;

/// Extra glyphs past ASCII (gen_font.py lists them).
pub const copyright: u8 = 0x7F;
pub const tri_left: u8 = 0x80;
pub const tri_right: u8 = 0x81;
pub const small_square: u8 = 0x82;

const unknown = [5]u8{ 0x7F, 0x41, 0x41, 0x41, 0x7F };

pub fn columns(ch: u8) *const [5]u8 {
    if (ch < gen.first or ch - gen.first >= gen.count) return &unknown;
    return &gen.columns[ch - gen.first];
}

/// Pixel width of `n` characters (no trailing blank column).
pub fn width(n: usize) i32 {
    if (n == 0) return 0;
    return @as(i32, @intCast(n)) * cell_w - 1;
}
