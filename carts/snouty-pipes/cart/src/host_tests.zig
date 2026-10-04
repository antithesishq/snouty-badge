//! Root for `zig build test`: pulls in every module that has no cart API
//! dependency so their `test` blocks run on the host.
const std = @import("std");

test {
    std.testing.refAllDecls(@This());
    _ = @import("math.zig");
    _ = @import("rng.zig");
    _ = @import("grid.zig");
    _ = @import("camera.zig");
    _ = @import("director.zig");
    _ = @import("render/draw.zig");
    _ = @import("render/zbuf.zig");
    _ = @import("render/shade.zig");
    _ = @import("render/trace.zig");
    _ = @import("render/teapot.zig");
}
