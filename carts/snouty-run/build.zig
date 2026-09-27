const std = @import("std");
const Build = std.Build;

const sycl_badge = @import("sycl_badge");

pub fn build(b: *Build) void {
    const sycl_badge_dep = b.dependency("sycl_badge", .{});

    sycl_badge.add_os_cart(b, sycl_badge_dep, .{
        .name = "snouty",
        .optimize = .ReleaseSmall,
        .root_source_file = b.path("cart/src/main.zig"),
        .custom_builder = &build_cart_assets,
    });
}

/// Converts the PNGs in assets/gen/ into a `gfx` module at build time,
/// mirroring sycl-badge/showcase/carts/dvd/build.zig.
fn build_cart_assets(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
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
    // Args per image: -i <png> <palette bits> <transparency>.
    // Transparency reserves palette index 0 as magenta (31,0,31), which the
    // flattened #FF00FF backgrounds of the run and jump strips and the Iris map onto.
    gen_gfx.addArg("-i");
    gen_gfx.addFileArg(b.path("assets/gen/snouty_run.png"));
    gen_gfx.addArg("4");
    gen_gfx.addArg("true");
    gen_gfx.addArg("-i");
    gen_gfx.addFileArg(b.path("assets/gen/snouty_jump.png"));
    gen_gfx.addArg("4");
    gen_gfx.addArg("true");
    gen_gfx.addArg("-i");
    gen_gfx.addFileArg(b.path("assets/gen/ghz_ground.png"));
    gen_gfx.addArg("4");
    gen_gfx.addArg("false");
    gen_gfx.addArg("-i");
    gen_gfx.addFileArg(b.path("assets/gen/iris_spin.png"));
    gen_gfx.addArg("4");
    gen_gfx.addArg("true");
    gen_gfx.addArg("-i");
    gen_gfx.addFileArg(b.path("assets/gen/ghz_bg_0.png"));
    gen_gfx.addArg("8");
    gen_gfx.addArg("false");
    gen_gfx.addArg("-i");
    gen_gfx.addFileArg(b.path("assets/gen/ghz_bg_1.png"));
    gen_gfx.addArg("8");
    gen_gfx.addArg("false");
    gen_gfx.addArg("-i");
    gen_gfx.addFileArg(b.path("assets/gen/ghz_bg_2.png"));
    gen_gfx.addArg("8");
    gen_gfx.addArg("false");
    gen_gfx.addArg("-i");
    gen_gfx.addFileArg(b.path("assets/gen/ghz_bg_3.png"));
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
                    .root_source_file = b.path("cart/src/packed_int_array.zig"),
                }),
            },
        },
    });
    gfx_mod.addImport("cart-api", cart_api);
    step.dependOn(&gen_gfx.step);
    cart.addImport("gfx", gfx_mod);
}
