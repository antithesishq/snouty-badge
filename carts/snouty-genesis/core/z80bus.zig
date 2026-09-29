//! The Z80's memory map (SPEC.md section 9) as `Z80Bus`, a concrete struct
//! holding `*Md` that Snouty Gear's `Z80(Z80Bus)` calls through (PLAN.md
//! "Frozen for M1"; the requirements are listed at the top of
//! carts/snouty-gear/core/z80.zig: `read`, `write`, `in`, `out`,
//! `irq_line`, and the optional `halt_steps`). M1 Track D owns this file.
//!
//! The Z80 core is imported as the `z80` module (rooted at
//! carts/snouty-gear/core/z80.zig by this cart's build.zig), not copied.
//!
//! Map (Z80 addresses):
//! - `0000-1FFF` 8 KB RAM, mirrored at `2000-3FFF`.
//! - `4000-5FFF` YM2612, four ports mirrored: `+0` part I address, `+1`
//!   part I data, `+2` part II address, `+3` part II data. Every read
//!   returns the status byte.
//! - `6000-60FF` bank register: each write shifts bit 0 of the byte in at
//!   the top of a 9-bit register (`bank = bank >> 1 | bit << 8`), so after
//!   nine writes, LSB first, the register holds 68000 address bits 15-23.
//!   Reads `FF`. `6100-7EFF` unmapped (`FF`, writes dropped).
//! - `7F00-7F1F` VDP. Writes to `7F11/13/15/17` go to the PSG; other
//!   VDP writes from the Z80 are dropped, reads are `FF` (no Genesis sound
//!   driver we target reads the VDP from the Z80). `7F20-7FFF` unmapped.
//! - `8000-FFFF` the 32 KB window at 68000 address `bank << 15`: ROM
//!   (`000000-3FFFFF`, through `rom.read8`) and work RAM (`E00000-FFFFFF`,
//!   readable and writable). The Z80's own area, the VDP, I/O and the rest
//!   are not reachable through the window: `FF`, writes dropped. Cartridge
//!   SRAM through the window is not decoded (M1 has no SRAM in `Md`).
//!
//! Window fast path: a `Z80Bus` caches a pointer to the window (ROM when
//! the source is contiguous and the window lies inside the ROM, or work
//! RAM) together with the bank value it was computed for; a read compares
//! the bank with `md.z80_bank` and indexes the pointer. A bank change from
//! any bus instance (the 68000 writes `A06000` too) invalidates it on the
//! next read. Clustered ROM and partial windows take `rom.read8`.
//!
//! Ports: the Genesis has no Z80 `IN`/`OUT` devices (reads `FF`, writes
//! dropped). Interrupts: `irq_line` is `md.z80_int`, which the frame loop
//! raises for the one line starting at V-int (line 224) and lowers after
//! it. `run` executes a slice and lets `HALT` skip to the slice end.
const z80 = @import("z80");
const md_mod = @import("md.zig");
const Md = md_mod.Md;
const rom = @import("rom.zig");

/// 68000 address of the first work RAM byte reachable through the window
/// (work RAM is mirrored across E00000-FFFFFF).
const work_ram_from: u32 = 0xE00000;
/// End of the 68000 ROM area (the window reads `rom.read8` below it).
const rom_area_end: u32 = 0x400000;
/// `win_bank` value that matches no bank (the register has 9 bits).
const no_bank: u16 = 0xFFFF;

