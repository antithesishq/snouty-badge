//! Track A: u16 z buffer, 160x128, column-major like the framebuffer.
//! Depth is view depth (ray t) scaled by `scale`; 0xFFFF = empty.
const camera = @import("../camera.zig");

pub const far: u16 = 0xFFFF;
/// Depth units per world unit.
pub const scale: f32 = 512.0;

pub var buf: [camera.screen_w][camera.screen_h]u16 = undefined;

pub fn clear() void {
    for (&buf) |*col| @memset(col, far);
}
