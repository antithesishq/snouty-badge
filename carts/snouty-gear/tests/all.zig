//! Host test entry point: `zig build test` from the repository root
//! (`-Dtest-filter=pattern` for a subset).
const core = @import("core");

test {
    _ = core;
    _ = @import("pattern.zig");
    _ = @import("rom_unit.zig");
    _ = @import("z80_single_step.zig");
}
