const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=__NAME__` from the repository root instead.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/__NAME__/";

pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    os_cart.add(b, sycl_badge_dep, .{
        .mode = opts.cart_mode,
        .name = "__NAME__",
        .optimize = .ReleaseSmall,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
    });
}
