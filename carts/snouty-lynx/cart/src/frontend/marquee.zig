//! The arcade marquee over the picture, badge rows 0..25 (PLAN.md "M8
//! Marquee: contract"). STUB: the interface Track B builds against; Track A
//! replaces the body with the drawn marquee and the drive BMP.
const cart = @import("cart-api");
const video = @import("video.zig");

/// Rows the marquee fills, 0..h-1 (the picture starts at `video.top`).
pub const h = 26;

/// Pick the title, colour scheme and drive BMP for the ROM that just
/// booted. Call after every boot (start, picker, Reset).
pub fn load() void {}

/// Paint rows 0..h-1 completely. Marks no dirty rect (the game presents
/// the full frame).
pub fn draw() void {
    video.fill_rows(0, h, .rgb(0x301008));
}

/// The About page's line: "Marquee: drawn", "Marquee: HD.BMP",
/// "BMP: not 160x26".
pub fn about_line(buf: *[24]u8) []const u8 {
    _ = buf;
    return "Marquee: drawn";
}
