//! SN76489 register model (SPEC.md section 9), written from either CPU
//! (68000 at C00011, Z80 at 7F11). No synthesis: the registers feed
//! `pick()`, the PSG half of `Md.tone()`.
//!
//! M0 scaffold: the state at real size and the register write (latch and
//! data bytes). M1 Track D owns this file and adds `pick()`.
const Tone = @import("md.zig").Tone;

pub const Psg = struct {
    /// Tone periods of channels 0-2 (10 bits).
    tone: [3]u16 = @splat(0),
    /// Noise control (bits 0-2: shift rate, bit 2 white/periodic).
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
        if (v & 0x80 != 0) {
            p.latch = @truncate(v >> 4);
            p.set(v & 0x0F, true);
        } else {
            p.set(v & 0x3F, false);
        }
    }

    fn set(p: *Psg, d: u8, low: bool) void {
        const ch: u2 = @truncate(p.latch >> 1);
        if (p.latch & 1 != 0) {
            p.atten[ch] = @truncate(d);
        } else if (ch == 3) {
            p.noise = d & 0x07;
        } else if (low) {
            p.tone[ch] = (p.tone[ch] & 0x3F0) | d;
        } else {
            p.tone[ch] = (p.tone[ch] & 0x00F) | @as(u16, d) << 4;
        }
    }

    /// The loudest tone channel as a `Tone` (SPEC.md section 9), or null.
    /// M0 stub: always null. M1 Track D.
    pub fn pick(p: *const Psg) ?Tone {
        _ = p;
        return null;
    }
};
