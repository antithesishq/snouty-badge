//! The 68000 memory map (SPEC.md section 3) as `Bus`, a concrete struct
//! holding `*Md` that `M68k(Bus)` calls through (PLAN.md "Frozen for M1":
//! `read8`, `read16`, `write8`, `write16`, `irq_level`, `ack_irq`).
//! M1 Track C owns this file.
//!
//! M0 scaffold: cartridge ROM through `rom.read8/read16` at 000000-3FFFFF
//! and work RAM at E00000-FFFFFF (64 KB, mirrored); everything else reads
//! open bus (FF / FFFF) and drops writes. M1 adds the Z80 window and
//! arbiter (A00000-A11200), I/O and pads (A10000), the VDP (C00000), the
//! PSG (C00011) and SRAM.
//!
//! Work RAM is stored as the 68000 sees it: byte `addr & FFFF` at index
//! `addr & FFFF` (big-endian words). M1 may keep it word-swapped for speed
//! and must say so here and in md.zig.
const md_mod = @import("md.zig");
const rom = @import("rom.zig");
const Md = md_mod.Md;

pub const Bus = struct {
    md: *Md,

    pub inline fn read8(self: *Bus, addr: u24) u8 {
        const md = self.md;
        if (addr < 0x400000) return rom.read8(&md.rom, addr);
        if (addr >= 0xE00000) return md.work_ram[addr & 0xFFFF];
        return 0xFF;
    }

    pub inline fn read16(self: *Bus, addr: u24) u16 {
        const md = self.md;
        if (addr < 0x400000) return rom.read16(&md.rom, addr);
        if (addr >= 0xE00000) {
            const i: u16 = @truncate(addr & 0xFFFE);
            return @as(u16, md.work_ram[i]) << 8 | md.work_ram[i + 1];
        }
        return 0xFFFF;
    }

    pub inline fn write8(self: *Bus, addr: u24, v: u8) void {
        if (addr >= 0xE00000) self.md.work_ram[addr & 0xFFFF] = v;
    }

    pub inline fn write16(self: *Bus, addr: u24, v: u16) void {
        if (addr >= 0xE00000) {
            const i: u16 = @truncate(addr & 0xFFFE);
            self.md.work_ram[i] = @truncate(v >> 8);
            self.md.work_ram[i + 1] = @truncate(v);
        }
    }

    /// The interrupt level presented to the 68000 (the VDP's; nothing else
    /// on the Genesis raises one the games use).
    pub inline fn irq_level(self: *Bus) u3 {
        return self.md.vdp.irq_level();
    }

    pub inline fn ack_irq(self: *Bus, level: u3) void {
        self.md.vdp.ack_irq(level);
    }
};
