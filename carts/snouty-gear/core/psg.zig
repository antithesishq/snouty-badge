//! SN76489 PSG (SPEC.md section 9): the register model (latch/data
//! writes, periods, attenuations, noise mode, the Game Gear stereo port)
//! and, when the frontend asks for it, synthesis at the badge's 44.1 kHz
//! (`Synth`). `voice()` is the old one-voice pick the wasm simulator path
//! still plays through its `tone` import.
//!
//! Writes (port 7F, any of 40-7F):
//! - Latch byte `1 cc t dddd`: selects channel `cc` and type `t` (1
//!   attenuation, 0 tone/noise) and writes `dddd` into the low 4 bits of that
//!   register (all 3 bits of the noise register, all 4 of an attenuation).
//! - Data byte `0 - dddddd`: goes to the latched register. Tone: the high
//!   6 bits of the 10-bit period. Noise: the low 3 bits. Attenuation: the
//!   low 4 bits.
//!
//! Synthesis (`Synth`, docs/EMU_SOUND.md section 2), from SMS Power's
//! "SN76489" page (Development/SN76489: counters, the Sega 16-bit noise
//! register tapped at bits 0 and 3, the 2 dB volume table, port 06):
//! - Each tone counter counts down at clock/16 and reloads from its period
//!   register at zero, flipping the channel's output; so a half period is
//!   `16 x period` Z80 T-states and the tone is `clock / (32 x period)` Hz.
//!   A period written mid-count takes effect at the next reload, as on the
//!   chip. Periods 0 and 1 give a constant +1 (Sega's chips; the sample
//!   playback trick).
//! - Noise: its counter reloads with 0x10/0x20/0x40 (clock/512, /1024,
//!   /2048 shift rates) or tone 2's period; the 16-bit shift register
//!   shifts once every two counter zeros (on the flip-flop's 0 -> 1 edge),
//!   white feeds back bit 0 XOR bit 3, periodic bit 0, into bit 15; the bit
//!   shifted out is the output. A write to the noise register resets the
//!   shift register to 0x8000.
//! - Outputs are bipolar (+v / -v), as SMS Power suggests for emulation
//!   (the real outputs are 0/+1 behind a decaying coupling): no DC step at
//!   every volume change, more headroom in 8 bits. Noise follows the same
//!   convention.
//! - Game Gear port 06 (bits 0-3 right enable of channels 0-3, bits 4-7
//!   left): averaged to mono, so a channel on one side plays at half level
//!   and a game that never writes it (0xFF) gets plain sums. (SMS Power
//!   notes the GG's own speaker ignores port 06; the badge is not a GG.)
//! - Box filter: each 44.1 kHz sample is the mean level over its bin of
//!   81 or 82 T-states (3,579,545 / 44,100 = 81.17, the fraction carried),
//!   integrated exactly between the counters' flips. Lazy: `run_to`
//!   catches up to a console time; the bus calls it before every PSG write
//!   and `Gg.step_frame` at the end of the frame. No per-sample events, no
//!   float.

pub const Psg = struct {
    /// 10-bit tone periods of channels 0..2.
    tone: [3]u16 = @splat(0),
    /// 3-bit noise control (bit 2 white/periodic, bits 0-1 rate).
    noise: u8 = 0,
    /// 4-bit attenuations of channels 0..3 (15 = silent).
    atten: [4]u8 = @splat(0x0F),
    /// Last latched register: channel << 1 | type (0 tone/noise, 1 volume).
    latch: u8 = 0,
    /// Port 06 stereo mask: bits 0-3 right enables of channels 0-3, bits
    /// 4-7 left (only `Synth` reads it).
    stereo: u8 = 0xFF,

    pub fn reset(p: *Psg) void {
        p.* = .{};
    }

    /// A byte written to the PSG port.
    pub fn write(p: *Psg, v: u8) void {
        if (v & 0x80 != 0) p.latch = (v >> 4) & 7;
        const ch = p.latch >> 1;
        if (p.latch & 1 != 0) {
            p.atten[ch] = v & 0x0F;
        } else if (ch == 3) {
            p.noise = v & 0x07;
        } else if (v & 0x80 != 0) {
            p.tone[ch] = (p.tone[ch] & 0x3F0) | (v & 0x0F);
        } else {
            p.tone[ch] = (p.tone[ch] & 0x00F) | (@as(u16, v & 0x3F) << 4);
        }
    }

    /// The tone candidate for the buzzer (SPEC.md section 9): the loudest
    /// tone channel (lowest attenuation) with attenuation below 15 and a
    /// period of at least `min_period`; ties go to the lowest channel. Noise
    /// is never a candidate. Null when nothing is audible.
    pub fn voice(p: *const Psg) ?Voice {
        var best: ?Voice = null;
        for (p.tone, p.atten[0..3], 0..) |period, att, i| {
            if (att >= 15 or period < min_period) continue;
            if (best) |b| if (att >= b.atten) continue;
            best = .{ .channel = @intCast(i), .period = period, .hz = clock / (32 * @as(u32, period)), .atten = @intCast(att) };
        }
        return best;
    }
};

