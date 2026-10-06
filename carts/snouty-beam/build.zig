const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root: run
// `zig build -Dcart=snouty-beam` from the repository root.
const common = @import("../../build/common.zig");

const dir = "carts/snouty-beam/";

var build_options: ?*Build.Step.Options = null;

/// Snouty Beam: send carts badge to badge over the link cable (PLAN.md).
pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    // -Dbeam_receive=true: the receiving side, which needs the fork
    // firmware's cart transfer (fork/CART_TRANSFER.md). Off on main until
    // that OS change ships: the cart is then send-only, and its footer says
    // receiving needs the fork firmware build.
    const options = b.addOptions();
    options.addOption(bool, "receive", b.option(bool, "beam_receive", "snouty-beam: the receiving side (needs the fork firmware's cart transfer); default off") orelse false);
    build_options = options;

    os_cart.add(b, sycl_badge_dep, .{
        .mode = opts.cart_mode,
        .name = "snouty-beam",
        .optimize = .ReleaseSafe,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &add_modules,
    });
    common.add_float_check(b, opts, "snouty-beam", opts.cart_mode);

    // Host tests: the protocol on two virtual badges (cart/src/proto_test.zig)
    // with the snouty-pong fixture and its slot (tests/fixtures/).
    const mod = b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/tests.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{
            .{ .name = "beam_slot", .module = beam_slot_module(b) },
            .{ .name = "link_host", .module = link_host_module(b) },
        },
    });
    mod.addAnonymousImport("pong_uf2", .{ .root_source_file = b.path(dir ++ "tests/fixtures/snouty-pong.uf2") });
    mod.addAnonymousImport("pong_slot", .{ .root_source_file = b.path(dir ++ "tests/fixtures/beam_slot_pong.bin") });
    const tests = b.addTest(.{ .root_module = mod });
    opts.test_step.dependOn(&b.addRunArtifact(tests).step);
    const own = b.step("test-beam", "Run snouty-beam's host tests only");
    own.dependOn(&b.addRunArtifact(tests).step);
}

fn add_modules(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = cart_api;
    _ = step;
    if (build_options) |o| cart.addImport("build_options", o.createModule());
    cart.addImport("link", b.createModule(.{ .root_source_file = b.path("lib/link.zig") }));
    cart.addImport("lockstep", b.createModule(.{ .root_source_file = b.path("lib/lockstep.zig") }));
    cart.addImport("romfs", b.createModule(.{ .root_source_file = b.path("lib/romfs.zig") }));
    cart.addImport("ext_flash", b.createModule(.{ .root_source_file = b.path("lib/ext_flash.zig") }));
    cart.addImport("beam_slot", beam_slot_module(b));
}

pub fn beam_slot_module(b: *Build) *Build.Module {
    return b.createModule(.{ .root_source_file = b.path("lib/beam_slot.zig") });
}

/// lib/link.zig and its virtual cable copied under one root, as
/// `link_host.link` and `link_host.virtual` (snouty-pong's build.zig).
fn link_host_module(b: *Build) *Build.Module {
    const wf = b.addWriteFiles();
    inline for (.{ "link.zig", "link_rp2350.zig", "link_virtual.zig" }) |f| {
        _ = wf.addCopyFile(b.path("lib/" ++ f), f);
    }
    const root = wf.add("link_host.zig", "pub const link = @import(\"link.zig\");\npub const virtual = @import(\"link_virtual.zig\");\n");
    return b.createModule(.{ .root_source_file = root });
}

/// `zig build beam-slot -- in.uf2 out.bin` (declared by the root build.zig
/// so it exists whatever -Dcart says): the slot area bytes for a cart.
pub fn add_beam_slot_step(b: *Build) void {
    const exe = b.addExecutable(.{
        .name = "beam-slot",
        .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "tools/beam_slot_cli.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "beam_slot", .module = beam_slot_module(b) }},
        }),
    });
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    run.has_side_effects = true;
    b.step("beam-slot", "Write a cart's received-slot bytes: zig build beam-slot -- in.uf2 out.bin (or --info a.uf2 ...)").dependOn(&run.step);
}
