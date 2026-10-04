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
//!   (the OS chord). Left is reserved during fast forward; the d-pad's
//!   other directions and the buttons reach the game as usual.
//! - Chorded rewind (Snouty Gear's): a fresh Left press during fast
//!   forward (Select held, Start not) turns the rest of that hold into
//!   rewind (`GameInput.rewind`): the game is not stepped, Left/Right step
//!   time with the menu's auto-repeat (`Repeat`, `GameInput.scrub`; Left
//!   steps back at once on entry), nothing reaches the game, and Start
//!   (the OS chord) only holds the position. A Left already held when fast
//!   forward starts does not count. Letting go of Select resumes from the
//!   scrubbed position with every held button suppressed, as the menu's
//!   resume does.
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

pub const GameInput = struct {
    /// Pad word for `Lynx.step_frame`.
    pad: u16,
    /// Select reached `hold_frames` this frame.
    open_menu: bool,
    /// Fast forward (Select double tapped and held): main.zig steps
    /// several game frames this update, all with `pad`.
    fast: bool = false,
    /// Chorded rewind (Left during fast forward).
    rewind: Rewind = .off,
    /// While `rewind` is `enter` or `on`: step time back (-1) or forward (1).
    scrub: i2 = 0,
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
    /// The fast-forward hold turned into rewind (Left), Select still held.
    rewinding: bool = false,
    repeat: Repeat = .{},
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
        s.rewinding = false;
        s.repeat.stop();
    }

    /// This frame's edge with the suppressed (held-over) buttons masked
    /// out: what the menu, the picker and the chorded rewind read.
    pub fn live_edge(s: *const State) Edge {
        return .{ .prev = s.edge.prev, .cur = s.edge.cur & ~s.suppress };
    }

    /// Input for a frame in which the game runs.
    pub fn game_frame(s: *State) GameInput {
        const e = s.edge;
        const live: cart.Controls = @bitCast(e.cur & ~s.suppress);
        const fresh_select = live.select and e.pressed(.select);
        var pad = pad_from_controls(live);
        var open_menu = false;

        if (s.rewinding) return s.rewind_frame();
        if (s.fast and live.left and e.pressed(.left) and e.held(.select) and !e.held(.start)) {
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
            return .{ .pad = 0, .open_menu = false, .rewind = .exit };
        }
        var scrub: i2 = 0;
        if (e.held(.start)) s.repeat.stop() else scrub = s.repeat.step(s.live_edge());
        return .{ .pad = 0, .open_menu = false, .rewind = .on, .scrub = scrub };
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
