//! Debug overlay (frame timing) drawn over the finished frame when built
//! with -Ddebug_overlay=true. M0 stub; Track B fills it in.
const cart = @import("cart-api");

pub fn draw(render_us: u32, frame: u32) void {
    _ = render_us;
    _ = frame;
}
