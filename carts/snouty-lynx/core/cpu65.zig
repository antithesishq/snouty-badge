//! 65SC02 interpreter, generic over a Bus type (SPEC.md section 7). M0
//! stub: the register file and the shape M1 Track A fills in. Written so
//! a 6502/65C02 variant switch lets NES, 2600 or C64 carts reuse it later;
//! the variant and test suite choice are M0 Track A's (SPEC.md 16).

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
    p: u8 = Flag.u | Flag.i,
    pc: u16 = 0,
};

/// The CPU over `Bus`, which must provide `read(addr: u16) u8` and
/// `write(addr: u16, v: u8) void` (and, in M1, the page-mode cycle
/// accounting of SPEC.md section 3).
pub fn Cpu(comptime Bus: type) type {
    return struct {
        const Self = @This();
        regs: Regs = .{},

        /// Execute one instruction; returns the CPU cycles it took. M0
        /// stub: does nothing and returns 0.
        pub fn step(self: *Self, b: *Bus) u32 {
            _ = self;
            _ = b;
            return 0;
        }
    };
}
