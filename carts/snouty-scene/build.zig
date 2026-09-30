const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=snouty-scene` from the repository root instead.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/snouty-scene/";

/// No build-time generation: the generated tables in cart/src/gen/ are
/// committed (tools/gen_font.py, tools/gen_textures.py).
pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    // -Ddebug_overlay=true compiles in the timing overlay (on at start, B
    // toggles it; the option is declared by the root build.zig).
    const options = b.addOptions();
    options.addOption(bool, "debug_overlay", opts.debug_overlay);
    build_options = options;

    os_cart.add(b, sycl_badge_dep, .{
        .mode = opts.cart_mode,
        .name = "snouty-scene",
        .optimize = .ReleaseFast,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &add_options,
    });

    // `zig build check-float` (shared step): fail if the cart ELF links soft-float or libm routines.
    const check_float = b.addSystemCommand(&.{"node"});
    check_float.addFileArg(b.path("tools/check_float.mjs"));
    check_float.addFileArg(b.graph.path(.install_prefix, "firmware/snouty-scene.elf"));
    check_float.step.dependOn(b.getInstallStep());
    check_float.has_side_effects = true;
    opts.check_float_step.dependOn(&check_float.step);

    // `zig build test` (shared step): host unit tests (cart/src/host_tests.zig
    // lists the modules). They get the real cart API for its types
    // (Pixel, DisplayColor, Framebuffer); nothing they run touches the
    // platform or the font.
    const cart_api = b.createModule(.{ .root_source_file = sycl_badge_dep.path("src/os/cart/api.zig") });
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/host_tests.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "cart-api", .module = cart_api },
            .{ .name = "iris_mark", .module = b.createModule(.{ .root_source_file = b.path("lib/iris_mark.zig") }) },
        },
    }) });
    opts.test_step.dependOn(&b.addRunArtifact(tests).step);
}

var build_options: ?*Build.Step.Options = null;

fn add_options(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = cart_api;
    _ = step;
    if (build_options) |o| cart.addImport("build_options", o.createModule());
    // The shared 24x24 Iris mark (lib/iris_mark.zig), for Fire.
    cart.addImport("iris_mark", b.createModule(.{ .root_source_file = b.path("lib/iris_mark.zig") }));
}