/// Z80/PSG clock in Hz (NTSC).
pub const clock: u32 = 3_579_545;

/// Periods 0 and 1 are the DC tricks sample playback uses (and a
/// 112 kHz / 56 kHz tone nobody hears): never a voice.
pub const min_period: u16 = 2;

pub const Voice = struct {
    /// Tone channel 0..2.
    channel: u2,
    /// 10-bit period.
    period: u16,
    /// `clock / (32 * period)`, rounded down.
    hz: u32,
    /// 0 (loudest) .. 14; each step is 2 dB.
    atten: u4,
};

// ---- Synthesis (render-only state) ----

/// T-states per 44.1 kHz bin: 81 and a fraction of `bin_frac / sample_rate`.
pub const sample_rate: u32 = 44_100;
pub const bin_whole: u32 = clock / sample_rate;
pub const bin_frac: u32 = clock % sample_rate;

/// Most samples one console frame (59,736 T-states, plus at most one
/// instruction of overshoot) can produce: 735.95 on average, 736 or 735.
pub const max_frame_samples = 738;

/// Volume per attenuation step, 2 dB apart, 15 = off (SMS Power's table).
pub const volume = [16]i32{ 32767, 26028, 20675, 16422, 13045, 10362, 8231, 6568, 5193, 4125, 3277, 2603, 2067, 1642, 1304, 0 };

/// Output gain: a sample is `128 + mean * gain >> 16` (rounded), `mean`
/// the sum of the four channels' levels with both stereo sides counted
/// (one channel at attenuation 0 on both sides is 65,534). At 48 one full
/// channel swings +-48 of the 127 available. Chosen from Sonic the
/// Hedgehog (GG), title and Green Hill Zone, 4,000 frames on the host
/// (2026-10-04): peaks reach 126, the 99th percentile 63-74, nothing
/// clips. The weak badge speaker wants the music as loud as that allows;
/// a game louder than Sonic clamps at the rails rather than wrapping.
pub const gain: i32 = 48;

/// "Never" for a channel that does not flip (period 0 or 1).
const never: u32 = std.math.maxInt(u32);

