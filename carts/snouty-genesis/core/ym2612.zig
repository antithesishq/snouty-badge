//! YM2612 register model (SPEC.md section 9): both register parts, the
//! address latches, key-on, timers A and B as status flags, DAC enable.
//! No envelopes and no output; `pick()` chooses the one voice.
//!
//! M0 scaffold: the state at real size and the port interface as stubs.
//! M1 Track D owns this file.
const Tone = @import("md.zig").Tone;

pub const Ym2612 = struct {
    /// Register file, part I (channels 1-3 and the globals 20-2F) and part
    /// II (channels 4-6), indexed by register number.
    regs: [2][256]u8 = @splat(@splat(0)),
    /// Address latch per part (the last byte written to 4000 / 4002).
    addr: [2]u8 = @splat(0),
    /// Key-on state per channel, operator mask (bits 0-3 = slots 1-4).
    key_on: [6]u4 = @splat(0),
    /// Timer A (10 bits) and B (8 bits) counters, in their own ticks.
    timer_a: u16 = 0,
    timer_b: u16 = 0,
    /// Cycles left over from the last timer advance (M1: the unit of the
    /// cycle count `md.zig` feeds in is Track D's call).
    timer_carry: u32 = 0,
    /// Status byte: bit 0 timer A overflow, bit 1 timer B overflow; the
    /// busy flag (bit 7) is never set.
    status: u8 = 0,

    /// Power-on state, field by field (no default image copied from flash).
    pub fn reset(y: *Ym2612) void {
        for (&y.regs) |*part| @memset(part, 0);
        @memset(&y.addr, 0);
        @memset(&y.key_on, 0);
        y.timer_a = 0;
        y.timer_b = 0;
        y.timer_carry = 0;
        y.status = 0;
    }

    /// 4000 / 4002 (part 0 / 1): latch a register number.
    pub fn write_addr(y: *Ym2612, part: u1, v: u8) void {
        y.addr[part] = v;
    }

    /// 4001 / 4003: write the latched register. M0 stores the byte only;
    /// M1 adds key-on (28), timers (24-27) and DAC enable (2B).
    pub fn write_data(y: *Ym2612, part: u1, v: u8) void {
        y.regs[part][y.addr[part]] = v;
    }

    /// Any of 4000-4003 read: the status byte.
    pub fn read_status(y: *const Ym2612) u8 {
        return y.status;
    }

    /// The keyed-on FM channel to play (SPEC.md section 9), or null.
    /// M0 stub: always null.
    pub fn pick(y: *const Ym2612) ?Tone {
        _ = y;
        return null;
    }
};
