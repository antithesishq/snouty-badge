//! The Z80's memory map (SPEC.md section 9) as `Z80Bus`, a concrete struct
//! holding `*Md` that Snouty Gear's `Z80(Z80Bus)` calls through (PLAN.md
//! "Frozen for M1"; the requirements are listed at the top of
//! carts/snouty-gear/core/z80.zig: `read`, `write`, `in`, `out`,
//! `irq_line`, and optionally `halt_steps`). M1 Track D owns this file.
//!
//! The Z80 core is imported as the `z80` module (rooted at
//! carts/snouty-gear/core/z80.zig by this cart's build.zig), not copied.
//!
//! M0 scaffold: Z80 RAM at 0000-3FFF (8 KB, mirrored); the rest reads FF and
//! drops writes. Ports are unused on the Genesis (no IN/OUT devices): reads
//! FF, writes dropped. M1 adds the YM2612 (4000-4003), the bank register
//! (6000), the VDP/PSG (7F00-7F1F) and the 68000 window (8000-FFFF).
const z80 = @import("z80");
const Md = @import("md.zig").Md;

pub const Z80Bus = struct {
    md: *Md,

    pub inline fn read(self: *Z80Bus, addr: u16) u8 {
        if (addr < 0x4000) return self.md.z80_ram[addr & 0x1FFF];
        return 0xFF;
    }

    pub inline fn write(self: *Z80Bus, addr: u16, v: u8) void {
        if (addr < 0x4000) self.md.z80_ram[addr & 0x1FFF] = v;
    }

    pub inline fn in(self: *Z80Bus, port: u8) u8 {
        _ = self;
        _ = port;
        return 0xFF;
    }

    pub inline fn out(self: *Z80Bus, port: u8, v: u8) void {
        _ = self;
        _ = port;
        _ = v;
    }

    /// INT, asserted for one line from V-int (SPEC.md section 9).
    pub inline fn irq_line(self: *Z80Bus) bool {
        return self.md.z80_int;
    }
};

/// The Z80 as the Genesis runs it: Gear's interpreter over this bus.
pub const Cpu = z80.Z80(Z80Bus);

// Analyse (and so compile) `Cpu.step` in every build that imports this file,
// so the cross-cart module import is proven before M1 calls it.
comptime {
    _ = &Cpu.step;
}
