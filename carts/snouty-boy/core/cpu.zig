//! SM83 interpreter. Owner in M1: track A. `step` executes one instruction
//! (or an interrupt dispatch) and returns the M-cycles it took; `Gb.tick`
//! advances everything else by that amount afterwards.
const gb_mod = @import("gb.zig");
const Gb = gb_mod.Gb;

pub const Cpu = struct {
    a: u8 = 0,
    f: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
    d: u8 = 0,
    e: u8 = 0,
    h: u8 = 0,
    l: u8 = 0,
    sp: u16 = 0,
    pc: u16 = 0,
    ime: bool = false,
    /// EI takes effect after the next instruction.
    ei_pending: bool = false,
    halted: bool = false,
    halt_bug: bool = false,
};

/// Post-boot DMG register values (SPEC.md section 3).
pub fn reset(gb: *Gb) void {
    gb.cpu = .{
        .a = 0x01,
        .f = 0xB0,
        .b = 0x00,
        .c = 0x13,
        .d = 0x00,
        .e = 0xD8,
        .h = 0x01,
        .l = 0x4D,
        .sp = 0xFFFE,
        .pc = 0x0100,
    };
}

/// Execute one instruction; return M-cycles (1..6). STUB: burns one cycle
/// without touching state so the scaffold builds; track A replaces it.
pub fn step(gb: *Gb) u8 {
    _ = gb;
    return 1;
}
