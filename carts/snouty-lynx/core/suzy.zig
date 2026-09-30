//! Suzy (SPEC.md sections 3 and 7): SCB walker, sprite decoder (literal
//! and packed, 1-4 bpp), scaling, stretch and tilt, quadrants, sprite
//! types, collision buffer and depository, math unit, bus-time estimate.
//! M0 stub; M1 Track B writes it.

pub const Suzy = struct {
    /// SPRSYS ($FC92 write / read) as last written.
    sprsys: u8 = 0,
};
