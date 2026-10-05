const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=snouty-morph` from the repository root instead.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/snouty-morph/";

/// No build-time generation: every mesh is generated in code at start().
pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    const options = b.addOptions();
    // -Ddebug_overlay=true draws the render time top-right.
    options.addOption(bool, "debug_overlay", opts.debug_overlay);
    // -Dsound: the initial value of the sound toggle (docs/SOUND.md).
    options.addOption(bool, "sound", opts.sound);
    // -Dtof-fake=true: the driver runs against its model (badge-bench).
    options.addOption(bool, "tof_fake", opts.tof_fake);
    build_options = options;

    os_cart.add(b, sycl_badge_dep, .{
        .mode = opts.cart_mode,
        .name = "snouty-morph",
        .optimize = .ReleaseFast,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &build_cart_modules,
    });

    // `zig build check-float` (shared step): f32 on the FPU only, no soft-float or libm.
    common.add_float_check(b, opts, "snouty-morph", opts.cart_mode);

    // `zig build test` (shared step): host tests for the modules without a
    // cart API dependency (cart/src/host_tests.zig lists them). The pose
    // library's own tests run from lib/tests.zig.
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/host_tests.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "tof", .module = tof_module(b) },
            .{ .name = "build_options", .module = options.createModule() },
        },
    }) });
    opts.test_step.dependOn(&b.addRunArtifact(tests).step);
}

var build_options: ?*Build.Step.Options = null;

/// lib/tof.zig: the driver, which also carries lib/tof_types.zig (`types`),
/// lib/tof_pose.zig (`pose`) and lib/tof_synth.zig (`synth`): one module,
/// so the Frame type is one type.
fn tof_module(b: *Build) *Build.Module {
    return b.createModule(.{ .root_source_file = b.path("lib/tof.zig") });
}

fn build_cart_modules(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = cart_api;
    _ = step;
    if (build_options) |o| cart.addImport("build_options", o.createModule());
    cart.addImport("tof", tof_module(b));
    // Sound on the newer firmware: tones and a drone rendered into the streaming ring.
    cart.addImport("tone_stream", b.createModule(.{ .root_source_file = b.path("lib/tone_stream.zig") }));
}
