//! Root for `zig build test`: pulls in every module that has no cart API
//! dependency so their `test` blocks run on the host.
const std = @import("std");

test {
    std.testing.refAllDecls(@This());
    _ = @import("rng.zig");
    _ = @import("sim.zig");
    _ = @import("ai.zig");
    _ = @import("render.zig");
    _ = @import("game.zig");
    _ = @import("levels.zig");
    _ = @import("layouts.zig");
    _ = @import("history.zig");
    _ = @import("net.zig");
    _ = @import("net_test.zig");
}
