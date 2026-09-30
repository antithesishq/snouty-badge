//! The column march, sky and sun, fog dither, cliff shading (SPEC.md 5.1-5.3).
//! Stub: Track A implements init() and draw(); this version paints the sky
//! gradient so the scaffold shows something.
const cart = @import("cart-api");
const fixed = @import("fixed.zig");
const world = @import("world.zig");
const palette = @import("palette.zig");
const camera = @import("camera.zig");

/// Far end of the march in Q16 cells (knob, SPEC.md 10).
pub const z_far: i32 = 256 << fixed.Q;
/// Step growth per march step, 1.0075 in Q16 (knob).
pub const lod_mul: i32 = 0x1_01EC;

pub fn init() void {}

pub fn draw(frame: u32) void {
    _ = frame;
    for (cart.framebuffer, 0..) |*column, x| {
        _ = x;
        for (column, 0..) |*px, y| {
            const t: u32 = @intCast(y);
            px.* = .from_color(.{ .r = @intCast(t / 8), .g = @intCast(t / 4), .b = @intCast(8 + t / 8) });
        }
    }
}
