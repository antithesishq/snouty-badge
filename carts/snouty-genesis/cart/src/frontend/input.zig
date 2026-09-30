//! Badge controls -> Genesis 3-button pad word (SPEC.md section 5), with
//! Snouty Gear's Select long-hold state machine adapted to 30 updates a
//! second (one update = two Genesis frames, SPEC.md section 8):
//!
//! - D-pad to d-pad, Start to Start; Genesis A, B and C go to badge B,
//!   badge A and the Select tap as `layout` says (the menu's Buttons row,
//!   SPEC.md sections 5 and 18 item 5). Default: badge B = B, badge A = C,
//!   Select tap = A.
//! - Select tap (released before `hold_updates`): the layout's third button
//!   (A by default), sent for `tap_frames` Genesis frames from the release
//!   (late by the tap's length).
//! - Select held for `hold_updates` (500 ms): `GameInput.open_menu` is set
//!   once and main.zig opens the emulator menu (frontend/menu.zig).
//! - Start pressed while Select is held is the OS exit chord: the hold is
//!   cancelled and no A is sent. Start itself still goes to the game.
//!
//! Buttons held across a state change are suppressed until released
//! (`suppress_held`). The joystick click belongs to the OS and is never
//! bound.
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

/// Result of one running update's input.
pub const GameInput = struct {
    /// Pad word for both `Md.step_frame` calls of the update.
    pad: u16,
    /// Select reached `hold_updates` this update (main.zig opens the menu).
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
                s.holding = false; // Released early: a tap (layout's third button).
                s.tap_left = (tap_frames + frames_per_update - 1) / frames_per_update;
            }
        }
        if (s.tap_left > 0) {
            pad |= layout.tap_bit();
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
    if (pad_mapped(c, .b_c_a) != Pad.b | Pad.c | Pad.left) @compileError("pad mapping");
    if (pad_mapped(c, .a_b_c) != Pad.a | Pad.b | Pad.left) @compileError("pad mapping a_b_c");
    if (Layout.b_c_a.tap_bit() != Pad.a or Layout.c_a_b.tap_bit() != Pad.b) @compileError("tap mapping");
}
