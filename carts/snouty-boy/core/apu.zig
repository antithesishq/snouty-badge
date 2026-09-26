//! Register-level model of sound channels 1..3 for the frontend's single
//! voice (SPEC.md section 9). M3 work; stub until then.
const gb_mod = @import("gb.zig");
const Gb = gb_mod.Gb;

pub const Apu = struct {
    /// Frame sequencer position (0..7), stepped at 512 Hz.
    seq: u8 = 0,
    seq_t: u16 = 0,
};

pub fn reset(gb: *Gb) void {
    gb.apu = .{};
}

pub fn tick(gb: *Gb, m: u8) void {
    _ = gb;
    _ = m;
}
