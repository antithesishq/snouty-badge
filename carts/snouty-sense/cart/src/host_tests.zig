//! The cart's host tests (`zig build test`): the modules without the cart
//! API. The driver's are lib/tests/tof_unit.zig.
test {
    _ = @import("audio.zig");
}
