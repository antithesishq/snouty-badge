//! Root for `zig build test`: pulls in every module that has no cart API
//! dependency so their `test` blocks run on the host.
const std = @import("std");

test {
    std.testing.refAllDecls(@This());
    _ = @import("math.zig");
    _ = @import("rng.zig");
    _ = @import("maze.zig");
    _ = @import("camera.zig");
    _ = @import("render/clip.zig");
}
