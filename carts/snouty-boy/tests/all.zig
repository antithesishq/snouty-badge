//! Host test entry point. `zig build test` (needs tools/fetch_test_roms.sh).
const core = @import("core");

test {
    _ = core;
    _ = @import("blargg.zig");
    _ = @import("acid2.zig");
    _ = @import("ppu_unit.zig");
}
