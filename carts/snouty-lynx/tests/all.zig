//! Host test entry point: `zig build test` (every cart) or `zig build
//! test-lynx` (this cart) from the repository root; `-Dtest-filter=cart`
//! for a subset (test names carry an area prefix: `cart:`, `drive:`,
//! `lynx:`). A new test file is one `_ = @import(...)` line here.
const std = @import("std");
const core = @import("core");

test {
    std.testing.refAllDecls(core);
    _ = @import("cart_unit.zig");
    _ = @import("drive_unit.zig");
    // TODO(M0 Track A): _ = @import("boot_unit.zig");
}
