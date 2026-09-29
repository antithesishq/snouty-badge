const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
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

/// Where the badge build looks for its ROM (`-Drom-source`, SPEC.md 11.1).
/// Same reason as `rom_path` for being a file-level var.
var rom_source: RomSource = .drive;
const RomSource = enum { drive, embed };

pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    if (opts.rom) |rom| {
        rom_path = if (exists(b, rom) or !exists(b, b.fmt(dir ++ "{s}", .{rom}))) rom else b.fmt(dir ++ "{s}", .{rom});
    } else if (!exists(b, rom_path)) {
        std.debug.print("snouty-boy: {s} not found (run carts/snouty-boy/tools/fetch_test_roms.sh); embedding {s}\n", .{ rom_path, fallback_rom });
        rom_path = fallback_rom;
    }
    rom_source = switch (opts.rom_source) {
        .drive => .drive,
        .embed => .embed,
        // `pack` is Snouty Gear's XIP bank packer (docs/ROM_DRIVE.md section 7).
        // A Game Boy ROM small enough to pack also fits in a RAM cart as is.
        .pack => std.process.fatal("snouty-boy: -Drom-source=pack is not supported for this cart; use drive (default) or embed", .{}),
    };
    const cart_optimize = opts.cart_optimize;
    // -Dneopixels=true (root build.zig) re-enables the menu's history meter,
    // compiled out by default (docs/NEOPIXELS.md).
    const options = b.addOptions();
    options.addOption(bool, "neopixels", opts.neopixels);
    build_options = options;
    font_path = sycl_badge_dep.path("src/font.zig");

    os_cart.add(b, sycl_badge_dep, .{
        .mode = opts.cart_mode,
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

/// The `build_options` module's contents, set by `add` for `build_cart_modules`.
var build_options: ?*Build.Step.Options = null;

/// `sycl-badge/src/font.zig`, set by `add` for `build_cart_modules`.
var font_path: ?Build.LazyPath = null;

fn exists(b: *Build, rel: []const u8) bool {
    b.root.access(b.graph.io, rel, .{}) catch return false;
    return true;
}

/// Adds the `core`, `romfs`, `iris`, `rom` and `build_options` modules to the cart. `rom.data` is the
/// embedded ROM (the file is copied next to a generated rom.zig so @embedFile
/// can see it), `rom.name` its file name for the About screen, `rom.source`
/// the `-Drom-source` choice. The same module serves the badge and the wasm
/// build; the frontend ignores `source` in wasm, which has no drive.
fn build_cart_modules(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = cart_api;
    cart.addImport("build_options", build_options.?.createModule());
    const core_mod = b.createModule(.{ .root_source_file = b.path(dir ++ "core/gb.zig") });
    cart.addImport("core", core_mod);
    // The FAT12 reader shared with Snouty Gear (docs/ROM_DRIVE.md section 4).
    cart.addImport("romfs", b.createModule(.{ .root_source_file = b.path("lib/romfs.zig") }));
    // The Iris mark the splash draws (SPEC.md section 12), shared with Snouty Gear.
    cart.addImport("iris", b.createModule(.{ .root_source_file = b.path("lib/iris_mark.zig") }));

    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(b.path(rom_path), "rom.gb");
    const rom_zig = wf.add("rom.zig", b.fmt(
        \\pub const data: []const u8 = @embedFile("rom.gb");
        \\pub const name: []const u8 = "{f}";
        \\pub const Source = enum {{ drive, embed }};
        \\pub const source: Source = .{s};
        \\
    , .{ std.zig.fmtString(std.fs.path.basename(rom_path)), @tagName(rom_source) }));
    cart.addImport("rom", b.createModule(.{ .root_source_file = rom_zig }));
    // The OS 8x8 font, for the debug overlay's own blitter (frontend/debug.zig).
    // A copy: the file itself already belongs to the SDK's `board` module.
    cart.addImport("font", b.createModule(.{ .root_source_file = wf.addCopyFile(font_path.?, "font.zig") }));
    step.dependOn(&wf.step);
}
