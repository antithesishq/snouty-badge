//! Memory map and memory bank controllers. Owner in M1: track A.
//! PPU registers 0xFF40..0xFF4B are delegated to core/ppu.zig
//! (`ppu.write_reg` / `ppu.read_reg`) so their side effects live with the PPU.
const gb_mod = @import("gb.zig");
const Gb = gb_mod.Gb;
const Reg = gb_mod.Reg;
const ppu = @import("ppu.zig");
const timer = @import("timer.zig");
const serial = @import("serial.zig");
const joypad = @import("joypad.zig");

pub const MbcKind = enum(u8) { none, mbc1, mbc3, mbc5 };

pub const Mbc = struct {
    kind: MbcKind = .none,
    /// Raw bank register as written (MBC1: low 5 bits; MBC3: 7 bits;
    /// MBC5: 9 bits).
    rom_bank: u16 = 1,
    /// MBC1: the 2-bit upper register; MBC3/MBC5: the RAM bank register.
    ram_bank: u8 = 0,
    ram_enabled: bool = false,
    /// Header declares cart RAM (0x149 != 0).
    has_ram: bool = false,
    /// MBC1 banking mode bit.
    mode: u8 = 0,
    /// ROM size in 16 KB banks minus one, rounded up to a power of two.
    rom_bank_mask: u16 = 1,
    /// Cached byte offset of the bank mapped at 0x0000 (MBC1 mode 1 only).
    rom0_offset: u32 = 0,
    /// Cached byte offset of the switchable ROM bank into `Gb.rom`.
    rom_bank_offset: u32 = 0x4000,
    /// Cached byte offset of the active RAM bank into `Gb.cart_ram`. With
    /// cart RAM capped at 8 KB it is always 0, kept for when that changes.
    ram_bank_offset: u32 = 0,
    /// Cart RAM reads/writes go through (enabled, present, not an MBC3 RTC
    /// register).
    ram_active: bool = false,

    /// Header byte 0x147 selects the controller (SPEC.md section 3).
    pub fn from_header(rom: []const u8) Mbc {
        var banks: u32 = 2;
        while (banks * 0x4000 < rom.len) banks *= 2;
        var m: Mbc = .{ .rom_bank_mask = @intCast(banks - 1) };
        if (rom.len < 0x150) return m;
        m.kind = switch (rom[0x147]) {
            0x00, 0x08, 0x09 => .none,
            0x01, 0x02, 0x03 => .mbc1,
            0x0F, 0x10, 0x11, 0x12, 0x13 => .mbc3,
            0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E => .mbc5,
            else => .none,
        };
        m.has_ram = rom[0x149] != 0;
        // No controller: RAM (if any) is always mapped.
        if (m.kind == .none) m.ram_enabled = true;
        m.update();
        return m;
    }

    /// Recompute the cached offsets after a register write.
    fn update(m: *Mbc) void {
        var bank: u32 = m.rom_bank;
        var bank0: u32 = 0;
        var ram: u32 = 0;
        switch (m.kind) {
            .none => bank = 1,
            .mbc1 => {
                // Zero check is on the low 5 bits only: 0x20/0x40/0x60 -> +1.
                var low = m.rom_bank & 0x1F;
                if (low == 0) low = 1;
                const upper: u32 = m.ram_bank & 3;
                bank = (upper << 5) | low;
                if (m.mode == 1) {
                    bank0 = upper << 5;
                    ram = upper;
                }
            },
            .mbc3 => {
                bank = m.rom_bank & 0x7F;
                if (bank == 0) bank = 1;
                ram = m.ram_bank & 3;
            },
            .mbc5 => {
                bank = m.rom_bank & 0x1FF;
                ram = m.ram_bank & 0xF;
            },
        }
        bank &= m.rom_bank_mask;
        bank0 &= m.rom_bank_mask;
        m.rom_bank_offset = bank * 0x4000;
        m.rom0_offset = bank0 * 0x4000;
        m.ram_bank_offset = (ram * 0x2000) & (0x2000 - 1);
        const rtc = m.kind == .mbc3 and m.ram_bank >= 0x08;
        m.ram_active = m.ram_enabled and m.has_ram and !rtc;
    }

    fn write(m: *Mbc, addr: u16, v: u8) void {
        switch (m.kind) {
            .none => return,
            .mbc1 => switch (addr >> 13) {
                0 => m.ram_enabled = (v & 0x0F) == 0x0A,
                1 => m.rom_bank = v & 0x1F,
                2 => m.ram_bank = v & 3,
                else => m.mode = v & 1,
            },
            .mbc3 => switch (addr >> 13) {
                0 => m.ram_enabled = (v & 0x0F) == 0x0A,
                1 => m.rom_bank = v & 0x7F,
                2 => m.ram_bank = v,
                else => {}, // RTC latch: no RTC
            },
            .mbc5 => switch (addr >> 12) {
                0, 1 => m.ram_enabled = (v & 0x0F) == 0x0A,
                2 => m.rom_bank = (m.rom_bank & 0x100) | v,
                3 => m.rom_bank = (m.rom_bank & 0xFF) | (@as(u16, v & 1) << 8),
                4, 5 => m.ram_bank = v & 0x0F,
                else => {},
            },
        }
        m.update();
    }
};

