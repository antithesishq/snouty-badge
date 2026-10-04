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
//! - Right pressed while that Select hold counts is the fast-forward chord
//!   (docs/FAST_FORWARD.md at the root): `GameInput.fast` is set while both
//!   stay held, the game sees neither Select nor Right, and the hold neither
//!   taps nor opens the menu. Right let go first: back to 1x and the Select
//!   hold counts again from zero (the menu can still open; its release still
//!   taps nothing). Select let go first: back to 1x, no tap, and the held
//!   Right waits for a release before it reaches the game. Start during fast
//!   forward ends it like any Start+Select chord.
//!
//! Buttons held across a state change (splash skipped, picker left, menu
//! opened or closed) are suppressed until released (`suppress_held`), so the
//! B that closed the menu does not also reach the game. Every screen other
//! than the game reads `State.live_edge()`, the edge with those buttons
//! masked out (frontend/flow.zig). The joystick click belongs to the OS and
//! is never bound.
//!
//! No cart-api import: `Controls` mirrors `Controls` bit for bit
//! (main.zig checks the layout at compile time), so frontend/flow.zig and
//! this file run in the host tests (tests/flow_unit.zig).
const core = @import("core");
const Pad = core.Pad;

/// `cart.Controls` (sycl-badge/src/os/cart/api.zig), same bit layout; main.zig
/// bit-casts the badge's controls into it.
pub const Controls = packed struct(u16) {
    start: bool = false,
    select: bool = false,
    a: bool = false,
    b: bool = false,
    click: bool = false,
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    _pad: u7 = 0,
};

/// Select held this long (frames at 60 Hz) opens the emulator menu.
pub const hold_frames = 30;
/// Frames a Select tap is delivered to the game for.
pub const tap_frames = 3;

/// The fast-forward chord, for the play hint strip and the About screen
/// (15 glyphs: fits the 160 px screen and the 18-glyph menu panel).
pub const fast_hint = "Sel+Right: fast";

