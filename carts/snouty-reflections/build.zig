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
    // -Dreflections_hw_trace=true prints every frame's render time on the OS console
    // (USB serial) for comparing hardware with badge-bench frame by frame.
    options.addOption(bool, "hw_trace", b.option(bool, "reflections_hw_trace", "snouty-reflections: print render_us per frame on the console") orelse false);
    // -Dreflections_variant picks frame rate, render scale and scene knobs; cart/src/variant.zig
    // maps it to constants (PLAN.md "M2.1 Perf variants").
    const variant = b.option(Variant, "reflections_variant", "snouty-reflections: cut20 (default, shipped), full20, full15 or half30") orelse .cut20;
    options.addOption(Variant, "reflections_variant", variant);

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
    const check_float = b.addSystemCommand(&.{"node"});
    check_float.addFileArg(b.path("tools/check_float.mjs"));
    check_float.addFileArg(b.graph.path(.install_prefix, "firmware/snouty-reflections.elf"));
    check_float.step.dependOn(b.getInstallStep());
    check_float.has_side_effects = true;
    opts.check_float_step.dependOn(&check_float.step);
}

/// Perf variants; the table is in cart/src/variant.zig.
const Variant = enum { full20, cut20, full15, half30 };

var build_options: ?*Build.Step.Options = null;

fn add_options(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = b;
    _ = cart_api;
    _ = step;
    if (build_options) |o| cart.addImport("build_options", o.createModule());
}