/// Documented post-boot DMG I/O values (Pan Docs, "Power Up Sequence").
pub fn reset_io(gb: *Gb) void {
    const io = &gb.io;
    io.* = @splat(0);
    io[Reg.p1] = 0xCF;
    io[Reg.sb] = 0x00;
    io[Reg.sc] = 0x7E;
    io[Reg.tima] = 0x00;
    io[Reg.tma] = 0x00;
    io[Reg.tac] = 0xF8;
    io[Reg.if_] = 0xE1;
    const apu_regs = [_]struct { u8, u8 }{
        .{ 0x10, 0x80 }, .{ 0x11, 0xBF }, .{ 0x12, 0xF3 }, .{ 0x13, 0xFF }, .{ 0x14, 0xBF },
        .{ 0x16, 0x3F }, .{ 0x17, 0x00 }, .{ 0x18, 0xFF }, .{ 0x19, 0xBF }, .{ 0x1A, 0x7F },
        .{ 0x1B, 0xFF }, .{ 0x1C, 0x9F }, .{ 0x1D, 0xFF }, .{ 0x1E, 0xBF }, .{ 0x20, 0xFF },
        .{ 0x21, 0x00 }, .{ 0x22, 0x00 }, .{ 0x23, 0xBF }, .{ 0x24, 0x77 }, .{ 0x25, 0xF3 },
        .{ 0x26, 0xF1 },
    };
    for (apu_regs) |r| io[r[0]] = r[1];
    io[Reg.lcdc] = 0x91;
    io[Reg.stat] = 0x85;
    io[Reg.scy] = 0;
    io[Reg.scx] = 0;
    io[Reg.ly] = 0;
    io[Reg.lyc] = 0;
    io[Reg.dma] = 0xFF;
    io[Reg.bgp] = 0xFC;
    io[Reg.obp0] = 0xFF;
    io[Reg.obp1] = 0xFF;
    io[Reg.wy] = 0;
    io[Reg.wx] = 0;
    gb.ie = 0;
}

pub fn read8(gb: *Gb, addr: u16) u8 {
    if (addr < 0x4000) {
        const off = gb.mbc.rom0_offset + addr;
        return if (off < gb.rom.len) gb.rom[off] else 0xFF;
    }
    switch (@as(u4, @truncate(addr >> 12))) {
        0x4...0x7 => {
            const off = gb.mbc.rom_bank_offset + (addr - 0x4000);
            return if (off < gb.rom.len) gb.rom[off] else 0xFF;
        },
        0x8, 0x9 => return gb.vram[addr - 0x8000],
        0xA, 0xB => {
            if (!gb.mbc.ram_active) return 0xFF;
            return gb.cart_ram[gb.mbc.ram_bank_offset + (addr - 0xA000)];
        },
        0xC, 0xD => return gb.wram[addr - 0xC000],
        0xE => return gb.wram[addr - 0xE000],
        0xF => {
            if (addr < 0xFE00) return gb.wram[addr - 0xE000];
            if (addr >= 0xFF80) {
                if (addr == 0xFFFF) return gb.ie;
                return gb.hram[addr - 0xFF80];
            }
            if (addr < 0xFEA0) return gb.oam[addr - 0xFE00];
            if (addr < 0xFF00) return 0x00; // unusable area (DMG, OAM not blocked)
            return read_io(gb, @truncate(addr));
        },
        else => unreachable,
    }
}

