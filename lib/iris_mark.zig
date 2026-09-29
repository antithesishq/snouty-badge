//! The Antithesis Iris mark as a 1-bit 24x24 bitmap, for the emulator
//! carts' boot splashes (Snouty Boy, Snouty Gear, Snouty Genesis: SPEC.md
//! section 12 of each). Traced from `snouty-art/ref/iris_mark.png` with a
//! 24 px box filter at a 50% threshold and made symmetric under a half
//! turn, which the mark is. Drawn at 2x it fills the 48 px square the
//! splashes lay out.
//!
//! No `cart-api` import: `draw` takes the cart module as a type so this
//! file stays host-testable (`lib/tests.zig`).

pub const size = 24;

/// One row per entry, bit 23 is the leftmost pixel.
pub const rows = [size]u24{
    0b000000000111111100000000,
    0b000000111111111100000000,
    0b000001111111111100000000,
    0b000111111111111100000000,
    0b000110000000000000000000,
    0b001100000000000000000000,
    0b011100000000000000000000,
    0b011100000001100000000000,
    0b011100000011110000001111,
    0b111100000111111000001111,
    0b111100001111111100001111,
    0b111100011111111110001111,
    0b111100011111111110001111,
    0b111100001111111100001111,
    0b111100000111111000001111,
    0b111100000011110000001110,
    0b000000000001100000001110,
    0b000000000000000000001110,
    0b000000000000000000001100,
    0b000000000000000000011000,
    0b000000001111111111111000,
    0b000000001111111111100000,
    0b000000001111111111000000,
    0b000000001111111000000000,
};

pub fn pixel(x: usize, y: usize) bool {
    return rows[y] & (@as(u24, 1) << @intCast(size - 1 - x)) != 0;
}

/// Draws the mark with its top left corner at (x, y), every pixel a
/// `scale` px square of `color`, one `rect` per run of set pixels.
/// `Cart` is the cart-api module (`@import("cart-api")`).
pub fn draw(comptime Cart: type, x: i32, y: i32, scale: u8, color: Cart.DisplayColor) void {
    for (rows, 0..) |row, r| {
        var c: usize = 0;
        while (c < size) {
            if (row & (@as(u24, 1) << @intCast(size - 1 - c)) == 0) {
                c += 1;
                continue;
            }
            const run_start = c;
            while (c < size and row & (@as(u24, 1) << @intCast(size - 1 - c)) != 0) c += 1;
            Cart.rect(.{
                .x = x + @as(i32, @intCast(run_start)) * scale,
                .y = y + @as(i32, @intCast(r)) * scale,
                .width = @as(u32, @intCast(c - run_start)) * scale,
                .height = scale,
                .fill_color = color,
            });
        }
    }
}

test "the Iris mark is symmetric under a half turn" {
    for (0..size) |y| {
        for (0..size) |x| {
            try @import("std").testing.expect(pixel(x, y) == pixel(size - 1 - x, size - 1 - y));
        }
    }
}

test "the Iris mark has its diamond in the middle and the arcs on the edges" {
    const std = @import("std");
    try std.testing.expect(pixel(11, 11) and pixel(12, 12)); // diamond
    try std.testing.expect(pixel(0, 12) and pixel(23, 11)); // arc tails on the sides
    try std.testing.expect(!pixel(0, 0) and !pixel(23, 23)); // open corners
    try std.testing.expect(!pixel(6, 12) and !pixel(17, 11)); // gap between arc and diamond
}
