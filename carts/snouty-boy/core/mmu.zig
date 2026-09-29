//! Memory map and memory bank controllers. Owner in M1 and M6: track A.
//! CGB (SPEC.md 19.1): VBK/SVBK banks, KEY1 storage (the switch is STOP in
//! cpu.zig), HDMA1..5 general and HBlank DMA, 32 KB cart RAM banking. In
//! DMG mode every CGB register reads 0xFF and ignores writes.
//! PPU registers 0xFF40..0xFF4B are delegated to core/ppu.zig
//! (`ppu.write_reg` / `ppu.read_reg`) so their side effects live with the PPU.
//! APU registers and wave RAM 0xFF10..0xFF3F likewise go to core/apu.zig.
const gb_mod = @import("gb.zig");
const Gb = gb_mod.Gb;
const Reg = gb_mod.Reg;
const ppu = @import("ppu.zig");
const timer = @import("timer.zig");
const serial = @import("serial.zig");
const joypad = @import("joypad.zig");
const apu = @import("apu.zig");

pub const MbcKind = enum(u8) { none, mbc1, mbc3, mbc5 };

/// Bytes of `Gb.cart_ram` a ROM can ever touch, from header byte 0x149: 0
/// without RAM, 2 KB for code 1 (mirrored, see `Mbc.ram_mask`), 8 KB for
/// code 2, 32 KB (4 banks) for code 3. Codes 4 and 5 (128, 64 KB) are capped
/// at 32 KB: bank numbers wrap modulo 4 (SPEC.md 19.1, romcheck.py warns).
/// Comptime-callable, so the frontend sizes its buffer and keyframes to the
/// embedded ROM.
pub fn cart_ram_len(rom: []const u8) usize {
    if (rom.len < 0x150) return 0;
    return switch (rom[0x149]) {
        0 => 0,
        1 => 0x800,
        2 => 0x2000,
        else => 0x8000,
    };
}

/// Cached bank offsets (SPEC.md 19.1). Owner: track A (VBK, SVBK writes).
pub const Banks = struct {
    /// Byte offset of the VRAM bank at 0x8000 into `Gb.vram` (0 or 0x2000).
    vram_off: u16 = 0,
    /// Byte offset of the WRAM bank at 0xD000 into `Gb.wram` (0x1000 * bank,
    /// bank 1..7).
    wram_off: u16 = 0x1000,
};

/// CGB general-purpose / HBlank DMA (HDMA1..5). Owner: track A.
pub const Hdma = struct {
    /// Next source address (HDMA1/2, low 4 bits clear).
    src: u16 = 0,
    /// Next destination offset into the VRAM bank (HDMA3/4, masked 0x1FF0).
    dst: u16 = 0,
    /// Blocks of 16 bytes left in an HBlank transfer (after a cancel: the
    /// blocks it did not copy; 0 when done).
    blocks_left: u8 = 0,
    /// An HBlank transfer is running.
    active: bool = false,
};

/// Called by the PPU on entering mode 0 on visible lines with the LCD on:
/// copies one 16-byte HBlank DMA block if a transfer is active.
pub fn hdma_hblank(gb: *Gb) void {
    if (!gb.hdma.active) return;
    hdma_block(gb);
}

/// Copy one 16-byte block, advance the addresses, stall the CPU for it:
/// 8 M-cycles at normal speed, 16 in double speed (the same 32 dots).
fn hdma_block(gb: *Gb) void {
    const h = &gb.hdma;
    const vram = gb.vram[gb.banks.vram_off..][0..0x2000];
    const src = h.src;
    const dst = h.dst;
    for (0..16) |i| {
        const s = src +% @as(u16, @intCast(i));
        // A source in VRAM is not a valid transfer; it reads open bus.
        vram[(dst + i) & 0x1FFF] = if (s >> 13 == 4) 0xFF else read8(gb, s);
    }
    h.src = src +% 16;
    h.dst = (dst + 16) & 0x1FF0;
    h.blocks_left -= 1;
    if (h.blocks_left == 0) h.active = false;
    gb.stall_m += @as(u16, 8) << (2 - gb.dot_shift);
}

