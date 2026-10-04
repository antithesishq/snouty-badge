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
//! - Double tap and hold Select: fast forward (`GameInput.fast`,
//!   docs/FAST_FORWARD.md at the root). A Select press released before
//!   `hold_frames` opens a window of `tuning.ff_tap_window` frames; a second
//!   press inside it starts fast forward at once, which lasts while Select
//!   stays held. That press never runs the menu timer and its release
//!   delivers nothing. A window that runs out does nothing (the tap is
//!   reserved anyway, so there is nothing to hold back). Start during the
//!   window or during fast forward cancels it (the OS chord). Left is
//!   reserved during fast forward; the d-pad's other directions and the
//!   buttons reach the game as usual.
//! - Chorded rewind: Left pressed during fast forward turns the rest of
//!   that hold into rewind (`GameInput.rewind`): the game is not stepped,
//!   Left/Right step time with the menu's auto-repeat (`Repeat`,
//!   `GameInput.scrub`), nothing reaches the game, and Start (the OS
//!   chord) only pauses the stepping. Letting go of Select resumes from the
//!   scrubbed position with every held button suppressed, as the menu's
//!   resume does.
//!
//! Buttons held across a state change are suppressed until released
//! (`suppress_held`); the menu reads `State.live_edge()`, the edge with them
//! masked out, so an A or B pressed with the Select hold that opens the menu
//! does not act on it (review EM-01, the same rule as Snouty Boy's
//! frontend/flow.zig). The joystick click belongs to the OS and is never bound.
const cart = @import("cart-api");
const core = @import("core");
const Pad = core.Pad;
const tuning = @import("tuning.zig");

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

/// Scrub auto-repeat (SPEC.md 5): a Left or Right press steps at once,
/// then every `repeat_frames` while held (4 steps a second). Shared by the
/// menu's scrubber and the chorded rewind.
pub const Repeat = struct {
    pub const repeat_frames = 15;

    /// Direction of the held key, 0 when none.
    dir: i2 = 0,
    left: u8 = 0,

    /// This frame's step: -1 back, 1 forward, 0 none.
    pub fn step(r: *Repeat, e: Edge) i2 {
        const d: i2 = if (e.pressed(.left)) -1 else if (e.pressed(.right)) 1 else 0;
        if (d != 0) {
            r.dir = d;
            r.left = repeat_frames;
            return d;
        }
        if (r.dir == 0) return 0;
        const still = if (r.dir < 0) e.held(.left) else e.held(.right);
        if (!still) {
            r.dir = 0;
            return 0;
        }
        r.left -= 1;
        if (r.left != 0) return 0;
        r.left = repeat_frames;
        return r.dir;
    }

    pub fn stop(r: *Repeat) void {
        r.dir = 0;
    }
};

/// The chorded rewind's phase in a running frame (main.zig).
pub const Rewind = enum {
    /// Play (1x or fast forward).
    off,
    /// Rewind starts this frame: freeze the picture, then as `on`.
    enter,
    /// The game is frozen; step time by `GameInput.scrub`.
    on,
    /// Select was let go: resume from the scrubbed position, stepping this
    /// frame as usual (held buttons are already suppressed).
    exit,
};

/// Result of one running frame's input.
pub const GameInput = struct {
    /// Pad byte for `Gg.step_frame`.
    pad: u8,
    /// Select reached `hold_frames` this frame (the menu opens here).
    open_menu: bool,
    /// Fast forward (Select double tapped and held): main.zig steps
    /// several game frames this update, all with `pad`.
    fast: bool = false,
    /// Chorded rewind (Left during fast forward).
    rewind: Rewind = .off,
    /// While `rewind` is `enter` or `on`: step time back (-1) or forward (1).
    scrub: i2 = 0,
};

/// The Select long-hold state machine plus the suppress mask.
pub const State = struct {
    edge: Edge = .{},
    holding: bool = false,
    held_frames: u16 = 0,
    /// Frames left in which a Select press starts fast forward (counts
    /// down from `tuning.ff_tap_window` after a short press); 0 = closed.
    tap_window: u8 = 0,
    /// Fast forward is on (the second press of a double tap, still held).
    fast: bool = false,
    /// The fast-forward hold turned into rewind (Left), Select still held.
    rewinding: bool = false,
    repeat: Repeat = .{},
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
        s.tap_window = 0;
        s.fast = false;
        s.rewinding = false;
        s.repeat.stop();
    }

    /// Input for a frame in which the game runs.
    pub fn game_frame(s: *State) GameInput {
        const e = s.edge;
        const live: cart.Controls = @bitCast(e.cur & ~s.suppress);
        const fresh_select = live.select and e.pressed(.select);
        var open_menu = false;

        if (s.rewinding) return s.rewind_frame();
        if (s.fast and live.left and e.pressed(.left) and !e.held(.start)) {
            s.fast = false;
            s.rewinding = true;
            s.repeat.stop();
            var g = s.rewind_frame();
            g.rewind = .enter;
            return g;
        }

        if (s.fast) {
            // Start+Select is the OS chord; letting go delivers nothing.
            if (e.held(.start) or !e.held(.select)) s.fast = false;
        } else if (s.tap_window != 0) {
            if (e.held(.start)) {
                s.tap_window = 0; // The OS chord: forget the tap.
            } else if (fresh_select) {
                // The second press: fast forward, no menu timer.
                s.tap_window = 0;
                s.fast = true;
            } else s.tap_window -= 1;
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
                // A tap: reserved, nothing happens, but a second press
                // soon after is the fast-forward double tap.
                s.holding = false;
                s.tap_window = tuning.ff_tap_window;
            }
        }
        var pad = pad_from_controls(live);
        if (s.fast) pad &= ~Pad.left; // Reserved: Left starts rewind.
        return .{ .pad = pad, .open_menu = open_menu, .fast = s.fast };
    }

    /// A frame of the chorded rewind: no game input, a scrub step from
    /// Left/Right with auto-repeat, held still while Start is down (the OS
    /// chord); Select let go ends it.
    fn rewind_frame(s: *State) GameInput {
        const e = s.edge;
        if (!e.held(.select)) {
            // As the menu's resume: everything held waits for a release.
            s.suppress_held();
            return .{ .pad = pad_from_controls(@bitCast(e.cur & ~s.suppress)), .open_menu = false, .rewind = .exit };
        }
        var scrub: i2 = 0;
        if (e.held(.start)) s.repeat.stop() else scrub = s.repeat.step(s.live_edge());
        return .{ .pad = 0, .open_menu = false, .rewind = .on, .scrub = scrub };
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
