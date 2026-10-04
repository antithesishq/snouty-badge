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
const tables = @import("ym_tables.zig");
const tunables = @import("tunables.zig");

/// FM synthesis is in this build (`build_options.synth`: the RAM cart,
/// see `Fm` below and core/sound.zig).
pub const synth_enabled: bool = @import("build_options").synth;

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
        // The chip resets with both outputs of every channel on (L and R,
        // B4-B6 bits 7-6: Nuked-OPN2's reset sets pan_l/pan_r to 1), so a
        // game that never writes B4 is heard. Only the synthesis reads them.
        if (synth_enabled) {
            for (&y.regs) |*part| @memset(part[0xB4..0xB7], 0xC0);
        }
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

// ---- FM synthesis (PLAN.md "Sound on the new firmware (2026-10-04)") ----
//
// The YM2612 as an instrument, rendered from the register model above at
// the badge's 44.1 kHz (or 22.05 / 14.7 kHz, `tunables.fm_rate_div`, each
// value repeated). Only the RAM cart has it (`synth_enabled`); everything
// here is render-only state, outside `Md` (core/sound.zig owns it), so
// keyframes, the goldens and the register model are untouched. Sources:
// the YM2612 (OPN2) and YM2608 (OPNA) datasheets for the register layout,
// the rate, detune and LFO tables; Nemesis' YM2612 notes on the SpritesMind
// forum (2008-2009) for the phase generator (detune added after the block
// shift, 17-bit wrap, then the multiple), the envelope generator (a counter
// stepping every 3 samples, 11 - rate/4 shift, the 8-step increment rows,
// the exponential attack `level += ~level * inc >> 4`), the modulation
// input (a modulator's 14-bit output >> 1 into the 10-bit phase) and the
// op1 feedback (the sum of its last two outputs >> (10 - FB)). MAME's
// fm.cpp and Nuked-OPN2 were read for what the documents leave open (the
// reset pan state, the LFO step lengths); nothing is copied.
//
// Per operator: a 32-bit phase (top 10 bits index the sine; the chip's
// 20-bit phase << 12), its increment per evaluation (the chip's increment
// times 53,267 / 44,100 times the rate divider), the 10-bit envelope level
// and the attenuation used by the sine (envelope + TL + AM, << 2 into the
// log domain). Output: logsin[quarter phase] + attenuation through the
// 2^-x table, signed by the half wave, +-8191 (14 bits).
//
// Modelled: all 8 algorithms, feedback, detune, multiple, key scaling,
// AR/D1R/D2R/RR and SL, TL, channel 3 special mode, the DAC on channel 6
// (as a held level), the LFO (AM and PM; PM as a triangle of the PMS depth
// in cents applied to the F-number), L/R enables to mono. Left out: SSG-EG,
// CSM key-on, the operators' one-sample pipeline delays, the 9-bit DAC's
// truncation and ladder effect, and the busy flag (as in the register
// model).

/// Chip samples (53,267 Hz) per badge sample (44,100 Hz), Q16, x 3:
/// envelope clocks per 44.1 kHz evaluation (the EG steps every 3 chip
/// samples): 53693175 / 7 / 144 / 44100 / 3 * 65536.
const eg_step_44k: u32 = 26386;
/// Phase increment scale: 53693175 / (7 * 144 * 44100) * 4096 * 256 (chip
/// increment -> this 32-bit phase per 44.1 kHz sample, Q8).
const phase_mul: u64 = 1_266_543;
/// LFO: chip samples per LFO step for register 22 rates 0-7 (3.98 to 72.2
/// Hz at 128 steps a cycle, YM2608 datasheet; step counts as MAME's).
const lfo_samples = [8]u32{ 108, 77, 71, 67, 62, 44, 8, 5 };
/// Detune (datasheet table, chip increment units) for DT 1-3 by key code.
const dt_tab = [3][32]u8{
    .{ 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 6, 6, 7, 8, 8, 8, 8 },
    .{ 1, 1, 1, 1, 2, 2, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 6, 6, 7, 8, 8, 9, 10, 11, 12, 13, 14, 16, 16, 16, 16 },
    .{ 2, 2, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 6, 6, 7, 8, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 20, 22, 22, 22, 22 },
};
/// Envelope increments per EG step for rate & 3, rates 2-47 (row 0-3)
/// and, doubled per rate/4 above 47, rates 48-59 (rows 4-7).
const eg_rows = [8][8]u8{
    .{ 0, 1, 0, 1, 0, 1, 0, 1 }, .{ 0, 1, 0, 1, 1, 1, 0, 1 },
    .{ 0, 1, 1, 1, 0, 1, 1, 1 }, .{ 0, 1, 1, 1, 1, 1, 1, 1 },
    .{ 1, 1, 1, 1, 1, 1, 1, 1 }, .{ 1, 1, 1, 2, 1, 1, 1, 2 },
    .{ 1, 2, 1, 2, 1, 2, 1, 2 }, .{ 1, 2, 2, 2, 1, 2, 2, 2 },
};
/// PM depth for PMS 1-7 (3.4 to 80 cents), as 2^(cents/1200) - 1 in Q16.
const pm_depth = [8]u32{ 0, 129, 254, 380, 532, 761, 1532, 3099 };
/// AM depth shift for AMS 0-3 (off, 1.4, 5.9, 11.8 dB of a 126-step wave).
const ams_shift = [4]u3{ 7, 3, 1, 0 };

