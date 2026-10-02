const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=snouty-reflections` from the repository root instead.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/snouty-reflections/";

pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {

    // -Ddebug_overlay=true draws frame timing in the top-left corner (declared by the root build.zig).
    const options = b.addOptions();
    options.addOption(bool, "debug_overlay", opts.debug_overlay);
    // -Dreflections_variant picks frame rate, render scale and scene knobs; cart/src/variant.zig
    // maps it to constants (PLAN.md "M2.1 Perf variants").
    const variant = b.option(Variant, "reflections_variant", "snouty-reflections: cut20 (default, shipped), full20, full15 or half30") orelse .cut20;
    options.addOption(Variant, "reflections_variant", variant);
    // -Dreflections_bench=height: attract sweeps the eye height min to max and back
    // continuously (a primary-table rebuild every frame), for the M3 bench row.
    // motion_off: scene.motion = false (the M2.2 legacy identity; bench row 1).
    const bench = b.option(Bench, "reflections_bench", "snouty-reflections: none (default), height (bench-only height sweep) or motion_off (legacy identity)") orelse .none;
    options.addOption(Bench, "reflections_bench", bench);

    // Set before add_os_cart: the custom builder runs inside that call.
    build_options = options;

    os_cart.add(b, sycl_badge_dep, .{
        .mode = opts.cart_mode,
        .name = "snouty-reflections",
        .optimize = .ReleaseFast,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &add_options,
    });

    // `zig build check-float` (shared step): install, then fail if the cart ELF links any
    // soft-float or libm routine (f64 math, or f32 work the M33 FPU cannot do).
    common.add_float_check(b, opts, "snouty-reflections", opts.cart_mode);

    // `zig build test` (shared step): the variant table's host test
    // (tests/variant_unit.zig, review 2026-10-01 G3): the frozen path tracer's
    // slice is shorter than the frame period in every variant. variant.zig is
    // pure apart from build_options, so it runs with the selected options.
    const variant_host = b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/variant.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{.{ .name = "build_options", .module = options.createModule() }},
    });
    const variant_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path(dir ++ "tests/variant_unit.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{.{ .name = "variant", .module = variant_host }},
    }) });
    opts.test_step.dependOn(&b.addRunArtifact(variant_tests).step);
}

/// Perf variants; the table is in cart/src/variant.zig.
const Variant = enum { full20, cut20, full15, half30 };
/// Bench-only behaviours (PLAN.md M3 "Budget and bench").
const Bench = enum { none, height, motion_off };

var build_options: ?*Build.Step.Options = null;

fn add_options(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = b;
    _ = cart_api;
    _ = step;
    if (build_options) |o| cart.addImport("build_options", o.createModule());
}
