//! Serial port stub. Nothing is connected; bytes written with a transfer
//! request are captured so test ROMs (Blargg) can be read on the host.
const gb_mod = @import("gb.zig");
const Gb = gb_mod.Gb;

pub const Serial = struct {
    out: [256]u8 = @splat(0),
    len: u16 = 0,

    pub fn text(s: *const Serial) []const u8 {
        return s.out[0..s.len];
    }
};

/// Called by the MMU on a write to SC (0xFF02) with bit 7 set.
///
/// Internal clock (bit 0 set): the transfer completes instantly and no peer
/// answers (received byte 0xFF, SPEC.md 10.3), so SC bit 7 clears and the
/// serial interrupt fires.
///
/// External clock (bit 0 clear): the Game Boy waits for the other side to
/// drive the clock, and with no cable that never happens. SC bit 7 stays
/// set and no interrupt fires. Tetris and Tetris DX probe for a link cable
/// this way on the title screen every frame; completing the transfer (or
/// raising the interrupt) makes them think a second Game Boy answered and
/// they stop reading the joypad.
pub fn start_transfer(gb: *Gb) void {
    if ((gb.io[gb_mod.Reg.sc] & 0x01) == 0) return;
    const s = &gb.serial;
    if (s.len == s.out.len) {
        // Full: drop the oldest half so the tail (e.g. "Passed") stays visible.
        const half = s.out.len / 2;
        @memcpy(s.out[0..half], s.out[half..]);
        s.len = half;
    }
    s.out[s.len] = gb.io[gb_mod.Reg.sb];
    s.len += 1;
    gb.io[gb_mod.Reg.sb] = 0xFF;
    gb.io[gb_mod.Reg.sc] &= 0x7F;
    gb.request_irq(gb_mod.Irq.serial);
}

pub inline fn tick(gb: *Gb, m: u32) void {
    _ = gb;
    _ = m;
}