pub const Z80Bus = struct {
    md: *Md,
    /// Window base pointer (`win[addr & 7FFF]` is the byte at `addr`) for
    /// the bank value `win_bank`, or null when the window takes the slow
    /// path.
    win: ?[*]const u8 = null,
    win_bank: u16 = no_bank,
    /// Z80 cycles left in the slice `run` is executing (0 outside `run`):
    /// the bound for `halt_steps`.
    left: u32 = 0,

    pub fn init(md: *Md) Z80Bus {
        return .{ .md = md };
    }

    pub inline fn read(self: *Z80Bus, addr: u16) u8 {
        if (addr < 0x4000) return self.md.z80_ram[addr & 0x1FFF];
        if (addr >= 0x8000) return self.read_window(addr);
        if (addr < 0x6000) return self.md.ym.read_status();
        return 0xFF;
    }

    pub inline fn write(self: *Z80Bus, addr: u16, v: u8) void {
        if (addr < 0x4000) {
            self.md.z80_ram[addr & 0x1FFF] = v;
        } else if (addr >= 0x8000) {
            self.write_window(addr, v);
        } else if (addr < 0x6000) {
            const part: u1 = @truncate(addr >> 1);
            if (addr & 1 == 0) self.md.ym.write_addr(part, v) else self.md.ym.write_data(part, v);
        } else if (addr < 0x6100) {
            write_bank(self.md, v);
        } else if (addr >= 0x7F10 and addr < 0x7F18 and addr & 1 != 0) {
            self.md.psg.write(v);
        }
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

    /// NOPs a halted Z80 may run in one go (Gear's `halt_nops`): up to the
    /// end of the slice `run` executes, since INT only changes between
    /// slices. At least 1 (outside `run`, one NOP per step as usual).
    pub inline fn halt_steps(self: *Z80Bus) u8 {
        const n = (self.left + 3) / 4;
        return @intCast(@max(1, @min(255, n)));
    }

    inline fn read_window(self: *Z80Bus, addr: u16) u8 {
        if (self.win_bank == self.md.z80_bank) {
            if (self.win) |p| return p[addr & 0x7FFF];
        } else {
            self.cache_window();
            if (self.win) |p| return p[addr & 0x7FFF];
        }
        return window_read_slow(self.md, addr);
    }

    fn cache_window(self: *Z80Bus) void {
        const md = self.md;
        self.win_bank = md.z80_bank;
        self.win = null;
        const base = window_base(md);
        if (base < rom_area_end) {
            if (md.rom.base) |p| {
                if (base + 0x8000 <= md.rom.size) self.win = p + base;
            }
        } else if (base >= work_ram_from) {
            self.win = @as([*]const u8, &md.work_ram) + (base & 0xFFFF);
        }
    }

    inline fn write_window(self: *Z80Bus, addr: u16, v: u8) void {
        const a = window_base(self.md) | (addr & 0x7FFF);
        if (a >= work_ram_from) self.md.work_ram[a & 0xFFFF] = v;
    }
};

/// 68000 address of Z80 8000 under the current bank register.
pub inline fn window_base(md: *const Md) u32 {
    return @as(u32, md.z80_bank & 0x1FF) << 15;
}

/// One write to 6000-60FF: bit 0 of `v` shifted in at bit 8.
pub inline fn write_bank(md: *Md, v: u8) void {
    md.z80_bank = ((md.z80_bank & 0x1FF) >> 1) | (@as(u16, v & 1) << 8);
}

fn window_read_slow(md: *const Md, addr: u16) u8 {
    const a = window_base(md) | (addr & 0x7FFF);
    if (a < rom_area_end) return rom.read8(&md.rom, a);
    if (a >= work_ram_from) return md.work_ram[a & 0xFFFF];
    return 0xFF;
}

/// The Z80 as the Genesis runs it: Gear's interpreter over this bus.
pub const Cpu = z80.Z80(Z80Bus);

/// Z80 state after its RESET line (power on, or the 68000 pulsing
/// A11200): PC, I, R and the IFFs 0, IM 0 (the driver sets IM 1; Gear's
/// core treats IM 0 as IM 1 anyway since the data bus reads FF = RST 38h),
/// AF and SP FFFF (Sean Young, "The Undocumented Z80 Documented", section
/// 2.4; drivers load SP before using it), the other registers 0, not
/// halted. Replaces Gear's Game Gear post-BIOS `reset` (SP DFF0, IM 1).
pub fn reset_genesis(cpu: *Cpu) void {
    cpu.* = .{};
    cpu.a = 0xFF;
    cpu.f = 0xFF;
    cpu.sp = 0xFFFF;
    cpu.im = 0;
}

/// The 68000 asserted Z80 RESET (A11200 = 0): the Z80 and the YM2612 are
/// reset (the bank register is not: it is outside the Z80). The frame loop
/// keeps the Z80 stopped while the line is held.
pub fn reset_line(md: *Md) void {
    reset_genesis(&md.z80);
    md.ym.reset();
}

/// Run the Z80 for at least `budget` cycles (one line slice) and return
/// the cycles used (at most 22 over the budget: the longest instruction or
/// interrupt acceptance; a halted Z80 stops within 3). The caller carries
/// the overshoot and skips the call while BUSREQ or RESET holds the Z80.
pub fn run(md: *Md, budget: u32) u32 {
    var zb = Z80Bus.init(md);
    var used: u32 = 0;
    while (used < budget) {
        zb.left = budget - used;
        used += md.z80.step(&zb);
    }
    return used;
}

// Analyse (and so compile) `Cpu.step` in every build that imports this file.
comptime {
    _ = &Cpu.step;
}
