const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=snouty-run` from the repository root instead.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/snouty-run/";

pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    os_cart.add(b, sycl_badge_dep, .{
        .mode = opts.cart_mode,
        .name = "snouty",
        .optimize = .ReleaseSmall,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &build_cart_assets,
    });
}

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
    // Args per image: -i <png> <palette bits> <transparency>.
    // Transparency reserves palette index 0 as magenta (31,0,31), which the
    // flattened #FF00FF backgrounds of the run and jump strips and the Iris map onto.
    gen_gfx.addArg("-i");
    gen_gfx.addFileArg(b.path(dir ++ "assets/gen/snouty_run.png"));
    gen_gfx.addArg("4");
    gen_gfx.addArg("true");
    gen_gfx.addArg("-i");
    gen_gfx.addFileArg(b.path(dir ++ "assets/gen/snouty_jump.png"));
    gen_gfx.addArg("4");
    gen_gfx.addArg("true");
    gen_gfx.addArg("-i");
    gen_gfx.addFileArg(b.path(dir ++ "assets/gen/ghz_ground.png"));
    gen_gfx.addArg("4");
    gen_gfx.addArg("false");
    gen_gfx.addArg("-i");
    gen_gfx.addFileArg(b.path(dir ++ "assets/gen/iris_spin.png"));
    gen_gfx.addArg("4");
    gen_gfx.addArg("true");
    gen_gfx.addArg("-i");
    gen_gfx.addFileArg(b.path(dir ++ "assets/gen/ghz_bg_0.png"));
    gen_gfx.addArg("8");
    gen_gfx.addArg("false");
    gen_gfx.addArg("-i");
    gen_gfx.addFileArg(b.path(dir ++ "assets/gen/ghz_bg_1.png"));
    gen_gfx.addArg("8");
    gen_gfx.addArg("false");
    gen_gfx.addArg("-i");
    gen_gfx.addFileArg(b.path(dir ++ "assets/gen/ghz_bg_2.png"));
    gen_gfx.addArg("8");
    gen_gfx.addArg("false");
    gen_gfx.addArg("-i");
    gen_gfx.addFileArg(b.path(dir ++ "assets/gen/ghz_bg_3.png"));
    gen_gfx.addArg("8");
    gen_gfx.addArg("false");
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
