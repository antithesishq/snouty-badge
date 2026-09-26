//! Serial port stub. Nothing is connected; bytes written with a transfer
//! request are captured so test ROMs (Blargg) can be read on the host.
const gb_mod = @import("gb.zig");
const Gb = gb_mod.Gb;

pub const Serial = struct {
    out: [256]u8 = @splat(0),
    len: u8 = 0,

    pub fn text(s: *const Serial) []const u8 {
        return s.out[0..s.len];
    }
};

/// Called by the MMU on a write to SC (0xFF02) with bit 7 set.
pub fn start_transfer(gb: *Gb) void {
    const s = &gb.serial;
    if (s.len < s.out.len) {
        s.out[s.len] = gb.io[gb_mod.Reg.sb];
        s.len += 1;
    }
    // No peer: the received byte is 0xFF and the transfer completes.
    gb.io[gb_mod.Reg.sb] = 0xFF;
    gb.io[gb_mod.Reg.sc] &= 0x7F;
    gb.request_irq(gb_mod.Irq.serial);
}

pub fn tick(gb: *Gb, m: u8) void {
    _ = gb;
    _ = m;
}
