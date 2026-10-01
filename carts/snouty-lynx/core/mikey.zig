//! Mikey (SPEC.md sections 3 and 7): the eight timers and their link
//! chains, interrupts (INTSET/INTRST), the palette, the display registers
//! (DISPCTL, DISPADR, PBKUP), CPUSLEEP, the audio register model (stored,
//! never heard: docs/SOUND.md and the no-audio decision), IODIR/IODAT/
//! SYSCTL1 with the cart block-select strobes, UART stubbed idle.
//! PLAN.md "Frozen for M1" says what the rest of the core sees; M1 Track C
//! owns this file and its internals. M0 stub: the registers the frontend
//! reads (palette, DISPADR).

pub const Mikey = struct {
    /// GREEN0..15 ($FDA0-$FDAF), low nibble used.
    green: [16]u8 = @splat(0),
    /// BLUERED0..15 ($FDB0-$FDBF): blue in the high nibble, red in the low.
    bluered: [16]u8 = @splat(0),
    /// DISPADR ($FD94/$FD95): start of the displayed frame in RAM. The M0
    /// test pattern draws at $C000.
    dispadr: u16 = 0xC000,
};
