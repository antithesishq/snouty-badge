//! The 68000 memory map (SPEC.md section 3) as `Bus`, a concrete struct
//! holding `*Md` that `M68k(Bus)` calls through (PLAN.md "Frozen for M1":
//! `read8`, `read16`, `write8`, `write16`, `irq_level`, `ack_irq`).
//! M1 Track C owns this file.
//!
//! | Range           | What                                                  |
//! |-----------------|-------------------------------------------------------|
//! | 000000-3FFFFF   | cartridge ROM (`rom.read8/read16`; past the ROM's end |
//! |                 | FF), cartridge SRAM over it where the header declares |
//! |                 | it (`Md.sram_active`)                                 |
//! | A00000-A07FFF   | the Z80 side (`Z80Bus`: Z80 RAM, YM2612) while the    |
//! |                 | 68000 holds the Z80 bus (BUSREQ), else open bus FF;   |
//! |                 | A08000-A0FFFF (the Z80's bank window) always FF       |
//! | A10000-A1001F   | version register and I/O ports (`io_read`)            |
//! | A11100          | Z80 BUSREQ, A11200 Z80 RESET                          |
//! | A130F1          | SRAM control (bit 0: SRAM visible)                    |
//! | C00000-DFFFFF   | VDP (`addr & 1F`: data 0-3, control 4-7, HV 8-F, PSG  |
//! |                 | 11/13/15/17 write-only), mirrored through the range   |
//! | E00000-FFFFFF   | 64 KB work RAM, mirrored every 64 KB                  |
//! | anything else   | open bus: FF / FFFF read, writes dropped (A14000 TMSS |
//! |                 | included: no TMSS)                                    |
//!
//! Open bus: the real 68000 reads back the last prefetched word; this map
//! returns FF / FFFF (SPEC.md section 4 does not model the prefetch).
//!
//! Byte order: work RAM, Z80 RAM and SRAM are stored as the 68000 sees
//! them, byte `a` at index `a` (big-endian words); a word access at an even
//! address is `mem[a] << 8 | mem[a + 1]`.
//!
//! 8-bit devices on 16-bit accesses (as common emulators do it): a word
//! read of the Z80 area or the I/O ports returns the byte in both halves; a
//! word write stores the high byte (Z80 area) or the low byte (I/O, PSG).
//! A byte write to a VDP port writes the byte to both halves of the word.
const std = @import("std");
const md_mod = @import("md.zig");
const rom = @import("rom.zig");
const m68k = @import("m68k.zig");
const tunables = @import("tunables.zig");
const z80bus = @import("z80bus.zig");
const Md = md_mod.Md;
const Pad = md_mod.Pad;

/// A10001 version register: bit 7 overseas (1), bit 6 PAL (0: NTSC), bit 5
/// no expansion unit (1), bits 3-0 hardware version 0 (a model 1 without
/// TMSS, SPEC.md section 3; games skip the TMSS write when it reads 0).
pub const version: u8 = 0xA0;

