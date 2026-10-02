//! Host test entry point. `zig build test` (needs tools/fetch_test_roms.sh).
const core = @import("core");

// Only this module's tests run: `_ = core` compiles the core but does not
// run tests written inside core/*.zig, so core tests live in tests/.
test {
    _ = core;
    _ = core.rom_mod;
    _ = @import("blargg.zig");
    _ = @import("acid2.zig");
    _ = @import("ppu_unit.zig");
    _ = @import("apu_unit.zig");
    _ = @import("ring_unit.zig");
    _ = @import("rom_unit.zig");
    _ = @import("determinism.zig");
    _ = @import("cgb_unit.zig");
    _ = @import("cgb_acid2.zig");
    _ = @import("kstore_unit.zig");
    _ = @import("serial_unit.zig");
    _ = @import("flow_unit.zig");
}
