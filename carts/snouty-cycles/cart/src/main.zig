//! Snouty Cycles: a top-down light-cycle arena (Tron). Scaffold: the cart
//! starts and shows nothing yet; sim.zig holds the rules.
const cart = @import("cart-api");

comptime {
    cart.export_start_code();
}

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.copy_forward);
}

pub fn update() void {}