pub const Bus = struct {
    md: *Md,

    /// Direct fetch window for the 68000 (`m68k.CodeWindow`): the whole
    /// ROM when it is contiguous, or the 64 KB work RAM (kept in bus byte
    /// order). Anything else, including a fragmented drive ROM, fetches
    /// through `read16`. Worth about 9 host cycles per instruction.
    pub fn code_window(self: *Bus, addr: u24) ?m68k.CodeWindow {
        const md = self.md;
        if (addr < 0x400000) {
            if (md.rom.base) |p| return .{ .ptr = p, .base = 0, .len = md.rom.size };
            return null;
        }
        if (addr >= 0xE00000) return .{ .ptr = &md.work_ram, .base = addr & 0xFF0000, .len = 0x10000 };
        return null;
    }

    pub fn read8(self: *Bus, addr: u24) u8 {
        const md = self.md;
        if (addr < 0x400000) {
            if (addr >= md.sram_active.lo and addr <= md.sram_active.hi) return md.sram[addr - md.sram_active.lo];
            return rom.read8(&md.rom, addr);
        }
        if (addr >= 0xE00000) return md.work_ram[addr & 0xFFFF];
        return read8_io(md, addr);
    }

    pub fn read16(self: *Bus, addr: u24) u16 {
        const md = self.md;
        if (addr < 0x400000) {
            if (addr >= md.sram_active.lo and addr <= md.sram_active.hi) return sram_read16(md, addr);
            return rom.read16(&md.rom, addr);
        }
        if (addr >= 0xE00000) {
            const i: u16 = @truncate(addr & 0xFFFE);
            return @as(u16, md.work_ram[i]) << 8 | md.work_ram[i + 1];
        }
        return read16_io(md, addr);
    }

    pub fn write8(self: *Bus, addr: u24, v: u8) void {
        const md = self.md;
        if (addr >= 0xE00000) {
            md.work_ram[addr & 0xFFFF] = v;
            return;
        }
        write8_io(md, addr, v);
    }

    pub fn write16(self: *Bus, addr: u24, v: u16) void {
        const md = self.md;
        if (addr >= 0xE00000) {
            const i: u16 = @truncate(addr & 0xFFFE);
            md.work_ram[i] = @truncate(v >> 8);
            md.work_ram[i + 1] = @truncate(v);
            return;
        }
        write16_io(md, addr, v);
    }

    /// `M68k`'s wait loop hook: `Md.skip_wait_loop`.
    pub fn wait_loop(self: *Bus, cpu: *md_mod.Cpu) void {
        self.md.skip_wait_loop(cpu);
    }

    /// The interrupt level presented to the 68000 (the VDP's; nothing else
    /// on the Genesis raises one the games use).
    pub inline fn irq_level(self: *Bus) u3 {
        return self.md.vdp.irq_level();
    }

    /// The same, as the VDP cached it at its last change (`Vdp.irq`): what
    /// `M68k.step` samples when the bus has it. Checked against
    /// `irq_level` in safe builds (the host tests).
    pub inline fn irq_sample(self: *Bus) u3 {
        const v = &self.md.vdp;
        if (std.debug.runtime_safety) std.debug.assert(v.irq == v.irq_level());
        return v.irq;
    }

    pub inline fn ack_irq(self: *Bus, level: u3) void {
        self.md.vdp.ack_irq(level);
    }
};

// ---- Everything off the two hot paths (ROM, work RAM) ----

fn sram_read16(md: *const Md, addr: u24) u16 {
    const i = addr - md.sram_active.lo;
    const hi = md.sram[i];
    const lo: u8 = if (addr + 1 <= md.sram_active.hi) md.sram[i + 1] else 0xFF;
    return @as(u16, hi) << 8 | lo;
}

/// The 68000 may use the Z80 side: it holds the bus (BUSREQ), or the Z80
/// is switched off (SPEC.md section 9's arbiter stub: plain memory).
inline fn z80_side_open(md: *const Md) bool {
    return md.arbiter.busreq or !tunables.z80_enabled;
}

/// BUSREQ as read at A11100 (bit 0 of the byte, bit 8 of the word): 0 when
/// the 68000 has the Z80's bus (granted at once, no latency), 1 while the
/// Z80 owns it. Reset does not grant the bus.
inline fn busack(md: *const Md) u8 {
    return if (md.arbiter.busreq) 0 else 1;
}

fn read8_io(md: *Md, addr: u24) u8 {
    if (addr >= 0xC00000) return if (addr < 0xE00000) vdp_read8(md, addr) else 0xFF;
    if (addr >= 0xA00000 and addr < 0xA10000) return z80_read(md, addr);
    if (addr >= 0xA10000 and addr < 0xA10020) return io_read(md, @truncate((addr >> 1) & 0xF));
    if (addr & 0xFFFFFE == 0xA11100) return if (addr & 1 == 0) 0xFE | busack(md) else 0xFF;
    return 0xFF;
}

fn read16_io(md: *Md, addr: u24) u16 {
    if (addr >= 0xC00000) return if (addr < 0xE00000) vdp_read16(md, addr) else 0xFFFF;
    if (addr >= 0xA00000 and addr < 0xA10000) {
        const b = z80_read(md, addr);
        return @as(u16, b) << 8 | b;
    }
    if (addr >= 0xA10000 and addr < 0xA10020) {
        const b = io_read(md, @truncate((addr >> 1) & 0xF));
        return @as(u16, b) << 8 | b;
    }
    if (addr & 0xFFFFFE == 0xA11100) return 0xFEFF | @as(u16, busack(md)) << 8;
    return 0xFFFF;
}

