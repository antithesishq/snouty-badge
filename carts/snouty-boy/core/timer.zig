//! DIV / TIMA / TMA / TAC. Owner in M1: track A.
const gb_mod = @import("gb.zig");
const Gb = gb_mod.Gb;

pub const Timer = struct {
    /// 16-bit internal counter; DIV is its high byte.
    div: u16 = 0,
};

pub fn reset(gb: *Gb) void {
    gb.timer = .{ .div = 0xABCC };
}

/// STUB: track A implements TIMA increments and the overflow interrupt.
pub fn tick(gb: *Gb, m: u8) void {
    gb.timer.div +%= @as(u16, m) * 4;
    gb.io[gb_mod.Reg.div] = @truncate(gb.timer.div >> 8);
}
