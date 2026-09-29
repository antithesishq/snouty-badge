//! SN76489 PSG register model (SPEC.md section 9): latch/data writes,
//! periods, attenuations, noise mode. No sample synthesis: the frontend
//! (M2) reads `voice()` once per frame and plays it on the badge buzzer.
//!
//! Writes (port 7F, any of 40-7F):
//! - Latch byte `1 cc t dddd`: selects channel `cc` and type `t` (1
//!   attenuation, 0 tone/noise) and writes `dddd` into the low 4 bits of that
//!   register (all 3 bits of the noise register, all 4 of an attenuation).
//! - Data byte `0 - dddddd`: goes to the latched register. Tone: the high
//!   6 bits of the 10-bit period. Noise: the low 3 bits. Attenuation: the
//!   low 4 bits.
//! The noise shift register reset on a noise write is not modelled (no
//! synthesis).

pub const Psg = struct {
    /// 10-bit tone periods of channels 0..2.
    tone: [3]u16 = @splat(0),
    /// 3-bit noise control (bit 2 white/periodic, bits 0-1 rate).
    noise: u8 = 0,
    /// 4-bit attenuations of channels 0..3 (15 = silent).
    atten: [4]u8 = @splat(0x0F),
    /// Last latched register: channel << 1 | type (0 tone/noise, 1 volume).
    latch: u8 = 0,
    /// Port 06 stereo mask (stored, ignored).
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
