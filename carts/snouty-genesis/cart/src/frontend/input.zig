//! Badge controls -> Genesis 3-button pad word (SPEC.md section 5), with
//! Snouty Gear's Select long-hold state machine adapted to 30 updates a
//! second (one update = two Genesis frames, SPEC.md section 8):
//!
//! - D-pad to d-pad, Start to Start; Genesis A, B and C go to badge B,
//!   badge A and the Select tap as `layout` says (the menu's Buttons row,
//!   SPEC.md sections 5 and 18 item 5). Default: badge B = B, badge A = C,
//!   Select tap = A.
//! - Select tap (released before `hold_updates`): the layout's third button
//!   (A by default), sent for `tap_frames` Genesis frames once the
//!   fast-forward window after it (`tuning.ff_tap_window_updates`, 200 ms)
//!   has run out with no second press: late by the tap's length plus
//!   200 ms.
//! - Select held for `hold_updates` (500 ms): `GameInput.open_menu` is set
//!   once and app.zig opens the emulator menu (frontend/menu.zig).
//! - Start pressed while Select is held is the OS exit chord: the hold is
//!   cancelled and no A is sent. Start itself still goes to the game.
//! - Double tap and hold Select: fast forward (`GameInput.fast`,
//!   docs/FAST_FORWARD.md at the root). A second Select press inside the
//!   tap's window drops the held-back tap and starts fast forward at
//!   once; it lasts while Select stays held, never runs the menu timer,
//!   and its release delivers nothing. Start during the window or during
//!   fast forward cancels everything (the OS chord). Where the scrubber
//!   exists (`chord_rewind`: the XIP cart and the simulator) Left is
//!   reserved during fast forward; the d-pad's other directions and the
//!   buttons reach the game as usual.
//! - Chorded rewind (`chord_rewind` builds): a fresh Left press during fast
//!   forward turns the rest of that Select hold into rewind
//!   (`GameInput.rewind`): the game is not stepped, Left/Right step time
//!   with the menu's auto-repeat (`Repeat`, `GameInput.scrub`, the first
//!   step back at once), nothing reaches the game, and Start (the OS
//!   chord) only pauses the stepping. Letting go of Select resumes from the
//!   scrubbed position with every held button suppressed, as the menu's
//!   resume does.
//!
//! Buttons held across a state change are suppressed until released
//! (`suppress_held`). The joystick click belongs to the OS and is never
//! bound.
const cart = @import("cart-api");
const core = @import("core");
const Pad = core.Pad;
const tuning = @import("tuning.zig");

/// The badge's buttons (`cart.Controls`), for host tests.
pub const Controls = cart.Controls;

/// Select held this many updates (at 30 Hz, 500 ms) opens the menu.
pub const hold_updates = 15;
/// Genesis frames a Select tap holds A for.
pub const tap_frames = 4;
/// Genesis frames per update: A lasts `tap_frames / frames_per_update`
/// updates.
const frames_per_update = core.tunables.render_every;
/// Updates a tap's button is sent for (`tap_frames`, rounded up).
pub const tap_updates = (tap_frames + frames_per_update - 1) / frames_per_update;
/// The chorded rewind exists where the scrubber does (`core.undo.enabled`:
/// not in the RAM cart, PLAN.md M5); without it Left is not reserved.
pub const chord_rewind = core.undo.enabled;

/// The six assignments of Genesis A, B and C to badge B, badge A and the
/// Select tap, in the menu's cycling order. The names read as the menu
/// label: `b_c_a` is "B=B A=C S=A" (badge B sends Genesis B, badge A sends
/// C, the tap sends A).
pub const Layout = enum(u8) {
    b_c_a = 0,
    c_b_a = 1,
    b_a_c = 2,
    a_b_c = 3,
    a_c_b = 4,
    c_a_b = 5,

    pub const count = 6;

    /// Pad bits for badge B, badge A and the Select tap.
    const bits = [count][3]u16{
        .{ Pad.b, Pad.c, Pad.a },
        .{ Pad.c, Pad.b, Pad.a },
        .{ Pad.b, Pad.a, Pad.c },
        .{ Pad.a, Pad.b, Pad.c },
        .{ Pad.a, Pad.c, Pad.b },
        .{ Pad.c, Pad.a, Pad.b },
    };
    const labels = [count][]const u8{
        "Btns B=B A=C S=A",
        "Btns B=C A=B S=A",
        "Btns B=B A=A S=C",
        "Btns B=A A=B S=C",
        "Btns B=A A=C S=B",
        "Btns B=C A=A S=B",
    };

    pub fn index(l: Layout) usize {
        return @backingInt(l);
    }

    /// The menu row's label (16 columns).
    pub fn label(l: Layout) []const u8 {
        return labels[l.index()];
    }

    /// The Genesis button (pad bit) the Select tap sends.
    pub fn tap_bit(l: Layout) u16 {
        return bits[l.index()][2];
    }

    /// The next (d > 0) or previous layout, wrapping.
    pub fn step(l: Layout, d: i2) Layout {
        const i = l.index();
        const n = if (d < 0) (i + count - 1) % count else (i + 1) % count;
        return @fromBackingInt(@intCast(n));
    }
};

