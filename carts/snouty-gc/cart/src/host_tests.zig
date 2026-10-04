//! Forked from snouty-zero/cart/src/host_tests.zig at f8f6962.
//! Root for `zig build test`: pulls in every module that has no cart API
//! dependency so their `test` blocks run on the host.
const std = @import("std");

test {
    std.testing.refAllDecls(@This());
    _ = @import("fixed.zig");
    _ = @import("roster_text.zig");
    _ = @import("track.zig");
    _ = @import("sim.zig");
    _ = @import("ai.zig");
    _ = @import("racers.zig");
    _ = @import("engine.zig");
    _ = @import("sim_test.zig");
    _ = @import("weapons.zig");
    _ = @import("weapons_test.zig");
}
