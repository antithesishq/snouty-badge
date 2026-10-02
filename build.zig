const std = @import("std");
const Build = std.Build;

const common = @import("build/common.zig");

/// Every cart. `dir` is the -Dcart name (the directory under carts/, except
/// badge-calibrate, which lives in badge-bench/calibrate/), `binary` the
/// name of the uf2/elf/wasm it produces. Either matches -Dcart.
const Cart = struct { dir: []const u8, binary: []const u8, add: common.AddFn };
const carts = [_]Cart{
    .{ .dir = "snouty-run", .binary = "snouty", .add = &@import("carts/snouty-run/build.zig").add },
    .{ .dir = "snouty-bugs", .binary = "snouty-bugs", .add = &@import("carts/snouty-bugs/build.zig").add },
    .{ .dir = "snoutenstein", .binary = "snoutenstein", .add = &@import("carts/snoutenstein/build.zig").add },
    .{ .dir = "snouty-reflections", .binary = "snouty-reflections", .add = &@import("carts/snouty-reflections/build.zig").add },
    .{ .dir = "snouty-boy", .binary = "snouty-boy", .add = &@import("carts/snouty-boy/build.zig").add },
    .{ .dir = "snouty-maze", .binary = "snouty-maze", .add = &@import("carts/snouty-maze/build.zig").add },
    .{ .dir = "snouty-gear", .binary = "snouty-gear", .add = &@import("carts/snouty-gear/build.zig").add },
    .{ .dir = "snouty-genesis", .binary = "snouty-genesis", .add = &@import("carts/snouty-genesis/build.zig").add },
    .{ .dir = "snouty-lynx", .binary = "snouty-lynx", .add = &@import("carts/snouty-lynx/build.zig").add },
    .{ .dir = "snouty-flyover", .binary = "snouty-flyover", .add = &@import("carts/snouty-flyover/build.zig").add },
    .{ .dir = "demosnout", .binary = "demosnout", .add = &@import("carts/demosnout/build.zig").add },
    .{ .dir = "badge-calibrate", .binary = "badge-calibrate", .add = &@import("badge-bench/calibrate/build.zig").add },
};

pub fn build(b: *Build) void {
    const sycl_badge_dep = b.dependency("sycl_badge", .{});

    const only = b.option([]const u8, "cart", "Comma-separated list of carts to build (default: all). Names: " ++ cart_names);

    const opts = common.Options{
        .cart_mode = b.option(common.CartMode, "cart-mode", "ram (default): the usual RAM cart; xip: execute in place from the 256 KB cart flash window (<binary>-xip.uf2); both") orelse .ram,
        .debug_overlay = b.option(bool, "debug_overlay", "Draw render timing on screen (snouty-reflections, snouty-maze, demosnout)") orelse false,
        .neopixels = b.option(bool, "neopixels", "Let carts light the neopixels (snoutenstein, snouty-maze, snouty-boy). Default off: the LEDs are painfully bright on hardware, see docs/NEOPIXELS.md") orelse false,
        .sound = b.option(bool, "sound", "Start every cart with sound on (snoutenstein, snouty-boy, snouty-gear, snouty-genesis). Default off: carts boot silent and their menu item or button turns sound on, see docs/SOUND.md") orelse false,
        .rom = b.option([]const u8, "rom", "snouty-boy: Game Boy ROM to embed (default carts/snouty-boy/tests/roms/dmg-acid2.gb, or roms/2048.gb when that is absent)"),
        .cart_optimize = b.option(std.builtin.OptimizeMode, "cart-optimize", "snouty-boy: optimize mode for the cart (default fast; its SPEC.md section 8)") orelse .fast,
        .test_optimize = b.option(std.builtin.OptimizeMode, "test-optimize", "snouty-boy: optimize mode for host tests (default safe)") orelse .safe,
        .test_filter = b.option([]const u8, "test-filter", "snouty-boy, snouty-gear: only run tests whose name contains this"),
        .rom_source = b.option(common.RomSource, "rom-source", "snouty-boy: drive (default; a ROM file on the badge drive, the embedded ROM as fallback) or embed (the embedded ROM only)") orelse .drive,
        .gg_rom = b.option([]const u8, "gg-rom", "snouty-gear: Game Gear ROM to embed (default carts/snouty-gear/roms/waternet.gg)"),
        .gg_rom_source = b.option(common.RomSource, "gg-rom-source", "snouty-gear: drive (default; ROM file on the badge drive, embedded ROM as fallback), embed, pack") orelse .drive,
        .md_rom = b.option([]const u8, "md-rom", "snouty-genesis: Genesis ROM to embed (default carts/snouty-genesis/roms/snouty-test.bin, a generated placeholder while that is absent)"),
        .md_rom_source = b.option(common.MdRomSource, "md-rom-source", "snouty-genesis: drive (default; a .gen/.md/.bin file on the badge drive, the embedded ROM as fallback) or embed") orelse .drive,
        .lynx_rom = b.option([]const u8, "lynx-rom", "snouty-lynx: Lynx ROM to embed, .lnx (headered) or headerless (default carts/snouty-lynx/roms/raycast.lnx)"),
        .lynx_rom_source = b.option(common.RomSource, "lynx-rom-source", "snouty-lynx: drive (default; a .lnx/.lyx file on the badge drive, the embedded ROM as fallback), embed, pack (not built yet)") orelse .drive,
        .only = only,
        .test_step = b.step("test", "Run every cart's host tests"),
        .check_float_step = b.step("check-float", "Fail if any cart ELF contains soft-float or libm routines"),
    };

    if (only) |list| check_names(list);
    for (carts) |c| {
        if (only) |list| if (!listed(list, c)) continue;
        c.add(b, sycl_badge_dep, opts);
    }

    // Shared library host tests (lib/): the romfs reader, the Iris mark and whatever follows.
    const lib_tests = b.addTest(.{
        .filters = if (opts.test_filter) |f| &.{f} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("lib/tests.zig"),
            .target = b.graph.host,
            .optimize = opts.test_optimize,
        }),
    });
    opts.test_step.dependOn(&b.addRunArtifact(lib_tests).step);
}

fn listed(list: []const u8, c: Cart) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        if (std.mem.eql(u8, name, c.dir) or std.mem.eql(u8, name, c.binary)) return true;
    }
    return false;
}

fn check_names(list: []const u8) void {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        var ok = false;
        for (carts) |c| ok = ok or std.mem.eql(u8, name, c.dir) or std.mem.eql(u8, name, c.binary);
        if (!ok) std.debug.panic("-Dcart: unknown cart '{s}'; known: {s}", .{ name, cart_names });
    }
}

const cart_names: []const u8 = blk: {
    var s: []const u8 = "";
    for (carts, 0..) |c, i| s = s ++ (if (i == 0) "" else ", ") ++ c.dir;
    break :blk s;
};