pub const EgState = enum(u2) { attack, decay, sustain, release };

pub const Op = struct {
    phase: u32 = 0,
    inc: u32 = 0,
    /// Envelope attenuation, 0 loudest .. 1023 silent.
    level: u16 = 1023,
    /// (level + TL + AM, at most 1023) << 2: the sine's attenuation.
    att: u16 = 4092,
    /// TL << 3 (0.75 dB steps in envelope units) and the sustain level.
    tl: u16 = 0,
    sl: u16 = 0,
    /// Effective rates (0-63, key scaling in) per `EgState`.
    rate: [4]u8 = @splat(0),
    /// The current state's rate and its step mask ((1 << shift) - 1: the
    /// envelope steps when the EG counter & mask is 0), `set_eg`.
    eg_rate: u8 = 0,
    eg_mask: u32 = 0,
    state: EgState = .release,
    am: bool = false,
};

pub const Chan = struct {
    /// Operator 1's last two outputs (feedback).
    prev: [2]i32 = @splat(0),
    alg: u3 = 0,
    fb: u3 = 0,
    /// Enabled outputs (0-2: L + R); the mono mix weighs by n / 2.
    pan: u2 = 2,
    ams: u2 = 0,
    pms: u3 = 0,
    /// Key-on mask as the synthesis last applied it (operators 1-4).
    keyed: u4 = 0,
    dirty: bool = true,
    /// Every operator released to silence: the channel is skipped until
    /// the next key-on.
    silent: bool = true,
};

