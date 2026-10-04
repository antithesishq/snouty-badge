//! Badge controls -> Lynx pad word (SPEC.md section 5), with Snouty Gear's
//! Select long-hold state machine (carts/snouty-gear/cart/src/frontend/
//! input.zig, trimmed):
//!
//! - D-pad to d-pad, badge A to A (outer), badge B to B (inner), Start to
//!   Pause. The menu's Buttons row swaps A and B (`swap_ab`).
//! - Select tap (released before `hold_frames`): Option 1 for `tap_frames`
//!   game frames, held back until the fast-forward window below runs out
//!   (`tuning.ff_tap_window`, 200 ms later than a plain tap would be).
//! - Select held `hold_frames` (500 ms): `GameInput.open_menu` is set once
//!   and main.zig opens the emulator menu (frontend/menu.zig).
//! - Start pressed while Select is held is the OS exit chord: the hold is
//!   cancelled.
//! - Double tap and hold Select: fast forward (`GameInput.fast`,
//!   docs/FAST_FORWARD.md at the root). A Select press released before
//!   `hold_frames` opens a window of `tuning.ff_tap_window` frames; a second
//!   press inside it starts fast forward at once, which lasts while Select
//!   stays held, and the first tap's Option 1 is dropped. That press never
//!   runs the menu timer and its release delivers nothing. A window that
//!   runs out with no second press delivers the held-back Option 1. Start
//!   during the window or during fast forward cancels it and drops the tap
//!   (the OS chord). The d-pad and the other buttons reach the game as
//!   usual.
//! - Option 2 and the Pause + Option 1 restart are menu rows (main.zig ORs
//!   `menu.hold_pad` into the pad for a few frames), never buttons.
//!
//! The joystick click belongs to the OS and is never bound.
const cart = @import("cart-api");
const core = @import("core");
const Pad = core.Pad;
const tuning = @import("tuning.zig");

/// The badge's buttons (`cart.Controls`), for host tests.
pub const Controls = cart.Controls;

/// Select held this long (frames at 60 Hz) opens the emulator menu.
pub const hold_frames = 30;
/// Frames Option 1 stays down after a Select tap.
pub const tap_frames = 3;

/// Menu setting (M2): false = badge A is A and B is B; true = swapped.
pub var swap_ab: bool = false;

pub fn pad_from_controls(c: cart.Controls) u16 {
    return pad_mapped(c, swap_ab);
}

/// The mapping with the swap given explicitly (the comptime check below).
fn pad_mapped(c: cart.Controls, swap: bool) u16 {
    var pad: u16 = 0;
    if (c.up) pad |= Pad.up;
    if (c.down) pad |= Pad.down;
    if (c.left) pad |= Pad.left;
    if (c.right) pad |= Pad.right;
    if (c.a) pad |= if (swap) Pad.b else Pad.a;
    if (c.b) pad |= if (swap) Pad.a else Pad.b;
    if (c.start) pad |= Pad.pause;
    return pad;
}

pub const Button = enum { start, select, a, b, up, down, left, right };

fn mask(comptime b: Button) u16 {
    var c: cart.Controls = @bitCast(@as(u16, 0));
    @field(c, @tagName(b)) = true;
    return @bitCast(c);
}

const all_buttons: u16 = mask(.start) | mask(.select) | mask(.a) | mask(.b) |
    mask(.up) | mask(.down) | mask(.left) | mask(.right);

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

pub const GameInput = struct {
    /// Pad word for `Lynx.step_frame`.
    pad: u16,
    /// Select reached `hold_frames` this frame.
    open_menu: bool,
    /// Fast forward (Select double tapped and held): main.zig steps
    /// several game frames this update, all with `pad`.
    fast: bool = false,
};

pub const State = struct {
    edge: Edge = .{},
    holding: bool = false,
    held_frames: u16 = 0,
    /// Game frames Option 1 still stays down after a tap.
    opt1_left: u8 = 0,
    /// Frames left in which a Select press starts fast forward (counts
    /// down from `tuning.ff_tap_window` after a short press, which waits
    /// for it to run out before it becomes Option 1); 0 = closed.
    tap_window: u8 = 0,
    /// Fast forward is on (the second press of a double tap, still held).
    fast: bool = false,
    /// Buttons ignored until released (Controls bits).
    suppress: u16 = 0,

    /// Once per badge frame, in every state, before anything else.
    pub fn poll(s: *State, c: cart.Controls) void {
        s.edge.update(c);
        s.suppress &= s.edge.cur;
    }

    /// Ignore every held button until released and forget a Select hold,
    /// a pending tap and fast forward.
    pub fn suppress_held(s: *State) void {
        s.suppress = s.edge.cur;
        s.holding = false;
        s.held_frames = 0;
        s.opt1_left = 0;
        s.tap_window = 0;
        s.fast = false;
    }

    /// Input for a frame in which the game runs.
    pub fn game_frame(s: *State) GameInput {
        const e = s.edge;
        const live: cart.Controls = @bitCast(e.cur & ~s.suppress);
        const fresh_select = live.select and e.pressed(.select);
        var pad = pad_from_controls(live);
        var open_menu = false;

        if (s.fast) {
            // Start+Select is the OS chord; letting go delivers nothing.
            if (e.held(.start) or !e.held(.select)) s.fast = false;
        } else if (s.tap_window != 0) {
            if (e.held(.start)) {
                s.tap_window = 0; // The OS chord: the tap is dropped.
            } else if (fresh_select) {
                // The second press: fast forward, no menu timer, no tap.
                s.tap_window = 0;
                s.fast = true;
            } else {
                s.tap_window -= 1;
                // No second press: the held-back tap is Option 1.
                if (s.tap_window == 0) s.opt1_left = tap_frames;
            }
        }

        if (!s.fast and fresh_select) {
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
                // A tap: Option 1 once the window runs out, unless a
                // second press soon after makes it the fast-forward
                // double tap.
                s.holding = false;
                s.tap_window = tuning.ff_tap_window;
            }
        }
        if (s.opt1_left > 0) {
            s.opt1_left -= 1;
            pad |= Pad.opt1;
        }
        return .{ .pad = pad, .open_menu = open_menu, .fast = s.fast };
    }
};

comptime {
    // A few straight-line checks (no comptime loops, CLAUDE.md).
    var c: cart.Controls = @bitCast(@as(u16, 0));
    c.a = true;
    c.start = true;
    c.left = true;
    if (pad_mapped(c, false) != Pad.a | Pad.pause | Pad.left) @compileError("pad mapping");
    if (pad_mapped(c, true) != Pad.b | Pad.pause | Pad.left) @compileError("swapped: badge A is B");
    if ((all_buttons & (1 << 4)) != 0) @compileError("click must not be a cart button");
}
