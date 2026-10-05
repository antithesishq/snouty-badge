//! Forked from snouty-zero/build.zig at f8f6962.
const std = @import("std");
const Build = std.Build;

const os_cart = @import("../../build/os_cart.zig");
// A module of the root build.zig, not a package root. If Zig says "import of
// file outside module path" here, `zig build` was run in this directory: run
// `zig build -Dcart=snouty-gc` from the repository root instead.
const common = @import("../../build/common.zig");

/// This cart's directory, relative to the repository root that build.zig runs from.
const dir = "carts/snouty-gc/";

/// Generated data files embedded by the `assets` module. Each becomes
/// `assets.<name>: []const u8`. Since M3 the league and track data live in
/// cart/src/gen/tracks/, embedded by track.zig itself.
const data_files = [_][]const u8{
    "font.bin",
};

/// The RAM cart is the shipped artifact (XIP is a no-go on SYCL hardware,
/// SPEC 2); `-Dcart-mode=xip|both` still builds the XIP variant from the
/// same modules, as for every cart, but nothing measures it.
pub fn add(b: *Build, sycl_badge_dep: *Build.Dependency, opts: common.Options) void {
    const options = b.addOptions();
    // -Ddebug_overlay=true draws the frame time top-right (declared by the root build.zig).
    options.addOption(bool, "debug_overlay", opts.debug_overlay);
    // -Dsound: the initial value of the sound toggle (docs/SOUND.md).
    options.addOption(bool, "sound", opts.sound);
    build_options = options;

    os_cart.add(b, sycl_badge_dep, .{
        .mode = opts.cart_mode,
        .name = "snouty-gc",
        .optimize = .ReleaseSmall,
        .root_source_file = b.path(dir ++ "cart/src/main.zig"),
        .custom_builder = &build_cart_modules,
    });

    // `zig build check-float` (shared step): the cart is all-integer; fail if the ELF
    // links any soft-float or libm routine.
    common.add_float_check(b, opts, "snouty-gc", opts.cart_mode);

    // `zig build test` (shared step): host tests for the modules without a cart
    // API dependency (cart/src/host_tests.zig lists them).
    const tests_mod = b.createModule(.{
        .root_source_file = b.path(dir ++ "cart/src/host_tests.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    tests_mod.addImport("assets", assets_module(b));
    tests_mod.addImport("link_host", link_host_module(b));
    tests_mod.addImport("lockstep", lockstep_module(b));
    // Cart saves (root docs/SAVES.md; career_save.zig): lib/save.zig's host fake.
    tests_mod.addImport("save", b.createModule(.{ .root_source_file = b.path("lib/save.zig") }));
    const tests = b.addTest(.{ .root_module = tests_mod });
    opts.test_step.dependOn(&b.addRunArtifact(tests).step);
    // `zig build test-gc`: this cart's host tests alone (the shared `test`
    // step also runs every other cart's).
    const own = b.step("test-gc", "Run snouty-gc's host tests only");
    own.dependOn(&b.addRunArtifact(tests).step);
}

var build_options: ?*Build.Step.Options = null;

/// lib/lockstep.zig imports only std (it is generic over the link), so one
/// module serves the cart and the host tests.
fn lockstep_module(b: *Build) *Build.Module {
    return b.createModule(.{ .root_source_file = b.path("lib/lockstep.zig") });
}

/// The host tests' link: lib/link.zig and its virtual cable
/// (lib/link_virtual.zig, which imports link.zig by path) copied side by
/// side under one root, `link_host.link` and `link_host.virtual` (a file
/// can belong to only one module, so the cart's `link` module cannot be
/// shared with the virtual cable).
fn link_host_module(b: *Build) *Build.Module {
    const wf = b.addWriteFiles();
    for ([_][]const u8{ "link.zig", "link_rp2350.zig", "link_virtual.zig" }) |f| {
        _ = wf.addCopyFile(b.path(b.fmt("lib/{s}", .{f})), f);
    }
    const root = wf.add("link_host.zig", "pub const link = @import(\"link.zig\");\npub const virtual = @import(\"link_virtual.zig\");\n");
    return b.createModule(.{ .root_source_file = root });
}

/// One entry per sprite sheet in assets/gen/ (ASSETS_ENGINE.md has the
/// manifest). `bits` is palette bits per pixel (4 = up to 15 colours +
/// transparent); `transparent` reserves palette index 0 for the #FF00FF
/// key. Each becomes `gfx.<stem>` with width, height, colors, indices.
const Image = struct { file: []const u8, bits: u8, transparent: bool };
const images = [_]Image{
    // Zero's engine sheets kept (ASSETS_ENGINE.md): the car shadow, and
    // Zero's fx.png renamed exhaust.png for the BURST flame (the art
    // track's fx.png owns the `fx` name).
    .{ .file = "shadow.png", .bits = 4, .transparent = true },
    .{ .file = "exhaust.png", .bits = 4, .transparent = true },
    // art track (tools/draw_art.py); see ASSETS.md
    .{ .file = "art/portrait_snouty.png", .bits = 4, .transparent = false },
    .{ .file = "art/portrait_legacy.png", .bits = 4, .transparent = false },
    .{ .file = "art/portrait_kiddie.png", .bits = 4, .transparent = false },
    .{ .file = "art/portrait_sysadmin.png", .bits = 4, .transparent = false },
    .{ .file = "art/portrait_rootkit.png", .bits = 4, .transparent = false },
    .{ .file = "art/portrait_botnet.png", .bits = 4, .transparent = false },
    .{ .file = "art/car_snouty.png", .bits = 4, .transparent = true },
    .{ .file = "art/car_legacy.png", .bits = 4, .transparent = true },
    .{ .file = "art/car_kiddie.png", .bits = 4, .transparent = true },
    .{ .file = "art/car_sysadmin.png", .bits = 4, .transparent = true },
    .{ .file = "art/car_rootkit.png", .bits = 4, .transparent = true },
    .{ .file = "art/car_botnet.png", .bits = 4, .transparent = true },
    .{ .file = "art/weapons.png", .bits = 4, .transparent = true },
    .{ .file = "art/decals.png", .bits = 4, .transparent = true },
    .{ .file = "art/pickups.png", .bits = 4, .transparent = true },
    .{ .file = "art/fx.png", .bits = 4, .transparent = true },
    .{ .file = "art/claw.png", .bits = 4, .transparent = true },
    .{ .file = "art/hud.png", .bits = 4, .transparent = true },
    .{ .file = "art/hazards.png", .bits = 4, .transparent = true },
};

/// The `assets` module: a generated assets.zig with one `@embedFile` per
/// data file, the files copied next to it (an @embedFile cannot reach
/// outside its module's directory).
fn assets_module(b: *Build) *Build.Module {
    const wf = b.addWriteFiles();
    var src: std.ArrayList(u8) = .empty;
    src.appendSlice(b.allocator, "//! Generated by carts/snouty-gc/build.zig: the committed assets/gen/*.bin files.\n") catch @panic("oom");
    for (data_files) |f| {
        _ = wf.addCopyFile(b.path(b.fmt(dir ++ "assets/gen/{s}", .{f})), f);
        const stem = f[0 .. f.len - ".bin".len];
        src.appendSlice(b.allocator, b.fmt("pub const {s}: []const u8 = @embedFile(\"{s}\");\n", .{ stem, f })) catch @panic("oom");
    }
    const assets_zig = wf.add("assets.zig", src.items);
    return b.createModule(.{ .root_source_file = assets_zig });
}

fn build_cart_modules(b: *Build, cart: *Build.Module, cart_api: *Build.Module, step: *Build.Step) void {
    cart.addImport("build_options", build_options.?.createModule());
    cart.addImport("assets", assets_module(b));
    // Sound on the newer firmware: tone2 rendered into the streaming ring.
    cart.addImport("tone_stream", b.createModule(.{ .root_source_file = b.path("lib/tone_stream.zig") }));
    // The badge-to-badge link (docs/LINK.md) under net.zig's lockstep (docs/NET.md).
    cart.addImport("link", b.createModule(.{ .root_source_file = b.path("lib/link.zig") }));
    // net.zig is GC's names over the shared lockstep (root docs/LOCKSTEP.md).
    cart.addImport("lockstep", lockstep_module(b));
    // Cart saves (root docs/SAVES.md): the CIRCUIT's `gcp/career`, career_save.zig.
    cart.addImport("save", b.createModule(.{ .root_source_file = b.path("lib/save.zig") }));

    // The `gfx` module: the PNGs in `images` through the per-cart converter
    // (snouty-maze / snouty-bugs pattern), generated at build time.
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
