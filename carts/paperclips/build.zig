const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=paperclips` from the repository root instead.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/paperclips/";

/// The `game` module: the port of the original's JavaScript (track L,
/// cart/src/game/). The cart, the UI host tests and the oracle runner all
/// import it as "game".
const game_root = dir ++ "cart/src/game/game.zig";

pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    // RAM cart only (XIP is gone from the show firmware). ReleaseFast: the
    // game runs its rules in soft-float f64 every frame.
    os_cart.add(b, sycl_badge_dep, .{
        .mode = .ram,
        .name = "paperclips",
        .optimize = .ReleaseSmall,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &build_cart_modules,
    });

    // `zig build test` (shared step): the game's tests (cart/src/game/tests.zig)
    // and the UI's (cart/src/ui/tests.zig: number formats, wrapping, the
    // page and cursor logic against the real game), both on the host.
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
            .imports = &.{
                .{ .name = "game", .module = game_module(b, b.graph.host, .Debug) },
                .{ .name = "save", .module = save_module(b) },
            },
        }),
    });
    opts.test_step.dependOn(&b.addRunArtifact(ui_tests).step);

    // The saved game (cart/src/game/snapshot_tests.zig): the autoplayer to
    // stage 3 with a save, load and compare at checkpoints. ReleaseSafe:
    // hours of virtual game time.
    const snapshot_tests = b.addTest(.{
        .filters = if (opts.test_filter) |f| &.{f} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "cart/src/game/snapshot_tests.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    opts.test_step.dependOn(&b.addRunArtifact(snapshot_tests).step);

    // `zig build paperclips-oracle`: the oracle's Zig side (tools/oracle_runner.zig,
    // track O) on the host, installed as zig-out/bin/paperclips-oracle.
    const oracle = b.addExecutable(.{
        .name = "paperclips-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "tools/oracle_runner.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "game", .module = game_module(b, b.graph.host, .ReleaseSafe) }},
        }),
    });
    const oracle_step = b.step("paperclips-oracle", "Build the paperclips oracle runner (zig-out/bin/paperclips-oracle)");
    oracle_step.dependOn(&b.addInstallArtifact(oracle, .{}).step);
}

/// lib/save.zig: cart saves (the badge OS's 0x2C messages; a fake on the
/// host, nothing in wasm).
fn save_module(b: *Build) *Build.Module {
    return b.createModule(.{ .root_source_file = b.path("lib/save.zig") });
}

fn game_module(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(game_root),
        .target = target,
        .optimize = optimize,
    });
}

/// Adds `game` to the cart module (the firmware's and the wasm's target).
fn build_cart_modules(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    _ = cart_api;
    _ = step;
    cart.addImport("game", b.createModule(.{ .root_source_file = b.path(game_root) }));
    cart.addImport("save", save_module(b));
}
