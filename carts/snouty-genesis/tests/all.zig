//! Host test entry point: `zig build test-genesis` (this cart) or
//! `zig build test` (every cart) from the repository root, with
//! `-Dcart=snouty-genesis -Dcart-mode=xip` or with no `-Dcart`
//! (`-Dtest-filter=smoke` for a subset: test names carry an area prefix).
const core = @import("core");

test {
    _ = core;
    _ = core.rom;
    _ = @import("smoke.zig");
    _ = @import("sound_unit.zig");
    _ = @import("bus_unit.zig");
    _ = @import("golden.zig");
}
