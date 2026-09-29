//! Badge controls -> Game Gear pad byte (SPEC.md section 5), with Snouty
//! Boy's Select long-hold state machine:
//!
//! - D-pad to d-pad, badge B to button 1, badge A to button 2 (physical
//!   position: 1 on the left, 2 on the right), Start to Start.
//! - The Game Gear has no Select. A Select tap is reserved and does nothing.
//! - Select held for `hold_frames` (30 frames, 500 ms): `GameInput.open_menu`
//!   is set once. The menu is M2; until then main.zig ignores it.
//! - Start pressed while Select is held is the OS exit chord: the hold is
//!   cancelled. Start itself still goes to the game.
//!
//! Buttons held across a state change are suppressed until released
//! (`suppress_held`). The joystick click belongs to the OS and is never bound.
const cart = @import("cart-api");
const core = @import("core");
const Pad = core.Pad;

/// Select held this long (frames at 60 Hz) opens the emulator menu.
pub const hold_frames = 30;

pub fn pad_from_controls(c: cart.Controls) u8 {
    var pad: u8 = 0;
    if (c.up) pad |= Pad.up;
    if (c.down) pad |= Pad.down;
    if (c.left) pad |= Pad.left;
    if (c.right) pad |= Pad.right;
    if (c.b) pad |= Pad.b1;
    if (c.a) pad |= Pad.b2;
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

/// Every button the cart may look at.
const all_buttons: u16 = mask(.start) | mask(.select) | mask(.a) | mask(.b) |
    mask(.up) | mask(.down) | mask(.left) | mask(.right);

/// Edge detection over whole frames: call `update` once per `update()` with
/// that frame's controls, then ask which buttons went down or up.
pub const Edge = struct {
    prev: u16 = 0,
    cur: u16 = 0,

    pub fn update(e: *Edge, c: cart.Controls) void {
        e.prev = e.cur;
        e.cur = @bitCast(c);
    }

    pub fn pressed(e: Edge, comptime b: Button) bool {
        return (e.cur & ~e.prev & mask(b)) != 0;
    }

    pub fn released(e: Edge, comptime b: Button) bool {
        return (~e.cur & e.prev & mask(b)) != 0;
    }

    pub fn held(e: Edge, comptime b: Button) bool {
        return (e.cur & mask(b)) != 0;
    }

    pub fn any_pressed(e: Edge) bool {
        return (e.cur & ~e.prev & all_buttons) != 0;
    }
};

/// Result of one running frame's input.
pub const GameInput = struct {
    /// Pad byte for `Gg.step_frame`.
    pad: u8,
    /// Select reached `hold_frames` this frame (the M2 menu opens here).
    open_menu: bool,
};

/// The Select long-hold state machine plus the suppress mask.
pub const State = struct {
    edge: Edge = .{},
    holding: bool = false,
    held_frames: u16 = 0,
    /// Buttons ignored until released (Controls bits).
    suppress: u16 = 0,

    /// Once per badge frame, in every state, before anything else.
    pub fn poll(s: *State, c: cart.Controls) void {
        s.edge.update(c);
        s.suppress &= s.edge.cur;
    }

    /// Ignore every held button until released and forget a Select hold.
    pub fn suppress_held(s: *State) void {
        s.suppress = s.edge.cur;
        s.holding = false;
        s.held_frames = 0;
    }

    /// Input for a frame in which the game runs.
    pub fn game_frame(s: *State) GameInput {
        const e = s.edge;
        const live: cart.Controls = @bitCast(e.cur & ~s.suppress);
        const pad = pad_from_controls(live);
        var open_menu = false;

        if (live.select and e.pressed(.select)) {
            s.holding = true;
            s.held_frames = 0;
        }
        if (s.holding) {
            if (e.held(.start)) {
                s.holding = false; // Start+Select: the OS exit chord.
            } else if (e.held(.select)) {
                s.held_frames +|= 1;
                if (s.held_frames >= hold_frames) {
                    s.holding = false;
                    open_menu = true;
                }
            } else {
                s.holding = false; // A tap: reserved, nothing happens.
            }
        }
        return .{ .pad = pad, .open_menu = open_menu };
    }
};

comptime {
    // Pad bits agree with SPEC.md section 5 and cart.Controls' layout. Kept
    // to a few straight-line checks (no comptime loops, see CLAUDE.md).
    var c: cart.Controls = @bitCast(@as(u16, 0));
    c.a = true;
    c.b = true;
    c.left = true;
    c.select = true;
    if (pad_from_controls(c) != Pad.b1 | Pad.b2 | Pad.left) @compileError("pad mapping");
    if ((all_buttons & (1 << 4)) != 0) @compileError("click must not be a cart button");
}
