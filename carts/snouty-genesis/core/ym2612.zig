//! YM2612 register model (SPEC.md section 9): both register parts, the
//! address latches, key-on, F-number/block (with the channel 3 special
//! mode frequencies), total levels, algorithm, LFO, DAC enable and data,
//! and timers A and B as status flags. No envelopes and no output;
//! `pick()` chooses the one voice and `pick_tone()` weighs it against the
//! PSG. M1 Track D owns this file.
//!
//! Ports (Z80 4000-4003, 68000 A04000-A04003): `write_addr(part, v)`
//! latches a register number, `write_data(part, v)` writes it. Part I
//! holds the globals (`22-2B`) and channels 1-3, part II channels 4-6;
//! global registers written through part II are ignored. Reads of any port
//! return the status byte: bit 0 timer A overflow, bit 1 timer B overflow,
//! bit 7 busy (never set: writes take effect at once).
//!
//! Timers: timer A counts one step per FM sample, 144 YM2612 clocks, so
//! it overflows every `(1024 - TA) * 144` clocks; timer B steps every 16
//! samples, `(256 - TB) * 2304` clocks (the YM2203/OPN datasheet's
//! `72 * (1024 - NA) / fM` is written for the OPN's prescaled clock; the
//! YM2612 has a 144-clock sample, MAME fm.c `OPNSetPres(6*24)`, Genesis
//! Plus GX: 18.77 us per timer A step at 7.67 MHz). The YM2612 clock is
//! the 68000's (master / 7), so `tick` takes 68000 cycles. Register 27:
//! bit 0/1 load (run) timer A/B, reloading the counter on a 0-to-1 edge;
//! bit 2/3 let an overflow set the flag; bit 4/5 clear the flag (write
//! strobes); bits 6-7 the channel 3 mode (00 normal, 01 special, 10 CSM;
//! CSM's key-on on timer A overflow is not modelled).
//!
//! The pick: FM level on the PSG's scale (2 dB per step): a carrier TL
//! step is 0.75 dB, so `level = 15 - min(15, TL * 3 / 8)`; TL 127 is
//! silent and never picked. See `pick`.
const Tone = @import("md.zig").Tone;
const Psg = @import("psg.zig").Psg;

/// YM2612 clocks per FM sample (and per timer A step).
pub const clocks_per_sample: u32 = 144;
/// 68000 clock = YM2612 clock, NTSC (53693175 / 7 Hz), numerator and
/// denominator.
pub const master_hz: u64 = 53_693_175;

/// Operator register offset of operators 1-4 (slot order in the chip's
/// register map is 1, 3, 2, 4 at +0, +4, +8, +C).
const op_offset = [4]u8{ 0x0, 0x8, 0x4, 0xC };

/// Carrier mask (bit n = operator n + 1) per algorithm.
const carriers = [8]u4{ 0b1000, 0b1000, 0b1000, 0b1000, 0b1010, 0b1110, 0b1110, 0b1111 };