pub const Fm = struct {
    op: [6][4]Op = @splat(@splat(.{})),
    ch: [6]Chan = @splat(.{}),
    eg_cnt: u32 = 0,
    eg_frac: u32 = 0,
    lfo_cnt: u8 = 0,
    lfo_frac: u32 = 0,
    /// The DAC (register 2A) as an output level, +-8192.
    dac: i32 = 0,

    /// Forget all render state and take the registers as they are (power
    /// on, Z80 RESET, a restore, rendering switched on): envelopes silent,
    /// then every keyed-on operator attacks.
    pub fn resync(f: *Fm, y: *const Ym2612) void {
        for (&f.op) |*ops| for (ops) |*o| {
            o.* = .{};
        };
        for (&f.ch) |*c| c.* = .{};
        f.eg_cnt = 0;
        f.eg_frac = 0;
        f.lfo_cnt = 0;
        f.lfo_frac = 0;
        f.dac = (@as(i32, y.regs[0][0x2A]) - 128) << 6;
        for (0..6) |c| f.key(y, c);
    }

    /// After register `r` of `part` was written (`Ym2612.write_data`).
    pub fn written(f: *Fm, y: *const Ym2612, part: u1, r: u8) void {
        if (r < 0x30) {
            if (part != 0) return;
            switch (r) {
                0x28 => {
                    const c = y.regs[0][0x28] & 7;
                    if (c != 3 and c != 7) f.key(y, c - (c >> 2));
                },
                0x2A => f.dac = (@as(i32, y.regs[0][0x2A]) - 128) << 6,
                0x27 => f.ch[2].dirty = true,
                0x22 => {
                    if (y.regs[0][0x22] & 8 == 0) f.lfo_cnt = 0;
                    for (&f.ch) |*c| c.dirty = true;
                },
                else => {},
            }
            return;
        }
        if (r >= 0xA8 and r < 0xB0) {
            if (part == 0) f.ch[2].dirty = true;
            return;
        }
        const c = r & 3;
        if (c == 3) return;
        f.ch[@as(usize, part) * 3 + c].dirty = true;
    }

    /// Apply channel `c`'s key-on mask from the register model: off-to-on
    /// operators attack from phase 0, on-to-off ones release.
    fn key(f: *Fm, y: *const Ym2612, c: usize) void {
        const ch = &f.ch[c];
        const now = y.key_on[c];
        if (now == ch.keyed) return;
        if (ch.dirty) f.refresh(y, c);
        for (0..4) |i| {
            const bit = @as(u4, 1) << @intCast(i);
            const o = &f.op[c][i];
            if (now & bit != 0 and ch.keyed & bit == 0) {
                ch.silent = false;
                o.phase = 0;
                if (o.rate[0] >= 62) {
                    o.level = 0;
                    o.state = .decay;
                } else o.state = .attack;
                o.att = att_of(o, 0);
                set_eg(o);
            } else if (now & bit == 0 and ch.keyed & bit != 0) {
                o.state = .release;
                set_eg(o);
            }
        }
        ch.keyed = now;
    }

    /// Recompute channel `c`'s operator parameters from the registers.
    fn refresh(f: *Fm, y: *const Ym2612, c: usize) void {
        const ch = &f.ch[c];
        ch.dirty = false;
        const regs = &y.regs[c / 3];
        const k: usize = c % 3;
        const b0 = regs[0xB0 + k];
        const b4 = regs[0xB4 + k];
        ch.alg = @truncate(b0);
        ch.fb = @truncate(b0 >> 3);
        ch.pan = @intCast(@as(u2, @truncate(b4 >> 7)) + @as(u2, @truncate(b4 >> 6 & 1)));
        ch.ams = @truncate(b4 >> 4);
        ch.pms = @truncate(b4);
        const lfo_on = y.regs[0][0x22] & 8 != 0;
        const special = c == 2 and y.ch3_mode() != 0;
        for (0..4) |i| {
            const o = &f.op[c][i];
            const r = op_offset[i] + k;
            const fr: u16 = if (special and i < 3) y.ch3_freq[i] else y.freq[c];
            const block: u5 = @truncate(fr >> 11 & 7);
            var fnum: u32 = fr & 0x7FF;
            // Key code: block and the F-number's top bits (datasheet).
            const f11 = fnum >> 10 & 1;
            const f10 = fnum >> 9 & 1;
            const f9 = fnum >> 8 & 1;
            const f8 = fnum >> 7 & 1;
            const kc: u32 = @as(u32, block) << 2 | f11 << 1 | ((f11 & (f10 | f9 | f8)) | ((f11 ^ 1) & f10 & f9 & f8));
            if (lfo_on and ch.pms != 0) fnum = pm_fnum(fnum, ch.pms, f.lfo_cnt);
            const dtmul = regs[0x30 + r];
            const dt: u32 = dtmul >> 4 & 7;
            var inc: u32 = (fnum << block) >> 1;
            if (dt & 3 != 0) {
                const d: u32 = dt_tab[(dt & 3) - 1][kc];
                inc = if (dt & 4 != 0) inc -% d else inc + d;
            }
            inc &= 0x1FFFF;
            const mul: u32 = dtmul & 15;
            inc = if (mul == 0) inc >> 1 else inc * mul;
            o.inc = @truncate((@as(u64, inc) * tunables.fm_rate_div * phase_mul) >> 8);
            o.tl = @as(u16, regs[0x40 + r] & 0x7F) << 3;
            const ksar = regs[0x50 + r];
            const ks: u32 = kc >> @intCast(3 - (ksar >> 6));
            o.rate[0] = eff_rate(ksar & 31, ks);
            const amd1 = regs[0x60 + r];
            o.am = amd1 & 0x80 != 0;
            o.rate[1] = eff_rate(amd1 & 31, ks);
            o.rate[2] = eff_rate(regs[0x70 + r] & 31, ks);
            const slrr = regs[0x80 + r];
            o.rate[3] = eff_rate((slrr & 15) * 2 + 1, ks);
            const sl: u16 = slrr >> 4;
            o.sl = if (sl == 15) 31 << 5 else sl << 5;
            if (!(o.state == .release and o.level >= 1023)) o.att = att_of(o, 0);
            set_eg(o);
        }
    }

    /// One evaluation of all six channels, mono, in operator units (each
    /// channel +-8191). Steps the envelopes and the LFO by one evaluation.
    pub fn sample(f: *Fm, y: *const Ym2612) i32 {
        f.eg_frac += eg_step_44k * tunables.fm_rate_div;
        while (f.eg_frac >= 1 << 16) {
            f.eg_frac -= 1 << 16;
            f.eg_cnt +%= 1;
            f.eg_tick();
        }
        const lfo = y.regs[0][0x22];
        if (lfo & 8 != 0) {
            f.lfo_frac += lfo_step(lfo & 7);
            while (f.lfo_frac >= 1 << 16) {
                f.lfo_frac -= 1 << 16;
                f.lfo_cnt = (f.lfo_cnt + 1) & 127;
                if (f.lfo_cnt & 3 == 0) for (&f.ch) |*c| {
                    if (c.pms != 0) c.dirty = true;
                };
            }
        }
        const dac_on = y.dac_enabled();
        var acc: i32 = 0;
        for (0..6) |c| {
            const ch = &f.ch[c];
            if (ch.dirty) f.refresh(y, c);
            if (c == 5 and dac_on) {
                acc += (f.dac * ch.pan) >> 1;
                continue;
            }
            if (ch.silent) continue;
            const ops = &f.op[c];
            // Silent when every carrier's envelope is at the bottom.
            const car = carriers[ch.alg];
            var live = false;
            inline for (0..4) |i| {
                if (car & (1 << i) != 0 and ops[i].att < 4092) live = true;
            }
            if (!live) continue;
            const fbm: i32 = if (ch.fb != 0) (ch.prev[0] + ch.prev[1]) >> @intCast(10 - @as(u4, ch.fb)) else 0;
            const o1 = op_out(&ops[0], fbm);
            ch.prev[1] = ch.prev[0];
            ch.prev[0] = o1;
            // The algorithm as masks (`routes`): which outputs feed each
            // operator's modulation input, which are carriers.
            const rt = routes[ch.alg];
            const o2 = op_out(&ops[1], (o1 & mask(rt, 0)) >> 1);
            const o3 = op_out(&ops[2], ((o1 & mask(rt, 1)) + (o2 & mask(rt, 2))) >> 1);
            const o4 = op_out(&ops[3], ((o1 & mask(rt, 3)) + (o2 & mask(rt, 4)) + (o3 & mask(rt, 5))) >> 1);
            var out: i32 = (o1 & mask(rt, 6)) + (o2 & mask(rt, 7)) + (o3 & mask(rt, 8)) + o4;
            out = @max(-8191, @min(8191, out));
            acc += (out * ch.pan) >> 1;
        }
        return acc;
    }

    /// One envelope clock for every operator that is not silent.
    noinline fn eg_tick(f: *Fm) void {
        const cnt = f.eg_cnt;
        const am_wave: u32 = if (f.lfo_cnt < 64) @as(u32, f.lfo_cnt) * 2 else (127 - @as(u32, f.lfo_cnt)) * 2;
        for (&f.ch, &f.op) |*ch, *ops| {
            if (ch.silent) continue;
            const am: u32 = if (ch.ams != 0) am_wave >> ams_shift[ch.ams] else 0;
            var any = false;
            for (ops) |*o| {
                if (o.state == .release and o.level >= 1023) continue;
                any = true;
                if (cnt & o.eg_mask != 0 or o.eg_rate < 2) {
                    if (am != 0 and o.am) o.att = att_of(o, am);
                    continue;
                }
                const r = o.eg_rate;
                const shift: u5 = if (r < 48) @intCast(11 - (r >> 2)) else 0;
                const inc = eg_inc(r, @truncate(cnt >> shift));
                var lv: i32 = o.level;
                switch (o.state) {
                    .attack => {
                        lv += (~lv * @as(i32, inc)) >> 4;
                        if (lv <= 0) {
                            lv = 0;
                            o.state = .decay;
                            set_eg(o);
                        }
                    },
                    .decay => {
                        lv += inc;
                        if (lv >= o.sl) {
                            o.state = .sustain;
                            set_eg(o);
                        }
                    },
                    .sustain, .release => lv += inc,
                }
                o.level = @intCast(@min(lv, 1023));
                o.att = if (o.state == .release and o.level >= 1023) 4092 else att_of(o, if (o.am) am else 0);
            }
            if (!any) ch.silent = true;
        }
    }
};