fn write8_io(md: *Md, addr: u24, v: u8) void {
    if (addr < 0x400000) {
        if (addr >= md.sram_active.lo and addr <= md.sram_active.hi) md.sram[addr - md.sram_active.lo] = v;
        return;
    }
    if (addr >= 0xC00000) {
        if (addr < 0xE00000) vdp_write8(md, addr, v);
        return;
    }
    if (addr >= 0xA00000 and addr < 0xA10000) return z80_write(md, addr, v);
    if (addr >= 0xA10000 and addr < 0xA10020) {
        if (addr & 1 != 0) io_write(md, @truncate((addr >> 1) & 0xF), v);
        return;
    }
    switch (addr) {
        0xA11100 => set_busreq(md, v & 1 != 0),
        0xA11200 => set_z80_reset(md, v & 1 == 0),
        0xA130F1 => sram_control(md, v),
        else => {},
    }
}

fn write16_io(md: *Md, addr: u24, v: u16) void {
    if (addr < 0x400000) {
        write8_io(md, addr, @truncate(v >> 8));
        write8_io(md, addr | 1, @truncate(v));
        return;
    }
    if (addr >= 0xC00000) {
        if (addr < 0xE00000) vdp_write16(md, addr, v);
        return;
    }
    if (addr >= 0xA00000 and addr < 0xA10000) return z80_write(md, addr, @truncate(v >> 8));
    if (addr >= 0xA10000 and addr < 0xA10020) return io_write(md, @truncate((addr >> 1) & 0xF), @truncate(v));
    switch (addr) {
        0xA11100 => set_busreq(md, v & 0x100 != 0),
        0xA11200 => set_z80_reset(md, v & 0x100 == 0),
        0xA130F0 => sram_control(md, @truncate(v)),
        else => {},
    }
}

// ---- Z80 side and arbiter (SPEC.md section 9) ----

/// A00000-A07FFF through `Z80Bus` (Z80 RAM and its mirror, the YM2612;
/// Track D's map) when the 68000 holds the bus. The Z80's bank window
/// (8000-FFFF) is not reachable from the 68000 and reads FF.
fn z80_read(md: *Md, addr: u24) u8 {
    if (!z80_side_open(md) or addr & 0x8000 != 0) return 0xFF;
    var zb = md.z80bus_for();
    return zb.read(@truncate(addr & 0x7FFF));
}

fn z80_write(md: *Md, addr: u24, v: u8) void {
    if (!z80_side_open(md) or addr & 0x8000 != 0) return;
    var zb = md.z80bus_for();
    zb.write(@truncate(addr & 0x7FFF), v);
}

fn set_busreq(md: *Md, on: bool) void {
    md.arbiter.busreq = on;
}

/// A11200: 0 asserts RESET (the Z80 and the YM2612 are reset and held),
/// 1 releases it (the Z80 starts at 0000 from its reset state).
fn set_z80_reset(md: *Md, assert: bool) void {
    if (assert) {
        z80bus.reset_line(md);
        md.z80_carry = 0;
    }
    md.arbiter.z80_reset = assert;
}

fn sram_control(md: *Md, v: u8) void {
    md.sram_active = if (v & 1 != 0) md.sram_map else .{};
}

// ---- I/O ports (A10000-A1001F) ----

/// Register `r` = (address >> 1) & F: 0 version, 1-3 data (pad 1, pad 2,
/// EXT), 4-6 control, 7-F serial (TxData FF, the rest 00).
fn io_read(md: *const Md, r: u4) u8 {
    return switch (r) {
        0 => version,
        1 => port_read(md.io.data[0], md.io.ctrl[0], pad_lines(md.pad, th_level(md.io.data[0], md.io.ctrl[0]))),
        2 => port_read(md.io.data[1], md.io.ctrl[1], 0x7F),
        3 => port_read(md.io.data[2], md.io.ctrl[2], 0x7F),
        4, 5, 6 => md.io.ctrl[r - 4],
        7, 0xA, 0xD => 0xFF,
        else => 0x00,
    };
}

