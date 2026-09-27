const std = @import("std");
const Build = std.Build;

const sycl_badge = @import("sycl_badge");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=snouty-boy` from the repository root instead.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/snouty-boy/";

/// ROM to embed in the cart. Set with `zig build -Drom=carts/snouty-boy/roms/game.gb`
/// (a path relative to this cart's directory is accepted too). Read by
/// `build_cart_modules`, whose signature has no user context.
var rom_path: []const u8 = dir ++ "tests/roms/dmg-acid2.gb";

/// Committed, freely licensed fallback when the default test ROM has not been
/// fetched (tools/fetch_test_roms.sh), so a fresh clone still builds every cart.
const fallback_rom = dir ++ "roms/2048.gb";

pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    if (opts.rom) |rom| {
        rom_path = if (exists(b, rom) or !exists(b, b.fmt(dir ++ "{s}", .{rom}))) rom else b.fmt(dir ++ "{s}", .{rom});
    } else if (!exists(b, rom_path)) {
        std.debug.print("snouty-boy: {s} not found (run carts/snouty-boy/tools/fetch_test_roms.sh); embedding {s}\n", .{ rom_path, fallback_rom });
        rom_path = fallback_rom;
    }
    const cart_optimize = opts.cart_optimize;

    sycl_badge.add_os_cart(b, sycl_badge_dep, .{
        .name = "snouty-boy",
        .optimize = cart_optimize,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &build_cart_modules,
    });

    // Host tests: the core is badge-agnostic and runs natively. Test ROMs come
    // from tools/fetch_test_roms.sh (tests/roms/, gitignored).
    const test_optimize = opts.test_optimize;
    const core_host = b.createModule(.{
        .root_source_file = b.path(dir ++ "core/gb.zig"),
        .target = b.graph.host,
        .optimize = test_optimize,
    });
    const test_filter = opts.test_filter;
    const tests = b.addTest(.{
        .filters = if (test_filter) |f| &.{f} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "tests/all.zig"),
            .target = b.graph.host,
            .optimize = test_optimize,
            .imports = &.{.{ .name = "core", .module = core_host }},
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    opts.test_step.dependOn(&run_tests.step);
}

fn exists(b: *Build, rel: []const u8) bool {
    b.root.access(b.graph.io, rel, .{}) catch return false;
    return true;
}

/// Adds the `core` and `rom` modules to the cart. `rom.data` is the embedded
/// ROM; the file is copied next to a generated rom.zig so @embedFile can see it.
fn build_cart_modules(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = cart_api;
    const core_mod = b.createModule(.{ .root_source_file = b.path(dir ++ "core/gb.zig") });
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
