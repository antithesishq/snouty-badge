const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=snouty-lynx` from the repository root instead.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/snouty-lynx/";

/// The embedded ROM (wasm and `-Dlynx-rom-source=embed` builds; a drive
/// badge build references none of it) unless `-Dlynx-rom` names another:
/// 42Bastian's textured raycaster (Apache-2.0, roms/LICENSE-raycast.txt,
/// docs/ROM_CANDIDATES.md).
/// tools/make_placeholder_rom.py still builds roms/placeholder.lnx for the
/// drive fixtures.
const default_rom = dir ++ "roms/raycast.lnx";

/// ROM to embed and where the badge build looks for its ROM. Module-level
/// because `build_cart_modules` has no user context parameter.
var rom_file: RomFile = undefined;
var rom_source: Source = .drive;

/// What the cart sees as `rom.source` (`pack` is not built yet and builds as `drive`).
const Source = enum { drive, embed };

const RomFile = struct { lazy: Build.LazyPath, name: []const u8 };

/// The `build_options` module (`sound`), set by `add` for `build_cart_modules`.
var build_options: ?*Build.Step.Options = null;

pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    rom_file = resolve_rom(b, opts.lynx_rom);
    rom_source = switch (opts.lynx_rom_source) {
        .drive => .drive,
        .embed => .embed,
        .pack => blk: {
            std.debug.print("snouty-lynx: -Dlynx-rom-source=pack: not built yet (SPEC.md 13.1); building the drive cart (no embedded ROM)\n", .{});
            break :blk .drive;
        },
    };

    // -Dsound=true starts with sound on; off by default, the menu's Sound row
    // toggles it (docs/SOUND.md).
    const options = b.addOptions();
    options.addOption(bool, "sound", opts.sound);
    build_options = options;

    os_cart.add(b, sycl_badge_dep, .{
        // Both artifacts from the default build: the RAM cart (the default on
        // the badge) and `snouty-lynx-xip.uf2`, the XIP cart whose 190 KB of
        // free RAM is what the M3 scrubber wants (docs/SCRUB.md); XIP is
        // untested on hardware, so the RAM cart stays the default until
        // Adrian's badge run says otherwise. -Dcart-mode=xip|both as usual.
        .mode = if (opts.cart_mode == .ram) .both else opts.cart_mode,
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
    // The frontend's sound path (M5): lib/stream_audio.zig and
    // frontend/audio.zig need no cart-api, so they run natively too.
    const stream_host = b.createModule(.{
        .root_source_file = b.path("lib/stream_audio.zig"),
        .target = b.graph.host,
        .optimize = test_optimize,
    });
    const audio_host = b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/frontend/audio.zig"),
        .target = b.graph.host,
        .optimize = test_optimize,
        .imports = &.{
            .{ .name = "core", .module = core_host },
            .{ .name = "stream_audio", .module = stream_host },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });
    // frontend/input.zig (the Select hold, the held-back tap and the
    // fast-forward double tap) for tests/input_unit.zig: it needs only
    // `cart.Controls` from the cart API, which the host compiles lazily.
    const input_host = b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/frontend/input.zig"),
        .target = b.graph.host,
        .optimize = test_optimize,
        .imports = &.{
            .{ .name = "core", .module = core_host },
            .{ .name = "cart-api", .module = b.createModule(.{
                .root_source_file = sycl_badge_dep.path("src/os/cart/api.zig"),
                .target = b.graph.host,
                .optimize = test_optimize,
            }) },
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
                .{ .name = "stream_audio", .module = stream_host },
                .{ .name = "frontend_audio", .module = audio_host },
                .{ .name = "input", .module = input_host },
            },
        }),
    });
    const run = b.addRunArtifact(tests);
    // The tests read ROMs, test data and scripts at run time (not build
    // inputs) and print golden hashes: run them every time, never from the cache.
    run.has_side_effects = true;
    opts.test_step.dependOn(&run.step);
    // This cart's tests alone (the shared `test` step runs every cart's).
    b.step("test-lynx", "Run snouty-lynx host tests").dependOn(&run.step);

    // `zig build run-lynx -- <rom> <script.json|-> <updates> <outdir> [...]`:
    // a ROM headless (tools/run_rom.zig over tests/runner.zig, the golden
    // test's runner), PPM frames and per-update hashes. Release build: the
    // core is slow in Debug.
    const core_fast = b.createModule(.{
        .root_source_file = b.path(dir ++ "core/lynx.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    const run_rom = b.addExecutable(.{
        .name = "run-lynx",
        .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "tools/run_rom.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "core", .module = core_fast },
                .{ .name = "runner", .module = b.createModule(.{
                    .root_source_file = b.path(dir ++ "tests/runner.zig"),
                    .target = b.graph.host,
                    .optimize = .ReleaseFast,
                    .imports = &.{.{ .name = "core", .module = core_fast }},
                }) },
            },
        }),
    });
    const run_rom_run = b.addRunArtifact(run_rom);
    run_rom_run.addPassthruArgs();
    run_rom_run.has_side_effects = true;
    b.step("run-lynx", "Run a Lynx ROM headless (snouty-lynx tools/run_rom.zig)").dependOn(&run_rom_run.step);
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

/// Adds `core`, `romfs` (lib/romfs.zig), `iris` (lib/iris_mark.zig), `hint`
/// (lib/hint.zig), `stream_audio` (lib/stream_audio.zig), `build_options`
/// (`sound`), `drive`
/// (cart/src/frontend/drive.zig as a module, shared with the host tests) and
/// the generated `rom` to the cart. `rom` holds the embedded ROM (`data`,
/// copied next to the generated rom.zig so @embedFile can see it; only
/// wasm and embed builds reference it, so a drive badge build carries none
/// of its bytes), its file name (`name`) and where the badge build gets its
/// ROM (`source`).
fn build_cart_modules(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = cart_api;
    const core = b.createModule(.{ .root_source_file = b.path(dir ++ "core/lynx.zig") });
    const romfs = b.createModule(.{ .root_source_file = b.path("lib/romfs.zig") });
    cart.addImport("core", core);
    cart.addImport("romfs", romfs);
    // The Iris mark the splash draws (SPEC.md section 12), shared with the other emulators.
    cart.addImport("iris", b.createModule(.{ .root_source_file = b.path("lib/iris_mark.zig") }));
    // The control hints (splash, first seconds of play, menu), shared with Boy, Gear, Genesis.
    cart.addImport("hint", b.createModule(.{ .root_source_file = b.path("lib/hint.zig") }));
    // The new firmware's streaming-audio ring (M5 sound, frontend/audio.zig).
    cart.addImport("stream_audio", b.createModule(.{ .root_source_file = b.path("lib/stream_audio.zig") }));
    cart.addImport("build_options", build_options.?.createModule());
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
