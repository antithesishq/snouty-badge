//! Memory map and memory bank controllers. Owner in M1: track A.
//! PPU registers 0xFF40..0xFF4B are delegated to core/ppu.zig
//! (`ppu.write_reg` / `ppu.read_reg`) so their side effects live with the PPU.
const gb_mod = @import("gb.zig");
const Gb = gb_mod.Gb;
const ppu = @import("ppu.zig");

pub const MbcKind = enum(u8) { none, mbc1, mbc3, mbc5 };

pub const Mbc = struct {
    kind: MbcKind = .none,
    rom_bank: u16 = 1,
    ram_bank: u8 = 0,
    ram_enabled: bool = false,
    /// MBC1 banking mode bit.
    mode: u8 = 0,
    /// Cached byte offset of the switchable ROM bank into `Gb.rom`.
    rom_bank_offset: u32 = 0x4000,
    /// Cached byte offset of the active RAM bank into `Gb.cart_ram`.
    ram_bank_offset: u32 = 0,

    /// Header byte 0x147 selects the controller (SPEC.md section 3).
    pub fn from_header(rom: []const u8) Mbc {
        if (rom.len < 0x150) return .{};
        const kind: MbcKind = switch (rom[0x147]) {
            0x00, 0x08, 0x09 => .none,
            0x01, 0x02, 0x03 => .mbc1,
            0x0F, 0x10, 0x11, 0x12, 0x13 => .mbc3,
            0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E => .mbc5,
            else => .none,
        };
        return .{ .kind = kind };
    }
};

/// Post-boot I/O register values. STUB for the scaffold; track A fills in
/// the documented DMG values (P1, TIMA/TMA/TAC, NRxx, LCDC=0x91, BGP=0xFC, ...).
pub fn reset_io(gb: *Gb) void {
    gb.io[gb_mod.Reg.lcdc] = 0x91;
    gb.io[gb_mod.Reg.bgp] = 0xFC;
    gb.io[gb_mod.Reg.p1] = 0xCF;
}

pub fn read8(gb: *Gb, addr: u16) u8 {
    // STUB: ROM and WRAM only; track A completes the map.
    return switch (addr) {
        0x0000...0x3FFF => if (addr < gb.rom.len) gb.rom[addr] else 0xFF,
        0x4000...0x7FFF => blk: {
            const off = gb.mbc.rom_bank_offset + (addr - 0x4000);
            break :blk if (off < gb.rom.len) gb.rom[off] else 0xFF;
        },
        0x8000...0x9FFF => gb.vram[addr - 0x8000],
        0xC000...0xDFFF => gb.wram[addr - 0xC000],
        0xE000...0xFDFF => gb.wram[addr - 0xE000],
        0xFE00...0xFE9F => gb.oam[addr - 0xFE00],
        0xFF80...0xFFFE => gb.hram[addr - 0xFF80],
        0xFFFF => gb.ie,
        else => 0xFF,
    };
}

pub fn write8(gb: *Gb, addr: u16, v: u8) void {
    // STUB: track A completes the map, MBC registers, I/O dispatch, DMA.
    switch (addr) {
        0x8000...0x9FFF => gb.vram[addr - 0x8000] = v,
        0xC000...0xDFFF => gb.wram[addr - 0xC000] = v,
        0xE000...0xFDFF => gb.wram[addr - 0xE000] = v,
        0xFE00...0xFE9F => gb.oam[addr - 0xFE00] = v,
        0xFF40...0xFF4B => ppu.write_reg(gb, @intCast(addr - 0xFF00), v),
        0xFF80...0xFFFE => gb.hram[addr - 0xFF80] = v,
        0xFFFF => gb.ie = v,
        else => {},
    }
}

/// OAM DMA progress (SPEC.md 4: instant copy is acceptable; this hook exists
/// so track A may make it cycle-accurate later). STUB.
pub fn tick_dma(gb: *Gb, m: u8) void {
    _ = gb;
    _ = m;
}
