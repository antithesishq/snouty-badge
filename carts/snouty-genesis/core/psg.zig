//! SN76489 register model (SPEC.md section 9), written from either CPU
//! (68000 at C00011, Z80 at 7F11). No synthesis: the registers feed
//! `pick()`, the PSG half of `Md.tone()` (`ym2612.pick_tone`). M1 Track D
//! owns this file.
//!
//! Writes (Gear's model, carts/snouty-gear/core/psg.zig):
//! - Latch byte `1 cc t dddd`: selects channel `cc` and type `t` (1
//!   attenuation, 0 tone/noise) and writes `dddd` into the low 4 bits of
//!   that register (all 3 bits of the noise register, all 4 of an
//!   attenuation).
//! - Data byte `0 - dddddd`: goes to the latched register. Tone: the high
//!   6 bits of the 10-bit period. Noise: the low 3 bits. Attenuation: the
//!   low 4 bits.
const Tone = @import("md.zig").Tone;

/// PSG clock in Hz (NTSC, master / 15).
pub const clock: u32 = 3_579_545;

/// Periods up to 6 are the DC tricks sample playback uses (and tones above
/// 18 kHz): never a voice.
pub const max_silent_period: u16 = 6;

pub const Psg = struct {
    /// Tone periods of channels 0-2 (10 bits).
    tone: [3]u16 = @splat(0),
    /// Noise control (bits 0-1 shift rate, bit 2 white/periodic).
    noise: u8 = 0,
    /// Attenuation of channels 0-3, 0 loudest, 15 off.
    atten: [4]u4 = @splat(15),
    /// Last latched register: channel << 1 | (1 = attenuation).
    latch: u3 = 0,

    pub fn reset(p: *Psg) void {
        p.* = .{};
    }

    /// One byte written to the PSG port.
    pub fn write(p: *Psg, v: u8) void {
        if (v & 0x80 != 0) p.latch = @truncate(v >> 4);
        const ch: u2 = @truncate(p.latch >> 1);
        if (p.latch & 1 != 0) {
            p.atten[ch] = @truncate(v);
        } else if (ch == 3) {
            p.noise = v & 0x07;
        } else if (v & 0x80 != 0) {
            p.tone[ch] = (p.tone[ch] & 0x3F0) | (v & 0x0F);
        } else {
            p.tone[ch] = (p.tone[ch] & 0x00F) | (@as(u16, v & 0x3F) << 4);
        }
    }

    /// The loudest tone channel (lowest attenuation, below 15, period
    /// above 6; ties go to the lower channel) as `hz = 3579545 / (32 *
    /// period)` (rounded down) and `level = 15 - attenuation`, or null.
    /// Noise is never a candidate.
    pub fn pick(p: *const Psg) ?Tone {
        var best: ?usize = null;
        for (0..3) |i| {
            if (p.atten[i] >= 15 or p.tone[i] <= max_silent_period) continue;
            if (best) |b| if (p.atten[i] >= p.atten[b]) continue;
            best = i;
        }
        const i = best orelse return null;
        return .{ .hz = @intCast(clock / (32 * @as(u32, p.tone[i]))), .level = 15 - p.atten[i] };
    }
};

// ---- Synthesis (PLAN.md "Sound on the new firmware (2026-10-04)") ----
//
// The SN76489 as an instrument, for the RAM cart's streamed sound
// (core/sound.zig); render-only state outside `Md`. Sources: the SN76489
// datasheet and SMS Power's "SN76489" page (Maxim): tone counters clocked
// at clock / 16 that flip the output each time they count down the
// 10-bit period (f = clock / (32 * period)); periods 0 and 1 give a
// constant high output on Sega's chips, which sample playback relies on;
// noise from a 16-bit LFSR with Sega's taps (bits 0 and 3, white) or bit
// 0 alone (periodic), shifted on every second count-down of its counter
// (rate clock / 512, / 1024, / 2048 or tone 2's), reset to 0x8000 by any
// noise register write, output bit 0; attenuation 2 dB per step, 15 off
// (core/ym_tables.zig `psg_vol`). Outputs are bipolar (+-volume).
//
// Box filter: each 44.1 kHz sample is the mean level over its bin (the
// counters run in master clocks, 240 per count, and a bin is 1217 or 1218
// of them), so a 100 kHz square comes out as its mean, not a whine.

const tables = @import("ym_tables.zig");

/// Master clocks per PSG count (16 PSG clocks of master / 15).
const count_clocks: i32 = 240;
/// Master clocks per 44.1 kHz sample, Q16 (53693175 / 44100).
const bin_q16: u32 = 79_792_198;
/// 2^26 / 1217.53: a bin's integral to its mean.
const inv_bin: i32 = 55_117;

/// The mean level of a bin whose +-1 integral is `acc` master clocks.
inline fn mean(acc: i32, vol: i32) i32 {
    // |acc * vol| < 2^22; >> 8 keeps the product with inv_bin under 2^30.
    return ((acc * vol) >> 8) * inv_bin >> 18;
}

