//! Per-tick snapshot of the buttons with rising-edge detection.
//! The state is `world.w.input`.
const cart = @import("cart-api");
const world = @import("world.zig");

pub const Button = enum { start, select, a, b, up, down, left, right };

const none: cart.Controls = @bitCast(@as(u16, 0));

pub const State = struct {
    current: cart.Controls = none,
    previous: cart.Controls = none,
};

/// Call once per tick, before anything reads the buttons.
pub fn update(c: cart.Controls) void {
    const s = &world.w.input;
    s.previous = s.current;
    s.current = c;
}

pub fn held(comptime btn: Button) bool {
    return @field(world.w.input.current, @tagName(btn));
}

/// True only on the tick the button went down.
pub fn pressed(comptime btn: Button) bool {
    const s = &world.w.input;
    return @field(s.current, @tagName(btn)) and !@field(s.previous, @tagName(btn));
}
