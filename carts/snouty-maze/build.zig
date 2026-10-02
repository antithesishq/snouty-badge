const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=snouty-maze` from the repository root instead.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/snouty-maze/";

pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {

    // -Ddebug_overlay=true draws render timing in the top-left corner (Select toggles it;
    // the option is declared by the root build.zig).
    const options = b.addOptions();
    options.addOption(bool, "debug_overlay", opts.debug_overlay);
    // -Dneopixels=true re-enables the dormant LED effects in leds.zig (default off:
    // the badge LEDs are unusably bright; docs/NEOPIXELS.md).
    options.addOption(bool, "neopixels", opts.neopixels);
    // -Dmaze_size=N: the maze's side in cells at start (default 12, clamped to
    // 4..16 = maze.max_size). badge-bench's `--poke maze_size=N` and the wasm
    // `debug_set_size` still change it at run time.
    const maze_size = b.option(u8, "maze_size", "snouty-maze: maze side in cells, 4..16 (default 12)") orelse 12;
    options.addOption(u8, "maze_size", std.math.clamp(maze_size, 4, 16));
    // -Dbadge=tufty (declared by the root build.zig; snouty-tufty only): the
    // maze seed comes from the microsecond clock (cart.rand() is always 0 there).
    common.add_badge_option(options, opts);
    build_options = options;

    os_cart.add(b, sycl_badge_dep, .{
        .mode = opts.cart_mode,
        .name = "snouty-maze",
        .optimize = .ReleaseFast,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &build_cart_assets,
    });

    // `zig build check-float` (shared step): fail if the cart ELF links soft-float or libm routines.
    common.add_float_check(b, opts, "snouty-maze", opts.cart_mode);

    // `zig build test` (shared step): host unit tests for the modules that do not
    // touch the cart API (cart/src/host_tests.zig lists them).
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
/// Sizes and frame counts: SPEC.md section 10 / PLAN.md "Asset contract".
const Image = struct { file: []const u8, bits: u8, transparent: bool };
const images = [_]Image{
    .{ .file = "wall.png", .bits = 4, .transparent = false },
    .{ .file = "floor.png", .bits = 4, .transparent = false },
    .{ .file = "ceiling.png", .bits = 4, .transparent = false },
    .{ .file = "finish.png", .bits = 4, .transparent = false },
    .{ .file = "snouty.png", .bits = 4, .transparent = true },
    .{ .file = "smiley.png", .bits = 4, .transparent = true },
    .{ .file = "logo.png", .bits = 4, .transparent = true },
    .{ .file = "wall_pic.png", .bits = 4, .transparent = false },
    .{ .file = "start.png", .bits = 4, .transparent = true },
    .{ .file = "iris.png", .bits = 4, .transparent = true },
};

/// Converts the PNGs in assets/gen/ into a `gfx` module at build time
/// (copied from snouty-bugs) and wires the build options module.
fn build_cart_assets(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    if (build_options) |o| cart.addImport("build_options", o.createModule());

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
