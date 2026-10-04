//! frontend/input.zig's game-frame state machine (Snouty Gear's
//! tests/input_unit.zig with the Lynx's Option 1): the Select long hold
//! that opens the menu, the Select tap that becomes Option 1 once the
//! fast-forward window runs out, and the double tap and hold that fast
//! forwards (docs/FAST_FORWARD.md at the root), driven frame by frame as
//! main.zig drives it (`poll`, then `game_frame`).
const std = @import("std");
const input = @import("input");
const core = @import("core");
const Pad = core.Pad;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// `tuning.ff_tap_window` (frontend/tuning.zig).
const window = 12;

const Btn = enum { start, select, a, b, up, down, left, right };

/// Controls with exactly `held` down.
fn controls(held: []const Btn) input.Controls {
    var c: input.Controls = @bitCast(@as(u16, 0));
    for (held) |b| switch (b) {
        inline else => |t| @field(c, @tagName(t)) = true,
    };
    return c;
}

/// One running frame with `held` down.
fn frame(s: *input.State, held: []const Btn) input.GameInput {
    s.poll(controls(held));
    return s.game_frame();
}

fn opt1(g: input.GameInput) bool {
    return g.pad & Pad.opt1 != 0;
}

/// A Select tap of `n` frames, then the release frame: nothing reaches the
/// game yet (the tap waits for the window).
fn tap(s: *input.State, n: usize) !void {
    for (0..n) |_| {
        const g = frame(s, &.{.select});
        try expect(!g.fast and !g.open_menu and !opt1(g));
    }
    const g = frame(s, &.{});
    try expect(!g.fast and !g.open_menu and !opt1(g));
}

test "input: Select held 30 frames opens the menu once, no Option 1" {
    var s: input.State = .{};
    var opened: u32 = 0;
    for (0..input.hold_frames) |i| {
        const g = frame(&s, &.{.select});
        try expect(!g.fast and !opt1(g));
        if (g.open_menu) {
            opened += 1;
            try expectEqual(input.hold_frames - 1, i);
        }
    }
    try expectEqual(@as(u32, 1), opened);
}

test "input: a tap is Option 1 for 3 frames once the window runs out" {
    var s: input.State = .{};
    try tap(&s, 3);
    // The window: 11 more frames with nothing, then Option 1 on the 12th
    // frame after the release (200 ms later than before the double tap).
    for (0..window - 1) |_| try expect(!opt1(frame(&s, &.{})));
    for (0..input.tap_frames) |_| {
        const g = frame(&s, &.{.up});
        try expect(!g.fast and !g.open_menu);
        try expectEqual(Pad.opt1 | Pad.up, g.pad);
    }
    for (0..2 * window) |_| try expect(!opt1(frame(&s, &.{})));
}

test "input: double tap and hold fast forwards while held: no tap, no menu" {
    var s: input.State = .{};
    try tap(&s, 3);
    try expect(!frame(&s, &.{}).fast);
    // The second press: fast at once, for as long as it is held, far past
    // the menu threshold; the d-pad and buttons still reach the game, and
    // the first tap's Option 1 never does.
    for (0..3 * input.hold_frames) |_| {
        const g = frame(&s, &.{ .select, .right, .a });
        try expect(g.fast);
        try expect(!g.open_menu);
        try expectEqual(Pad.right | Pad.a, g.pad);
    }
    // Release: 1x, nothing delivered, and no window opens from it.
    for (0..2 * window) |_| {
        const g = frame(&s, &.{});
        try expect(!g.fast and !g.open_menu);
        try expectEqual(@as(u16, 0), g.pad);
    }
    for (0..input.hold_frames) |_| try expect(!frame(&s, &.{.select}).fast);
}

test "input: the second press counts on the window's last frame, not after" {
    var s: input.State = .{};
    try tap(&s, 2);
    for (0..window - 1) |_| _ = frame(&s, &.{});
    const g = frame(&s, &.{.select});
    try expect(g.fast and !opt1(g));

    s = .{};
    try tap(&s, 2);
    for (0..window - 1) |_| _ = frame(&s, &.{});
    // The window runs out: the tap goes to the game.
    try expect(opt1(frame(&s, &.{})));
    // An ordinary press now: the tap's frames finish, the menu hold runs.
    var opened = false;
    for (0..input.hold_frames) |_| {
        const h = frame(&s, &.{.select});
        try expect(!h.fast);
        opened = opened or h.open_menu;
    }
    try expect(opened);
}

test "input: a single long hold still opens the menu, no window after it" {
    var s: input.State = .{};
    var opened = false;
    for (0..input.hold_frames) |_| opened = opened or frame(&s, &.{.select}).open_menu;
    try expect(opened);
    // main.zig suppresses held buttons when the menu opens; without that a
    // long press past the threshold still opens no tap window.
    for (0..2 * window) |_| try expect(!opt1(frame(&s, &.{})));
    try expect(!frame(&s, &.{.select}).fast);
}

test "input: Start during the window or during fast forward cancels" {
    var s: input.State = .{};
    try tap(&s, 2);
    _ = frame(&s, &.{.start});
    // The tap is dropped, and the window is gone: this press is the menu
    // hold, not fast forward.
    for (0..2 * window) |_| try expect(!opt1(frame(&s, &.{})));
    try expect(!frame(&s, &.{.select}).fast);

    s = .{};
    try tap(&s, 2);
    try expect(frame(&s, &.{.select}).fast);
    for (0..2 * input.hold_frames) |_| {
        const g = frame(&s, &.{ .select, .start });
        try expect(!g.fast and !g.open_menu and !opt1(g));
    }
    // Start up, Select still held: it does not come back, no menu either.
    for (0..2 * input.hold_frames) |_| {
        const g = frame(&s, &.{.select});
        try expect(!g.fast and !g.open_menu and !opt1(g));
    }
    for (0..2 * window) |_| try expect(!opt1(frame(&s, &.{})));
}

test "input: Start+Select still cancels the menu hold" {
    var s: input.State = .{};
    _ = frame(&s, &.{.select});
    for (0..2 * input.hold_frames) |_| {
        const g = frame(&s, &.{ .select, .start });
        try expect(!g.open_menu and !g.fast and !opt1(g));
        try expectEqual(Pad.pause, g.pad);
    }
}

test "input: suppress_held (menu, picker or splash) clears the tap and fast forward" {
    var s: input.State = .{};
    try tap(&s, 2);
    try expect(frame(&s, &.{.select}).fast);
    s.suppress_held();
    try expect(!frame(&s, &.{.select}).fast);

    // A tap waiting for its window: dropped, and the window is closed.
    s = .{};
    try tap(&s, 2);
    s.suppress_held();
    for (0..2 * window) |_| try expect(!opt1(frame(&s, &.{})));
    try expect(!frame(&s, &.{.select}).fast);

    // A tap being delivered: its remaining frames are dropped too.
    s = .{};
    try tap(&s, 2);
    for (0..window - 1) |_| _ = frame(&s, &.{});
    try expect(opt1(frame(&s, &.{})));
    s.suppress_held();
    try expect(!opt1(frame(&s, &.{})));
}
