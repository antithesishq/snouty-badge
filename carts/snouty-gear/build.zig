const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=snouty-gear` from the repository root instead.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/snouty-gear/";

/// The shipped ROM (MIT, roms/LICENSE-waternet): the embedded fallback and
/// the simulator's ROM unless `-Dgg-rom` names another.
const default_rom = dir ++ "roms/waternet.gg";

/// ROM to embed and where the badge build looks for its ROM. Module-level
/// because `build_cart_modules` has no user context parameter.
var rom_path: Build.LazyPath = undefined;
var rom_name: []const u8 = "waternet.gg";
var rom_source: Source = .drive;

/// What the cart sees as `rom.source` (`pack` is not built yet and builds as `drive`).
const Source = enum { drive, embed };

/// The `build_options` module (`sound`), set by `add` for `build_cart_modules`.
var build_options: ?*Build.Step.Options = null;

pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    const path = resolve_rom(b, opts.gg_rom orelse default_rom);
    rom_path = path.lazy;
    rom_name = std.fs.path.basename(path.text);
    rom_source = switch (opts.gg_rom_source) {
        .drive => .drive,
        .embed => .embed,
        .pack => blk: {
            std.debug.print("snouty-gear: -Dgg-rom-source=pack: not built yet (SPEC 13.1); building the RAM cart with the drive ROM and {s} embedded\n", .{rom_name});
            break :blk .drive;
        },
    };

    // -Dsound=true starts with sound on; off by default, the menu's Sound row
    // toggles it (docs/SOUND.md).
    const options = b.addOptions();
    options.addOption(bool, "sound", opts.sound);
    build_options = options;

    os_cart.add(b, sycl_badge_dep, .{
        .mode = opts.cart_mode,
        .name = "snouty-gear",
        .optimize = opts.cart_optimize,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &build_cart_modules,
    });

    // Host tests: the core is badge-agnostic and runs natively. Test ROMs
    // come from tools/fetch_test_roms.sh (tests/roms/, gitignored).
    const test_optimize = opts.test_optimize;
    const core_host = b.createModule(.{
        .root_source_file = b.path(dir ++ "core/gg.zig"),
        .target = b.graph.host,
        .optimize = test_optimize,
    });
    const tests = b.addTest(.{
        .filters = if (opts.test_filter) |f| &.{f} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "tests/all.zig"),
            .target = b.graph.host,
            .optimize = test_optimize,
            .imports = &.{.{ .name = "core", .module = core_host }},
        }),
    });
    const run = b.addRunArtifact(tests);
    // The tests read ROMs and fixtures at run time (not build inputs), so a
    // cached result would hide a fixture appearing or vanishing: run every time.
    run.has_side_effects = true;
    opts.test_step.dependOn(&run.step);

    // Strict Z80 oracle gate (not part of `test`): SingleStepTests, ZEXDOC
    // and ZEXALL with SNOUTY_FIXTURES=required, so absent fixtures fail
    // instead of skipping. No fetch here: tools/fetch_test_roms.sh first.
    const strict = b.addTest(.{
        .name = "snouty-gear-z80-oracle",
        .filters = &.{"z80 strict"},
        .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "tests/z80_oracle.zig"),
            .target = b.graph.host,
            .optimize = test_optimize,
            .imports = &.{.{ .name = "core", .module = core_host }},
        }),
    });
    const strict_run = b.addRunArtifact(strict);
    strict_run.setEnvironmentVariable("SNOUTY_FIXTURES", "required");
    strict_run.has_side_effects = true;
    b.step("test-z80-strict", "Run the snouty-gear Z80 oracle tests; fail if fixtures are absent").dependOn(&strict_run.step);
}

const RomPath = struct { lazy: Build.LazyPath, text: []const u8 };

/// `-Dgg-rom` as given: `~/x.gg` (expanded here, the shell leaves `=~` alone),
/// an absolute path, a path relative to the repository root, or one relative
/// to this cart's directory (`roms/x.gg`).
fn resolve_rom(b: *Build, arg: []const u8) RomPath {
    if (std.mem.startsWith(u8, arg, "~/")) {
        const home = b.graph.environ_map.get("HOME") orelse @panic("snouty-gear: -Dgg-rom=~/...: HOME is not set");
        const abs = b.pathJoin(&.{ home, arg[2..] });
        return .{ .lazy = .{ .cwd_relative = abs }, .text = abs };
    }
    if (std.fs.path.isAbsolute(arg)) return .{ .lazy = .{ .cwd_relative = arg }, .text = arg };
    const rel = if (exists(b, arg) or !exists(b, b.fmt(dir ++ "{s}", .{arg}))) arg else b.fmt(dir ++ "{s}", .{arg});
    return .{ .lazy = b.path(rel), .text = rel };
}

fn exists(b: *Build, rel: []const u8) bool {
    b.root.access(b.graph.io, rel, .{}) catch return false;
    return true;
}

/// Adds `build_options`, `core`, `romfs` (lib/romfs.zig, the drive reader), `iris` (lib/iris_mark.zig), `hint` (lib/hint.zig), `audio_feed` (lib/audio_feed.zig) and `rom` to the
/// cart. `rom` is generated: the embedded ROM (`data`, copied next to the
/// generated rom.zig so @embedFile can see it), its file name (`name`) and
/// where the badge build gets its ROM (`source`, `.drive` or `.embed`).
fn build_cart_modules(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = cart_api;
    cart.addImport("build_options", build_options.?.createModule());
    cart.addImport("core", b.createModule(.{ .root_source_file = b.path(dir ++ "core/gg.zig") }));
    cart.addImport("romfs", b.createModule(.{ .root_source_file = b.path("lib/romfs.zig") }));
    // The Iris mark the splash draws (SPEC.md section 12), shared with Snouty Boy.
    cart.addImport("iris", b.createModule(.{ .root_source_file = b.path("lib/iris_mark.zig") }));
    // The control hints (splash, first seconds of play, menu), shared with Boy, Genesis, Lynx.
    cart.addImport("hint", b.createModule(.{ .root_source_file = b.path("lib/hint.zig") }));
    // The badge's streaming sound (docs/EMU_SOUND.md), shared with Boy and Genesis.
    cart.addImport("audio_feed", b.createModule(.{ .root_source_file = b.path("lib/audio_feed.zig") }));

    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(rom_path, "rom.bin");
    const rom_zig = wf.add("rom.zig", b.fmt(
        \\//! Generated by carts/snouty-gear/build.zig.
        \\pub const data: []const u8 = @embedFile("rom.bin");
        \\pub const name = "{f}";
        \\pub const Source = enum {{ drive, embed }};
        \\pub const source: Source = .{s};
        \\
    , .{ std.zig.fmtString(rom_name), @tagName(rom_source) }));
    cart.addImport("rom", b.createModule(.{ .root_source_file = rom_zig }));
    step.dependOn(&wf.step);
}