/// The eight algorithms (YM2612 datasheet), operators 1-4 evaluated in
/// order. Bits: 0 op1 -> op2; 1 op1 -> op3; 2 op2 -> op3; 3 op1 -> op4;
/// 4 op2 -> op4; 5 op3 -> op4; 6-8 op1, op2, op3 are carriers (op4 always
/// is). A modulation input is the sum of its sources >> 1.
const routes = [8]u16{
    0b000_100_101, // 0: 1 -> 2 -> 3 -> 4
    0b000_100_110, // 1: (1 + 2) -> 3 -> 4
    0b000_101_100, // 2: (1 + (2 -> 3)) -> 4
    0b000_110_001, // 3: ((1 -> 2) + 3) -> 4
    0b010_100_001, // 4: (1 -> 2) + (3 -> 4)
    0b110_001_011, // 5: 1 -> 2, 3, 4
    0b110_000_001, // 6: (1 -> 2) + 3 + 4
    0b111_000_000, // 7: 1 + 2 + 3 + 4
};

/// All ones when bit `b` of a route is set, else 0.
inline fn mask(rt: u16, comptime b: u4) i32 {
    return -@as(i32, (rt >> b) & 1);
}

/// The current state's rate and step mask into `eg_rate` / `eg_mask`.
fn set_eg(o: *Op) void {
    const r = o.rate[@backingInt(o.state)];
    o.eg_rate = r;
    const shift: u5 = if (r < 48) @intCast(11 - (r >> 2)) else 0;
    o.eg_mask = (@as(u32, 1) << shift) - 1;
}

