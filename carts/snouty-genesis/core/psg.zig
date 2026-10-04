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
const inv_bin: i64 = 55_117;

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

    /// One 44.1 kHz sample: the four channels' mean levels summed.
    pub fn sample(s: *Synth, p: *const Psg) i32 {
        s.frac += bin_q16;
        const bin: i32 = @intCast(s.frac >> 16);
        s.frac &= 0xFFFF;
        var total: i64 = 0;
        for (0..3) |c| {
            const vol: i64 = tables.psg_vol[p.atten[c]];
            const period = p.tone[c];
            if (period <= 1) {
                // Constant high (Sega): the level is the volume.
                total += vol * bin;
                continue;
            }
            const half: i32 = @as(i32, period) * count_clocks;
            if (vol == 0) {
                // Silent: only keep the counter running.
                s.left[c] -= bin;
                while (s.left[c] <= 0) {
                    s.left[c] += half;
                    s.high[c] = !s.high[c];
                }
                continue;
            }
            var rem = bin;
            var acc: i32 = 0;
            while (s.left[c] <= rem) {
                acc += if (s.high[c]) s.left[c] else -s.left[c];
                rem -= s.left[c];
                s.high[c] = !s.high[c];
                s.left[c] = half;
            }
            acc += if (s.high[c]) rem else -rem;
            s.left[c] -= rem;
            total += vol * acc;
        }
        // Noise.
        const nvol: i64 = tables.psg_vol[p.atten[3]];
        const rate = p.noise & 3;
        const nhalf: i32 = if (rate == 3) @as(i32, @max(p.tone[2], 1)) * count_clocks else (@as(i32, 0x10) << @intCast(rate)) * count_clocks;
        var rem = bin;
        var acc: i32 = 0;
        while (s.left[3] <= rem) {
            acc += if (s.lfsr & 1 != 0) s.left[3] else -s.left[3];
            rem -= s.left[3];
            s.left[3] = nhalf;
            s.high[3] = !s.high[3];
            if (s.high[3]) {
                const fb: u16 = if (p.noise & 4 != 0) (s.lfsr ^ (s.lfsr >> 3)) & 1 else s.lfsr & 1;
                s.lfsr = (s.lfsr >> 1) | (fb << 15);
            }
        }
        acc += if (s.lfsr & 1 != 0) rem else -rem;
        s.left[3] -= rem;
        total += nvol * acc;
        return @intCast((total * inv_bin) >> 26);
    }
};
