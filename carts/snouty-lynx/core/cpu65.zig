//! 65C02 interpreter (the Lynx's Rockwell set: RMB/SMB/BBR/BBS, no WAI/STP;
//! SPEC.md sections 3, 4, 16, 20), generic over a Bus type. PLAN.md "Frozen
//! for M1: core/cpu65.zig" is the contract; M1 Track A fills `step`.
//!
//! Bus contract (`Cpu(Bus)` calls nothing else):
//!
//! - `bus.fetch(addr: u16) u8`: an opcode or operand byte read at PC (the
//!   Lynx charges these 4 ticks in page mode).
//! - `bus.read(addr: u16) u8`: every other read, dummy reads included (the
//!   65C02 performs them on the real bus too, and a dummy read of RCART0
//!   advances the cart counter, so they are never skipped).
//! - `bus.write(addr: u16, v: u8) void`.
//! - `bus.irq_line() bool`: sampled once per `step`, before the opcode
//!   fetch; when set and I is clear the step is the 7-cycle interrupt
//!   sequence instead of an instruction (pushes PCH, PCL, P with B clear,
//!   sets I, PC from `read($FFFE/$FFFF)`).
//!
//! Timing: the CPU does exactly the bus cycles the hardware does (the
//! SingleStepTests `cycles` lists are the reference), one `fetch`/`read`/
//! `write` call each; the bus turns them into 16 MHz ticks. `step` returns
//! nothing; the bus owns the clock. No NMI (the Lynx has no NMI source).
//!
//! Variant switch for later consoles (NES, 2600, C64 would want an NMOS
//! 6502 with its illegal opcodes): `Variant` is the hook; only `.lynx` is
//! implemented in M1.

pub const Variant = enum { lynx };

/// Processor status bits.
pub const Flag = struct {
    pub const c: u8 = 0x01;
    pub const z: u8 = 0x02;
    pub const i: u8 = 0x04;
    pub const d: u8 = 0x08;
    pub const b: u8 = 0x10;
    pub const u: u8 = 0x20;
    pub const v: u8 = 0x40;
    pub const n: u8 = 0x80;
};

pub const Regs = struct {
    a: u8 = 0,
    x: u8 = 0,
    y: u8 = 0,
    s: u8 = 0xFF,
    /// Bits 4 and 5 always read set (as PHP pushes them).
    p: u8 = Flag.u | Flag.i,
    pc: u16 = 0,
};

/// The CPU over `Bus` (see the file comment for what `Bus` provides).
pub fn Cpu(comptime Bus: type) type {
    return struct {
        const Self = @This();
        pub const variant: Variant = .lynx;

        regs: Regs = .{},
        /// Instructions executed (interrupt sequences not counted); wraps.
        /// Diagnostic for the frontend overlay (SPEC.md section 14).
        instr_count: u32 = 0,

        /// The reset sequence: I set, D clear, S -= 3 (the three fake
        /// pushes), PC from `bus.read($FFFC/$FFFD)`. The Lynx core never
        /// calls this at boot (core/boot.zig sets the registers directly)
        /// but tests and later consoles do.
        pub fn reset(self: *Self, bus: *Bus) void {
            self.regs.p = (self.regs.p | Flag.i | Flag.u) & ~Flag.d;
            self.regs.s -%= 3;
            const lo: u16 = bus.read(0xFFFC);
            const hi: u16 = bus.read(0xFFFD);
            self.regs.pc = hi << 8 | lo;
        }

        /// One instruction, or the interrupt sequence when `bus.irq_line()`
        /// and I is clear. M0 stub: does nothing (Track A).
        pub fn step(self: *Self, bus: *Bus) void {
            _ = self;
            _ = bus;
        }
    };
}
