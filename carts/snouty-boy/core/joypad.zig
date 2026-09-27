//! P1 (0xFF00) from the pad byte. Owner in M1: track A.
const gb_mod = @import("gb.zig");
const Gb = gb_mod.Gb;
const Pad = gb_mod.Pad;

/// Recompute the low nibble of P1 from the selected group and `gb.pad`, and
/// raise the joypad interrupt on any newly pressed selected button.
pub fn update(gb: *Gb) void {
    const p1 = gb.io[gb_mod.Reg.p1];
    var low: u8 = 0x0F;
    if ((p1 & 0x10) == 0) low &= ~(gb.pad & 0x0F); // d-pad group
    if ((p1 & 0x20) == 0) low &= ~((gb.pad >> 4) & 0x0F); // buttons group
    const prev_low = p1 & 0x0F;
    gb.io[gb_mod.Reg.p1] = 0xC0 | (p1 & 0x30) | low;
    if ((prev_low & ~low) != 0) gb.request_irq(gb_mod.Irq.joypad);
}
