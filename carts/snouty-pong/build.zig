const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root: run
// `zig build -Dcart=snouty-pong` from the repository root.
const common = @import("../../build/common.zig");

const dir = "carts/snouty-pong/";

/// Snouty Pong: the example two-badge game on lib/lockstep.zig.
pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    os_cart.add(b, sycl_badge_dep, .{
        .mode = opts.cart_mode,
        .name = "snouty-pong",
        .optimize = .ReleaseSafe,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &add_modules,
    });
    common.add_float_check(b, opts, "snouty-pong", opts.cart_mode);

    // Host tests: two badges on the virtual cable (cart/src/pong_test.zig).
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/pong_test.zig"),
        .target = b.graph.host,
        .imports = &.{
            .{ .name = "lockstep", .module = lockstep_module(b) },
            .{ .name = "link_host", .module = link_host_module(b) },
        },
    }) });
    opts.test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn add_modules(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = cart_api;
    _ = step;
    cart.addImport("link", b.createModule(.{ .root_source_file = b.path("lib/link.zig") }));
    cart.addImport("lockstep", lockstep_module(b));
}

fn lockstep_module(b: *Build) *Build.Module {
    return b.createModule(.{ .root_source_file = b.path("lib/lockstep.zig") });
}

/// lib/link.zig and its virtual cable copied under one root, as
/// `link_host.link` and `link_host.virtual` (link_virtual.zig imports
/// link.zig by path, and a file can belong to only one module).
fn link_host_module(b: *Build) *Build.Module {
    const wf = b.addWriteFiles();
    inline for (.{ "link.zig", "link_rp2350.zig", "link_virtual.zig" }) |f| {
        _ = wf.addCopyFile(b.path("lib/" ++ f), f);
    }
    const root = wf.add("link_host.zig", "pub const link = @import(\"link.zig\");\npub const virtual = @import(\"link_virtual.zig\");\n");
    return b.createModule(.{ .root_source_file = root });
}
