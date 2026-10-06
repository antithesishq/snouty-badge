//! Host test entry point (`zig build test`): the modules without a cart API
//! dependency. The pose library's own tests run from lib/tests.zig.
test {
    _ = @import("math.zig");
    _ = @import("mesh.zig");
    _ = @import("raster.zig");
    _ = @import("hand.zig");
    _ = @import("body.zig");
    _ = @import("select_hold.zig");
}
