//! Root for `zig build test`: the pure suites that tools/check.sh runs one
//! by one with `zig test` (sim, levels, level_parse, rewind, demo). rewind.zig
//! pulls sim, levels and level_parse (and through sim: ai, projectiles,
//! fixed, state) transitively; demo.zig is the only one outside that graph.
//! Nothing here touches the cart API or the generated gfx module.
const std = @import("std");

test {
    std.testing.refAllDecls(@This());
    _ = @import("rewind.zig");
    _ = @import("demo.zig");
    _ = @import("match.zig");
    // M7: two badges over the virtual cable (needs the build's `lockstep`
    // and `link_host` imports, so only `zig build test` runs it).
    _ = @import("dm_net_test.zig");
}
