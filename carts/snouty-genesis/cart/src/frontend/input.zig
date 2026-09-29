//! Badge controls -> Genesis 3-button pad word (SPEC.md section 5), with
//! Snouty Gear's Select long-hold state machine adapted to 30 updates a
//! second (one update = two Genesis frames, SPEC.md section 8):
//!
//! - D-pad to d-pad, badge B to B, badge A to C, Start to Start.
//! - Select tap (released before `hold_updates`): Genesis A, sent for
//!   `tap_frames` Genesis frames from the release (late by the tap's length;
//!   a menu remap is M2, SPEC.md section 18 item 5).
//! - Select held for `hold_updates` (500 ms): `GameInput.open_menu` is set
//!   once. The menu is M2; until then main.zig only counts it.
//! - Start pressed while Select is held is the OS exit chord: the hold is
//!   cancelled and no A is sent. Start itself still goes to the game.
//!
//! Buttons held across a state change are suppressed until released
//! (`suppress_held`). The joystick click belongs to the OS and is never
//! bound. M1 Track C owns this file.
const cart = @import("cart-api");
const core = @import("core");
const Pad = core.Pad;

/// Select held this many updates (at 30 Hz, 500 ms) opens the menu.
pub const hold_updates = 15;
/// Genesis frames a Select tap holds A for.
pub const tap_frames = 4;
/// Genesis frames per update: A lasts `tap_frames / frames_per_update`
/// updates.
const frames_per_update = core.tunables.render_every;

pub fn pad_from_controls(c: cart.Controls) u16 {
    var pad: u16 = 0;
    if (c.up) pad |= Pad.up;
    if (c.down) pad |= Pad.down;
    if (c.left) pad |= Pad.left;
    if (c.right) pad |= Pad.right;
    if (c.b) pad |= Pad.b;
    if (c.a) pad |= Pad.c;
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

    pub fn held(e: Edge, comptime b: Button) bool {
        return (e.cur & mask(b)) != 0;
    }
};

/// Result of one running update's input.
pub const GameInput = struct {
    /// Pad word for both `Md.step_frame` calls of the update.
    pad: u16,
    /// Select reached `hold_updates` this update (the M2 menu opens here).
    open_menu: bool,
};

/// The Select tap/hold state machine plus the suppress mask.
pub const State = struct {
    edge: Edge = .{},
    holding: bool = false,
    held_updates: u16 = 0,
    /// Updates A is still held for after a tap.
    tap_left: u8 = 0,
    /// Buttons ignored until released (Controls bits).
    suppress: u16 = 0,

    /// Once per update, in every state, before anything else.
    pub fn poll(s: *State, c: cart.Controls) void {
        s.edge.update(c);
        s.suppress &= s.edge.cur;
    }

    /// Ignore every held button until released and forget a Select hold.
    pub fn suppress_held(s: *State) void {
        s.suppress = s.edge.cur;
        s.holding = false;
        s.held_updates = 0;
        s.tap_left = 0;
    }

    /// Input for an update in which the game runs.
    pub fn game_frame(s: *State) GameInput {
        const e = s.edge;
        const live: cart.Controls = @bitCast(e.cur & ~s.suppress);
        var pad = pad_from_controls(live);
        var open_menu = false;

        if (live.select and e.pressed(.select)) {
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
                s.holding = false; // Released early: a tap, Genesis A.
                s.tap_left = (tap_frames + frames_per_update - 1) / frames_per_update;
            }
        }
        if (s.tap_left > 0) {
            pad |= Pad.a;
            s.tap_left -= 1;
        }
        return .{ .pad = pad, .open_menu = open_menu };
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
    if (pad_from_controls(c) != Pad.b | Pad.c | Pad.left) @compileError("pad mapping");
}
