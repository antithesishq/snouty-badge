//! Host test entry point (`zig build test`): the modules without a cart API
//! dependency. The pose library's own tests run from lib/tests.zig.
test {
    _ = @import("math.zig");
    _ = @import("surface.zig");
    _ = @import("palette.zig");
    _ = @import("field.zig");
    _ = @import("noise.zig");
    _ = @import("hand.zig");
    _ = @import("uniforms.zig");
    _ = @import("app.zig");
    _ = @import("programs_test.zig");
}
