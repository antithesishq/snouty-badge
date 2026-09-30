//! Flight model (SPEC.md 5.5): stick steering with roll shear, pitch, the
//! altitude spring, boost. Stub: Track B implements update().
const cart = @import("cart-api");
const fixed = @import("fixed.zig");

pub const Cam = struct {
    /// Position in Q16 cells; y only increases.
    x: i32 = 128 * fixed.one,
    y: i32 = 0,
    alt: i32 = 56 * fixed.one,
    /// 1/1024 turn, 0 = +y.
    yaw: i32 = 0,
    /// Screen row of the horizon; 64 is level.
    horizon: i32 = 64,
    /// Q16 rows of horizon shear across the screen (positive = right side lower).
    roll: i32 = 0,
};

pub var cam: Cam = .{};

pub fn update(controls: cart.Controls, frame: u32) void {
    _ = controls;
    _ = frame;
    cam.y += 3 * fixed.one / 4;
}
