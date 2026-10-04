const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=snouty-pipes` from the repository root instead.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/snouty-pipes/";

pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    // -Ddebug_overlay=true starts with the timing overlay on (Select toggles
    // it in such a build; the option is declared by the root build.zig).
    const options = b.addOptions();
    options.addOption(bool, "debug_overlay", opts.debug_overlay);
    build_options = options;

    os_cart.add(b, sycl_badge_dep, .{
        .mode = opts.cart_mode,
        .name = "snouty-pipes",
        .optimize = .ReleaseFast,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &build_cart_modules,
    });

    // `zig build check-float` (shared step): fail if the cart ELF links soft-float or libm routines.
    common.add_float_check(b, opts, "snouty-pipes", opts.cart_mode);

    // `zig build test` (shared step): host unit tests for the modules that do not
    // touch the cart API (cart/src/host_tests.zig lists them).
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/host_tests.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "iris", .module = b.createModule(.{ .root_source_file = b.path("lib/iris_mark.zig") }) },
        },
    }) });
    opts.test_step.dependOn(&b.addRunArtifact(tests).step);
}

var build_options: ?*Build.Step.Options = null;

/// Adds `build_options` and `iris` (lib/iris_mark.zig, the name strip's mark).
fn build_cart_modules(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = cart_api;
    _ = step;
    if (build_options) |o| cart.addImport("build_options", o.createModule());
    cart.addImport("iris", b.createModule(.{ .root_source_file = b.path("lib/iris_mark.zig") }));
}
