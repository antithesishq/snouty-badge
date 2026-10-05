//! Host test entry point: `zig build test` (every cart) or `zig build
//! test-lynx` (this cart) from the repository root; `-Dtest-filter=cart`
//! for a subset (test names carry an area prefix: `cart:`, `drive:`,
//! `lynx:`, `boot:`, `cpu65:`, `suzy:`, `mikey:`, `golden:`, `stream:`,
//! `audio:`, `input:`, `ff:`, `comlynx:`). A new test file is one `_ = @import(...)`
//! line here.
const std = @import("std");
const core = @import("core");

test {
    std.testing.refAllDecls(core);
    _ = @import("cart_unit.zig");
    _ = @import("drive_unit.zig");
    _ = @import("boot_unit.zig");
    _ = @import("boot_local.zig");
    _ = @import("boot_crosscheck.zig");
    _ = @import("cpu65_single_step.zig");
    _ = @import("suzy_unit.zig");
    _ = @import("math_unit.zig");
    _ = @import("mikey_unit.zig");
    _ = @import("golden.zig");
    _ = @import("undo_unit.zig");
    _ = @import("determinism.zig");
    _ = @import("scrub_sizing.zig");
    _ = @import("stream_unit.zig");
    _ = @import("audio_unit.zig");
    _ = @import("input_unit.zig");
    _ = @import("ff_determinism.zig");
    _ = @import("comlynx_unit.zig");
    _ = @import("comlynx_warbirds.zig");
    _ = @import("comlynx_cable.zig");
}
