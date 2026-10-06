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

/// No `-Dmd-rom`: the embedded ROM is the shipped test ROM, which the RAM
/// cart embeds without its zero padding (`rom_module_ram`).
var rom_is_default = true;

/// The `build_options` modules of the two variants (`sound`,
/// `debug_overlay`, `z80`, `scrub`, `synth`), set by `add` for the custom builders.
var build_options: ?*Build.Step.Options = null;
var build_options_xip: ?*Build.Step.Options = null;

/// What a variant carries (PLAN.md M5): the XIP cart (and the simulator
/// wasm) the full set, the RAM cart neither the Z80 nor the scrubber.
const Variant = struct {
    /// The Z80 core runs the sound driver; false: the arbiter stub
    /// (core/z80bus.zig) and no sound.
    z80: bool,
    /// The time scrubber (core/undo.zig, frontend/rewind.zig).
    scrub: bool,
    /// YM2612 + PSG synthesis streamed to the new firmware's audio ring
    /// (core/sound.zig, PLAN.md "Sound on the new firmware"): the RAM cart
    /// only, where the 68000's own writes to the chips are what plays.
    /// The XIP cart and the simulator keep the one-voice `tone` path.
    synth: bool,
    /// The party lobby and lockstep over the fork firmware's cart serial
    /// port (docs/MULTIPLAYER.md, root docs/LOCKSTEP_N.md).
    party: bool = false,
    /// The Sonic 1 DAC fake (core/s1dac.zig, PLAN.md "Sonic 1 DAC fake"):
    /// the RAM cart with `-Dgenesis_s1dac=true` only (it needs `synth`
    /// and no Z80).
    s1dac: bool = false,
    /// core/probe.zig's trace points: the host trace tool only
    /// (tools/s1dac_trace.zig), never a cart.
    probe: bool = false,
};
const full: Variant = .{ .z80 = true, .scrub = true, .synth = false };
const ram_cart: Variant = .{ .z80 = false, .scrub = false, .synth = true };

fn variant_options(b: *Build, sound: bool, debug_overlay: bool, v: Variant) *Build.Step.Options {
    const options = b.addOptions();
    // -Dsound=true starts with sound on; off by default, the menu's Sound
    // row toggles it (docs/SOUND.md).
    options.addOption(bool, "sound", sound and (v.z80 or v.synth));
    // -Ddebug_overlay=true starts with the timing overlay on; off by
    // default, the menu's Debug overlay row toggles it.
    options.addOption(bool, "debug_overlay", debug_overlay);
    options.addOption(bool, "z80", v.z80);
    options.addOption(bool, "scrub", v.scrub);
    options.addOption(bool, "synth", v.synth);
    options.addOption(bool, "party", v.party);
    options.addOption(bool, "s1dac", v.s1dac);
    options.addOption(bool, "probe", v.probe);
    return options;
}

pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    rom_file = resolve_rom(b, opts.md_rom);
    rom_is_default = opts.md_rom == null;
    rom_source = opts.md_rom_source;
    cart_optimize = opts.cart_optimize;
    // -Dgenesis_s1dac=true: the RAM cart fakes Sonic 1's Z80 DAC driver
    // (PLAN.md "Sonic 1 DAC fake"); the XIP cart and the wasm have the Z80.
    const s1dac = b.option(bool, "genesis_s1dac", "snouty-genesis: the RAM cart plays Sonic 1's DAC drums and SEGA chant through a fake of its Z80 driver; default off") orelse false;
    var ram_variant = ram_cart;
    ram_variant.s1dac = s1dac;
    build_options = variant_options(b, opts.sound, opts.debug_overlay, ram_variant);
    build_options_xip = variant_options(b, opts.sound, opts.debug_overlay, full);

    // Two variants (PLAN.md M5): the RAM cart `snouty-genesis` (no Z80, no
    // scrubber: code plus the ~150 KB console fit the 268 KB RAM window) and
    // the XIP cart `snouty-genesis-xip` (SPEC.md section 13: everything).
    // -Dcart-mode=ram (the default) builds both, like snouty-zero and
    // snouty-lynx; the simulator wasm comes from the XIP variant's modules so
    // it keeps the Z80 and the scrubber.
    const mode: os_cart.Mode = if (opts.cart_mode == .ram) .both else opts.cart_mode;
    os_cart.add(b, sycl_badge_dep, .{
        .mode = mode,
        .name = "snouty-genesis",
        .optimize = opts.cart_optimize,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &build_cart_modules_ram,
        .xip_custom_builder = &build_cart_modules_xip,
        .wasm_from = .xip,
        // The SDK's script with a 20 KB stack reservation (the measured
        // peak is about 6 KB): room for the link beside the sound.
        .ram_linker_script = b.path(dir ++ "cart/cart_ram.ld"),
    });

    // `zig build check-float` (shared step): the core and the frontend are
    // all-integer; fail if an ELF links any soft-float or libm routine.
    common.add_float_check(b, opts, "snouty-genesis", mode);

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
        .imports = &.{
            .{ .name = "z80", .module = z80_host },
            .{ .name = "build_options", .module = variant_options(b, false, false, full).createModule() },
        },
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
    // frontend/input.zig (the Select tap, hold and fast-forward double
    // tap) for tests/input_unit.zig: it needs only `cart.Controls` from the
    // cart API, which the host compiles lazily.
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
    // Two-player link play over the virtual cable (tests/link_play.zig):
    // the session module with the real core, lib/link.zig and
    // lib/link_virtual.zig under one root (`link_host`).
    const lockstep_host = b.createModule(.{
        .root_source_file = b.path("lib/lockstep.zig"),
        .target = b.graph.host,
        .optimize = test_optimize,
    });
    const linkplay_host = b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/frontend/linkplay.zig"),
        .target = b.graph.host,
        .optimize = test_optimize,
        .imports = &.{
            .{ .name = "core", .module = core_host },
            .{ .name = "lockstep", .module = lockstep_host },
        },
    });
    const link_host = link_host_module(b, test_optimize);
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
                .{ .name = "input", .module = input_host },
                .{ .name = "lockstep", .module = lockstep_host },
                .{ .name = "linkplay", .module = linkplay_host },
                .{ .name = "link_host", .module = link_host },
            },
        }),
    });
    // The RAM cart's core (PLAN.md M5): no Z80, no scrubber, and its
    // trimmed test ROM; a binary of its own (tests/ram_variant.zig).
    const core_host_ram = b.createModule(.{
        .root_source_file = b.path(dir ++ "core/md.zig"),
        .target = b.graph.host,
        .optimize = test_optimize,
        .imports = &.{
            .{ .name = "z80", .module = z80_host },
            .{ .name = "build_options", .module = variant_options(b, false, false, ram_cart).createModule() },
        },
    });
    const ram_tests = ram_test_binary(b, opts, "snouty-genesis-ram-tests", "tests/ram_variant.zig", core_host_ram, rom_host, lockstep_host, link_host);
    // The same with the Sonic 1 DAC fake (`-Dgenesis_s1dac`) and the trace
    // probe: tests/s1dac_unit.zig, which runs every RAM-cart test too.
    var s1dac_variant = ram_cart;
    s1dac_variant.s1dac = true;
    s1dac_variant.probe = true;
    const core_host_s1dac = b.createModule(.{
        .root_source_file = b.path(dir ++ "core/md.zig"),
        .target = b.graph.host,
        .optimize = test_optimize,
        .imports = &.{
            .{ .name = "z80", .module = z80_host },
            .{ .name = "build_options", .module = variant_options(b, false, false, s1dac_variant).createModule() },
        },
    });
    const s1dac_tests = ram_test_binary(b, opts, "snouty-genesis-s1dac-tests", "tests/s1dac_unit.zig", core_host_s1dac, rom_host, lockstep_host, link_host);
    const s1dac_run = b.addRunArtifact(s1dac_tests);
    s1dac_run.has_side_effects = true;
    opts.test_step.dependOn(&s1dac_run.step);
    const ram_run = b.addRunArtifact(ram_tests);
    ram_run.has_side_effects = true;
    opts.test_step.dependOn(&ram_run.step);
    const run = b.addRunArtifact(tests);
    // The tests read ROMs and scripts at run time (not build inputs) and
    // print the golden hashes: run them every time, never from the cache.
    run.has_side_effects = true;
    opts.test_step.dependOn(&run.step);
    // This cart's tests alone (the shared `test` step runs every cart's).
    const test_genesis = b.step("test-genesis", "Run snouty-genesis host tests");
    test_genesis.dependOn(&run.step);
    test_genesis.dependOn(&ram_run.step);
    test_genesis.dependOn(&s1dac_run.step);

    add_s1dac_trace(b, z80_host);

    // Strict 68000 oracle gate (not part of `test`): SingleStepTests with
    // SNOUTY_FIXTURES=required, so absent fixtures fail instead of
    // skipping. No fetch here: tools/fetch_test_roms.sh first.
    const strict = b.addTest(.{
        .name = "snouty-genesis-m68k-oracle",
        .filters = &.{"m68k strict"},
        .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "tests/m68k_oracle.zig"),
            .target = b.graph.host,
            .optimize = test_optimize,
            .imports = &.{.{ .name = "core", .module = core_host }},
        }),
    });
    const strict_run = b.addRunArtifact(strict);
    strict_run.setEnvironmentVariable("SNOUTY_FIXTURES", "required");
    strict_run.has_side_effects = true;
    b.step("test-m68k-strict", "Run the snouty-genesis 68000 oracle tests; fail if fixtures are absent").dependOn(&strict_run.step);
}

