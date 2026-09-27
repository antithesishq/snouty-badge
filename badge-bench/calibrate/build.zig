const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=badge-calibrate` from the repository root instead.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "badge-bench/calibrate/";

/// The calibration cart (SPEC.md next to this file): no options, no assets,
/// no float check. ReleaseFast like the carts it calibrates. -Dcart-mode
/// applies as for every cart; the calibration targets RAM mode (the default),
/// which is what badge-bench models.
pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    os_cart.add(b, sycl_badge_dep, .{
        .mode = opts.cart_mode,
        .name = "badge-calibrate",
        .optimize = .ReleaseFast,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
    });
}