pub const Ym2612 = struct {
    /// Register file, part I (channels 1-3 and the globals 20-2F) and part
    /// II (channels 4-6), indexed by register number: the raw bytes.
    regs: [2][256]u8 = @splat(@splat(0)),
    /// Address latch per part (the last byte written to 4000 / 4002).
    addr: [2]u8 = @splat(0),
    /// Key-on state per channel, operator mask (bits 0-3 = operators 1-4).
    key_on: [6]u4 = @splat(0),
    /// Block and F-number per channel, `block << 11 | fnum`, committed by
    /// the write to A0-A2 (with the A4-A6 latch).
    freq: [6]u16 = @splat(0),
    /// Channel 3 special mode frequencies, same encoding: index 0 = A9
    /// (operator 1), 1 = AA (operator 2), 2 = A8 (operator 3). Operator 4
    /// uses `freq[2]`.
    ch3_freq: [3]u16 = @splat(0),
    /// The A4-A6 and AC-AE high-byte latches (one each, shared by both
    /// parts as in the chip).
    fh_latch: u8 = 0,
    fh3_latch: u8 = 0,
    /// YM2612 clocks until timer A / B next overflows (while loaded).
    timer_a_left: u32 = 0,
    timer_b_left: u32 = 0,
    /// Status byte: bit 0 timer A overflow, bit 1 timer B overflow; the
    /// busy flag (bit 7) is never set.
    status: u8 = 0,

    /// Power-on (and Z80 RESET) state, field by field.
    pub fn reset(y: *Ym2612) void {
        for (&y.regs) |*part| @memset(part, 0);
        @memset(&y.addr, 0);
        @memset(&y.key_on, 0);
        @memset(&y.freq, 0);
        @memset(&y.ch3_freq, 0);
        y.fh_latch = 0;
        y.fh3_latch = 0;
        y.timer_a_left = 0;
        y.timer_b_left = 0;
        y.status = 0;
    }

    /// 4000 / 4002 (part 0 / 1): latch a register number.
    pub inline fn write_addr(y: *Ym2612, part: u1, v: u8) void {
        y.addr[part] = v;
    }

    /// 4001 / 4003: write the latched register.
    pub fn write_data(y: *Ym2612, part: u1, v: u8) void {
        const r = y.addr[part];
        if (r < 0x30) {
            // Globals exist in part I only.
            if (part != 0 or r < 0x20) return;
            const old = y.regs[0][r];
            y.regs[0][r] = v;
            switch (r) {
                0x27 => y.write_mode(old, v),
                0x28 => {
                    const c = v & 7;
                    if (c == 3 or c == 7) return;
                    y.key_on[c - (c >> 2)] = @truncate(v >> 4);
                },
                else => {},
            }
            return;
        }
        y.regs[part][r] = v;
        if (r < 0xA0 or r >= 0xB0) return;
        const c: u8 = r & 3;
        if (c == 3) return;
        const ch = @as(usize, part) * 3 + c;
        switch (r & 0xFC) {
            0xA4 => y.fh_latch = v & 0x3F,
            0xA0 => y.freq[ch] = @as(u16, y.fh_latch) << 8 | v,
            0xAC => y.fh3_latch = v & 0x3F,
            // A8-AA (part I only): 0 = A8 (operator 3), 1 = A9 (1), 2 = AA (2).
            0xA8 => if (part == 0) {
                const slot: usize = switch (c) {
                    0 => 2,
                    1 => 0,
                    else => 1,
                };
                y.ch3_freq[slot] = @as(u16, y.fh3_latch) << 8 | v;
            },
            else => {},
        }
    }

    fn write_mode(y: *Ym2612, old: u8, v: u8) void {
        if (v & 1 != 0 and old & 1 == 0) y.timer_a_left = y.period_a();
        if (v & 2 != 0 and old & 2 == 0) y.timer_b_left = y.period_b();
        if (v & 0x10 != 0) y.status &= ~@as(u8, 1);
        if (v & 0x20 != 0) y.status &= ~@as(u8, 2);
        // The reset bits are strobes: keep them out of the stored mode.
        y.regs[0][0x27] = v & 0xCF;
    }

    /// Timer A value (10 bits: register 24 = bits 9-2, 25 = bits 1-0).
    pub fn timer_a_value(y: *const Ym2612) u32 {
        return @as(u32, y.regs[0][0x24]) << 2 | (y.regs[0][0x25] & 3);
    }

    /// YM2612 clocks per timer A / B overflow.
    pub fn period_a(y: *const Ym2612) u32 {
        return (1024 - y.timer_a_value()) * clocks_per_sample;
    }
    pub fn period_b(y: *const Ym2612) u32 {
        return (256 - @as(u32, y.regs[0][0x26])) * clocks_per_sample * 16;
    }

    /// Any of 4000-4003 read: the status byte.
    pub inline fn read_status(y: *const Ym2612) u8 {
        return y.status;
    }

    /// Advance the timers by `cycles` 68000 (= YM2612) clocks: the frame
    /// loop calls it once per line with the line's 68000 cycles (488/489)
    /// or more often. Overflows reload from the current register value.
    pub fn tick(y: *Ym2612, cycles: u32) void {
        const mode = y.regs[0][0x27];
        if (mode & 1 != 0) {
            if (advance(&y.timer_a_left, cycles, y.period_a()) and mode & 4 != 0) y.status |= 1;
        }
        if (mode & 2 != 0) {
            if (advance(&y.timer_b_left, cycles, y.period_b()) and mode & 8 != 0) y.status |= 2;
        }
    }

    /// Count `left` down by `cycles`; on reaching 0 reload with `period`
    /// (as often as needed). True when it overflowed at least once.
    fn advance(left: *u32, cycles: u32, period: u32) bool {
        if (cycles < left.*) {
            left.* -= cycles;
            return false;
        }
        const over = cycles - left.*;
        left.* = period - over % period;
        return true;
    }

    /// Channel 3 mode (register 27 bits 6-7): 0 normal, 1 special, 2 CSM.
    pub inline fn ch3_mode(y: *const Ym2612) u2 {
        return @truncate(y.regs[0][0x27] >> 6);
    }

    pub inline fn dac_enabled(y: *const Ym2612) bool {
        return y.regs[0][0x2B] & 0x80 != 0;
    }

    /// Algorithm (register B0-B2 bits 0-2) of channel 0-5.
    pub inline fn algorithm(y: *const Ym2612, ch: usize) u3 {
        return @truncate(y.regs[ch / 3][0xB0 + ch % 3]);
    }

    /// Total level (7 bits) of operator `op` (0-3 = operators 1-4) of
    /// channel `ch`.
    pub inline fn total_level(y: *const Ym2612, ch: usize, op: usize) u7 {
        return @truncate(y.regs[ch / 3][0x40 + op_offset[op] + ch % 3]);
    }

    /// The loudest keyed-on carrier TL of channel `ch`, or null when no
    /// carrier is keyed on (a modulator alone makes no sound).
    pub fn carrier_tl(y: *const Ym2612, ch: usize) ?u7 {
        const on = y.key_on[ch] & carriers[y.algorithm(ch)];
        if (on == 0) return null;
        var best: u7 = 127;
        for (0..4) |op| {
            if (on & (@as(u4, 1) << @intCast(op)) != 0) best = @min(best, y.total_level(ch, op));
        }
        return best;
    }

    /// The FM channel to play (SPEC.md section 9), or null: among channels
    /// with a keyed-on carrier (channel 6 skipped while the DAC is
    /// enabled), the one whose loudest keyed-on carrier has the lowest TL
    /// (the minimum, not the sum: the loudest operator is what the ear
    /// follows); ties go to the lower channel. TL 127 and F-number 0 are
    /// silent. Channel 3 in special (or CSM) mode uses operator 4's
    /// frequency, which is the channel's own A2/A6 pair.
    pub fn pick(y: *const Ym2612) ?Tone {
        var best_ch: usize = 6;
        var best_tl: u7 = 127;
        const n: usize = if (y.dac_enabled()) 5 else 6;
        for (0..n) |ch| {
            const tl = y.carrier_tl(ch) orelse continue;
            if (tl >= best_tl or y.freq[ch] & 0x7FF == 0) continue;
            best_tl = tl;
            best_ch = ch;
        }
        if (best_ch == 6) return null;
        const f = y.freq[best_ch];
        const hz = fm_hz(@truncate(f >> 11), @truncate(f));
        if (hz == 0) return null;
        return .{ .hz = hz, .level = @intCast(15 - @min(15, @as(u32, best_tl) * 3 / 8)) };
    }
};

/// `fnum * 2^(block-1) * 53693175 / (7 * 144 * 2^20)` Hz, rounded to the
/// nearest integer (SPEC.md section 9): fnum 1082 block 4 = 440 (439.73).
pub fn fm_hz(block: u3, fnum: u11) u16 {
    const den: u64 = 7 * 144 << 21;
    const num: u64 = (@as(u64, fnum) << block) * master_hz;
    return @intCast((num + den / 2) / den);
}

/// The one voice (SPEC.md section 9): the FM pick against the PSG pick by
/// level, FM winning ties. `Md.tone()` calls this at frame end.
pub fn pick_tone(y: *const Ym2612, p: *const Psg) ?Tone {
    const fm = y.pick() orelse return p.pick();
    const ps = p.pick() orelse return fm;
    return if (fm.level >= ps.level) fm else ps;
}