/// A RAM-cart test binary over `core` (a RAM variant's): the embedded test
/// ROM, its trimmed copy, and link play over that core.
fn ram_test_binary(b: *Build, opts: common.Options, name: []const u8, root: []const u8, core: *Build.Module, rom_host: *Build.Module, lockstep_host: *Build.Module, link_host: *Build.Module) *Build.Step.Compile {
    const test_optimize = opts.test_optimize;
    return b.addTest(.{
        .name = name,
        .filters = if (opts.test_filter) |f| &.{f} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt(dir ++ "{s}", .{root})),
            .target = b.graph.host,
            .optimize = test_optimize,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "rom", .module = rom_host },
                .{ .name = "rom_ram", .module = b.createModule(.{
                    .root_source_file = rom_module_ram(b),
                    .target = b.graph.host,
                    .optimize = test_optimize,
                }) },
                // Link play on the RAM cart's core (tests/link_play.zig).
                .{ .name = "lockstep", .module = lockstep_host },
                .{ .name = "linkplay", .module = b.createModule(.{
                    .root_source_file = b.path(dir ++ "cart/src/frontend/linkplay.zig"),
                    .target = b.graph.host,
                    .optimize = test_optimize,
                    .imports = &.{
                        .{ .name = "core", .module = core },
                        .{ .name = "lockstep", .module = lockstep_host },
                    },
                }) },
                .{ .name = "link_host", .module = link_host },
            },
        }),
    });
}

/// `zig build s1dac-trace -Dcart=snouty-genesis -- <sonic1.bin> <out-dir>`
/// (PLAN.md "Sonic 1 DAC fake", tools/s1dac_trace.zig): the trace tool
/// over the full core with the real Z80 (`s1dac-oracle`) and over the RAM
/// cart's core with the fake (`s1dac-fake`), both with the RAM cart's
/// synthesis and the probe; runs both. Not part of `test`.
fn add_s1dac_trace(b: *Build, z80_host: *Build.Module) void {
    const step = b.step("s1dac-trace", "Run the Sonic 1 DAC oracle and the fake (args: <sonic1.bin> <out-dir>)");
    const Tool = struct { name: []const u8, v: Variant };
    for ([_]Tool{
        .{ .name = "s1dac-oracle", .v = .{ .z80 = true, .scrub = false, .synth = true, .probe = true } },
        .{ .name = "s1dac-fake", .v = .{ .z80 = false, .scrub = false, .synth = true, .s1dac = true, .probe = true } },
    }) |t| {
        const core = b.createModule(.{
            .root_source_file = b.path(dir ++ "core/md.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "z80", .module = z80_host },
                .{ .name = "build_options", .module = variant_options(b, false, false, t.v).createModule() },
            },
        });
        const names = b.addOptions();
        names.addOption([]const u8, "name", t.name);
        const exe = b.addExecutable(.{
            .name = t.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(dir ++ "tools/s1dac_trace.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "core", .module = core },
                    .{ .name = "trace_options", .module = names.createModule() },
                },
            }),
        });
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        step.dependOn(&run.step);
    }
}

