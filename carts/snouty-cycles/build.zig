const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=snouty-cycles` from the repository root instead.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/snouty-cycles/";

pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    // -Ddebug_overlay=true shows the render time in the HUD (the option is
    // declared by the root build.zig).
    const options = b.addOptions();
    options.addOption(bool, "debug_overlay", opts.debug_overlay);
    build_options = options;

    os_cart.add(b, sycl_badge_dep, .{
        .mode = opts.cart_mode,
        .name = "snouty-cycles",
        // TEMPORARY (Track L): ReleaseSmall until Track F lands its own
        // build mode and RAM savings; the lead keeps F's version on merge.
        .optimize = .ReleaseSmall,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &build_cart_modules,
    });

    // `zig build check-float` (shared step): fail if the cart ELF links soft-float or libm routines.
    common.add_float_check(b, opts, "snouty-cycles", opts.cart_mode);

    // `zig build test` (shared step): host unit tests for the modules that do not
    // touch the cart API (cart/src/host_tests.zig lists them).
    // -Dtest-filter (shared option): `tools/check.sh link` runs "LINK DUEL".
    const tests = b.addTest(.{ .filters = if (opts.test_filter) |f| &.{f} else &.{}, .root_module = b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/host_tests.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "iris", .module = b.createModule(.{ .root_source_file = b.path("lib/iris_mark.zig") }) },
            .{ .name = "link_host", .module = link_host_module(b) },
            .{ .name = "lockstep", .module = b.createModule(.{ .root_source_file = b.path("lib/lockstep.zig") }) },
        },
    }) });
    opts.test_step.dependOn(&b.addRunArtifact(tests).step);
}

var build_options: ?*Build.Step.Options = null;

/// The host tests' link (LINK DUEL's lockstep test, cart/src/net_test.zig):
/// lib/link.zig and its virtual cable (lib/link_virtual.zig, which imports
/// link.zig by path) copied side by side under one root, as
/// `link_host.link` and `link_host.virtual` (a file can belong to only one
/// module), the way snouty-gc does it.
fn link_host_module(b: *Build) *Build.Module {
    const wf = b.addWriteFiles();
    for ([_][]const u8{ "link.zig", "link_rp2350.zig", "link_virtual.zig" }) |f| {
        _ = wf.addCopyFile(b.path(b.fmt("lib/{s}", .{f})), f);
    }
    const root = wf.add("link_host.zig", "pub const link = @import(\"link.zig\");\npub const virtual = @import(\"link_virtual.zig\");\n");
    return b.createModule(.{ .root_source_file = root });
}

/// Adds `build_options`, `iris` (lib/iris_mark.zig, the title's mark),
/// `link` (lib/link.zig, the badge-to-badge link, docs/LINK.md) and
/// `lockstep` (lib/lockstep.zig, LINK DUEL's lockstep, docs/LOCKSTEP.md).
/// Both are cold next to the game and built ReleaseSmall to save RAM, as
/// Snouty Zero does.
fn build_cart_modules(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = cart_api;
    _ = step;
    if (build_options) |o| cart.addImport("build_options", o.createModule());
    cart.addImport("iris", b.createModule(.{ .root_source_file = b.path("lib/iris_mark.zig") }));
    cart.addImport("link", b.createModule(.{ .root_source_file = b.path("lib/link.zig"), .optimize = .ReleaseSmall }));
    cart.addImport("lockstep", b.createModule(.{ .root_source_file = b.path("lib/lockstep.zig"), .optimize = .ReleaseSmall }));
}