pub fn pad_from_controls(c: Controls) u8 {
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
    var c: Controls = @bitCast(@as(u16, 0));
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

    pub fn update(e: *Edge, c: Controls) void {
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
    /// Select+Right is held: step several frames with this pad, drawing only
    /// the last (main.zig `Ctx.step`).
    fast: bool = false,
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
    /// Fast forward is on: Right went down during the counted Select hold
    /// and both are still held.
    fast: bool = false,
    /// The current Select hold was used for fast forward, so its release
    /// taps nothing.
    chorded: bool = false,
    /// Buttons ignored until released (Controls bits).
    suppress: u16 = 0,
    /// Last frame's `live_edge().cur`, so a suppressed button reads neither
    /// pressed nor released on the live edge until it is pressed afresh.
    live_prev: u16 = 0,

    /// Once per badge frame, in every state, before anything else.
    pub fn poll(s: *State, c: Controls) void {
        s.live_prev = s.edge.cur & ~s.suppress;
        s.edge.update(c);
        s.suppress &= s.edge.cur;
    }

    /// This frame's edge with the suppressed (held-over) buttons masked out
    /// of both frames: what the splash, picker and menu read, so the button
    /// that left one screen does not act on the next.
    pub fn live_edge(s: *const State) Edge {
        return .{ .prev = s.live_prev, .cur = s.edge.cur & ~s.suppress };
    }

    /// Ignore every currently held button until it is released, and forget
    /// any Select hold or pending tap. Call on every state change.
    pub fn suppress_held(s: *State) void {
        s.suppress = s.edge.cur;
        s.holding = false;
        s.held_frames = 0;
        s.tap_left = 0;
        s.fast = false;
        s.chorded = false;
    }

    /// Input for a frame in which the game runs.
    pub fn game_frame(s: *State) GameInput {
        const e = s.edge;
        var live: Controls = @bitCast(e.cur & ~s.suppress);
        var open_menu = false;

        if (live.select and e.pressed(.select)) {
            s.holding = true;
            s.held_frames = 0;
            s.chorded = false;
        }
        if (s.fast and (e.held(.start) or !live.select or !live.right)) {
            s.fast = false;
            if (live.select and !e.held(.start)) {
                // Right let go, Select still held: count the hold afresh.
                s.holding = true;
                s.held_frames = 0;
            } else if (live.right) {
                // Select let go (or Start+Select): the Right of the chord
                // reaches the game only once pressed again.
                s.suppress |= mask(.right);
                live.right = false;
            }
        }
        if (s.holding) {
            if (e.held(.start)) {
                // Start+Select: the OS exit chord. Cancel the hold.
                s.holding = false;
            } else if (e.held(.select)) {
                if (live.right and e.pressed(.right)) {
                    // Select+Right: fast forward, no tap, no menu.
                    s.holding = false;
                    s.fast = true;
                    s.chorded = true;
                } else {
                    s.held_frames +|= 1;
                    if (s.held_frames >= hold_frames) {
                        s.holding = false;
                        open_menu = true;
                    }
                }
            } else {
                // Released before the menu threshold: a tap, unless this
                // hold fast-forwarded.
                s.holding = false;
                if (!s.chorded) s.tap_left = tap_frames;
            }
        }
        var pad = pad_from_controls(live) & ~Pad.select;
        if (s.fast) pad &= ~Pad.right;
        if (s.tap_left > 0) {
            pad |= Pad.select;
            s.tap_left -= 1;
        }
        return .{ .pad = pad, .open_menu = open_menu, .fast = s.fast };
    }
};

fn ctl(comptime names: []const Button) Controls {
    var c: Controls = @bitCast(@as(u16, 0));
    inline for (names) |n| @field(c, @tagName(n)) = true;
    return c;
}

comptime {
    // Pad bits and the Edge masks agree with Controls' layout.
    var c: Controls = @bitCast(@as(u16, 0));
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

comptime {
    @setEvalBranchQuota(40_000);
    const none = ctl(&.{});
    const sel = ctl(&.{.select});
    const sel_right = ctl(&.{ .select, .right });
    const right = ctl(&.{.right});

    // Select, then Right: fast forward from the Right press for as long as
    // both are held, well past the menu threshold; the game sees neither.
    var s: State = .{};
    for (0..5) |_| {
        s.poll(sel);
        if (s.game_frame().fast) @compileError("fast before Right");
    }
    for (0..hold_frames * 2) |_| {
        s.poll(sel_right);
        const g = s.game_frame();
        if (!g.fast or g.open_menu or g.pad != 0) @compileError("fast: no menu, no Select, no Right");
    }
    // Right let go: 1x, and the hold counts from zero, so the menu opens
    // `hold_frames` frames later, not at once.
    var opened: u32 = 0;
    for (0..hold_frames + 5) |i| {
        s.poll(sel);
        const g = s.game_frame();
        if (g.fast or g.pad != 0) @compileError("fast after Right let go");
        if (g.open_menu) {
            if (i + 1 != hold_frames) @compileError("menu: the hold must count again from zero");
            opened += 1;
        }
    }
    if (opened != 1) @compileError("menu after fast forward must open once");

    // Select+Right pressed together count as the chord too; Select let go
    // first: 1x, no tap, and the held Right stays from the game until it is
    // pressed again.
    s = .{};
    s.poll(sel_right);
    if (!s.game_frame().fast) @compileError("Select and Right together");
    s.poll(right);
    if (s.game_frame().fast) @compileError("fast after Select let go");
    for (0..tap_frames + 2) |_| {
        s.poll(right);
        if (s.game_frame().pad != 0) @compileError("no tap, no Right after the chord");
    }
    s.poll(none);
    if (s.game_frame().pad != 0) @compileError("no tap at all after the chord");
    s.poll(right);
    if (s.game_frame().pad != Pad.right) @compileError("Right pressed again");

    // Right let go first, then a quick Select release: still no tap.
    s = .{};
    s.poll(sel);
    _ = s.game_frame();
    s.poll(sel_right);
    _ = s.game_frame();
    s.poll(sel);
    _ = s.game_frame();
    for (0..tap_frames + 1) |_| {
        s.poll(none);
        const g = s.game_frame();
        if (g.pad != 0 or g.fast or g.open_menu) @compileError("a fast-forward hold must not tap");
    }

    // Start during fast forward is the Start+Select chord: 1x, Start goes
    // to the game, Right does not, and neither tap nor menu follows.
    s = .{};
    s.poll(sel);
    _ = s.game_frame();
    s.poll(sel_right);
    _ = s.game_frame();
    for (0..hold_frames + 5) |_| {
        s.poll(ctl(&.{ .select, .right, .start }));
        const g = s.game_frame();
        if (g.fast or g.open_menu or g.pad != Pad.start) @compileError("Start+Select ends fast forward");
    }
    s.poll(none);
    if (s.game_frame().pad != 0) @compileError("chord after fast forward must not tap");

    // Right held before Select is pressed: no chord (Right is game input),
    // and the Select tap works as always.
    s = .{};
    s.poll(right);
    _ = s.game_frame();
    s.poll(sel_right);
    const g0 = s.game_frame();
    if (g0.fast or g0.pad != Pad.right) @compileError("Right first is not the chord");
    s.poll(right);
    if (s.game_frame().pad != Pad.right | Pad.select) @compileError("tap with Right held");
}