fn read_io(gb: *Gb, reg: u8) u8 {
    return switch (reg) {
        Reg.p1 => gb.io[Reg.p1] | 0xC0,
        Reg.sb => gb.io[Reg.sb],
        Reg.sc => gb.io[Reg.sc] | 0x7E,
        Reg.div, Reg.tima, Reg.tma => gb.io[reg],
        Reg.tac => gb.io[Reg.tac] | 0xF8,
        Reg.if_ => gb.io[Reg.if_] | 0xE0,
        // APU registers and wave RAM: raw until M3.
        0x10...0x14, 0x16...0x1E, 0x20...0x26, 0x30...0x3F => gb.io[reg],
        Reg.dma => gb.io[Reg.dma],
        0x40...0x45, 0x47...0x4B => ppu.read_reg(gb, reg),
        else => 0xFF,
    };
}

pub fn write8(gb: *Gb, addr: u16, v: u8) void {
    switch (@as(u4, @truncate(addr >> 12))) {
        0x0...0x7 => gb.mbc.write(addr, v),
        0x8, 0x9 => gb.vram[addr - 0x8000] = v,
        0xA, 0xB => {
            if (gb.mbc.ram_active) gb.cart_ram[gb.mbc.ram_bank_offset + (addr - 0xA000)] = v;
        },
        0xC, 0xD => gb.wram[addr - 0xC000] = v,
        0xE => gb.wram[addr - 0xE000] = v,
        0xF => {
            if (addr < 0xFE00) {
                gb.wram[addr - 0xE000] = v;
            } else if (addr >= 0xFF80) {
                if (addr == 0xFFFF) gb.ie = v else gb.hram[addr - 0xFF80] = v;
            } else if (addr < 0xFEA0) {
                gb.oam[addr - 0xFE00] = v;
            } else if (addr >= 0xFF00) {
                write_io(gb, @truncate(addr), v);
            }
        },
    }
}

fn write_io(gb: *Gb, reg: u8, v: u8) void {
    switch (reg) {
        Reg.p1 => {
            gb.io[Reg.p1] = (gb.io[Reg.p1] & 0xCF) | (v & 0x30);
            joypad.update(gb);
        },
        Reg.sb => gb.io[Reg.sb] = v,
        Reg.sc => {
            gb.io[Reg.sc] = v | 0x7E;
            if ((v & 0x80) != 0) serial.start_transfer(gb);
        },
        Reg.div => timer.write_div(gb),
        Reg.tima, Reg.tma => gb.io[reg] = v,
        Reg.tac => timer.write_tac(gb, v),
        Reg.if_ => gb.io[Reg.if_] = v | 0xE0,
        0x10...0x14, 0x16...0x1E, 0x20...0x26, 0x30...0x3F => gb.io[reg] = v,
        Reg.dma => {
            oam_dma(gb, v);
            ppu.write_reg(gb, reg, v);
        },
        0x40...0x45, 0x47...0x4B => ppu.write_reg(gb, reg, v),
        else => {},
    }
}

/// Instant OAM DMA: copy 160 bytes from page `v` (SPEC.md section 4).
fn oam_dma(gb: *Gb, v: u8) void {
    const src = @as(u16, v) << 8;
    // Pages 0xFE/0xFF alias echo RAM on real hardware.
    const base = if (v >= 0xFE) src - 0x2000 else src;
    for (&gb.oam, 0..) |*o, i| o.* = read8(gb, base + @as(u16, @intCast(i)));
}

/// OAM DMA progress (SPEC.md 4: instant copy is acceptable; this hook exists
/// so DMA may be made cycle-accurate later). Nothing to do.
pub fn tick_dma(gb: *Gb, m: u8) void {
    _ = gb;
    _ = m;
}
