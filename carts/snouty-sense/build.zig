const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root: run
// `zig build -Dcart=snouty-sense` from the repository root.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/snouty-sense/";

/// The time-of-flight probe cart: lib/tof.zig on the Qwiic port
/// (docs/TOF.md). The driver's host tests are lib/'s
/// (lib/tests/tof_unit.zig); the cart's own (the EYES voice) are
/// cart/src/host_tests.zig.
pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    const options = b.addOptions();
    options.addOption(bool, "tof_fake", opts.tof_fake);
    // -Dsound: the initial value of the EYES sound toggle (docs/SOUND.md).
    options.addOption(bool, "sound", opts.sound);
    build_options = options;

    const tests_mod = b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/host_tests.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    tests_mod.addImport("stream_audio", b.createModule(.{ .root_source_file = b.path("lib/stream_audio.zig") }));
    const tests = b.addTest(.{ .root_module = tests_mod });
    opts.test_step.dependOn(&b.addRunArtifact(tests).step);

    os_cart.add(b, sycl_badge_dep, .{
        .mode = opts.cart_mode,
        .name = "snouty-sense",
        .optimize = .ReleaseSafe,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &add_modules,
    });
}

var build_options: ?*Build.Step.Options = null;

fn add_modules(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = cart_api;
    _ = step;
    if (build_options) |o| cart.addImport("build_options", o.createModule());
    cart.addImport("tof", b.createModule(.{ .root_source_file = b.path("lib/tof.zig") }));
    cart.addImport("stream_audio", b.createModule(.{ .root_source_file = b.path("lib/stream_audio.zig") }));
}
