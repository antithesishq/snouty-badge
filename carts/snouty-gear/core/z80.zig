//! Zilog Z80 interpreter, generic over the bus. M0 stub with the public
//! shape of PLAN.md's M1 contract ("Frozen for M1: core/gg.zig", Track A).
//!
//! `Z80(BusT)` is the register file plus `step`. The bus is a comptime
//! parameter (no function pointers on the hot path) and must provide
//! `read(addr: u16) u8`, `write(addr: u16, v: u8)`, `in(port: u8) u8`,
//! `out(port: u8, v: u8)` and `irq_line() bool`, sampled between
//! instructions. Nothing here depends on the Game Gear, so the file can move
//! to lib/ when a second Z80 machine arrives (SPEC.md section 7).
//! Flag tables come from a host generator (tools/gen_tables.py ->
//! core/tables.zig), never from comptime loops (Adrian's Mac Zig OOMs).

pub fn Z80(comptime BusT: type) type {
    return struct {
        const Self = @This();
        pub const Bus = BusT;

        // Main and alternate register sets. Plain bytes so a keyframe is a
        // struct copy; M1 may add pair accessors.
        a: u8 = 0xFF,
        f: u8 = 0xFF,
        b: u8 = 0,
        c: u8 = 0,
        d: u8 = 0,
        e: u8 = 0,
        h: u8 = 0,
        l: u8 = 0,
        a_: u8 = 0,
        f_: u8 = 0,
        b_: u8 = 0,
        c_: u8 = 0,
        d_: u8 = 0,
        e_: u8 = 0,
        h_: u8 = 0,
        l_: u8 = 0,
        ix: u16 = 0,
        iy: u16 = 0,
        sp: u16 = 0xDFF0,
        pc: u16 = 0,
        /// Interrupt vector base (IM 2) and refresh register (low 7 bits count).
        i: u8 = 0,
        r: u8 = 0,
        /// MEMPTR, visible through the X/Y flags of BIT n,(HL).
        wz: u16 = 0,
        iff1: bool = false,
        iff2: bool = false,
        im: u2 = 1,
        halted: bool = false,
        /// EI was the last instruction: no interrupt before the next one.
        ei_delay: bool = false,

        /// Post-BIOS register state (SPEC.md section 3): SP DFF0, IM 1,
        /// interrupts off, PC 0.
        pub fn reset(self: *Self) void {
            self.* = .{};
        }

        /// Run one instruction (or accept an interrupt) and return its
        /// T-states. M0 stub: executes nothing, fetches the opcode so the
        /// bus shape is exercised, and reports a NOP's 4 T-states.
        pub fn step(self: *Self, bus: *BusT) u32 {
            if (bus.irq_line() and self.iff1 and !self.ei_delay) {
                // M1: acknowledge (IM 1: RST 38h, 13 T-states).
            }
            self.ei_delay = false;
            _ = bus.read(self.pc);
            self.pc +%= 1;
            self.r = (self.r & 0x80) | ((self.r +% 1) & 0x7F);
            return 4;
        }
    };
}
