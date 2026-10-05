//! Builds one cart for the SYCL Badge V2 in RAM mode, XIP mode or both.
//!
//! RAM mode mirrors upstream's `add_os_cart` (the pinned SDK's copy takes
//! microzig from the SDK's own build.zig.zon, whose 0.17.7 does not build
//! with Zig 0.17.0; this one takes it from ours). XIP mode mirrors it with
//! three differences: the firmware root is `build/xip/entry.zig` (vector
//! table plus a reset handler that initialises memory and calls the SDK's
//! `_start`), the linker script is the SDK's `cart_xip.ld` (code and
//! read-only data in the 256 KB cart flash window, `.data`/`.bss` in cart
//! RAM), and the artifact is named `<name>-xip`. The wasm for the simulator is
//! the same in both modes and is built once.
const std = @import("std");
const Build = std.Build;

const microzig = @import("microzig");

const MicroBuild = microzig.MicroBuild(.{ .rp2xxx = true });

pub const Mode = enum {
    ram,
    xip,
    both,

    /// The name suffixes of the firmware ELFs this mode installs under
    /// `<prefix>/firmware/`: `<name>.elf` for RAM, `<name>-xip.elf` for XIP.
    pub fn elf_suffixes(mode: Mode) []const []const u8 {
        return switch (mode) {
            .ram => &.{""},
            .xip => &.{"-xip"},
            .both => &.{ "", "-xip" },
        };
    }
};

