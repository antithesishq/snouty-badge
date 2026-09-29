const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=snouty-bugs` from the repository root instead.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/snouty-bugs/";

pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    os_cart.add(b, sycl_badge_dep, .{
        .mode = opts.cart_mode,
        .name = "snouty-bugs",
        .optimize = .ReleaseSmall,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &build_cart_assets,
    });
}

/// One entry per PNG in assets/gen/. `bits` is palette bits per pixel (4 =
/// up to 15 colors + transparent). `transparent` reserves palette index 0 for
/// magenta #FF00FF, which tools/prepare_assets.py flattens alpha 0 to.
const Image = struct { file: []const u8, bits: u8, transparent: bool };
const images = [_]Image{
    // Sizes and frame counts: PLAN.md "Asset contract" / SPEC.md section 12.
    .{ .file = "ship.png", .bits = 4, .transparent = true },
    .{ .file = "thruster.png", .bits = 4, .transparent = true },
    .{ .file = "bolt.png", .bits = 4, .transparent = true },
    .{ .file = "bugs_small.png", .bits = 4, .transparent = true },
    .{ .file = "bugs.png", .bits = 4, .transparent = true },
    .{ .file = "boss.png", .bits = 4, .transparent = true },
    .{ .file = "fx_small.png", .bits = 4, .transparent = true },
    .{ .file = "fx_big.png", .bits = 4, .transparent = true },
    .{ .file = "hud.png", .bits = 4, .transparent = true },
    .{ .file = "portrait.png", .bits = 4, .transparent = true },
    .{ .file = "bg_far.png", .bits = 4, .transparent = false },
    .{ .file = "bg_near.png", .bits = 4, .transparent = true },
    .{ .file = "iris_16.png", .bits = 4, .transparent = true },
    .{ .file = "title.png", .bits = 4, .transparent = true },
};

/// Converts the PNGs in assets/gen/ into a `gfx` module at build time,
/// mirroring sycl-badge/showcase/carts/dvd/build.zig.
fn build_cart_assets(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    const convert = b.addExecutable(.{
        .name = "convert_gfx",
        .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "cart/build/convert_gfx.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    convert.root_module.addImport("zigimg", b.dependency("zigimg", .{}).module("zigimg"));

    const gen_gfx = b.addRunArtifact(convert);
    for (images) |img| {
        gen_gfx.addArg("-i");
        gen_gfx.addFileArg(b.path(b.fmt(dir ++ "assets/gen/{s}", .{img.file})));
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
                    .root_source_file = b.path(dir ++ "cart/src/packed_int_array.zig"),
                }),
            },
        },
    });
    gfx_mod.addImport("cart-api", cart_api);
    step.dependOn(&gen_gfx.step);
    cart.addImport("gfx", gfx_mod);
}
