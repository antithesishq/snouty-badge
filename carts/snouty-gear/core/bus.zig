//! Game Gear memory map and port decode. M0 stub with the public shape of
//! PLAN.md's M1 contract: a concrete struct holding `*Gg` that `Z80(Bus)`
//! calls through (`read`, `write`, `in`, `out`, `irq_line`).
//!
//! M1 (Track C) fills in: the Sega mapper with the first 1 KB fixed, cart
//! RAM in slot 2 (FFFC bit 3), RAM mirror at E000, port decode per SPEC.md
//! section 3, SDSC console capture on ports FC/FD for the ZEX tests.
const gg_mod = @import("gg.zig");
const rom_mod = @import("rom.zig");
const Gg = gg_mod.Gg;

/// Sega mapper registers (FFFC-FFFF). Part of the console state.
pub const Mapper = struct {
    /// FFFC: bit 3 cart RAM in slot 2, bit 2 RAM bank select.
    control: u8 = 0,
    /// FFFD/FFFE/FFFF: ROM bank in slots 0, 1, 2 (post-BIOS 0, 1, 2).
    slot: [3]u8 = .{ 0, 1, 2 },
};

pub const Bus = struct {
    gg: *Gg,

    pub fn read(self: *Bus, addr: u16) u8 {
        const gg = self.gg;
        return switch (addr >> 14) {
            // M0: slots through the mapper without the fixed first 1 KB or
            // cart RAM; M1 replaces this with the real map.
            0, 1, 2 => gg.rom.read(@as(u32, gg.mapper.slot[addr >> 14]) * rom_mod.bank_size + (addr & 0x3FFF)),
            else => gg.ram[addr & 0x1FFF],
        };
    }

    pub fn write(self: *Bus, addr: u16, v: u8) void {
        const gg = self.gg;
        if (addr >= 0xC000) {
            gg.ram[addr & 0x1FFF] = v;
            switch (addr) {
                0xFFFC => gg.mapper.control = v,
                0xFFFD...0xFFFF => gg.mapper.slot[addr - 0xFFFD] = v,
                else => {},
            }
        }
    }

    /// Port read. M0 stub: everything reads idle (0xFF).
    pub fn in(self: *Bus, port: u8) u8 {
        _ = self;
        _ = port;
        return 0xFF;
    }

    /// Port write. M0 stub: PSG writes (40-7F) reach the register model,
    /// everything else is dropped.
    pub fn out(self: *Bus, port: u8, v: u8) void {
        if (port & 0xC0 == 0x40) self.gg.psg.write(v);
    }

    /// The VDP's interrupt output, sampled by the Z80 between instructions.
    pub fn irq_line(self: *Bus) bool {
        return self.gg.vdp.irq_line();
    }
};
