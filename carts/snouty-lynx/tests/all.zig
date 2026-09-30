//! Host test entry point: `zig build test` from the repository root
//! (`-Dtest-filter=boot` for a subset: test names carry an area prefix).
//! M0 Track A: the boot path and the CPU test data. The `boot` module is
//! core/boot.zig (M1 may re-export it from core/lynx.zig).
test {
    _ = @import("boot_unit.zig");
    _ = @import("boot_local.zig");
    _ = @import("boot_crosscheck.zig");
}
