const std = @import("std");
const Build = std.Build;

// A module of the root build.zig, not a package root: run `zig build test`
// from the repository root.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/snouty-lynx/";

// M0 Track A (boot) build: host tests only. Track B (scaffold) owns the cart
// build; on merge keep its `add` and move the "Host tests" block below into
// it (the `boot` import is what tests/all.zig needs).
pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    _ = sycl_badge_dep;

    // Host tests: tests/all.zig; test data from tools/fetch_test_roms.sh and
    // tools/bootrom_crosscheck.py (tests/roms/, gitignored).
    const boot_host = b.createModule(.{
        .root_source_file = b.path(dir ++ "core/boot.zig"),
        .target = b.graph.host,
        .optimize = opts.test_optimize,
    });
    const tests = b.addTest(.{
        .filters = if (opts.test_filter) |f| &.{f} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "tests/all.zig"),
            .target = b.graph.host,
            .optimize = opts.test_optimize,
            .imports = &.{.{ .name = "boot", .module = boot_host }},
        }),
    });
    opts.test_step.dependOn(&b.addRunArtifact(tests).step);
}
