//! Badge controls -> Game Boy pad byte. The Select long-hold state machine
//! (SPEC.md section 5) is M3; M1 maps buttons straight through.
const cart = @import("cart-api");
const core = @import("core");
const Pad = core.Pad;

pub fn pad_from_controls(c: cart.Controls) u8 {
    var pad: u8 = 0;
    if (c.right) pad |= Pad.right;
    if (c.left) pad |= Pad.left;
    if (c.up) pad |= Pad.up;
    if (c.down) pad |= Pad.down;
    if (c.a) pad |= Pad.a;
    if (c.b) pad |= Pad.b;
    if (c.select) pad |= Pad.select;
    if (c.start) pad |= Pad.start;
    return pad;
}
