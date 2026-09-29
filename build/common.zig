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
    /// -Ddebug_overlay: on-screen render timing (snouty-reflections, snouty-maze).
    debug_overlay: bool,
    /// -Drom: Game Boy ROM to embed (snouty-boy).
    rom: ?[]const u8,
    /// -Dcart-optimize: optimize mode for snouty-boy's cart.
    cart_optimize: std.builtin.OptimizeMode,
    /// -Dtest-optimize / -Dtest-filter: host test options (snouty-boy).
    test_optimize: std.builtin.OptimizeMode,
    test_filter: ?[]const u8,
    /// -Dgg-rom: Game Gear ROM to embed (snouty-gear); -Dgg-rom-source: where
    /// the badge build gets its ROM (carts/snouty-gear/SPEC.md section 7).
    gg_rom: ?[]const u8,
    gg_rom_source: RomSource,
    /// `zig build test`: every cart with host tests depends on this step.
    test_step: *Build.Step,
    /// `zig build check-float`: every cart with a float check depends on this step.
    check_float_step: *Build.Step,
};

/// -Dgg-rom-source (snouty-gear, docs/ROM_DRIVE.md): `drive` reads a ROM file
/// from the badge's USB drive with the embedded ROM as fallback; `embed` uses
/// only the embedded ROM; `pack` is the XIP bank-packer fallback (not built yet).
pub const RomSource = enum { drive, embed, pack };

pub const AddFn = *const fn (b: *Build, sycl_badge_dep: *Build.Dependency, opts: Options) void;
