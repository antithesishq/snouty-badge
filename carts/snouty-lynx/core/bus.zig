//! Lynx memory map (SPEC.md section 7): 64 KB RAM with the Suzy
//! ($FC00-$FCFF), Mikey ($FD00-$FDFF), boot ROM ($FE00-$FFF7) and vector
//! ($FFFA-$FFFF) overlays switched by MAPCTL ($FFF9), and the cart port
//! (block select through Mikey's IODAT/SYSCTL1 strobes, a ripple counter
//! for the byte within the block, reads at $FCB2 RCART0). M0 stub: the
//! addresses and MAPCTL bits only; M1 Track C writes the Bus.

pub const suzy_base: u16 = 0xFC00;
pub const mikey_base: u16 = 0xFD00;
pub const rom_base: u16 = 0xFE00;
pub const mapctl_addr: u16 = 0xFFF9;

/// MAPCTL bits: set = the overlay is off and RAM shows through.
pub const Mapctl = struct {
    pub const suzy_off: u8 = 0x01;
    pub const mikey_off: u8 = 0x02;
    pub const rom_off: u8 = 0x04;
    pub const vectors_off: u8 = 0x08;
};
