const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=snouty-lynx` from the repository root instead.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/snouty-lynx/";

/// The embedded ROM unless `-Dlynx-rom` names another: the M0 placeholder
/// (tools/make_placeholder_rom.py, 576 bytes, not a Lynx program). M0
/// Track A replaces it with the shipped homebrew ROM.
const default_rom = dir ++ "roms/placeholder.lnx";

/// ROM to embed and where the badge build looks for its ROM. Module-level
/// because `build_cart_modules` has no user context parameter.
var rom_file: RomFile = undefined;
var rom_source: Source = .drive;

/// What the cart sees as `rom.source` (`pack` is not built yet and builds as `drive`).
const Source = enum { drive, embed };

const RomFile = struct { lazy: Build.LazyPath, name: []const u8 };

pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    rom_file = resolve_rom(b, opts.lynx_rom);
    rom_source = switch (opts.lynx_rom_source) {
        .drive => .drive,
        .embed => .embed,
        .pack => blk: {
            std.debug.print("snouty-lynx: -Dlynx-rom-source=pack: not built yet (SPEC.md 13.1); building the RAM cart with the drive ROM and {s} embedded\n", .{rom_file.name});
            break :blk .drive;
        },
    };

    os_cart.add(b, sycl_badge_dep, .{
        .mode = opts.cart_mode,
        .name = "snouty-lynx",
        .optimize = opts.cart_optimize,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &build_cart_modules,
    });

    // Host tests: the core and the drive scan are badge-agnostic and run
    // natively. Every test file hangs off tests/all.zig (one line each).
    const test_optimize = opts.test_optimize;
    const core_host = b.createModule(.{
        .root_source_file = b.path(dir ++ "core/lynx.zig"),
        .target = b.graph.host,
        .optimize = test_optimize,
    });
    const romfs_host = b.createModule(.{
        .root_source_file = b.path("lib/romfs.zig"),
        .target = b.graph.host,
        .optimize = test_optimize,
    });
    const drive_host = b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/frontend/drive.zig"),
        .target = b.graph.host,
        .optimize = test_optimize,
        .imports = &.{
            .{ .name = "core", .module = core_host },
            .{ .name = "romfs", .module = romfs_host },
        },
    });
    const tests = b.addTest(.{
        .name = "snouty-lynx-tests",
        .filters = if (opts.test_filter) |f| &.{f} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "tests/all.zig"),
            .target = b.graph.host,
            .optimize = test_optimize,
            .imports = &.{
                .{ .name = "core", .module = core_host },
                .{ .name = "romfs", .module = romfs_host },
                .{ .name = "drive", .module = drive_host },
            },
        }),
    });
    const run = b.addRunArtifact(tests);
    opts.test_step.dependOn(&run.step);
    // This cart's tests alone (the shared `test` step runs every cart's).
    b.step("test-lynx", "Run snouty-lynx host tests").dependOn(&run.step);
}

/// `-Dlynx-rom` as given: `~/x.lnx` (expanded here, the shell leaves `=~`
/// alone), an absolute path, or a path relative to the repository root.
/// No option: roms/placeholder.lnx. No filesystem probe: this Zig caches
/// the configure graph by build files and options, so a decision taken from
/// a file's existence would be frozen at the first configure (Snouty Genesis
/// M0). A named file that is missing fails the build as any missing source.
fn resolve_rom(b: *Build, opt: ?[]const u8) RomFile {
    const arg = opt orelse return .{ .lazy = b.path(default_rom), .name = std.fs.path.basename(default_rom) };
    if (std.mem.startsWith(u8, arg, "~/")) {
        const home = b.graph.environ_map.get("HOME") orelse @panic("snouty-lynx: -Dlynx-rom=~/...: HOME is not set");
        const abs = b.pathJoin(&.{ home, arg[2..] });
        return .{ .lazy = .{ .cwd_relative = abs }, .name = std.fs.path.basename(abs) };
    }
    if (std.fs.path.isAbsolute(arg)) return .{ .lazy = .{ .cwd_relative = arg }, .name = std.fs.path.basename(arg) };
    return .{ .lazy = b.path(arg), .name = std.fs.path.basename(arg) };
}

/// Adds `core`, `romfs` (lib/romfs.zig), `iris` (lib/iris_mark.zig), `drive`
/// (cart/src/frontend/drive.zig as a module, shared with the host tests) and
/// the generated `rom` to the cart. `rom` holds the embedded ROM (`data`,
/// copied next to the generated rom.zig so @embedFile can see it), its file
/// name (`name`) and where the badge build gets its ROM (`source`).
fn build_cart_modules(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = cart_api;
    const core = b.createModule(.{ .root_source_file = b.path(dir ++ "core/lynx.zig") });
    const romfs = b.createModule(.{ .root_source_file = b.path("lib/romfs.zig") });
    cart.addImport("core", core);
    cart.addImport("romfs", romfs);
    // The Iris mark the splash draws (SPEC.md section 12), shared with the other emulators.
    cart.addImport("iris", b.createModule(.{ .root_source_file = b.path("lib/iris_mark.zig") }));
    cart.addImport("drive", b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/frontend/drive.zig"),
        .imports = &.{
            .{ .name = "core", .module = core },
            .{ .name = "romfs", .module = romfs },
        },
    }));

    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(rom_file.lazy, "rom.bin");
    const rom_zig = wf.add("rom.zig", b.fmt(
        \\//! Generated by carts/snouty-lynx/build.zig.
        \\pub const data: []const u8 = @embedFile("rom.bin");
        \\pub const name = "{f}";
        \\pub const Source = enum {{ drive, embed }};
        \\pub const source: Source = .{s};
        \\
    , .{ std.zig.fmtString(rom_file.name), @tagName(rom_source) }));
    cart.addImport("rom", b.createModule(.{ .root_source_file = rom_zig }));
    step.dependOn(&wf.step);
}
