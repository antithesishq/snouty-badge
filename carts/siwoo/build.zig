const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=siwoo` from the repository root instead.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/siwoo/";

/// No build-time generation: cart/src/gen/name_font.zig is committed
/// (tools/gen_name_font.py).
pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    os_cart.add(b, sycl_badge_dep, .{
        .mode = opts.cart_mode,
        .name = "siwoo",
        .optimize = .ReleaseFast,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
    });

    // `zig build check-float` (shared step): fail if the cart ELF links soft-float or libm routines.
    const check_float = b.addSystemCommand(&.{"node"});
    check_float.addFileArg(b.path("tools/check_float.mjs"));
    check_float.addFileArg(b.graph.path(.install_prefix, "firmware/siwoo.elf"));
    check_float.step.dependOn(b.getInstallStep());
    check_float.has_side_effects = true;
    opts.check_float_step.dependOn(&check_float.step);

    // `zig build test` (shared step): host unit tests (cart/src/host_tests.zig
    // lists the modules), with the real cart API for its types.
    const cart_api = b.createModule(.{ .root_source_file = sycl_badge_dep.path("src/os/cart/api.zig") });
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/host_tests.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "cart-api", .module = cart_api },
        },
    }) });
    opts.test_step.dependOn(&b.addRunArtifact(tests).step);
}