/// The Buttons row's setting (not saved; resets to the M1 mapping at boot).
pub var layout: Layout = .b_c_a;

pub fn pad_from_controls(c: cart.Controls) u16 {
    return pad_mapped(c, layout);
}

/// The mapping with the layout given explicitly (the comptime check below).
fn pad_mapped(c: cart.Controls, l: Layout) u16 {
    var pad: u16 = 0;
    if (c.up) pad |= Pad.up;
    if (c.down) pad |= Pad.down;
    if (c.left) pad |= Pad.left;
    if (c.right) pad |= Pad.right;
    if (c.b) pad |= Layout.bits[l.index()][0];
    if (c.a) pad |= Layout.bits[l.index()][1];
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

/// Edge detection over whole updates.
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

    /// Any cart button (not the OS's click) went down this update.
    pub fn any_pressed(e: Edge) bool {
        return (e.cur & ~e.prev & all_buttons) != 0;
    }
};

/// Every `Button` bit (straight-line, no comptime loop: CLAUDE.md).
const all_buttons: u16 = mask(.start) | mask(.select) | mask(.a) | mask(.b) |
    mask(.up) | mask(.down) | mask(.left) | mask(.right);

/// Scrub auto-repeat (SPEC.md 5): a Left or Right press steps at once,
/// then every `repeat_updates` while held (4 steps a second at 30 Hz).
/// Shared by the menu's scrubber and the chorded rewind.
pub const Repeat = struct {
    pub const repeat_updates = 8;

    /// Direction of the held key, 0 when none.
    dir: i2 = 0,
    left: u8 = 0,

    /// This update's step: -1 back, 1 forward, 0 none.
    pub fn step(r: *Repeat, e: Edge) i2 {
        const d: i2 = if (e.pressed(.left)) -1 else if (e.pressed(.right)) 1 else 0;
        if (d != 0) {
            r.dir = d;
            r.left = repeat_updates;
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
        r.left = repeat_updates;
        return r.dir;
    }

    pub fn stop(r: *Repeat) void {
        r.dir = 0;
    }
};

/// The chorded rewind's phase in a running update (app.zig).
pub const Rewind = enum {
    /// Play (1x or fast forward).
    off,
    /// Rewind starts this update: freeze the picture, then as `on`.
    enter,
    /// The game is frozen; step time by `GameInput.scrub`.
    on,
    /// Select was let go: resume from the scrubbed position, stepping this
    /// update as usual (held buttons are already suppressed).
    exit,
};

/// Result of one running update's input.
pub const GameInput = struct {
    /// Pad word for both `Md.step_frame` calls of the update.
    pad: u16,
    /// Select reached `hold_updates` this update (app.zig opens the menu).
    open_menu: bool,
    /// Fast forward (Select double tapped and held): app.zig steps up to
    /// `tuning.ff_max_frames` Genesis frames this update, all with `pad`.
    fast: bool = false,
    /// Chorded rewind (Left during fast forward).
    rewind: Rewind = .off,
    /// While `rewind` is `enter` or `on`: step time back (-1) or forward (1).
    scrub: i2 = 0,
};

/// The Select tap/hold/double-tap state machine plus the suppress mask.
pub const State = struct {
    edge: Edge = .{},
    holding: bool = false,
    held_updates: u16 = 0,
    /// Updates left in which a Select press starts fast forward (counts
    /// down from `tuning.ff_tap_window_updates` after a tap, whose button
    /// waits for it to run out); 0 = closed.
    tap_window: u8 = 0,
    /// Fast forward is on (the second press of a double tap, still held).
    fast: bool = false,
    /// The fast-forward hold turned into rewind (Left), Select still held.
    rewinding: bool = false,
    repeat: Repeat = .{},
    /// Updates A is still held for after a tap.
    tap_left: u8 = 0,
    /// Buttons ignored until released (Controls bits).
    suppress: u16 = 0,

    /// Once per update, in every state, before anything else.
    pub fn poll(s: *State, c: cart.Controls) void {
        s.edge.update(c);
        s.suppress &= s.edge.cur;
    }

    /// Ignore every held button until released and forget a Select hold,
    /// a held-back tap, fast forward and the chorded rewind.
    pub fn suppress_held(s: *State) void {
        s.suppress = s.edge.cur;
        s.holding = false;
        s.held_updates = 0;
        s.tap_window = 0;
        s.fast = false;
        s.tap_left = 0;
        s.rewinding = false;
        s.repeat.stop();
    }

    /// This update's edge with the suppressed (held-over) buttons masked
    /// out, so they never read as pressed.
    pub fn live_edge(s: *const State) Edge {
        return .{ .prev = s.edge.prev, .cur = s.edge.cur & ~s.suppress };
    }

    /// Input for an update in which the game runs.
    pub fn game_frame(s: *State) GameInput {
        const e = s.edge;
        const live: cart.Controls = @bitCast(e.cur & ~s.suppress);
        const fresh_select = live.select and e.pressed(.select);
        var pad = pad_from_controls(live);
        var open_menu = false;

        if (chord_rewind) {
            if (s.rewinding) return s.rewind_update();
            if (s.fast and live.left and e.pressed(.left) and e.held(.select) and !e.held(.start)) {
                s.fast = false;
                s.rewinding = true;
                s.repeat.stop();
                var g = s.rewind_update();
                g.rewind = .enter;
                return g;
            }
        }

        if (s.fast) {
            // Start+Select is the OS chord; letting go delivers nothing.
            if (e.held(.start) or !e.held(.select)) s.fast = false;
        } else if (s.tap_window != 0) {
            if (e.held(.start)) {
                s.tap_window = 0; // The OS chord: drop the tap.
            } else if (fresh_select) {
                // The second press: fast forward, no tap, no menu timer.
                s.tap_window = 0;
                s.fast = true;
            } else {
                s.tap_window -= 1;
                // No second press: the held-back tap goes to the game now.
                if (s.tap_window == 0) s.tap_left = tap_updates;
            }
        }

        if (!s.fast and fresh_select) {
            s.holding = true;
            s.held_updates = 0;
        }
        if (s.holding) {
            if (e.held(.start)) {
                s.holding = false; // Start+Select: the OS exit chord.
            } else if (e.held(.select)) {
                s.held_updates +|= 1;
                if (s.held_updates >= hold_updates) {
                    s.holding = false;
                    open_menu = true;
                }
            } else {
                // Released early: a tap, held back while a second press
                // could still make it the fast-forward double tap.
                s.holding = false;
                s.tap_window = tuning.ff_tap_window_updates;
            }
        }
        if (s.tap_left > 0) {
            pad |= layout.tap_bit();
            s.tap_left -= 1;
        }
        if (chord_rewind and s.fast) pad &= ~Pad.left; // Reserved: Left starts rewind.
        return .{ .pad = pad, .open_menu = open_menu, .fast = s.fast };
    }

    /// An update of the chorded rewind: no game input, a scrub step from
    /// Left/Right with auto-repeat, held still while Start is down (the OS
    /// chord); Select let go ends it.
    fn rewind_update(s: *State) GameInput {
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
    // Pad bits agree with SPEC.md section 5 (a few straight-line checks,
    // no comptime loops, see CLAUDE.md).
    var c: cart.Controls = @bitCast(@as(u16, 0));
    c.a = true;
    c.b = true;
    c.left = true;
    c.select = true;
    if (pad_mapped(c, .b_c_a) != Pad.b | Pad.c | Pad.left) @compileError("pad mapping");
    if (pad_mapped(c, .a_b_c) != Pad.a | Pad.b | Pad.left) @compileError("pad mapping a_b_c");
    if (Layout.b_c_a.tap_bit() != Pad.a or Layout.c_a_b.tap_bit() != Pad.b) @compileError("tap mapping");
}
