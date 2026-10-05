const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=snouty-theremin` from the repository root instead.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/snouty-theremin/";

/// The theremin (docs/TOF.md M1): hand distance over the TMF8820, or the
/// stick, to a continuous voice streamed into the newer firmware's ring.
pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    os_cart.add(b, sycl_badge_dep, .{
        .mode = opts.cart_mode,
        .name = "snouty-theremin",
        .optimize = .ReleaseFast,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &add_modules,
    });

    // `zig build check-float` (shared step): the cart is all-integer.
    common.add_float_check(b, opts, "snouty-theremin", opts.cart_mode);

    // `zig build test` (shared step): the modules without the cart API
    // (cart/src/host_tests.zig lists them).
    const tests_mod = b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/host_tests.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    add_lib_imports(b, tests_mod);
    const tests = b.addTest(.{ .root_module = tests_mod });
    opts.test_step.dependOn(&b.addRunArtifact(tests).step);
}

/// lib/ modules the cart uses. The sensor driver (lib/tof.zig, M0) joins
/// these when it lands; cart/src/input.zig `sensor_frame` is where it is
/// called.
fn add_lib_imports(b: *Build, m: *Build.Module) void {
    m.addImport("tof_types", b.createModule(.{ .root_source_file = b.path("lib/tof_types.zig") }));
    m.addImport("stream_audio", b.createModule(.{ .root_source_file = b.path("lib/stream_audio.zig") }));
}

fn add_modules(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = cart_api;
    _ = step;
    add_lib_imports(b, cart);
}