/// A silent channel's counter over `bins`: the flips without the levels.
fn run_silent(left: *i32, high: *bool, half: i32, bins: []const i32) void {
    var total: i32 = 0;
    for (bins) |b| total += b;
    left.* -= total;
    if (left.* > 0) return;
    const k = @divTrunc(-left.*, half) + 1;
    left.* += k * half;
    if (k & 1 != 0) high.* = !high.*;
}

/// One tone channel over `bins`: a bin without a flip adds the level
/// (the common case: periods above 5 flip less than once a bin), one with
/// flips adds the integral's mean.
noinline fn tone(left: *i32, high: *bool, half: i32, vol: i32, bins: []const i32, mix: []i32) void {
    if (vol == 0) return run_silent(left, high, half, bins);
    for (bins, mix) |bin, *m| {
        if (left.* > bin) {
            left.* -= bin;
            m.* += if (high.*) vol else -vol;
            continue;
        }
        var rem = bin;
        var acc: i32 = 0;
        while (left.* <= rem) {
            acc += if (high.*) left.* else -left.*;
            rem -= left.*;
            high.* = !high.*;
            left.* = half;
        }
        acc += if (high.*) rem else -rem;
        left.* -= rem;
        m.* += mean(acc, vol);
    }
}

pub const Synth = struct {
    /// Master clocks to each counter's next count-down (tones 0-2, noise).
    left: [4]i32 = @splat(count_clocks),
    /// Output flip-flops (tones) and the noise counter's half step.
    high: [4]bool = @splat(false),
    lfsr: u16 = 0x8000,
    /// The bin length's fraction (Q16 master clocks).
    frac: u32 = 0,

    pub fn reset(s: *Synth) void {
        s.* = .{};
    }

    /// After a write to the PSG port: a noise register write resets the LFSR.
    pub fn written(s: *Synth, p: *const Psg) void {
        if (p.latch == 6) s.lfsr = 0x8000;
    }

    /// The next `bins.len` bin lengths (master clocks, 1217 or 1218).
    pub fn next_bins(s: *Synth, bins: []i32) void {
        for (bins) |*b| {
            s.frac += bin_q16;
            b.* = @intCast(s.frac >> 16);
            s.frac &= 0xFFFF;
        }
    }

    /// Add the four channels' mean levels over `bins` (from `next_bins`)
    /// to `mix`, one per bin.
    pub fn add(s: *Synth, p: *const Psg, bins: []const i32, mix: []i32) void {
        for (0..3) |c| {
            const vol: i32 = tables.psg_vol[p.atten[c]];
            const period = p.tone[c];
            if (period <= 1) {
                // Constant high (Sega): the level is the volume.
                if (vol != 0) for (mix) |*m| {
                    m.* += vol;
                };
                continue;
            }
            tone(&s.left[c], &s.high[c], @as(i32, period) * count_clocks, vol, bins, mix);
        }
        // Noise: the LFSR shifts when its counter's flip-flop goes high.
        const nvol: i32 = tables.psg_vol[p.atten[3]];
        const rate = p.noise & 3;
        const nhalf: i32 = if (rate == 3) @as(i32, @max(p.tone[2], 1)) * count_clocks else (@as(i32, 0x10) << @intCast(rate)) * count_clocks;
        const white = p.noise & 4 != 0;
        // Silent noise only keeps its counter (the LFSR waits).
        if (nvol == 0) return run_silent(&s.left[3], &s.high[3], nhalf, bins);
        for (bins, mix) |bin, *m| {
            const lvl: i32 = if (s.lfsr & 1 != 0) nvol else -nvol;
            if (s.left[3] > bin) {
                s.left[3] -= bin;
                m.* += lvl;
                continue;
            }
            var rem = bin;
            var acc: i32 = 0;
            while (s.left[3] <= rem) {
                acc += if (s.lfsr & 1 != 0) s.left[3] else -s.left[3];
                rem -= s.left[3];
                s.left[3] = nhalf;
                s.high[3] = !s.high[3];
                if (s.high[3]) {
                    const fb: u16 = if (white) (s.lfsr ^ (s.lfsr >> 3)) & 1 else s.lfsr & 1;
                    s.lfsr = (s.lfsr >> 1) | (fb << 15);
                }
            }
            acc += if (s.lfsr & 1 != 0) rem else -rem;
            s.left[3] -= rem;
            m.* += mean(acc, nvol);
        }
    }

    /// One 44.1 kHz sample of all four channels (tests).
    pub fn sample(s: *Synth, p: *const Psg) i32 {
        var bin: [1]i32 = undefined;
        var m: [1]i32 = .{0};
        s.next_bins(&bin);
        s.add(p, &bin, &m);
        return m[0];
    }
};