/// The sine's attenuation for envelope level, TL and an AM offset.
inline fn att_of(o: *const Op, am: u32) u16 {
    return @intCast(@as(u32, @min(@as(u32, o.level) + o.tl + am, 1023)) << 2);
}

/// One operator: advance the phase, add the modulation (10-bit phase
/// units), look up the log-sine and convert with the exponent table.
inline fn op_out(o: *Op, m: i32) i32 {
    o.phase +%= o.inc;
    const p: u32 = ((o.phase >> 22) +% @as(u32, @bitCast(m))) & 0x3FF;
    var q = p & 0xFF;
    if (p & 0x100 != 0) q ^= 0xFF;
    const a: u32 = tables.logsin[q] + @as(u32, o.att);
    if (a >= 13 << 8) return 0;
    const v: i32 = tables.exp[a & 0xFF] >> @intCast(a >> 8);
    return if (p & 0x200 != 0) -v else v;
}

/// Rate register (0-31) and key scaling to the effective rate, 0-63.
fn eff_rate(reg: u32, ks: u32) u8 {
    if (reg == 0) return 0;
    return @intCast(@min(63, reg * 2 + ks));
}

/// The envelope increment of rate `r` (2-63) at EG step `step`.
fn eg_inc(r: u8, step: u3) u8 {
    if (r < 48) return eg_rows[r & 3][step];
    if (r >= 60) return 8;
    return eg_rows[4 + (r & 3)][step] << @intCast((r >> 2) - 12);
}

/// LFO steps per evaluation, Q16 (`lfo_samples` chip samples per step).
inline fn lfo_step(rate: u8) u32 {
    return (eg_step_44k * 3 * tunables.fm_rate_div) / lfo_samples[rate];
}

/// The F-number moved by the LFO's PM: a triangle of 32 steps (lfo_cnt /
/// 4) peaking at +-7/7 of the PMS depth.
fn pm_fnum(fnum: u32, pms: u3, lfo_cnt: u8) u32 {
    const s: u32 = lfo_cnt >> 2;
    const t: i32 = @intCast(if (s & 8 == 0) s & 7 else 7 - (s & 7));
    const tri: i32 = if (s & 16 != 0) -t else t;
    const d: i32 = @divTrunc(@as(i32, @intCast(fnum)) * @as(i32, @intCast(pm_depth[pms])) * tri, 7 << 16);
    return @intCast(@max(0, @as(i32, @intCast(fnum)) + d));
}
