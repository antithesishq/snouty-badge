//! Host test entry point for the shared library code in lib/ (`zig build test`).
test {
    _ = @import("romfs.zig");
    _ = @import("tests/romfs_unit.zig");
}