pub const CustomBuilder = *const fn (b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void;

pub const Options = struct {
    name: []const u8,
    optimize: std.builtin.OptimizeMode,
    root_source_file: Build.LazyPath,
    /// Adds the cart's own modules (assets, options) to the user cart module.
    custom_builder: ?CustomBuilder = null,
    /// The XIP variant's builder when it must differ from `custom_builder`
    /// (snouty-zero: a build option saying which variant this is).
    xip_custom_builder: ?CustomBuilder = null,
    mode: Mode = .ram,
    /// Which variant the simulator wasm is built from in `.both` mode. `.ram`
    /// (the default) is upstream's: `add_os_cart` builds it from the RAM
    /// firmware's module. `.xip` builds the RAM firmware without a wasm and
    /// the wasm from the XIP variant's modules (snouty-genesis: the RAM cart
    /// drops the Z80 and the scrubber, the simulator keeps them).
    wasm_from: WasmFrom = .ram,
    /// The RAM firmware's linker script when it must differ from the SDK's
    /// `cart_ram.ld` (snouty-genesis: the same script with a smaller stack
    /// reservation, its measured peak being a fraction of the SDK's 32 KB).
    ram_linker_script: ?Build.LazyPath = null,
};

pub const WasmFrom = enum { ram, xip };

pub fn add(b: *Build, dep: *Build.Dependency, options: Options) void {
    switch (options.mode) {
        .ram => add_ram(b, dep, options),
        .xip => add_xip(b, dep, options, true),
        .both => switch (options.wasm_from) {
            .ram => {
                add_ram(b, dep, options);
                add_xip(b, dep, options, false);
            },
            .xip => {
                _ = add_ram_firmware(b, dep, options);
                add_xip(b, dep, options, true);
            },
        },
    }
}

/// Upstream's `add_os_cart`: the RAM firmware, and the simulator wasm from a
/// copy of the firmware's root module, as upstream builds it.
fn add_ram(b: *Build, dep: *Build.Dependency, options: Options) void {
    const ram = add_ram_firmware(b, dep, options) orelse return;

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_module = b.allocator.create(Build.Module) catch @panic("oom");
    wasm_module.* = ram.fw.exe.root_module.*;
    wasm_module.resolved_target = wasm_target;
    const wasm = b.addExecutable(.{
        .name = options.name,
        .root_module = wasm_module,
    });
    wasm.entry = .disabled;
    wasm.import_memory = true;
    wasm.initial_memory = 64 * 65536;
    wasm.max_memory = 64 * 65536;
    wasm.stack_size = 14752;
    wasm.global_base = 160 * 128 * 2 + 0x1e;
    wasm.rdynamic = true;
    b.installArtifact(wasm);
    if (ram.asset_step) |step| wasm.step.dependOn(step);
}

const RamFirmware = struct { fw: *MicroBuild.Firmware, asset_step: ?*Build.Step };

/// Upstream's `add_os_cart` without its wasm: the same target, root, linker
/// script, imports and installs. `add_ram` adds the wasm; `wasm_from = .xip`
/// uses it alone.
fn add_ram_firmware(b: *Build, dep: *Build.Dependency, options: Options) ?RamFirmware {
    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return null;
    const badge_v2_target = badge_v2(mb, dep);

    const cart_api_module = b.createModule(.{
        .root_source_file = dep.builder.path("src/os/cart/api.zig"),
    });
    const user_cart_module = b.createModule(.{
        .root_source_file = options.root_source_file,
        .imports = &.{
            .{ .name = "cart-api", .module = cart_api_module },
        },
    });
    const fw = mb.add_firmware(.{
        .name = options.name,
        .target = badge_v2_target,
        .optimize = options.optimize,
        .root_source_file = options.root_source_file,
        .linker_script = .{
            .file = options.ram_linker_script orelse dep.builder.path("src/cart/cart_ram.ld"),
            .generate = .none,
            .assert_microzig_main = false,
        },
    });
    fw.exe.root_module.addImport("user_cart", user_cart_module);
    fw.exe.root_module.addImport("cart-api", cart_api_module);

    const asset_step: ?*Build.Step = if (options.custom_builder) |builder| blk: {
        const shared_step = b.allocator.create(Build.Step.TopLevel) catch @panic("oom");
        shared_step.* = .{
            .step = .init(.{
                .name = b.fmt("{s} assets", .{options.name}),
                .tag = .top_level,
                .owner = b,
            }),
            .description = "Reusable build node for cart assets",
        };
        builder(b, fw.exe.root_module, cart_api_module, &shared_step.step);
        break :blk &shared_step.step;
    } else null;

    const board_mod = fw.core_mod.import_table.get("board").?;
    cart_api_module.addImport("board", board_mod);
    cart_api_module.addImport("tracy_protocol", b.createModule(.{
        .root_source_file = b.path("src/os/system/tracy_protocol.zig"),
    }));

    mb.install_firmware(fw, .{ .format = .elf });
    mb.install_firmware(fw, .{ .format = .{ .uf2 = .{ .family_id = .RP2350_ARM_S } } });
    if (asset_step) |step| fw.exe.step.dependOn(step);
    return .{ .fw = fw, .asset_step = asset_step };
}

/// Same target as upstream's sycl_badge_v2_microzig_target (private there).
fn badge_v2(mb: *MicroBuild, dep: *Build.Dependency) *microzig.Target {
    return mb.ports.rp2xxx.boards.raspberrypi.pico2_arm.derive(.{
        .board = .{
            .name = "SYCL Badge V2",
            .root_source_file = dep.builder.path("src/board_v2.zig"),
        },
    });
}

fn add_xip(b: *Build, dep: *Build.Dependency, options: Options, with_wasm: bool) void {
    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    // Same target as upstream's sycl_badge_v2_microzig_target (private there).
    const badge_v2_target = mb.ports.rp2xxx.boards.raspberrypi.pico2_arm.derive(.{
        .board = .{
            .name = "SYCL Badge V2",
            .root_source_file = dep.builder.path("src/board_v2.zig"),
        },
    });

    const cart_api_module = b.createModule(.{
        .root_source_file = dep.builder.path("src/os/cart/api.zig"),
    });
    const user_cart_module = b.createModule(.{
        .root_source_file = options.root_source_file,
        .imports = &.{
            .{ .name = "cart-api", .module = cart_api_module },
        },
    });

    const fw = mb.add_firmware(.{
        .name = b.fmt("{s}-xip", .{options.name}),
        .target = badge_v2_target,
        .optimize = options.optimize,
        .root_source_file = b.path("build/xip/entry.zig"),
        .linker_script = .{
            .file = dep.builder.path("src/cart/cart_xip.ld"),
            .generate = .none,
            .assert_microzig_main = false,
        },
    });
    fw.exe.root_module.addImport("user_cart", user_cart_module);
    fw.exe.root_module.addImport("cart-api", cart_api_module);

    const asset_step: ?*Build.Step = if (options.xip_custom_builder orelse options.custom_builder) |builder| blk: {
        const shared_step = b.allocator.create(Build.Step.TopLevel) catch @panic("oom");
        shared_step.* = .{
            .step = .init(.{
                .name = b.fmt("{s}-xip assets", .{options.name}),
                .tag = .top_level,
                .owner = b,
            }),
            .description = "Reusable build node for cart assets",
        };
        builder(b, user_cart_module, cart_api_module, &shared_step.step);
        break :blk &shared_step.step;
    } else null;

    // As upstream: font.zig must belong to exactly one module (board).
    const board_mod = fw.core_mod.import_table.get("board").?;
    cart_api_module.addImport("board", board_mod);
    cart_api_module.addImport("tracy_protocol", b.createModule(.{
        .root_source_file = b.path("src/os/system/tracy_protocol.zig"),
    }));

    mb.install_firmware(fw, .{ .format = .elf });
    mb.install_firmware(fw, .{ .format = .{ .uf2 = .{ .family_id = .RP2350_ARM_S } } });
    if (asset_step) |step| fw.exe.step.dependOn(step);

    if (!with_wasm) return;

    // Simulator build from the user cart module, as upstream does from its root.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_module = b.allocator.create(Build.Module) catch @panic("oom");
    wasm_module.* = user_cart_module.*;
    wasm_module.resolved_target = wasm_target;
    wasm_module.optimize = options.optimize;
    const wasm = b.addExecutable(.{
        .name = options.name,
        .root_module = wasm_module,
    });
    wasm.entry = .disabled;
    wasm.import_memory = true;
    wasm.initial_memory = 64 * 65536;
    wasm.max_memory = 64 * 65536;
    wasm.stack_size = 14752;
    wasm.global_base = 160 * 128 * 2 + 0x1e;
    wasm.rdynamic = true;
    b.installArtifact(wasm);
    if (asset_step) |step| wasm.step.dependOn(step);
}
