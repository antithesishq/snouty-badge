//! Per-tick snapshot of the buttons with rising-edge detection.
//! The play state is `world.w.input`, stepped only by simulated ticks (so
//! a replay from the input log sees exactly the edges the live run saw);
//! the state machine (title, pause) reads its own detector, `meta`,
//! stepped every frame and never rewound.
const cart = @import("cart-api");
const world = @import("world.zig");

pub const Button = enum { start, select, a, b, up, down, left, right };

const none: cart.Controls = @bitCast(@as(u16, 0));

pub const State = struct {
    current: cart.Controls = none,
    previous: cart.Controls = none,
};

/// The state machine's detector (outside the World).
pub var meta: State = .{};

fn step(s: *State, c: cart.Controls) void {
    s.previous = s.current;
    s.current = c;
}

/// Call once per simulated tick, before the simulation reads the buttons.
pub fn update(c: cart.Controls) void {
    step(&world.w.input, c);
}

/// Call once per frame, before the state machine reads `meta_pressed`.
pub fn update_meta(c: cart.Controls) void {
    step(&meta, c);
}

pub fn held(comptime btn: Button) bool {
    return @field(world.w.input.current, @tagName(btn));
}

/// True only on the tick the button went down.
pub fn pressed(comptime btn: Button) bool {
    return edge(btn, &world.w.input);
}

/// True only on the frame the button went down (state machine).
pub fn meta_pressed(comptime btn: Button) bool {
    return edge(btn, &meta);
}

fn edge(comptime btn: Button, s: *const State) bool {
    return @field(s.current, @tagName(btn)) and !@field(s.previous, @tagName(btn));
}
