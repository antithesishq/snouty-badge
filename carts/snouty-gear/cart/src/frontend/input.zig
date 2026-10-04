//! Badge controls -> Game Gear pad byte (SPEC.md section 5), with Snouty
//! Boy's Select long-hold state machine:
//!
//! - D-pad to d-pad, badge B to button 1, badge A to button 2 (physical
//!   position: 1 on the left, 2 on the right), Start to Start.
//! - The Game Gear has no Select. A Select tap is reserved and does nothing.
//! - Select held for `hold_frames` (30 frames, 500 ms): `GameInput.open_menu`
//!   is set once and main.zig opens the emulator menu (frontend/menu.zig).
//! - Start pressed while Select is held is the OS exit chord: the hold is
//!   cancelled. Start itself still goes to the game.
//! - Right pressed while Select is held starts fast forward
//!   (`GameInput.fast`, docs/FAST_FORWARD.md at the root), which lasts
//!   while both stay held. Right does not reach the game meanwhile. Letting
//!   go of Right returns to 1x and the Select hold counts from zero again;
//!   letting go of Select returns to 1x with no tap, and a Right still held
//!   waits for its release. Start cancels it as it cancels the hold.
//!
//! Buttons held across a state change are suppressed until released
//! (`suppress_held`); the menu reads `State.live_edge()`, the edge with them
//! masked out, so an A or B pressed with the Select hold that opens the menu
//! does not act on it (review EM-01, the same rule as Snouty Boy's
//! frontend/flow.zig). The joystick click belongs to the OS and is never bound.
const cart = @import("cart-api");
const core = @import("core");
const Pad = core.Pad;

/// The badge's buttons (`cart.Controls`), for host tests.
pub const Controls = cart.Controls;

/// Select held this long (frames at 60 Hz) opens the emulator menu.
pub const hold_frames = 30;

/// Menu setting ("Buttons" row, SPEC.md section 5): false = badge B is button 1 and A is
/// button 2 (physical position); true = swapped.
pub var swap_ab: bool = false;

pub fn pad_from_controls(c: cart.Controls) u8 {
    return pad_mapped(c, swap_ab);
}

/// The mapping with the swap given explicitly (the comptime check below).
fn pad_mapped(c: cart.Controls, swap: bool) u8 {
    var pad: u8 = 0;
    if (c.up) pad |= Pad.up;
    if (c.down) pad |= Pad.down;
    if (c.left) pad |= Pad.left;
    if (c.right) pad |= Pad.right;
    if (c.b) pad |= if (swap) Pad.b2 else Pad.b1;
    if (c.a) pad |= if (swap) Pad.b1 else Pad.b2;
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
    /// Select reached `hold_frames` this frame (the menu opens here).
    open_menu: bool,
    /// Fast forward (Select then Right, both held): main.zig steps several
    /// game frames this update, all with `pad`.
    fast: bool = false,
};

/// The Select long-hold state machine plus the suppress mask.
pub const State = struct {
    edge: Edge = .{},
    holding: bool = false,
    held_frames: u16 = 0,
    /// Fast forward is on (Select then Right, both still held).
    fast: bool = false,
    /// Buttons ignored until released (Controls bits).
    suppress: u16 = 0,
    /// Last frame's `live_edge().cur`, so a suppressed button reads neither
    /// pressed nor released on the live edge until it is pressed afresh.
    live_prev: u16 = 0,

    /// Once per badge frame, in every state, before anything else.
    pub fn poll(s: *State, c: cart.Controls) void {
        s.live_prev = s.edge.cur & ~s.suppress;
        s.edge.update(c);
        s.suppress &= s.edge.cur;
    }

    /// This frame's edge with the suppressed (held-over) buttons masked out
    /// of both frames: what the menu reads.
    pub fn live_edge(s: *const State) Edge {
        return .{ .prev = s.live_prev, .cur = s.edge.cur & ~s.suppress };
    }

    /// Ignore every held button until released and forget a Select hold.
    pub fn suppress_held(s: *State) void {
        s.suppress = s.edge.cur;
        s.holding = false;
        s.held_frames = 0;
        s.fast = false;
    }

    /// Input for a frame in which the game runs.
    pub fn game_frame(s: *State) GameInput {
        const e = s.edge;
        var open_menu = false;

        if (s.fast) {
            if (e.held(.start)) {
                // Start+Select: the OS chord, as for the hold.
                s.end_fast();
                s.holding = false;
            } else if (!e.held(.select)) {
                s.end_fast(); // No tap either.
            } else if (!e.held(.right)) {
                // Back to 1x; the Select hold starts counting again.
                s.fast = false;
                s.holding = true;
                s.held_frames = 0;
            }
        }

        const live: cart.Controls = @bitCast(e.cur & ~s.suppress);
        if (live.select and e.pressed(.select)) {
            s.holding = true;
            s.held_frames = 0;
        }
        if (s.holding) {
            if (e.held(.start)) {
                s.holding = false; // Start+Select: the OS exit chord.
            } else if (e.held(.select)) {
                if (live.right and e.pressed(.right)) {
                    s.holding = false;
                    s.fast = true;
                } else {
                    s.held_frames +|= 1;
                    if (s.held_frames >= hold_frames) {
                        s.holding = false;
                        open_menu = true;
                    }
                }
            } else {
                s.holding = false; // A tap: reserved, nothing happens.
            }
        }

        var pad = pad_from_controls(@bitCast(e.cur & ~s.suppress));
        if (s.fast) pad &= ~Pad.right;
        return .{ .pad = pad, .open_menu = open_menu, .fast = s.fast };
    }

    /// Leave fast forward; a Right still held waits for its release.
    fn end_fast(s: *State) void {
        s.fast = false;
        s.suppress |= s.edge.cur & mask(.right);
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
    if (pad_mapped(c, false) != Pad.b1 | Pad.b2 | Pad.left) @compileError("pad mapping");
    c.a = false;
    if (pad_mapped(c, false) != Pad.b1 | Pad.left) @compileError("badge B is button 1");
    if (pad_mapped(c, true) != Pad.b2 | Pad.left) @compileError("swapped: badge B is button 2");
    if ((all_buttons & (1 << 4)) != 0) @compileError("click must not be a cart button");
}
