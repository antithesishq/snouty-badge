//! Motorola 68000 interpreter, generic over the bus (SPEC.md sections 4
//! and 7; PLAN.md M1 Track A owns this file).
//!
//! `M68k(BusT)` is the register file plus `step`. The bus is a comptime
//! parameter (no function pointers on the hot path) and must provide, on
//! `*BusT`: `read8(addr: u24) u8`, `read16(addr: u24) u16`,
//! `write8(addr: u24, v: u8)`, `write16(addr: u24, v: u16)`,
//! `irq_level() u3` (sampled between instructions) and
//! `ack_irq(level: u3)` (the CPU took an interrupt at that level).
//! Decode comes from a host-generated table (tools/gen_m68k.py ->
//! core/m68k_tables.zig), never from comptime loops (Adrian's Mac Zig OOMs).
//!
//! M0 scaffold: the registers, the reset vector fetch and a `step` that
//! fetches one word and charges 4 cycles (a NOP for every opcode).

pub fn M68k(comptime BusT: type) type {
    return struct {
        const Self = @This();
        pub const Bus = BusT;

        /// Data registers D0-D7.
        d: [8]u32 = @splat(0),
        /// Address registers A0-A7; `a[7]` is the stack pointer of the
        /// current mode (SSP in supervisor, USP in user).
        a: [8]u32 = @splat(0),
        /// The stack pointer of the other mode (USP while supervisor, SSP
        /// while user); swapped with `a[7]` on every S-bit change.
        other_sp: u32 = 0,
        pc: u32 = 0,
        /// Status register: T, S, interrupt mask I2-I0, CCR (XNZVC).
        sr: u16 = 0x2700,
        /// STOP executed; waits for an interrupt above the mask.
        stopped: bool = false,

        /// Power-on/RESET: supervisor, interrupts masked, SSP and PC from
        /// the vectors at 000000 and 000004.
        pub fn reset(self: *Self, bus: *BusT) void {
            self.* = .{};
            self.a[7] = read32(bus, 0);
            self.pc = read32(bus, 4);
        }

        /// Run one instruction (or take an interrupt) and return its 68000
        /// cycles. M0 stub: fetch one word, 4 cycles.
        pub fn step(self: *Self, bus: *BusT) u32 {
            if (self.stopped) return 4;
            _ = bus.read16(@truncate(self.pc));
            self.pc +%= 2;
            return 4;
        }

        /// Interrupt mask (SR bits 8-10).
        pub fn mask(self: *const Self) u3 {
            return @truncate(self.sr >> 8);
        }

        fn read32(bus: *BusT, addr: u24) u32 {
            return @as(u32, bus.read16(addr)) << 16 | bus.read16(addr +% 2);
        }
    };
}
