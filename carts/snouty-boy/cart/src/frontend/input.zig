//! Badge controls -> Game Boy pad byte, with the Select long-hold state
//! machine from SPEC.md section 5:
//!
//! - Select is never passed straight through. While it is held the game
//!   sees Select up.
//! - Released before `hold_frames` (30 frames, 500 ms): the game gets a
//!   Select press lasting `tap_frames` frames, so it registers even in games
//!   that poll the joypad once per frame.
//! - Held for `hold_frames`: `GameInput.open_menu` is set once; the game is
//!   paused by the caller and no Select is delivered.
//! - Start pressed while Select is held is the OS exit chord (250 ms): the
//!   hold is cancelled, so neither a tap nor the menu follows. Start itself
//!   still goes to the game as usual.
//!
//! Buttons held across a state change (splash skipped, menu closed) are
//! suppressed until released (`suppress_held`), so the B that closed the menu
//! does not also reach the game. The joystick click belongs to the OS and is
//! never bound.
const cart = @import("cart-api");
const core = @import("core");
const Pad = core.Pad;

/// Select held this long (frames at 60 Hz) opens the emulator menu.
pub const hold_frames = 30;
/// Frames a Select tap is delivered to the game for.
pub const tap_frames = 3;

pub fn pad_from_controls(c: cart.Controls) u8 {
    var pad: u8 = 0;
    if (c.right) pad |= Pad.right;
    if (c.left) pad |= Pad.left;
    if (c.up) pad |= Pad.up;
    if (c.down) pad |= Pad.down;
    if (c.a) pad |= Pad.a;
    if (c.b) pad |= Pad.b;
    if (c.select) pad |= Pad.select;
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
const all_buttons: u16 = blk: {
    var m: u16 = 0;
    for (@typeInfo(Button).@"enum".field_values) |v| m |= mask(@fromBackingInt(v));
    break :blk m;
};

/// Edge detection over whole frames: call `update` once per `update()` with
/// that frame's controls, then ask which buttons went down or up.
pub const Edge = struct {
    prev: u16 = 0,
    cur: u16 = 0,

    pub fn update(e: *Edge, c: cart.Controls) void {
        e.prev = e.cur;
        e.cur = @bitCast(c);
    }

    /// Down this frame, up last frame.
    pub fn pressed(e: Edge, comptime b: Button) bool {
        return (e.cur & ~e.prev & mask(b)) != 0;
    }

    /// Up this frame, down last frame.
    pub fn released(e: Edge, comptime b: Button) bool {
        return (~e.cur & e.prev & mask(b)) != 0;
    }

    pub fn held(e: Edge, comptime b: Button) bool {
        return (e.cur & mask(b)) != 0;
    }

    /// Any cart button went down this frame.
    pub fn any_pressed(e: Edge) bool {
        return (e.cur & ~e.prev & all_buttons) != 0;
    }
};

/// Result of one running frame's input.
pub const GameInput = struct {
    /// Pad byte for `Gb.step_frame`.
    pad: u8,
    /// Select reached `hold_frames` this frame: open the menu, do not step.
    open_menu: bool,
};

/// The Select long-hold state machine plus the suppress mask.
pub const State = struct {
    edge: Edge = .{},
    /// Select is being held and counted (pressed while running, not part of
    /// the Start+Select chord, menu not yet opened).
    holding: bool = false,
    /// Frames Select has been held, saturating.
    held_frames: u16 = 0,
    /// Remaining frames of a delivered Select tap.
    tap_left: u8 = 0,
    /// Buttons ignored until released (Controls bits).
    suppress: u16 = 0,

    /// Once per badge frame, in every state, before anything else.
    pub fn poll(s: *State, c: cart.Controls) void {
        s.edge.update(c);
        s.suppress &= s.edge.cur;
    }

    /// Ignore every currently held button until it is released, and forget
    /// any Select hold or pending tap. Call on every state change.
    pub fn suppress_held(s: *State) void {
        s.suppress = s.edge.cur;
        s.holding = false;
        s.held_frames = 0;
        s.tap_left = 0;
    }

    /// Input for a frame in which the game runs.
    pub fn game_frame(s: *State) GameInput {
        const e = s.edge;
        const live: cart.Controls = @bitCast(e.cur & ~s.suppress);
        var pad = pad_from_controls(live) & ~Pad.select;
        var open_menu = false;

        if (live.select and e.pressed(.select)) {
            s.holding = true;
            s.held_frames = 0;
        }
        if (s.holding) {
            if (e.held(.start)) {
                // Start+Select: the OS exit chord. Cancel the hold.
                s.holding = false;
            } else if (e.held(.select)) {
                s.held_frames +|= 1;
                if (s.held_frames >= hold_frames) {
                    s.holding = false;
                    open_menu = true;
                }
            } else {
                // Released before the menu threshold: a tap.
                s.holding = false;
                s.tap_left = tap_frames;
            }
        }
        if (s.tap_left > 0) {
            pad |= Pad.select;
            s.tap_left -= 1;
        }
        return .{ .pad = pad, .open_menu = open_menu };
    }
};

fn ctl(comptime names: []const Button) cart.Controls {
    var c: cart.Controls = @bitCast(@as(u16, 0));
    inline for (names) |n| @field(c, @tagName(n)) = true;
    return c;
}

comptime {
    // Pad bits and the Edge masks agree with cart.Controls' layout.
    var c: cart.Controls = @bitCast(@as(u16, 0));
    c.a = true;
    c.left = true;
    if (pad_from_controls(c) != Pad.a | Pad.left) @compileError("pad mapping");
    var e: Edge = .{};
    e.update(c);
    if (!e.pressed(.a) or e.released(.a) or e.pressed(.b)) @compileError("edge press");
    e.update(@bitCast(@as(u16, 0)));
    if (e.pressed(.a) or !e.released(.a) or e.held(.left)) @compileError("edge release");
    if ((all_buttons & (1 << 4)) != 0) @compileError("click must not be a cart button");
}

comptime {
    @setEvalBranchQuota(20_000);
    const none = ctl(&.{});
    const sel = ctl(&.{.select});

    // Tap: 5 frames held, then release -> no Select while held, then
    // exactly `tap_frames` frames of Select.
    var s: State = .{};
    for (0..5) |_| {
        s.poll(sel);
        const g = s.game_frame();
        if (g.pad & Pad.select != 0 or g.open_menu) @compileError("select leaked while held");
    }
    for (0..tap_frames) |_| {
        s.poll(none);
        if (s.game_frame().pad & Pad.select == 0) @compileError("tap not delivered");
    }
    s.poll(none);
    if (s.game_frame().pad & Pad.select != 0) @compileError("tap too long");

    // Hold: menu opens on frame `hold_frames`, exactly once, no Select.
    s = .{};
    var opened: u32 = 0;
    for (0..hold_frames + 10) |i| {
        s.poll(sel);
        const g = s.game_frame();
        if (g.pad & Pad.select != 0) @compileError("select leaked during hold");
        if (g.open_menu) {
            if (i + 1 != hold_frames) @compileError("menu opened on the wrong frame");
            opened += 1;
        }
    }
    if (opened != 1) @compileError("menu must open exactly once");

    // Start+Select chord: neither tap nor menu.
    s = .{};
    s.poll(sel);
    _ = s.game_frame();
    s.poll(ctl(&.{ .select, .start }));
    if (s.game_frame().pad != Pad.start) @compileError("chord: start only");
    s.poll(none);
    if (s.game_frame().pad != 0) @compileError("chord must not tap");

    // Suppress: a held B stays hidden until released and pressed again.
    s = .{};
    s.poll(ctl(&.{.b}));
    s.suppress_held();
    s.poll(ctl(&.{.b}));
    if (s.game_frame().pad != 0) @compileError("suppressed B leaked");
    s.poll(none);
    _ = s.game_frame();
    s.poll(ctl(&.{.b}));
    if (s.game_frame().pad != Pad.b) @compileError("B after release");
}