fn io_write(md: *Md, r: u4, v: u8) void {
    switch (r) {
        1, 2, 3 => md.io.data[r - 1] = v,
        4, 5, 6 => md.io.ctrl[r - 4] = v,
        else => {},
    }
}

/// TH (bit 6): driven by the data register when the control register makes
/// it an output, else pulled high.
inline fn th_level(data: u8, ctrl: u8) bool {
    return ctrl & 0x40 == 0 or data & 0x40 != 0;
}

/// A data port read: output pins (control bit set) read back the data
/// register, input pins read the device; bit 7 reads the data register.
inline fn port_read(data: u8, ctrl: u8, lines: u8) u8 {
    return (data & 0x80) | (data & ctrl & 0x7F) | (lines & ~ctrl & 0x7F);
}

/// The 3-button pad's lines, active low, with TH on bit 6 as selected:
/// TH high `1 TH C B R L D U`, TH low `1 TH St A 0 0 D U`.
pub fn pad_lines(pad: u16, th: bool) u8 {
    var pressed: u8 = 0;
    if (pad & Pad.up != 0) pressed |= 0x01;
    if (pad & Pad.down != 0) pressed |= 0x02;
    if (th) {
        if (pad & Pad.left != 0) pressed |= 0x04;
        if (pad & Pad.right != 0) pressed |= 0x08;
        if (pad & Pad.b != 0) pressed |= 0x10;
        if (pad & Pad.c != 0) pressed |= 0x20;
        return 0x40 | (0x3F & ~pressed);
    }
    pressed |= 0x0C;
    if (pad & Pad.a != 0) pressed |= 0x10;
    if (pad & Pad.start != 0) pressed |= 0x20;
    return 0x3F & ~pressed;
}

// ---- VDP and PSG (C00000-DFFFFF) ----
//
// Thin adapters over the VDP's port functions (Track B's vdp.zig), so the
// integration touches only these when a signature changes. Expected at
// integration: `write_control` starts DMA with a source read through
// `dma_read16` and returns (or records) its 68000 stall, which goes into
// `md.dma_stall`.

fn vdp_read16(md: *Md, addr: u24) u16 {
    return switch (addr & 0x1F) {
        0x00...0x03 => md.vdp.read_data(),
        0x04...0x07 => md.vdp.read_status(),
        0x08...0x0F => md.vdp.hv_counter(),
        else => 0xFFFF,
    };
}

fn vdp_read8(md: *Md, addr: u24) u8 {
    const r = addr & 0x1F;
    if (r >= 0x10) return 0xFF;
    const w = vdp_read16(md, addr);
    return if (addr & 1 == 0) @truncate(w >> 8) else @truncate(w);
}

fn vdp_write16(md: *Md, addr: u24, v: u16) void {
    switch (addr & 0x1F) {
        0x00...0x03 => md.vdp.write_data(v),
        0x04...0x07 => {
            // A control write may start a 68000-memory DMA: its source words
            // come through this bus and the 68000 pays the stall next.
            var b: Bus = .{ .md = md };
            md.dma_stall += md.vdp.write_control(v, &b);
        },
        0x10...0x17 => md.psg.write(@truncate(v)),
        else => {},
    }
}

fn vdp_write8(md: *Md, addr: u24, v: u8) void {
    const r = addr & 0x1F;
    if (r >= 0x10) {
        // The PSG sits on the odd byte (C00011, mirrors 13/15/17).
        if (r < 0x18 and r & 1 != 0) md.psg.write(v);
        return;
    }
    vdp_write16(md, addr, @as(u16, v) << 8 | v);
}

/// A word of 68000 space for a VDP DMA source (ROM, SRAM, work RAM; the
/// VDP's 68000-to-VRAM DMA can reach nothing else). For Track B.
pub fn dma_read16(md: *Md, addr: u24) u16 {
    var b: Bus = .{ .md = md };
    if (addr < 0x400000 or addr >= 0xE00000) return b.read16(addr & 0xFFFFFE);
    return 0xFFFF;
}
