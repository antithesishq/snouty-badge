//! Game Gear memory map and port decode (SPEC.md section 3). A concrete
//! struct holding `*Gg` that `Z80(Bus)` calls through (`read`, `write`,
//! `in`, `out`, `irq_line`); PLAN.md "Frozen for M1".
//!
//! Memory:
//! - `0000-03FF` always ROM bank 0 (the Sega mapper keeps the vectors fixed).
//! - `0400-3FFF`, `4000-7FFF`, `8000-BFFF` slots 0, 1, 2 through the mapper;
//!   slot 2 is cart RAM instead when `FFFC` bit 3 is set.
//! - `C000-DFFF` 8 KB RAM, mirrored at `E000-FFFF`. `FFFC-FFFF` are RAM too
//!   (reads give back the last value written) and also drive the mapper.
//!
//! Mapper simplifications (no known Game Gear software needs more):
//! - Cart RAM is `Gg.cart_ram` (8 KB), mirrored twice in the 16 KB slot;
//!   `FFFC` bit 2 (16 KB RAM bank) is ignored, so a 32 KB-RAM cart would see
//!   one 8 KB RAM. `FFFC` bit 4 (cart RAM over `C000`), bits 1-0 (bank
//!   shift) and bit 7 (ROM write enable) are stored and ignored.
//! - Bank numbers wrap to the ROM's bank count (`Rom.wrap_bank`), resolved
//!   once per mapper write into `Mapper.bank`, so a read never divides.
//!
//! Ports (Game Gear mode, partial decoding; SMS Power "I/O Port Map - Game
//! Gear" and "Gear to Gear Cable"):
//! - `00` read: bit 7 Start (0 = pressed), bit 6 region (1 = export), bit 5
//!   0 = NTSC, bits 4-0 read 0. `01-05` link port: fixed idle values, writes
//!   dropped. `06` stereo: written to `psg.stereo`, read back.
//! - `07-3F`: even = memory control (`mem_control`), odd = I/O control
//!   (`io_control`); writes stored, reads `FF`.
//! - `40-7F`: read even V counter, odd H counter; write PSG.
//! - `80-BF`: even VDP data, odd VDP control/status.
//! - `C0`/`DC` read the pad (active low: up, down, left, right, 1, 2, bits
//!   6-7 high); `C1`/`DD` read the absent second port, all ones. Everything
//!   else in `C0-FF` reads `FF` (the Game Gear decodes this range fully,
//!   unlike the Master System's even/odd mirror). Writes dropped, except
//!   SDSC debug console: `FD` bytes go to `Gg.console_sink` when set
//!   (ZEXDOC/ZEXALL print there), `FC` (its control port) is dropped.
const gg_mod = @import("gg.zig");
const rom_mod = @import("rom.zig");
const Gg = gg_mod.Gg;
const Pad = gg_mod.Pad;

/// Sega mapper registers (FFFC-FFFF). Part of the console state.
pub const Mapper = struct {
    /// FFFC: bit 3 cart RAM in slot 2 (the only bit acted on).
    control: u8 = 0,
    /// FFFD/FFFE/FFFF as written: ROM bank for slots 0, 1, 2 (post-BIOS
    /// 0, 1, 2).
    slot: [3]u8 = .{ 0, 1, 2 },
    /// `slot` wrapped to the ROM's bank count (`Rom.wrap_bank`): what the
    /// reads use. Recomputed on every slot write and by `sync`.
    bank: [3]u8 = .{ 0, 1, 2 },

    /// Recompute `bank` from `slot` for `r` (after a reset or ROM change).
    pub fn sync(m: *Mapper, r: *const rom_mod.Rom) void {
        for (&m.bank, m.slot) |*b, s| b.* = r.wrap_bank(s);
    }
};

/// Where SDSC debug console bytes (port FD writes) go. Test-only in
/// practice; the bus pays one null compare per FD write.
pub const ByteSink = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, b: u8) void,

    pub fn emit(self: ByteSink, b: u8) void {
        self.func(self.ctx, b);
    }
};

/// Port 00 with nothing pressed: Start released (bit 7), export (bit 6),
/// NTSC (bit 5 clear).
pub const port00_idle: u8 = 0xC0;

/// Idle reads of the link port 01-05 with no cable (Gear to Gear Cable doc;
/// the values Genesis Plus GX resets to): 01 parallel data 7F, 02 direction
/// FF (all inputs), 03 transmit 00, 04 receive FF, 05 status 00.
const link_idle = [5]u8{ 0x7F, 0xFF, 0x00, 0xFF, 0x00 };

