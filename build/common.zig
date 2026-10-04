//! Shared between the root build.zig and every carts/<name>/build.zig.
//!
//! Each cart exposes `pub fn add(b, sycl_badge_dep, opts)`. It calls
//! upstream's `add_os_cart` for its own cart and hangs any host tests or
//! checks off the shared steps in `Options`. Build options that more than one
//! cart uses are declared once by the root and passed here, because
//! `b.option` refuses to declare the same name twice.
const std = @import("std");
const Build = std.Build;

/// -Dcart-mode: RAM cart (the default), execute-in-place cart, or both.
pub const CartMode = @import("os_cart.zig").Mode;

pub const Options = struct {
    cart_mode: CartMode,
    /// -Ddebug_overlay: on-screen render timing (snouty-reflections, snouty-maze,
    /// demosnout, snouty-zero, snouty-flyover); the emulators' overlay on at boot.
    debug_overlay: bool,
    /// -Dneopixels: let a cart light the neopixels. Default false: the badge
    /// LEDs are painfully bright even at 1%, so every cart leaves them dark
    /// and the LED code in snoutenstein, snouty-maze and snouty-boy is
    /// compiled out (docs/NEOPIXELS.md).
    neopixels: bool,
    /// -Dsound: the initial value of every sounding cart's sound toggle
    /// (snoutenstein, snouty-boy, snouty-gear, snouty-genesis). Default false:
    /// carts boot silent and a menu item or button turns sound on for the
    /// session (docs/SOUND.md).
    sound: bool,
    /// -Drom: Game Boy ROM for snouty-boy's simulator and `-Drom-source=embed`
    /// builds (the default badge build embeds none).
    rom: ?[]const u8,
    /// -Dcart-optimize: optimize mode for snouty-boy's cart.
    cart_optimize: std.builtin.OptimizeMode,
    /// -Dtest-optimize / -Dtest-filter: host test options (snouty-boy).
    test_optimize: std.builtin.OptimizeMode,
    test_filter: ?[]const u8,
    /// -Drom-source: where the snouty-boy badge build gets its ROM
    /// (carts/snouty-boy/SPEC.md section 11, docs/ROM_DRIVE.md).
    rom_source: RomSource,
    /// -Dgg-rom: Game Gear ROM to embed (snouty-gear); -Dgg-rom-source: where
    /// the badge build gets its ROM (carts/snouty-gear/SPEC.md section 7).
    gg_rom: ?[]const u8,
    gg_rom_source: RomSource,
    /// -Dmd-rom: Genesis ROM to embed (snouty-genesis); -Dmd-rom-source:
    /// where its badge build gets the ROM (carts/snouty-genesis/SPEC.md
    /// section 11).
    md_rom: ?[]const u8,
    md_rom_source: MdRomSource,
    /// -Dlynx-rom: Lynx ROM to embed (snouty-lynx); -Dlynx-rom-source: where
    /// its badge build gets the ROM (carts/snouty-lynx/SPEC.md section 7).
    lynx_rom: ?[]const u8,
    lynx_rom_source: RomSource,
    /// -Dcart as given (null: every cart is built). snouty-genesis builds
    /// only as an XIP cart: named here without -Dcart-mode=xip it stops the
    /// build, in an all-carts build it builds XIP regardless.
    only: ?[]const u8,
    /// `zig build test`: every cart with host tests depends on this step.
    test_step: *Build.Step,
    /// `zig build check-float`: every cart with a float check depends on this step.
    check_float_step: *Build.Step,
};

/// -Drom-source (snouty-boy), -Dgg-rom-source (snouty-gear), -Dlynx-rom-source
/// (snouty-lynx), docs/ROM_DRIVE.md: `drive` reads a ROM file from the badge's
/// USB drive and puts no ROM in the badge cart; `embed` uses only the embedded
/// ROM; `pack` is the XIP bank-packer fallback (not built yet).
pub const RomSource = enum { drive, embed, pack };

/// -Dmd-rom-source (snouty-genesis): `drive` reads a `.gen`/`.md`/`.bin`
/// file from the badge's USB drive and puts no ROM in the badge cart;
/// `embed` uses only the embedded ROM.
pub const MdRomSource = enum { drive, embed };

/// `zig build check-float` for one cart: after install, run
/// tools/check_float.mjs on every firmware ELF the cart's mode produces
/// (`<name>.elf` for RAM, `<name>-xip.elf` for XIP, both for `both`), so the
/// check always inspects the artifact that was just built and never a stale
/// ELF of the other mode left in the output directory. `mode` is the mode
/// the cart passed to os_cart.add (usually `opts.cart_mode`; XIP-only carts
/// pass `.xip`).
pub fn add_float_check(b: *Build, opts: Options, name: []const u8, mode: CartMode) void {
    for (mode.elf_suffixes()) |suffix| {
        const check = b.addSystemCommand(&.{"node"});
        check.addFileArg(b.path("tools/check_float.mjs"));
        check.addFileArg(b.graph.path(.install_prefix, b.fmt("firmware/{s}{s}.elf", .{ name, suffix })));
        check.step.dependOn(b.getInstallStep());
        check.has_side_effects = true;
        opts.check_float_step.dependOn(&check.step);
    }
}

pub const AddFn = *const fn (b: *Build, sycl_badge_dep: *Build.Dependency, opts: Options) void;
