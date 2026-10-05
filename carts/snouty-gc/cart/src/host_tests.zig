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
    _ = @import("pickups.zig");
    _ = @import("pickups_test.zig");
    _ = @import("hazards.zig");
    _ = @import("gc_mode.zig");
    _ = @import("content_test.zig");
    _ = @import("net_test.zig");
    _ = @import("career.zig");
    _ = @import("career_test.zig");
    _ = @import("career_save_test.zig");
    _ = @import("panel_text_test.zig");
    _ = @import("net_compat_test.zig");
    // M6 BATTLE: the rules and the hunter (Track A), the presentation (Track B).
    _ = @import("battle.zig");
    _ = @import("hunt.zig");
    _ = @import("battle_test.zig");
    _ = @import("battle_ui_test.zig");
    // M7 track packs: every pack module's tests (pack_test.zig imports them).
    _ = @import("pack_test.zig");
}