pub const Bus = struct {
    gg: *Gg,

    /// One ROM byte from bank `bank` (already wrapped) at `off` (0..3FFF):
    /// the direct pointer when the bank has one, else the ROM's slow path
    /// (partial last bank, fragmented drive file).
    inline fn rom_byte(gg: *const Gg, bank: u8, off: u16) u8 {
        if (gg.rom.banks[bank]) |p| return p[off];
        return gg.rom.read(@as(u32, bank) * rom_mod.bank_size + off);
    }

    pub inline fn read(self: *Bus, addr: u16) u8 {
        const gg = self.gg;
        if (addr >= 0xC000) return gg.ram[addr & 0x1FFF];
        if (gg.read_map[addr >> 10]) |p| return p[addr & 0x3FF];
        return read_slow(gg, addr);
    }

    /// 0000-BFFF where `read_map` has no pointer: cart RAM, or a ROM bank
    /// without a direct pointer.
    noinline fn read_slow(gg: *const Gg, addr: u16) u8 {
        if (addr < 0x0400) return rom_byte(gg, 0, addr);
        const s = addr >> 14;
        if (s == 2 and gg.mapper.control & 0x08 != 0) return gg.cart_ram[addr & (gg_mod.cart_ram_size - 1)];
        return rom_byte(gg, gg.mapper.bank[s], addr & 0x3FFF);
    }

    pub inline fn write(self: *Bus, addr: u16, v: u8) void {
        const gg = self.gg;
        if (addr >= 0xC000) {
            gg.ram[addr & 0x1FFF] = v;
            if (addr >= 0xFFFC) mapper_write(gg, addr, v);
        } else if (addr >= 0x8000 and gg.mapper.control & 0x08 != 0) {
            gg.cart_ram[addr & (gg_mod.cart_ram_size - 1)] = v;
        }
        // ROM writes are dropped.
    }

    fn mapper_write(gg: *Gg, addr: u16, v: u8) void {
        if (addr == 0xFFFC) {
            gg.mapper.control = v;
            gg.sync_slot(2);
            return;
        }
        const i = addr - 0xFFFD;
        gg.mapper.slot[i] = v;
        gg.mapper.bank[i] = gg.rom.wrap_bank(v);
        gg.sync_slot(@intCast(i));
    }

    /// Port read (Game Gear decoding, see the file comment).
    pub fn in(self: *Bus, port: u8) u8 {
        const gg = self.gg;
        switch (port >> 6) {
            0 => {
                if (port == 0x00) return if (gg.pad & Pad.start != 0) port00_idle & 0x7F else port00_idle;
                if (port <= 0x05) return link_idle[port - 1];
                if (port == 0x06) return gg.psg.stereo;
                return 0xFF;
            },
            1 => return if (port & 1 == 0) gg.vdp.v_counter() else gg.vdp.h_counter(),
            2 => return if (port & 1 == 0) gg.vdp.read_data() else gg.vdp.read_status(),
            else => {
                // Pad bits 0-5 are the port DC bits, active high: invert.
                if (port == 0xDC or port == 0xC0) return 0xFF ^ (gg.pad & 0x3F);
                return 0xFF;
            },
        }
    }

    /// Port write (Game Gear decoding, see the file comment).
    pub fn out(self: *Bus, port: u8, v: u8) void {
        const gg = self.gg;
        switch (port >> 6) {
            0 => {
                if (port <= 0x05) return; // Start port and link port.
                if (port == 0x06) {
                    gg.psg.stereo = v;
                } else if (port & 1 == 0) {
                    gg.mem_control = v;
                } else {
                    gg.io_control = v;
                }
            },
            1 => gg.psg.write(v),
            2 => if (port & 1 == 0) gg.vdp.write_data(v) else gg.vdp.write_control(v),
            else => if (port == 0xFD) {
                if (gg.console_sink) |s| s.emit(v);
            },
        }
    }

    /// Steps a halted CPU can run before the interrupt line can change: the
    /// 4 T-state NOPs until the next line start, where the VDP raises its
    /// interrupts (nothing else does while the CPU is halted). Z80.step
    /// calls it after `irq_line` said no.
    pub inline fn halt_steps(self: *Bus) u8 {
        const left: u32 = gg_mod.vdp.tstates_per_line - self.gg.vdp.line_tstates;
        return @intCast((left + 3) / 4);
    }

    /// The VDP's interrupt output, sampled by the Z80 between instructions.
    pub inline fn irq_line(self: *Bus) bool {
        return self.gg.vdp.irq_line();
    }
};
