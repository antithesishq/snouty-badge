//! Quantisation of linear f32 RGB to RGB565 `Pixel`. M0 stub: truncation
//! only. Track B (PLAN.md) replaces this with temporal Bayer dithering and
//! the B-button mode cycle; the public API below is the contract.
const cart = @import("cart-api");
const math = @import("math.zig");

pub const Mode = enum(u32) { bayer_temporal = 0, none = 1 };

pub var mode: Mode = .bayer_temporal;

pub fn next_mode() void {
    mode = if (mode == .bayer_temporal) .none else .bayer_temporal;
}

/// Called once per frame before any quantise() call.
pub fn begin_frame(frame: u32) void {
    _ = frame;
}

/// Quantise linear RGB in [0, 1] (already saturated) for screen pixel (x, y).
pub inline fn quantise(x: u32, y: u32, rgb: math.Vec3) cart.Pixel {
    _ = x;
    _ = y;
    const c = cart.DisplayColor{
        .r = @intFromFloat(rgb[0] * 31.0),
        .g = @intFromFloat(rgb[1] * 63.0),
        .b = @intFromFloat(rgb[2] * 31.0),
    };
    return cart.Pixel.from_color(c);
}
