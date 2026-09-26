//! Per-tick snapshot of the buttons with rising-edge detection.
const cart = @import("cart-api");

pub const Button = enum { start, select, a, b, up, down, left, right };

const none: cart.Controls = @bitCast(@as(u16, 0));

var current: cart.Controls = none;
var previous: cart.Controls = none;

/// Call once per tick, before anything reads the buttons.
pub fn update(c: cart.Controls) void {
    previous = current;
    current = c;
}

pub fn held(comptime btn: Button) bool {
    return @field(current, @tagName(btn));
}

/// True only on the tick the button went down.
pub fn pressed(comptime btn: Button) bool {
    return @field(current, @tagName(btn)) and !@field(previous, @tagName(btn));
}
