//! Badge controls -> Game Boy pad byte. The Select long-hold state machine
//! (SPEC.md section 5) is M3; M1 maps buttons straight through. `Edge` is
//! the per-frame press/release tracking M3 will build on; not wired yet.
//! The joystick click and Start+Select belong to the OS and are never bound.
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

/// Badge buttons the cart may look at (no `click`: the OS owns it).
pub const Button = enum { start, select, a, b, up, down, left, right };

fn mask(comptime b: Button) u16 {
    var c: cart.Controls = @bitCast(@as(u16, 0));
    @field(c, @tagName(b)) = true;
    return @bitCast(c);
}

/// Edge detection over whole frames: call `update` once per `update()` with
/// that frame's controls, then ask which buttons went down or up.
pub const Edge = struct {
    prev: u16 = 0,
    cur: u16 = 0,

    pub fn update(e: *Edge, c: cart.Controls) void {
        e.prev = e.cur;
        e.cur = @bitCast(c);
    }

    /// Down this frame, up last frame.
    pub fn pressed(e: Edge, comptime b: Button) bool {
        return (e.cur & ~e.prev & mask(b)) != 0;
    }

    /// Up this frame, down last frame.
    pub fn released(e: Edge, comptime b: Button) bool {
        return (~e.cur & e.prev & mask(b)) != 0;
    }

    pub fn held(e: Edge, comptime b: Button) bool {
        return (e.cur & mask(b)) != 0;
    }
};

comptime {
    // Pad bits and the Edge masks agree with cart.Controls' layout.
    var c: cart.Controls = @bitCast(@as(u16, 0));
    c.a = true;
    c.left = true;
    if (pad_from_controls(c) != Pad.a | Pad.left) @compileError("pad mapping");
    var e: Edge = .{};
    e.update(c);
    if (!e.pressed(.a) or e.released(.a) or e.pressed(.b)) @compileError("edge press");
    e.update(@bitCast(@as(u16, 0)));
    if (e.pressed(.a) or !e.released(.a) or e.held(.left)) @compileError("edge release");
}
