//! Host test entry point. `zig build test` (needs tools/fetch_test_roms.sh).
const core = @import("core");

test {
    _ = core;
    _ = core.rom_mod;
    _ = @import("blargg.zig");
    _ = @import("acid2.zig");
    _ = @import("ppu_unit.zig");
    _ = @import("apu_unit.zig");
    _ = @import("ring_unit.zig");
    _ = @import("determinism.zig");
}
