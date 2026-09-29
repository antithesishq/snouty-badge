const std = @import("std");
const Build = std.Build;
const common = @import("../../build/common.zig");

/// M0 skeleton: nothing is built yet. Replaced by the cart track.
pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    _ = b;
    _ = sycl_badge_dep;
    _ = opts;
}