/// HDMA5 write (SPEC.md 19.1). Bit 7 clear starts a general DMA, which
/// copies everything now and stalls the CPU; bit 7 set starts an HBlank DMA
/// (16 bytes per `hdma_hblank`). Bit 7 clear while an HBlank DMA runs
/// cancels it instead.
fn write_hdma5(gb: *Gb, v: u8) void {
    const h = &gb.hdma;
    if (h.active and v & 0x80 == 0) {
        h.active = false;
        return;
    }
    h.blocks_left = (v & 0x7F) + 1;
    if (v & 0x80 == 0) {
        while (h.blocks_left != 0) hdma_block(gb);
        return;
    }
    h.active = true;
    // With the LCD off there are no HBlanks: hardware copies one block now.
    if (!ppu.lcd_on(gb)) hdma_block(gb);
}

/// HDMA5 read: while an HBlank DMA runs, the blocks left minus one with
/// bit 7 clear; otherwise bit 7 set (0xFF once a transfer has finished,
/// 0x80 | left - 1 after a cancel).
fn read_hdma5(gb: *const Gb) u8 {
    const h = &gb.hdma;
    const left = (h.blocks_left -% 1) & 0x7F;
    return if (h.active) left else 0x80 | left;
}

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
    /// Cart RAM address mask applied to `ram_bank_offset + offset`, so the
    /// RAM mirrors as on hardware: a 2 KB RAM (header 0x149 == 1) every 2 KB,
    /// 8 KB ignores the bank number, 32 KB wraps banks modulo 4. Only
    /// `cart_ram[0..cart_ram_len]` is ever touched.
    ram_mask: u16 = 0x1FFF,
    /// MBC1 banking mode bit.
    mode: u8 = 0,
    /// ROM size in 16 KB banks minus one, rounded up to a power of two.
    rom_bank_mask: u16 = 1,
    /// Cached byte offset of the bank mapped at 0x0000 (MBC1 mode 1 only).
    rom0_offset: u32 = 0,
    /// Cached byte offset of the switchable ROM bank into `Gb.rom`.
    rom_bank_offset: u32 = 0x4000,
    /// Cached byte offset of the active RAM bank into `Gb.cart_ram`
    /// (bank * 0x2000; `ram_mask` wraps banks past the RAM size).
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
        m.ram_mask = @intCast(@max(cart_ram_len(rom), 1) - 1);
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
        m.ram_bank_offset = ram * 0x2000;
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
    if (gb.is_cgb()) reset_io_cgb(gb);
}

/// Post-boot CGB I/O values that differ from the DMG ones (Pan Docs, "Power
/// Up Sequence"). The CGB-only registers keep their writable bits in `io`,
/// all 0 after boot (normal speed, VRAM bank 0, WRAM bank 1, no HDMA);
/// `read_cgb` adds the fixed bits (KEY1 0x7E, VBK 0xFE, SVBK 0xF8, RP 0x3E,
/// FF75 0x8F). `Gb.reset` has already zeroed `io`, `banks` and `hdma`.
fn reset_io_cgb(gb: *Gb) void {
    gb.io[Reg.sc] = 0x7F;
    gb.io[Reg.dma] = 0x00;
}

// CGB undocumented registers: plain storage (FF75 only bits 4..6).
const reg_ff72: u8 = 0x72;
const reg_ff73: u8 = 0x73;
const reg_ff74: u8 = 0x74;
const reg_ff75: u8 = 0x75;
const reg_pcm12: u8 = 0x76;
const reg_pcm34: u8 = 0x77;

