const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=raspberry-trail` from the repository root instead.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/raspberry-trail/";

/// The `game` module: the port of reference/oregon.bas (track L,
/// cart/src/game/). The cart, the UI host tests and the oracle runner all
/// import it as "game".
const game_root = dir ++ "cart/src/game/game.zig";

/// Set by `add` before `os_cart.add` calls `build_cart_modules`.
var build_options: ?*Build.Step.Options = null;

pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    // -Dsound seeds the sound toggle (docs/SOUND.md); M2 adds the sound.
    const options = b.addOptions();
    options.addOption(bool, "sound", opts.sound);
    build_options = options;

    // RAM cart only (XIP is gone from the show firmware).
    os_cart.add(b, sycl_badge_dep, .{
        .mode = .ram,
        .name = "raspberry-trail",
        .optimize = .ReleaseSmall,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &build_cart_modules,
    });

    // `zig build test` (shared step): the engine's tests and the UI's, on the host.
    const game_tests = b.addTest(.{
        .filters = if (opts.test_filter) |f| &.{f} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "cart/src/game/tests.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    opts.test_step.dependOn(&b.addRunArtifact(game_tests).step);

    const ui_tests = b.addTest(.{
        .filters = if (opts.test_filter) |f| &.{f} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "cart/src/ui/tests.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "game", .module = game_module(b, b.graph.host, .Debug) }},
        }),
    });
    opts.test_step.dependOn(&b.addRunArtifact(ui_tests).step);

    // `zig build raspberry-trail-oracle`: the engine side of the oracle
    // (tools/oracle_runner.zig) on the host, installed as
    // zig-out/bin/raspberry-trail-oracle. SPEC section 6.
    const oracle = b.addExecutable(.{
        .name = "raspberry-trail-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "tools/oracle_runner.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "game", .module = game_module(b, b.graph.host, .ReleaseSafe) }},
        }),
    });
    const oracle_step = b.step("raspberry-trail-oracle", "Build the Raspberry Trail oracle runner (zig-out/bin/raspberry-trail-oracle)");
    oracle_step.dependOn(&b.addInstallArtifact(oracle, .{}).step);
}

fn game_module(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(game_root),
        .target = target,
        .optimize = optimize,
    });
}

/// Adds `game`, `build_options` and `tone_stream` to the cart module (the
/// firmware's and the wasm's target).
fn build_cart_modules(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = cart_api;
    _ = step;
    cart.addImport("game", b.createModule(.{ .root_source_file = b.path(game_root) }));
    if (build_options) |o| cart.addImport("build_options", o.createModule());
    cart.addImport("tone_stream", b.createModule(.{ .root_source_file = b.path("lib/tone_stream.zig") }));
}