/// lib/link.zig and its virtual cable copied under one root, as
/// `link_host.link` and `link_host.virtual` (link_virtual.zig imports
/// link.zig by path, and a file can belong to only one module): Snouty
/// Pong's.
fn link_host_module(b: *Build, optimize: std.builtin.OptimizeMode) *Build.Module {
    const wf = b.addWriteFiles();
    inline for (.{ "link.zig", "link_rp2350.zig", "link_virtual.zig" }) |f| {
        _ = wf.addCopyFile(b.path("lib/" ++ f), f);
    }
    const root = wf.add("link_host.zig", "pub const link = @import(\"link.zig\");\npub const virtual = @import(\"link_virtual.zig\");\n");
    return b.createModule(.{ .root_source_file = root, .target = b.graph.host, .optimize = optimize });
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
/// (`source`, `.drive` or `.embed`). Made once per build graph. A drive
/// badge build never references `data`, so its bytes reach only the
/// simulator wasm, the embed builds and the host tests.
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

/// The RAM cart's `rom` module (PLAN.md M5 cut 3): the shipped test ROM
/// without its trailing zero padding (16 KB -> 2.9 KB, tools/trim_rom.zig;
/// `tests/ram_variant.zig` checks the trimmed ROM plays the M1 golden run
/// identically), any `-Dmd-rom` as it is. Made once per build graph.
var rom_zig_ram: ?Build.LazyPath = null;
var rom_step_ram: *Build.Step = undefined;

fn rom_module_ram(b: *Build) Build.LazyPath {
    if (!rom_is_default) {
        const p = rom_module(b);
        rom_step_ram = rom_step;
        return p;
    }
    if (rom_zig_ram) |p| return p;
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(trimmed_rom(b), "rom.bin");
    const p = wf.add("rom.zig", b.fmt(
        \\//! Generated by carts/snouty-genesis/build.zig (the RAM cart: the test
        \\//! ROM without its zero padding, tools/trim_rom.zig).
        \\pub const data: []const u8 = @embedFile("rom.bin");
        \\pub const name = "{f}";
        \\pub const Source = enum {{ drive, embed }};
        \\pub const source: Source = .{s};
        \\
    , .{ std.zig.fmtString(rom_file.name), @tagName(rom_source) }));
    rom_zig_ram = p;
    rom_step_ram = &wf.step;
    return p;
}

/// `rom_file` through tools/trim_rom.zig (a host program run at build time).
fn trimmed_rom(b: *Build) Build.LazyPath {
    const tool = b.addExecutable(.{
        .name = "snouty-genesis-trim-rom",
        .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "tools/trim_rom.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run = b.addRunArtifact(tool);
    run.addFileArg(rom_file.lazy);
    return run.addOutputFileArg("rom.bin");
}

/// Adds `build_options` (the variant's), `core` (with `z80` and the same
/// `build_options`), `video` (frontend/video.zig: the line sink), `app`
/// (frontend/app.zig: the state machine and every other frontend file),
/// `romfs` (lib/romfs.zig, the drive reader), `iris` (lib/iris_mark.zig),
/// `hint` (lib/hint.zig), the generated `rom` and `drive` (the drive scan,
/// cart/src/frontend/drive.zig, a module so the host tests share it) to the
/// cart.
fn build_cart_modules_ram(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    // PLAN.md M5 cut 4: the frontend, the drive reader and the splash art
    // are cold (menus, picker, help, start-up), so the RAM cart builds them
    // ReleaseSmall; the core and the line sink keep the cart's mode. The
    // cart API module (upstream's text, rect and blit, the start code) is
    // cold too.
    cart_api.optimize = .ReleaseSmall;
    build_cart_modules(b, cart, cart_api, step, build_options.?, .{ .hot = cart_optimize, .cold = .ReleaseSmall, .trimmed_rom = true });
}

fn build_cart_modules_xip(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    build_cart_modules(b, cart, cart_api, step, build_options_xip.?, .{});
}

/// How a variant's modules are built: optimize modes (null inherits the
/// cart's) and which `rom` module it embeds (`-Dmd-rom-source=embed` only:
/// a drive build embeds none).
const Modes = struct {
    hot: ?std.builtin.OptimizeMode = null,
    cold: ?std.builtin.OptimizeMode = null,
    /// The test ROM without its zero padding (`rom_module_ram`).
    trimmed_rom: bool = false,
};

/// `-Dcart-optimize`, set by `add` for `build_cart_modules_ram`.
var cart_optimize: std.builtin.OptimizeMode = .ReleaseFast;

fn build_cart_modules(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step, opts: *Build.Step.Options, modes: Modes) void {
    // A drive build links no embedded ROM (frontend/romsrc.zig never
    // reads `rom.data` there), so it needs no trimmed copy either; the host
    // tests still get theirs.
    const trimmed = modes.trimmed_rom and rom_source == .embed;
    const rom_zig_path = if (trimmed) rom_module_ram(b) else rom_module(b);
    const rom_gen_step = if (trimmed) rom_step_ram else rom_step;
    const options = opts.createModule();
    cart.addImport("build_options", options);
    const z80 = b.createModule(.{ .root_source_file = b.path(gear_core ++ "z80.zig"), .optimize = modes.hot });
    const core = b.createModule(.{
        .root_source_file = b.path(dir ++ "core/md.zig"),
        .optimize = modes.hot,
        .imports = &.{
            .{ .name = "z80", .module = z80 },
            .{ .name = "build_options", .module = options },
        },
    });
    const romfs = b.createModule(.{ .root_source_file = b.path("lib/romfs.zig"), .optimize = modes.cold });
    const rom = b.createModule(.{ .root_source_file = rom_zig_path, .optimize = modes.cold });
    const iris = b.createModule(.{ .root_source_file = b.path("lib/iris_mark.zig"), .optimize = modes.cold });
    // The control hints (splash, first seconds of play, menu), shared with Boy, Gear, Lynx.
    const hint = b.createModule(.{ .root_source_file = b.path("lib/hint.zig"), .optimize = modes.cold });
    // The new firmware's streaming ring and its rate control (the RAM
    // cart's sound; it imports lib/stream_audio.zig by file).
    const audio_feed = b.createModule(.{ .root_source_file = b.path("lib/audio_feed.zig"), .optimize = modes.cold });
    const drive = b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/frontend/drive.zig"),
        .optimize = modes.cold,
        .imports = &.{
            .{ .name = "core", .module = core },
            .{ .name = "rom", .module = rom },
            .{ .name = "romfs", .module = romfs },
        },
    });
    const video = b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/frontend/video.zig"),
        .optimize = modes.hot,
        .imports = &.{
            .{ .name = "cart-api", .module = cart_api },
            .{ .name = "core", .module = core },
        },
    });
    // Two-player link play (docs/LINK_PLAY.md): the link
    // cable, the lockstep and the session over them (cart-api-free, so
    // the host tests share it).
    const lockstep = b.createModule(.{ .root_source_file = b.path("lib/lockstep.zig"), .optimize = modes.cold });
    const link = b.createModule(.{ .root_source_file = b.path("lib/link.zig"), .optimize = modes.cold });
    const linkplay = b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/frontend/linkplay.zig"),
        .optimize = modes.cold,
        .imports = &.{
            .{ .name = "core", .module = core },
            .{ .name = "lockstep", .module = lockstep },
        },
    });
    const app = b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/frontend/app.zig"),
        .optimize = modes.cold,
        .imports = &.{
            .{ .name = "cart-api", .module = cart_api },
            .{ .name = "build_options", .module = options },
            .{ .name = "core", .module = core },
            .{ .name = "video", .module = video },
            .{ .name = "rom", .module = rom },
            .{ .name = "romfs", .module = romfs },
            .{ .name = "drive", .module = drive },
            .{ .name = "iris", .module = iris },
            .{ .name = "hint", .module = hint },
            .{ .name = "audio_feed", .module = audio_feed },
            .{ .name = "link", .module = link },
            .{ .name = "lockstep", .module = lockstep },
            .{ .name = "linkplay", .module = linkplay },
        },
    });
    cart.addImport("core", core);
    cart.addImport("video", video);
    cart.addImport("app", app);
    step.dependOn(rom_gen_step);
}
