//! DIV / TIMA / TMA / TAC. Owner in M1: track A.
//! DIV is the high byte of a 16-bit counter that advances 4 per M-cycle.
//! TIMA increments on each falling edge of the counter bit that TAC selects
//! (while TAC bit 2 is set); overflow reloads TMA and raises the timer IRQ
//! immediately (the one-cycle reload delay is not modelled).
const gb_mod = @import("gb.zig");
const Gb = gb_mod.Gb;
const Reg = gb_mod.Reg;

pub const Timer = struct {
    /// 16-bit internal counter; DIV is its high byte.
    div: u16 = 0,
};

/// Counter bit whose falling edge clocks TIMA, per TAC bits 0..1
/// (4096, 262144, 65536, 16384 Hz).
const tac_shift = [4]u4{ 9, 3, 5, 7 };

pub fn reset(gb: *Gb) void {
    gb.timer = .{ .div = 0xABCC };
    gb.io[Reg.div] = 0xAB;
}

/// Advance `m` CPU M-cycles (batched by `Gb.flush`; exact for any `m`).
pub inline fn tick(gb: *Gb, m: u32) void {
    const old = gb.timer.div;
    const new = old +% @as(u16, @truncate(m *% 4));
    gb.timer.div = new;
    gb.io[Reg.div] = @truncate(new >> 8);
    const tac = gb.io[Reg.tac];
    if ((tac & 0x04) == 0) return;
    // Falling edges of bit b in (old, old + 4m] = multiples of 2^(b+1)
    // crossed. Done in u32 so the u16 wrap needs no special case.
    const s: u5 = @as(u5, tac_shift[tac & 3]) + 1;
    const o32: u32 = old;
    const edges = ((o32 + m * 4) >> s) - (o32 >> s);
    if (edges != 0) inc_tima_n(gb, edges);
}

fn inc_tima_n(gb: *Gb, edges: u32) void {
    var n = edges;
    while (n != 0) : (n -= 1) inc_tima(gb);
}

inline fn inc_tima(gb: *Gb) void {
    const t = gb.io[Reg.tima];
    if (t == 0xFF) {
        gb.io[Reg.tima] = gb.io[Reg.tma];
        gb.request_irq(gb_mod.Irq.timer);
    } else {
        gb.io[Reg.tima] = t + 1;
    }
}

/// M-cycles until TIMA next overflows (the timer interrupt), rounded up,
/// with TAC enabled: the (0x100 - TIMA)-th falling edge from now. Used by
/// `Gb.halt_m`.
pub fn m_to_overflow(gb: *const Gb) u32 {
    const tac = gb.io[Reg.tac];
    const s: u5 = @as(u5, tac_shift[tac & 3]) + 1;
    const div: u32 = gb.timer.div;
    const target = ((div >> s) + (0x100 - @as(u32, gb.io[Reg.tima]))) << s;
    return (target - div + 3) >> 2;
}

inline fn selected_bit_high(gb: *const Gb) bool {
    const tac = gb.io[Reg.tac];
    if ((tac & 0x04) == 0) return false;
    return ((gb.timer.div >> tac_shift[tac & 3]) & 1) != 0;
}

/// Any write to DIV clears the counter; if the selected bit was high that
/// is a falling edge and TIMA ticks.
pub fn write_div(gb: *Gb) void {
    if (selected_bit_high(gb)) inc_tima(gb);
    gb.timer.div = 0;
    gb.io[Reg.div] = 0;
}

/// TAC write: a high-to-low change of the (enable AND selected bit) signal
/// also clocks TIMA on DMG.
pub fn write_tac(gb: *Gb, v: u8) void {
    const before = selected_bit_high(gb);
    gb.io[Reg.tac] = v | 0xF8;
    if (before and !selected_bit_high(gb)) inc_tima(gb);
}
