const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=snouty-flyover` from the repository root instead.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/snouty-flyover/";

pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    // -Ddebug_overlay=true draws render timing in the top-right corner (declared by the root build.zig).
    const options = b.addOptions();
    options.addOption(bool, "debug_overlay", opts.debug_overlay);
    // PLAN.md "Knobs in the root build": the vsync lock and the map ring depth.
    const fps = b.option(u32, "flyover_fps", "snouty-flyover: vsync lock, 30 (default) or 60") orelse 30;
    if (fps != 30 and fps != 60) std.debug.panic("-Dflyover_fps must be 30 or 60, got {d}", .{fps});
    options.addOption(u32, "flyover_fps", fps);
    const depth = b.option(u32, "flyover_depth", "snouty-flyover: map ring depth in rows, 256 (default) or 128") orelse 256;
    if (depth != 128 and depth != 256) std.debug.panic("-Dflyover_depth must be 128 or 256, got {d}", .{depth});
    options.addOption(u32, "flyover_depth", depth);

    // Set before add_os_cart: the custom builder runs inside that call.
    build_options = options;

    os_cart.add(b, sycl_badge_dep, .{
        .mode = opts.cart_mode,
        .name = "snouty-flyover",
        .optimize = .ReleaseFast,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &add_options,
    });

    // `zig build check-float` (shared step): the cart is all-integer; fail if the ELF
    // links any soft-float or libm routine.
    const check_float = b.addSystemCommand(&.{"node"});
    check_float.addFileArg(b.path("tools/check_float.mjs"));
    check_float.addFileArg(b.graph.path(.install_prefix, "firmware/snouty-flyover.elf"));
    check_float.step.dependOn(b.getInstallStep());
    check_float.has_side_effects = true;
    opts.check_float_step.dependOn(&check_float.step);
}

var build_options: ?*Build.Step.Options = null;

fn add_options(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = b;
    _ = cart_api;
    _ = step;
    if (build_options) |o| cart.addImport("build_options", o.createModule());
}
