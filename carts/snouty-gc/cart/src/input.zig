//! Forked from snouty-zero/cart/src/input.zig at f8f6962.
//! Per-frame snapshot of the buttons with rising-edge detection, and the
//! race input byte (SPEC 5.1, `world.Input`).
//!
//! Start+Select belongs to the OS (exit, or the settings box on newer
//! firmware): while both are held the cart sees neither, and a press of
//! either that ends up in the chord is never reported (the repository
//! rule). The joystick click is never read.
const cart = @import("cart-api");
const world = @import("world.zig");

pub const Button = enum { start, select, a, b, up, down, left, right };

const none: cart.Controls = @bitCast(@as(u16, 0));

pub var current: cart.Controls = none;
var previous: cart.Controls = none;

/// Call once per frame, before anything reads the buttons.
pub fn update(c: cart.Controls) void {
    previous = current;
    current = c;
    if (current.start and current.select) {
        current.start = false;
        current.select = false;
        // Keep them "held" in `previous` so letting go of one button of the
        // chord does not report a press of the other.
        chord = true;
    } else if (chord) {
        if (!current.start and !current.select) chord = false;
        current.start = false;
        current.select = false;
    }
}
var chord: bool = false;

pub fn held(comptime btn: Button) bool {
    return @field(current, @tagName(btn));
}

/// True only on the frame the button went down.
pub fn pressed(comptime btn: Button) bool {
    return @field(current, @tagName(btn)) and !@field(previous, @tagName(btn));
}

/// The race byte for this frame (bit 0 up, 1 down, 2 left, 3 right, 4 A,
/// 5 B, 6 Start, 7 Select), from the chord-masked buttons.
pub fn race_byte() u8 {
    return pack(current);
}

pub fn pack(c: cart.Controls) u8 {
    const in = world.Input{
        .up = c.up,
        .down = c.down,
        .left = c.left,
        .right = c.right,
        .a = c.a,
        .b = c.b,
        .start = c.start,
        .select = c.select,
    };
    return in.byte();
}
