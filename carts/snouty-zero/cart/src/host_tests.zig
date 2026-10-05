//! Root for `zig build test`: pulls in every module that has no cart API
//! dependency so their `test` blocks run on the host.
const std = @import("std");

test {
    std.testing.refAllDecls(@This());
    _ = @import("fixed.zig");
    _ = @import("track.zig");
    _ = @import("sim.zig");
    _ = @import("ai.zig");
    _ = @import("history.zig");
    _ = @import("engine.zig");
    _ = @import("link_race.zig");
    _ = @import("link_race_test.zig");
}
