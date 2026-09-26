const std = @import("std");
const Build = std.Build;

const sycl_badge = @import("sycl_badge");

/// ROM to embed in the cart. Set with `zig build -Drom=roms/game.gb`.
/// Read by `build_cart_modules`, whose signature has no user context.
var rom_path: []const u8 = "tests/roms/dmg-acid2.gb";

pub fn build(b: *Build) void {
    const sycl_badge_dep = b.dependency("sycl_badge", .{});

    rom_path = b.option([]const u8, "rom", "Game Boy ROM to embed in the cart (default tests/roms/dmg-acid2.gb)") orelse rom_path;
    const cart_optimize = b.option(std.builtin.OptimizeMode, "cart-optimize", "Optimize mode for the cart (default fast; SPEC.md section 8)") orelse .fast;

    sycl_badge.add_os_cart(b, sycl_badge_dep, .{
        .name = "snouty-boy",
        .optimize = cart_optimize,
        .root_source_file = b.path("cart/src/main.zig"),
        .custom_builder = &build_cart_modules,
    });

    // Host tests: the core is badge-agnostic and runs natively. Test ROMs come
    // from tools/fetch_test_roms.sh (tests/roms/, gitignored).
    const test_optimize = b.option(std.builtin.OptimizeMode, "test-optimize", "Optimize mode for host tests (default safe)") orelse .safe;
    const core_host = b.createModule(.{
        .root_source_file = b.path("core/gb.zig"),
        .target = b.graph.host,
        .optimize = test_optimize,
    });
    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this");
    const tests = b.addTest(.{
        .filters = if (test_filter) |f| &.{f} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/all.zig"),
            .target = b.graph.host,
            .optimize = test_optimize,
            .imports = &.{.{ .name = "core", .module = core_host }},
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the core tests on the host").dependOn(&run_tests.step);
}

/// Adds the `core` and `rom` modules to the cart. `rom.data` is the embedded
/// ROM; the file is copied next to a generated rom.zig so @embedFile can see it.
fn build_cart_modules(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = cart_api;
    const core_mod = b.createModule(.{ .root_source_file = b.path("core/gb.zig") });
    cart.addImport("core", core_mod);

    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(b.path(rom_path), "rom.gb");
    const rom_zig = wf.add("rom.zig",
        \\pub const data: []const u8 = @embedFile("rom.gb");
        \\
    );
    cart.addImport("rom", b.createModule(.{ .root_source_file = rom_zig }));
    step.dependOn(&wf.step);
}
