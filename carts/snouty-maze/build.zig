const std = @import("std");
const Build = std.Build;

const sycl_badge = @import("sycl_badge");

pub fn build(b: *Build) void {
    const sycl_badge_dep = b.dependency("sycl_badge", .{});

    // -Ddebug_overlay=true draws render timing in the top-left corner (Select toggles it).
    const debug_overlay = b.option(bool, "debug_overlay", "Draw render timing on screen") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "debug_overlay", debug_overlay);
    build_options = options;

    sycl_badge.add_os_cart(b, sycl_badge_dep, .{
        .name = "snouty-maze",
        .optimize = .ReleaseFast,
        .root_source_file = b.path("cart/src/main.zig"),
        .custom_builder = &build_cart_assets,
    });

    // `zig build check-float`: fail if the cart ELF links soft-float or libm routines.
    const check_float = b.addSystemCommand(&.{"node"});
    check_float.addFileArg(b.path("tools/check_float.mjs"));
    check_float.addFileArg(b.graph.path(.install_prefix, "firmware/snouty-maze.elf"));
    check_float.step.dependOn(b.getInstallStep());
    check_float.has_side_effects = true;
    b.step("check-float", "Fail if the cart ELF contains soft-float routines").dependOn(&check_float.step);

    // `zig build test`: host unit tests for the modules that do not touch the
    // cart API (cart/src/host_tests.zig lists them).
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("cart/src/host_tests.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    b.step("test", "Run host unit tests").dependOn(&b.addRunArtifact(tests).step);
}

var build_options: ?*Build.Step.Options = null;

/// One entry per PNG in assets/gen/. `bits` is palette bits per pixel (4 =
/// up to 15 colors + transparent). `transparent` reserves palette index 0 for
/// magenta #FF00FF, which tools/prepare_assets.py flattens alpha 0 to.
/// Sizes and frame counts: SPEC.md section 10 / PLAN.md "Asset contract".
const Image = struct { file: []const u8, bits: u8, transparent: bool };
const images = [_]Image{
    .{ .file = "wall.png", .bits = 4, .transparent = false },
    .{ .file = "floor.png", .bits = 4, .transparent = false },
    .{ .file = "ceiling.png", .bits = 4, .transparent = false },
    .{ .file = "finish.png", .bits = 4, .transparent = false },
    .{ .file = "snouty.png", .bits = 4, .transparent = true },
    .{ .file = "snouty_top.png", .bits = 4, .transparent = true },
    .{ .file = "smiley.png", .bits = 4, .transparent = true },
    .{ .file = "logo.png", .bits = 4, .transparent = true },
};

/// Converts the PNGs in assets/gen/ into a `gfx` module at build time
/// (copied from snouty-bugs) and wires the build options module.
fn build_cart_assets(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    if (build_options) |o| cart.addImport("build_options", o.createModule());

    const convert = b.addExecutable(.{
        .name = "convert_gfx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cart/build/convert_gfx.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    convert.root_module.addImport("zigimg", b.dependency("zigimg", .{}).module("zigimg"));

    const gen_gfx = b.addRunArtifact(convert);
    for (images) |img| {
        gen_gfx.addArg("-i");
        gen_gfx.addFileArg(b.path(b.fmt("assets/gen/{s}", .{img.file})));
        gen_gfx.addArg(b.fmt("{d}", .{img.bits}));
        gen_gfx.addArg(if (img.transparent) "true" else "false");
    }
    gen_gfx.addArg("-o");
    const gfx_zig = gen_gfx.addOutputFileArg("gfx.zig");

    const gfx_mod = b.createModule(.{
        .root_source_file = gfx_zig,
        .imports = &.{
            .{
                .name = "packed_int_array",
                .module = b.createModule(.{
                    .root_source_file = b.path("cart/src/packed_int_array.zig"),
                }),
            },
        },
    });
    gfx_mod.addImport("cart-api", cart_api);
    step.dependOn(&gen_gfx.step);
    cart.addImport("gfx", gfx_mod);
}
