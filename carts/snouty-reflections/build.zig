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
}

var build_options: ?*Build.Step.Options = null;

fn add_options(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = b;
    _ = cart_api;
    _ = step;
    if (build_options) |o| cart.addImport("build_options", o.createModule());
}
