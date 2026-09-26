const std = @import("std");
const Build = std.Build;

const sycl_badge = @import("sycl_badge");

pub fn build(b: *Build) void {
    const sycl_badge_dep = b.dependency("sycl_badge", .{});

    // -Ddebug_overlay=true draws frame timing in the top-left corner.
    const debug_overlay = b.option(bool, "debug_overlay", "Draw render timing on screen") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "debug_overlay", debug_overlay);

    // Set before add_os_cart: the custom builder runs inside that call.
    build_options = options;

    sycl_badge.add_os_cart(b, sycl_badge_dep, .{
        .name = "snouty-reflections",
        .optimize = .ReleaseFast,
        .root_source_file = b.path("cart/src/main.zig"),
        .custom_builder = &add_options,
    });

    // `zig build check-float`: install, then fail if the cart ELF links any
    // soft-float or libm routine (f64 math, or f32 work the M33 FPU cannot do).
    const check_float = b.addSystemCommand(&.{"node"});
    check_float.addFileArg(b.path("tools/check_float.mjs"));
    check_float.addFileArg(b.graph.path(.install_prefix, "firmware/snouty-reflections.elf"));
    check_float.step.dependOn(b.getInstallStep());
    check_float.has_side_effects = true;
    b.step("check-float", "Fail if the cart ELF contains soft-float routines").dependOn(&check_float.step);
}

var build_options: ?*Build.Step.Options = null;

fn add_options(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = b;
    _ = cart_api;
    _ = step;
    if (build_options) |o| cart.addImport("build_options", o.createModule());
}
