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
/// While it is absent the build embeds a generated placeholder instead.
const default_rom = dir ++ "roms/snouty-test.bin";

/// ROM to embed and where the badge build looks for its ROM. Module-level
/// because `build_cart_modules` has no user context parameter.
var rom_file: RomFile = undefined;
var rom_source: common.MdRomSource = .drive;

const RomFile = union(enum) {
    /// A ROM file: its path and the name the report line shows.
    path: struct { lazy: Build.LazyPath, name: []const u8 },
    /// No ROM file: `placeholder_rom` bytes, named "placeholder.bin".
    placeholder,
};

pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    // XIP only (SPEC.md section 13): the console state and the code do not
    // both fit a RAM cart. Named on -Dcart in RAM mode, stop and say so; in
    // an all-carts build (no -Dcart) build the XIP cart anyway, so the plain
    // `zig build` keeps compiling this cart. `both` builds the XIP cart only.
    const explicit = opts.only != null;
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
            },
        }),
    });
    const run = b.addRunArtifact(tests);
    opts.test_step.dependOn(&run.step);
    // This cart's tests alone (the shared `test` step runs every cart's).
    b.step("test-genesis", "Run snouty-genesis host tests").dependOn(&run.step);
}

/// `-Dmd-rom` as given: `~/x.bin` (expanded here, the shell leaves `=~`
/// alone), an absolute path, a path relative to the repository root, or one
/// relative to this cart's directory (`roms/x.bin`). No option and no
/// `roms/snouty-test.bin`: the placeholder. A named file that is missing is
/// an error at build time, as for any missing source file.
fn resolve_rom(b: *Build, opt: ?[]const u8) RomFile {
    const arg = opt orelse {
        if (!exists(b, default_rom)) return .placeholder;
        return .{ .path = .{ .lazy = b.path(default_rom), .name = std.fs.path.basename(default_rom) } };
    };
    if (std.mem.startsWith(u8, arg, "~/")) {
        const home = b.graph.environ_map.get("HOME") orelse @panic("snouty-genesis: -Dmd-rom=~/...: HOME is not set");
        const abs = b.pathJoin(&.{ home, arg[2..] });
        return .{ .path = .{ .lazy = .{ .cwd_relative = abs }, .name = std.fs.path.basename(abs) } };
    }
    if (std.fs.path.isAbsolute(arg)) return .{ .path = .{ .lazy = .{ .cwd_relative = arg }, .name = std.fs.path.basename(arg) } };
    const rel = if (exists(b, arg) or !exists(b, b.fmt(dir ++ "{s}", .{arg}))) arg else b.fmt(dir ++ "{s}", .{arg});
    return .{ .path = .{ .lazy = b.path(rel), .name = std.fs.path.basename(rel) } };
}

fn exists(b: *Build, rel: []const u8) bool {
    b.root.access(b.graph.io, rel, .{}) catch return false;
    return true;
}

/// The generated `rom` module (the cart and the host tests both import it):
/// the embedded ROM (`data`, copied next to the generated rom.zig so
/// @embedFile can see it), its file name (`name`), whether it is the
/// placeholder (`placeholder`) and where the badge build gets its ROM
/// (`source`, `.drive` or `.embed`). Made once per build graph.
var rom_zig: ?Build.LazyPath = null;
var rom_step: *Build.Step = undefined;

fn rom_module(b: *Build) Build.LazyPath {
    if (rom_zig) |p| return p;
    const wf = b.addWriteFiles();
    const name = switch (rom_file) {
        .path => |p| blk: {
            _ = wf.addCopyFile(p.lazy, "rom.bin");
            break :blk p.name;
        },
        .placeholder => blk: {
            _ = wf.add("rom.bin", placeholder_rom(b));
            break :blk "placeholder.bin";
        },
    };
    const p = wf.add("rom.zig", b.fmt(
        \\//! Generated by carts/snouty-genesis/build.zig.
        \\pub const data: []const u8 = @embedFile("rom.bin");
        \\pub const name = "{f}";
        \\/// True when `data` is the build's 512-byte placeholder (no
        \\/// roms/snouty-test.bin and no -Dmd-rom).
        \\pub const placeholder = {};
        \\pub const Source = enum {{ drive, embed }};
        \\pub const source: Source = .{s};
        \\
    , .{ std.zig.fmtString(name), rom_file == .placeholder, @tagName(rom_source) }));
    rom_zig = p;
    rom_step = &wf.step;
    return p;
}

/// Adds `core` (with `z80`), `romfs` (lib/romfs.zig, the drive reader) and
/// the generated `rom` to the cart.
fn build_cart_modules(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = cart_api;
    const z80 = b.createModule(.{ .root_source_file = b.path(gear_core ++ "z80.zig") });
    cart.addImport("core", b.createModule(.{
        .root_source_file = b.path(dir ++ "core/md.zig"),
        .imports = &.{.{ .name = "z80", .module = z80 }},
    }));
    cart.addImport("romfs", b.createModule(.{ .root_source_file = b.path("lib/romfs.zig") }));
    cart.addImport("rom", b.createModule(.{ .root_source_file = rom_module(b) }));
    step.dependOn(rom_step);
}

/// The placeholder ROM, 512 bytes: 68000 vectors (SSP FFFE00, reset PC
/// 0000C0), `BRA.S *` at 0000C0 (a reserved vector slot, so the program
/// fits below the header), and a header at 0x100 with "SEGA GENESIS",
/// domestic and overseas name "SNOUTY PLACEHOLDER", ROM 000000-0001FF, RAM
/// FF0000-FFFFFF, region "JUE" and checksum 0 (no words past 0x200). Written
/// by the build so nothing binary is committed and the gitignored `roms/`
/// stays Track R's.
fn placeholder_rom(b: *Build) []const u8 {
    const r = b.allocator.alloc(u8, 512) catch @panic("oom");
    @memset(r, 0);
    const put32 = struct {
        fn f(buf: []u8, at: usize, v: u32) void {
            std.mem.writeInt(u32, buf[at..][0..4], v, .big);
        }
    }.f;
    put32(r, 0x000, 0x00FF_FE00); // initial SSP
    put32(r, 0x004, 0x0000_00C0); // reset PC
    r[0x0C0] = 0x60; // BRA.S *
    r[0x0C1] = 0xFE;
    const text = struct {
        fn f(buf: []u8, at: usize, len: usize, s: []const u8) void {
            @memset(buf[at..][0..len], ' ');
            @memcpy(buf[at..][0..s.len], s);
        }
    }.f;
    text(r, 0x100, 16, "SEGA GENESIS");
    text(r, 0x110, 16, "(C)SNOUTY 2026");
    text(r, 0x120, 48, "SNOUTY PLACEHOLDER");
    text(r, 0x150, 48, "SNOUTY PLACEHOLDER");
    text(r, 0x180, 14, "GM 00000000-00");
    // 0x18E checksum: 0.
    text(r, 0x190, 16, "J");
    put32(r, 0x1A0, 0x0000_0000); // ROM start
    put32(r, 0x1A4, 0x0000_01FF); // ROM end
    put32(r, 0x1A8, 0x00FF_0000); // RAM start
    put32(r, 0x1AC, 0x00FF_FFFF); // RAM end
    text(r, 0x1B0, 12, "");
    text(r, 0x1BC, 12, "");
    text(r, 0x1C8, 40, "");
    text(r, 0x1F0, 16, "JUE");
    return r;
}
