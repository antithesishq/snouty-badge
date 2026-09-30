//! Host test entry point: `zig build test` from the repository root
//! (`-Dtest-filter=bus` for a subset: test names carry a track prefix).
const core = @import("core");

test {
    _ = core;
    _ = @import("rom_unit.zig");
    _ = @import("z80_unit.zig");
    _ = @import("z80_single_step.zig");
    _ = @import("z80_zex.zig");
    _ = @import("vdp_unit.zig");
    _ = @import("bus_unit.zig");
    _ = @import("psg_unit.zig");
    _ = @import("smoke.zig");
    _ = @import("golden.zig");
    _ = @import("ring_unit.zig");
    _ = @import("kstore_unit.zig");
    _ = @import("determinism.zig");
    _ = @import("scrub_sizing.zig");
}
