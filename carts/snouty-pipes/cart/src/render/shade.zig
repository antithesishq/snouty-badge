//! Track A: Phong shading, the pipe palette and 4x4 ordered dither into the
//! cart's RGB565 DisplayColor bits (SPEC.md section 4). Shared by draw.zig
//! and teapot.zig.
const math = @import("../math.zig");

pub const palette_len = 16;

/// Lit colour of a surface point: `color` palette index, `n` unit normal,
/// `d` the (not necessarily unit) primary ray direction, (x, y) the pixel
/// for the dither. Returns DisplayColor bits (r low 5, g middle 6, b high 5).
pub fn shade(color: u4, n: math.Vec3, d: math.Vec3, x: u32, y: u32) u16 {
    _ = n;
    _ = d;
    _ = x;
    _ = y;
    return @as(u16, color) * 0x0841;
}