/// `read8` for opcode and immediate fetches, inlined at the few fetch
/// sites: code almost always runs from ROM, so that is one select and one
/// load; anything else (HRAM, WRAM routines) takes the out-of-line path.
pub inline fn fetch8(gb: *Gb, addr: u16) u8 {
    if (addr < 0x8000) {
        const base = if (addr < 0x4000) gb.mbc.rom0_offset else gb.mbc.rom_bank_offset - 0x4000;
        const off = base + addr;
        return if (off < gb.rom.len) gb.rom[off] else 0xFF;
    }
    return read8(gb, addr);
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
        0x8, 0x9 => return gb.vram[gb.banks.vram_off + (addr - 0x8000)],
        0xA, 0xB => {
            if (!gb.mbc.ram_active) return 0xFF;
            return gb.cart_ram[(gb.mbc.ram_bank_offset + (addr - 0xA000)) & gb.mbc.ram_mask];
        },
        0xC => return gb.wram[addr - 0xC000],
        0xD => return gb.wram[gb.banks.wram_off + (addr - 0xD000)],
        0xE => return gb.wram[addr - 0xE000],
        0xF => {
            if (addr < 0xFE00) return gb.wram[gb.banks.wram_off + (addr - 0xF000)];
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
    // PPU (LY, STAT) and APU registers change only at the events that
    // `Gb.tick_lazy` flushes on, so they are current as they are. TIMA
    // counts between events: catch up. DIV is computed from the pending
    // cycles (it is the counter's high byte, 4 counts per M-cycle).
    switch (reg) {
        Reg.tima => gb.sync(),
        Reg.div => return @truncate((gb.timer.div +% @as(u16, @truncate(gb.pend_m *% 4))) >> 8),
        else => {},
    }
    return switch (reg) {
        Reg.p1 => gb.io[Reg.p1] | 0xC0,
        Reg.sb => gb.io[Reg.sb],
        Reg.sc => gb.io[Reg.sc] | 0x7C,
        Reg.div, Reg.tima, Reg.tma => gb.io[reg],
        Reg.tac => gb.io[Reg.tac] | 0xF8,
        Reg.if_ => gb.io[Reg.if_] | 0xE0,
        0x10...0x3F => apu.read_reg(gb, reg),
        Reg.dma => gb.io[Reg.dma],
        Reg.stat, Reg.ly => blk: {
            if (gb.is_cgb()) gb.sync_for_read();
            break :blk ppu.read_reg(gb, reg);
        },
        0x40, 0x42, 0x43, 0x45, 0x47...0x4B => ppu.read_reg(gb, reg),
        // CGB-only registers read 0xFF on a DMG.
        Reg.key1, Reg.vbk, Reg.hdma5, Reg.rp, Reg.bcps...Reg.opri, Reg.svbk, reg_ff72...reg_pcm34 => if (gb.is_cgb()) read_cgb(gb, reg) else 0xFF,
        else => 0xFF,
    };
}

fn read_cgb(gb: *Gb, reg: u8) u8 {
    return switch (reg) {
        // Bit 7 current speed (mirrors `dot_shift`), bit 0 switch armed.
        Reg.key1 => 0x7E | gb.io[Reg.key1],
        Reg.vbk => 0xFE | gb.io[Reg.vbk],
        Reg.hdma5 => read_hdma5(gb),
        // Bit 1 reads 1: no infrared light received.
        Reg.rp => gb.io[Reg.rp] | 0x3E,
        Reg.bcps...Reg.opri => ppu.read_reg(gb, reg),
        Reg.svbk => 0xF8 | gb.io[Reg.svbk],
        reg_ff72, reg_ff73, reg_ff74 => gb.io[reg],
        reg_ff75 => gb.io[reg] | 0x8F,
        reg_pcm12, reg_pcm34 => 0x00,
        else => 0xFF,
    };
}

pub fn write8(gb: *Gb, addr: u16, v: u8) void {
    switch (@as(u4, @truncate(addr >> 12))) {
        0x0...0x7 => gb.mbc.write(addr, v),
        0x8, 0x9 => gb.vram[gb.banks.vram_off + (addr - 0x8000)] = v,
        0xA, 0xB => {
            if (gb.mbc.ram_active) gb.cart_ram[(gb.mbc.ram_bank_offset + (addr - 0xA000)) & gb.mbc.ram_mask] = v;
        },
        0xC => gb.wram[addr - 0xC000] = v,
        0xD => gb.wram[gb.banks.wram_off + (addr - 0xD000)] = v,
        0xE => gb.wram[addr - 0xE000] = v,
        0xF => {
            if (addr < 0xFE00) {
                gb.wram[gb.banks.wram_off + (addr - 0xF000)] = v;
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

/// Every I/O write catches the subsystems up first (their registers, and
/// the PPU renders with the registers as they are) and reschedules the
/// next event after (LCDC, TAC, TIMA, NR52 ... move it).
fn write_io(gb: *Gb, reg: u8, v: u8) void {
    gb.sync();
    write_io_now(gb, reg, v);
    gb.reschedule();
}

fn write_io_now(gb: *Gb, reg: u8, v: u8) void {
    switch (reg) {
        Reg.p1 => {
            gb.io[Reg.p1] = (gb.io[Reg.p1] & 0xCF) | (v & 0x30);
            joypad.update(gb);
        },
        Reg.sb => gb.io[Reg.sb] = v,
        Reg.sc => {
            // CGB: bit 1 selects the fast clock and is writable.
            gb.io[Reg.sc] = v | @as(u8, if (gb.is_cgb()) 0x7C else 0x7E);
            if ((v & 0x80) != 0) serial.start_transfer(gb);
        },
        Reg.div => timer.write_div(gb),
        Reg.tima, Reg.tma => gb.io[reg] = v,
        Reg.tac => timer.write_tac(gb, v),
        Reg.if_ => gb.io[Reg.if_] = v | 0xE0,
        0x10...0x3F => apu.write_reg(gb, reg, v),
        Reg.dma => {
            oam_dma(gb, v);
            ppu.write_reg(gb, reg, v);
        },
        0x40...0x45, 0x47...0x4B => ppu.write_reg(gb, reg, v),
        // CGB-only registers ignore writes on a DMG.
        Reg.key1, Reg.vbk, Reg.hdma1...Reg.hdma5, Reg.rp, Reg.bcps...Reg.opri, Reg.svbk, reg_ff72...reg_ff75 => if (gb.is_cgb()) write_cgb(gb, reg, v),
        else => {},
    }
}

fn write_cgb(gb: *Gb, reg: u8, v: u8) void {
    const h = &gb.hdma;
    switch (reg) {
        // Only the arm bit is writable; STOP performs the switch (cpu.zig).
        Reg.key1 => gb.io[Reg.key1] = (gb.io[Reg.key1] & 0x80) | (v & 1),
        Reg.vbk => {
            gb.io[Reg.vbk] = v & 1;
            gb.banks.vram_off = @as(u16, v & 1) * 0x2000;
        },
        Reg.hdma1 => h.src = (h.src & 0x00F0) | (@as(u16, v) << 8),
        Reg.hdma2 => h.src = (h.src & 0xFF00) | (v & 0xF0),
        Reg.hdma3 => h.dst = (h.dst & 0x00F0) | (@as(u16, v & 0x1F) << 8),
        Reg.hdma4 => h.dst = (h.dst & 0x1F00) | (v & 0xF0),
        Reg.hdma5 => write_hdma5(gb, v),
        Reg.rp => gb.io[Reg.rp] = v & 0xC1,
        Reg.bcps...Reg.opri => ppu.write_reg(gb, reg, v),
        Reg.svbk => {
            gb.io[Reg.svbk] = v & 7;
            gb.banks.wram_off = @as(u16, @max(v & 7, 1)) * 0x1000;
        },
        reg_ff72, reg_ff73, reg_ff74 => gb.io[reg] = v,
        reg_ff75 => gb.io[reg] = v & 0x70,
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
pub inline fn tick_dma(gb: *Gb, m: u32) void {
    _ = gb;
    _ = m;
}
