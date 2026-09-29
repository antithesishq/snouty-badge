//! SN76489 PSG register model (SPEC.md section 9): latch/data writes,
//! periods, attenuations, noise mode. No sample synthesis. M0 stub with the
//! public shape of PLAN.md's M1 contract (Track C).

pub const Psg = struct {
    /// 10-bit tone periods of channels 0..2.
    tone: [3]u16 = @splat(0),
    /// 4-bit noise control (bit 2 white/periodic, bits 0-1 rate).
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

    /// A byte written to port 7F. M0 stub: latch bookkeeping only.
    pub fn write(p: *Psg, v: u8) void {
        if (v & 0x80 != 0) p.latch = (v >> 4) & 7;
    }
};
