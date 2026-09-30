const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=snouty-genesis -Dcart-mode=xip` from the repository root.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/snouty-genesis/";

/// Snouty Gear's core directory: its `z80.zig` (and the `tables.zig` next to
/// it) is this cart's Z80, imported as the `z80` module, not copied
/// (SPEC.md section 7).
const gear_core = "carts/snouty-gear/core/";

/// The shipped test ROM (built from source by M0 Track R, tools/testrom/).
const default_rom = dir ++ "roms/snouty-test.bin";

/// ROM to embed and where the badge build looks for its ROM. Module-level
/// because `build_cart_modules` has no user context parameter.
var rom_file: RomFile = undefined;
var rom_source: common.MdRomSource = .drive;

/// A ROM file: its path and the name the report line shows.
const RomFile = struct { lazy: Build.LazyPath, name: []const u8 };

/// The `build_options` module (`sound`), set by `add` for `build_cart_modules`.
var build_options: ?*Build.Step.Options = null;

pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    // XIP only (SPEC.md section 13): the console state and the code do not
    // both fit a RAM cart. Named on -Dcart in RAM mode, stop and say so; in
    // an all-carts build (no -Dcart) build the XIP cart anyway, so the plain
    // `zig build` keeps compiling this cart. `both` builds the XIP cart only.
    const explicit = if (opts.only) |list| std.mem.eql(u8, list, "snouty-genesis") else false;
    if (opts.cart_mode == .ram and explicit) {
        std.debug.print(
            \\snouty-genesis: this cart builds as an XIP cart only (carts/snouty-genesis/SPEC.md
            \\section 13: code plus ~140 KB of console state do not fit a RAM cart).
            \\Pass -Dcart-mode=xip:
            \\    zig build -Dcart=snouty-genesis -Dcart-mode=xip
            \\
        , .{});
        std.process.exit(1);
    }

    rom_file = resolve_rom(b, opts.md_rom);
    rom_source = opts.md_rom_source;
    // -Dsound=true starts with sound on; off by default, A in the menu
    // toggles it (docs/SOUND.md).
    const options = b.addOptions();
    options.addOption(bool, "sound", opts.sound);
    build_options = options;

    os_cart.add(b, sycl_badge_dep, .{
        .mode = .xip,
        .name = "snouty-genesis",
        .optimize = opts.cart_optimize,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &build_cart_modules,
    });

    // Host tests: the core is badge-agnostic and runs natively. Test ROMs
    // come from tools/fetch_test_roms.sh (tests/roms/, gitignored).
    const test_optimize = opts.test_optimize;
    const z80_host = b.createModule(.{
        .root_source_file = b.path(gear_core ++ "z80.zig"),
        .target = b.graph.host,
        .optimize = test_optimize,
    });
    const core_host = b.createModule(.{
        .root_source_file = b.path(dir ++ "core/md.zig"),
        .target = b.graph.host,
        .optimize = test_optimize,
        .imports = &.{.{ .name = "z80", .module = z80_host }},
    });
    const rom_host = b.createModule(.{
        .root_source_file = rom_module(b),
        .target = b.graph.host,
        .optimize = test_optimize,
    });
    // The drive scan (cart/src/frontend/drive.zig) is a module of its own so
    // the tests can run it against FAT12 fixture images (tests/fixtures/).
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
            .{ .name = "rom", .module = rom_host },
            .{ .name = "romfs", .module = romfs_host },
        },
    });
    const tests = b.addTest(.{
        .name = "snouty-genesis-tests",
        .filters = if (opts.test_filter) |f| &.{f} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "tests/all.zig"),
            .target = b.graph.host,
            .optimize = test_optimize,
            .imports = &.{
                .{ .name = "core", .module = core_host },
                .{ .name = "rom", .module = rom_host },
                .{ .name = "romfs", .module = romfs_host },
                .{ .name = "drive", .module = drive_host },
            },
        }),
    });
    const run = b.addRunArtifact(tests);
    // The tests read ROMs and scripts at run time (not build inputs) and
    // print the golden hashes: run them every time, never from the cache.
    run.has_side_effects = true;
    opts.test_step.dependOn(&run.step);
    // This cart's tests alone (the shared `test` step runs every cart's).
    b.step("test-genesis", "Run snouty-genesis host tests").dependOn(&run.step);
}

/// `-Dmd-rom` as given: `~/x.bin` (expanded here, the shell leaves `=~`
/// alone), an absolute path, a path relative to the repository root, or one
/// relative to this cart's directory (`roms/x.bin`). No option: `roms/snouty-test.bin`.
/// A named file that is missing is an error at build time, as for any
/// missing source file.
fn resolve_rom(b: *Build, opt: ?[]const u8) RomFile {
    // No filesystem probe here: this Zig caches the configure phase's build
    // graph keyed by the build files and options, so a decision taken from a
    // file's existence would be frozen at the first configure (M0 hit this
    // with a placeholder ROM that outlived the real one).
    const arg = opt orelse return .{ .lazy = b.path(default_rom), .name = std.fs.path.basename(default_rom) };
    if (std.mem.startsWith(u8, arg, "~/")) {
        const home = b.graph.environ_map.get("HOME") orelse @panic("snouty-genesis: -Dmd-rom=~/...: HOME is not set");
        const abs = b.pathJoin(&.{ home, arg[2..] });
        return .{ .lazy = .{ .cwd_relative = abs }, .name = std.fs.path.basename(abs) };
    }
    if (std.fs.path.isAbsolute(arg)) return .{ .lazy = .{ .cwd_relative = arg }, .name = std.fs.path.basename(arg) };
    const rel = if (exists(b, arg) or !exists(b, b.fmt(dir ++ "{s}", .{arg}))) arg else b.fmt(dir ++ "{s}", .{arg});
    return .{ .lazy = b.path(rel), .name = std.fs.path.basename(rel) };
}

fn exists(b: *Build, rel: []const u8) bool {
    b.root.access(b.graph.io, rel, .{}) catch return false;
    return true;
}

/// The generated `rom` module (the cart and the host tests both import it):
/// the embedded ROM (`data`, copied next to the generated rom.zig so
/// @embedFile can see it), its file name (`name`) and where the badge build gets its ROM
/// (`source`, `.drive` or `.embed`). Made once per build graph.
var rom_zig: ?Build.LazyPath = null;
var rom_step: *Build.Step = undefined;

fn rom_module(b: *Build) Build.LazyPath {
    if (rom_zig) |p| return p;
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(rom_file.lazy, "rom.bin");
    const name = rom_file.name;
    const p = wf.add("rom.zig", b.fmt(
        \\//! Generated by carts/snouty-genesis/build.zig.
        \\pub const data: []const u8 = @embedFile("rom.bin");
        \\pub const name = "{f}";
        \\pub const Source = enum {{ drive, embed }};
        \\pub const source: Source = .{s};
        \\
    , .{ std.zig.fmtString(name), @tagName(rom_source) }));
    rom_zig = p;
    rom_step = &wf.step;
    return p;
}

/// Adds `build_options`, `core` (with `z80`), `romfs` (lib/romfs.zig, the
/// drive reader), `iris` (lib/iris_mark.zig), the generated `rom` and `drive` (the drive scan,
/// cart/src/frontend/drive.zig, a module so the host tests share it) to the
/// cart.
fn build_cart_modules(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = cart_api;
    cart.addImport("build_options", build_options.?.createModule());
    const z80 = b.createModule(.{ .root_source_file = b.path(gear_core ++ "z80.zig") });
    const core = b.createModule(.{
        .root_source_file = b.path(dir ++ "core/md.zig"),
        .imports = &.{.{ .name = "z80", .module = z80 }},
    });
    const romfs = b.createModule(.{ .root_source_file = b.path("lib/romfs.zig") });
    const rom = b.createModule(.{ .root_source_file = rom_module(b) });
    cart.addImport("core", core);
    cart.addImport("romfs", romfs);
    cart.addImport("rom", rom);
    cart.addImport("iris", b.createModule(.{ .root_source_file = b.path("lib/iris_mark.zig") }));
    cart.addImport("drive", b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/frontend/drive.zig"),
        .imports = &.{
            .{ .name = "core", .module = core },
            .{ .name = "rom", .module = rom },
            .{ .name = "romfs", .module = romfs },
        },
    }));
    step.dependOn(rom_step);
}
