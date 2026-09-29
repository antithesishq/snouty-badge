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
