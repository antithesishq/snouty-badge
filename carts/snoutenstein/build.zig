const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=snoutenstein` from the repository root instead.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/snoutenstein/";

pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    // -Dneopixels=true (declared by the root build.zig) re-enables the dormant
    // LED effects in cart/src/audio.zig; off by default (docs/NEOPIXELS.md).
    const options = b.addOptions();
    options.addOption(bool, "neopixels", opts.neopixels);
    // -Dsound=true starts with sound on; off by default, Select on the title
    // toggles it (docs/SOUND.md).
    options.addOption(bool, "sound", opts.sound);
    build_options = options;

    os_cart.add(b, sycl_badge_dep, .{
        .mode = opts.cart_mode,
        .name = "snoutenstein",
        .optimize = .ReleaseSmall,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &build_cart_assets,
    });

    // `zig build test` (shared step): the pure sim/levels/parser/rewind/demo
    // suites (cart/src/host_tests.zig), the same ones tools/check.sh runs.
    // The generated-source freshness checks stay in check.sh (read-only, git).
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/host_tests.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    opts.test_step.dependOn(&b.addRunArtifact(tests).step);
}

var build_options: ?*Build.Step.Options = null;

/// One entry per PNG in assets/gen/. `bits` is palette bits per pixel (4 =
/// up to 15 colors + transparent). `transparent` reserves palette index 0 for
/// magenta #FF00FF, which tools/prepare_assets.py flattens alpha 0 to.
const Image = struct { file: []const u8, bits: u8, transparent: bool };
const images = [_]Image{
    // Sizes and frame counts: SPEC.md section 14 / PLAN.md "Asset contract".
    .{ .file = "walls.png", .bits = 4, .transparent = false },
    .{ .file = "doors.png", .bits = 4, .transparent = false },
    .{ .file = "bug_gnat.png", .bits = 4, .transparent = true },
    .{ .file = "bug_wasp.png", .bits = 4, .transparent = true },
    .{ .file = "bug_beetle.png", .bits = 4, .transparent = true },
    .{ .file = "bug_spider.png", .bits = 4, .transparent = true },
    .{ .file = "bug_boss.png", .bits = 4, .transparent = true },
    // Deathmatch (M7): the other player's billboard.
    .{ .file = "rival.png", .bits = 4, .transparent = true },
    .{ .file = "pickups.png", .bits = 4, .transparent = true },
    .{ .file = "projectiles.png", .bits = 4, .transparent = true },
    .{ .file = "weapons.png", .bits = 4, .transparent = true },
    .{ .file = "face.png", .bits = 4, .transparent = true },
    .{ .file = "hud.png", .bits = 4, .transparent = true },
    .{ .file = "title.png", .bits = 4, .transparent = true },
    .{ .file = "iris_16.png", .bits = 4, .transparent = true },
};

/// Converts the PNGs in assets/gen/ into a `gfx` module at build time,
/// mirroring sycl-badge/showcase/carts/dvd/build.zig, and wires the build
/// options module.
fn build_cart_assets(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    if (build_options) |o| cart.addImport("build_options", o.createModule());
    // Sound on the newer firmware: tone2 rendered into the streaming ring.
    cart.addImport("tone_stream", b.createModule(.{ .root_source_file = b.path("lib/tone_stream.zig") }));
    // Deathmatch (M7): the badge-to-badge link cable (root docs/LINK.md).
    cart.addImport("link", b.createModule(.{ .root_source_file = b.path("lib/link.zig") }));
    const convert = b.addExecutable(.{
        .name = "convert_gfx",
        .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "cart/build/convert_gfx.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    convert.root_module.addImport("zigimg", b.dependency("zigimg", .{}).module("zigimg"));

    const gen_gfx = b.addRunArtifact(convert);
    for (images) |img| {
        gen_gfx.addArg("-i");
        gen_gfx.addFileArg(b.path(b.fmt(dir ++ "assets/gen/{s}", .{img.file})));
        gen_gfx.addArg(b.fmt("{d}", .{img.bits}));
        gen_gfx.addArg(if (img.transparent) "true" else "false");
    }
    gen_gfx.addArg("-o");
    const gfx_zig = gen_gfx.addOutputFileArg("gfx.zig");

    const gfx_mod = b.createModule(.{
        .root_source_file = gfx_zig,
        .imports = &.{
            .{
                .name = "packed_int_array",
                .module = b.createModule(.{
                    .root_source_file = b.path(dir ++ "cart/src/packed_int_array.zig"),
                }),
            },
        },
    });
    gfx_mod.addImport("cart-api", cart_api);
    step.dependOn(&gen_gfx.step);
    cart.addImport("gfx", gfx_mod);
}
