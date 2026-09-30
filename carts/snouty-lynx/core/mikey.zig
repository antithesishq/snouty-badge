//! Mikey (SPEC.md sections 3 and 7): timers, interrupts, palette, display
//! DMA source, audio register model, IODAT/SYSCTL1 cart strobes. M0 stub:
//! the registers the frontend reads (palette, DISPADR); M1 Track C fills
//! in the rest.

pub const Mikey = struct {
    /// GREEN0..15 ($FDA0-$FDAF), low nibble used.
    green: [16]u8 = @splat(0),
    /// BLUERED0..15 ($FDB0-$FDBF): blue in the high nibble, red in the low.
    bluered: [16]u8 = @splat(0),
    /// DISPADR ($FD94/$FD95): start of the displayed frame in RAM. The M0
    /// test pattern draws at $C000.
    dispadr: u16 = 0xC000,
};
