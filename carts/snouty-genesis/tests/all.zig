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
    _ = @import("golden_mini.zig");
    _ = @import("md_wait_loop.zig");
    _ = @import("vdp_unit.zig");
    _ = @import("m68k_single_step.zig");
    _ = @import("drive_unit.zig");
    _ = @import("rom_unit.zig");
    _ = @import("frag_mini.zig");
    _ = @import("undo_unit.zig");
    _ = @import("determinism.zig");
    _ = @import("scrub_sizing.zig");
    _ = @import("input_unit.zig");
    _ = @import("mp_determinism.zig");
    _ = @import("ports_unit.zig");
    _ = @import("mp_bomberman.zig");
    _ = @import("link_play.zig");
}