pub const Synth = struct {
    /// False: the next `Gg.step_frame` with rendering on calls `resync`
    /// first (after a reset, a restore, or rendering switched back on).
    live: bool = false,
    /// Console time (T-states into the current frame) rendered up to.
    cursor: u32 = 0,
    /// Where the current output bin ends, and its length (81 or 82).
    bin_end: u32 = 0,
    bin_len: u32 = bin_whole,
    /// The carried fraction of a bin, in 1/sample_rate T-states.
    frac: u32 = 0,
    /// Level x T-states summed so far in the current bin.
    acc: i32 = 0,
    /// When each channel's counter next reaches zero (tones 0-2, noise 3);
    /// `never` for a constant tone.
    next_flip: [4]u32 = @splat(never),
    /// The earliest of `next_flip`.
    next_event: u32 = never,
    /// Output flip-flops (for noise: the shift clock).
    flip: [4]bool = @splat(false),
    /// The noise shift register and the bit it last shifted out.
    lfsr: u16 = 0x8000,
    noise_bit: bool = false,
    /// Each channel's volume with its stereo sides (from the registers).
    amp: [4]i32 = @splat(0),
    /// Signed level of each channel now, and their sum.
    level: [4]i32 = @splat(0),
    level_sum: i32 = 0,

    /// Start rendering at console time `now` from a clean phase: counters
    /// one period away, flip-flops low, the shift register reset.
    pub fn resync(s: *Synth, p: *const Psg, now: u32) void {
        s.* = .{ .live = true, .cursor = now, .bin_end = now + bin_whole };
        for (0..4) |c| s.next_flip[c] = s.reload_at(p, c, now);
        s.refresh(p);
    }

    /// Half period of channel `c` in T-states, 0 for a constant tone.
    fn half(p: *const Psg, c: usize) u32 {
        if (c < 3) {
            const per = p.tone[c];
            return if (per <= 1) 0 else 16 * @as(u32, per);
        }
        const r = p.noise & 3;
        if (r == 3) return 16 * @as(u32, @max(p.tone[2], 1));
        return 16 * (@as(u32, 0x10) << @intCast(r));
    }

    fn reload_at(s: *const Synth, p: *const Psg, c: usize, t: u32) u32 {
        _ = s;
        const h = half(p, c);
        return if (h == 0) never else t + h;
    }

    /// Levels from the registers and flip-flops; `next_event` from the flips.
    pub fn refresh(s: *Synth, p: *const Psg) void {
        var sum: i32 = 0;
        var ev: u32 = never;
        for (0..4) |c| {
            const lr: i32 = @as(i32, (p.stereo >> @intCast(c)) & 1) + ((p.stereo >> @intCast(c + 4)) & 1);
            const amp = volume[p.atten[c] & 15] * lr;
            s.amp[c] = amp;
            const high = if (c < 3) (s.flip[c] or p.tone[c] <= 1) else s.noise_bit;
            s.level[c] = if (high) amp else -amp;
            sum += s.level[c];
            ev = @min(ev, s.next_flip[c]);
        }
        s.level_sum = sum;
        s.next_event = ev;
    }

    /// Before a PSG write at console time `now` the caller has run
    /// `run_to(now)`; this applies the write's side effects on the phase.
    pub fn after_write(s: *Synth, p: *const Psg, now: u32) void {
        const ch = p.latch >> 1;
        if (p.latch & 1 == 0) {
            if (ch == 3) {
                s.lfsr = 0x8000;
            } else if (half(p, ch) == 0) {
                s.next_flip[ch] = never;
            } else if (s.next_flip[ch] == never) {
                // Leaving the constant output: the counter was at 0 or 1, so
                // it reloads from the new period at once.
                s.next_flip[ch] = now + half(p, ch);
            }
        }
        s.refresh(p);
    }

    /// The flips due at `t` (counters at zero): reload, toggle, shift
    /// noise; only the flipped channels' levels change.
    fn flips(s: *Synth, p: *const Psg, t: u32) void {
        var ev: u32 = never;
        for (0..4) |c| {
            if (s.next_flip[c] == t) {
                s.flip[c] = !s.flip[c];
                s.next_flip[c] = s.reload_at(p, c, t);
                var high = s.flip[c];
                if (c == 3) {
                    if (s.flip[3]) {
                        const out = s.lfsr & 1;
                        const fb: u16 = if (p.noise & 4 != 0) (s.lfsr ^ (s.lfsr >> 3)) & 1 else out;
                        s.lfsr = (s.lfsr >> 1) | (fb << 15);
                        s.noise_bit = out != 0;
                    }
                    high = s.noise_bit;
                }
                const l = if (high) s.amp[c] else -s.amp[c];
                s.level_sum += l - s.level[c];
                s.level[c] = l;
            }
            ev = @min(ev, s.next_flip[c]);
        }
        s.next_event = ev;
    }

    /// Render from `cursor` to console time `now`, appending finished
    /// samples to `out[len.*..]` (dropped past its end).
    pub fn run_to(s: *Synth, p: *const Psg, now: u32, out: []u8, len: *u16) void {
        var cur = s.cursor;
        var acc = s.acc;
        while (cur < now) {
            const end = @min(now, @min(s.bin_end, s.next_event));
            acc += s.level_sum * @as(i32, @intCast(end - cur));
            cur = end;
            if (cur == s.next_event) s.flips(p, cur);
            if (cur == s.bin_end) {
                const mean = @divTrunc(acc, @as(i32, @intCast(s.bin_len)));
                const v = std.math.clamp(128 + ((mean * gain + 0x8000) >> 16), 0, 255);
                if (len.* < out.len) {
                    out[len.*] = @intCast(v);
                    len.* += 1;
                }
                acc = 0;
                s.frac += bin_frac;
                var l = bin_whole;
                if (s.frac >= sample_rate) {
                    s.frac -= sample_rate;
                    l += 1;
                }
                s.bin_len = l;
                s.bin_end = cur + l;
            }
        }
        s.cursor = cur;
        s.acc = acc;
    }

    /// Move every time back by `t` (the frame that just ended).
    pub fn rebase(s: *Synth, t: u32) void {
        s.cursor -= t;
        s.bin_end -= t;
        for (&s.next_flip) |*f| {
            if (f.* != never) f.* -= t;
        }
        if (s.next_event != never) s.next_event -= t;
    }
};

const std = @import("std");
