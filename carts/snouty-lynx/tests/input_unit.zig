//! frontend/input.zig's game-frame state machine (Snouty Gear's
//! tests/input_unit.zig with the Lynx's Option 1): the Select long hold
//! that opens the menu, the Select tap that becomes Option 1 once the
//! fast-forward window runs out, the double tap and hold that fast
//! forwards and the chorded rewind (Left during it; docs/FAST_FORWARD.md
//! at the root), driven frame by frame as main.zig drives it (`poll`, then
//! `game_frame`).
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

// ---- Chorded rewind ----

/// Double tap and hold: the frame fast forward starts.
fn start_fast(s: *input.State) !void {
    try tap(s, 2);
    try expect(frame(s, &.{.select}).fast);
}

test "input: Left during fast forward enters rewind and steps back at once" {
    var s: input.State = .{};
    try start_fast(&s);
    const g = frame(&s, &.{ .select, .left });
    try expectEqual(input.Rewind.enter, g.rewind);
    try expectEqual(@as(i2, -1), g.scrub);
    try expect(!g.fast and !g.open_menu);
    // Held on, far past the menu threshold: rewind, never the menu.
    for (0..3 * input.hold_frames) |_| {
        const h = frame(&s, &.{.select});
        try expectEqual(input.Rewind.on, h.rewind);
        try expect(!h.fast and !h.open_menu);
    }
}

test "input: a Left held when fast forward starts does not enter rewind" {
    var s: input.State = .{};
    try tap(&s, 2);
    const g = frame(&s, &.{ .select, .left });
    try expect(g.fast);
    try expectEqual(input.Rewind.off, g.rewind);
    // Reserved, so it does not reach the game either.
    try expectEqual(@as(u16, 0), g.pad);
    for (0..20) |_| {
        const h = frame(&s, &.{ .select, .left });
        try expect(h.fast);
        try expectEqual(input.Rewind.off, h.rewind);
        try expectEqual(@as(u16, 0), h.pad);
    }
    // Let go of Left and press it again: now it counts.
    try expect(frame(&s, &.{.select}).fast);
    try expectEqual(input.Rewind.enter, frame(&s, &.{ .select, .left }).rewind);
}

test "input: rewind steps with the menu's auto-repeat" {
    var s: input.State = .{};
    try start_fast(&s);
    // Left held for 61 frames from entry: a step at once, then every 15.
    var back: u32 = 0;
    for (0..61) |_| {
        const g = frame(&s, &.{ .select, .left });
        if (g.scrub < 0) back += 1;
        try expect(g.scrub <= 0);
    }
    try expectEqual(@as(u32, 5), back);
    // Released: no more steps; Right steps forward the same way.
    for (0..20) |_| try expectEqual(@as(i2, 0), frame(&s, &.{.select}).scrub);
    var fwd: u32 = 0;
    for (0..16) |_| {
        if (frame(&s, &.{ .select, .right }).scrub > 0) fwd += 1;
    }
    try expectEqual(@as(u32, 2), fwd);
}

test "input: no button reaches the game in rewind, Left never during fast forward" {
    var s: input.State = .{};
    try start_fast(&s);
    // During fast forward Left is masked out, Right and A are not.
    var g = frame(&s, &.{ .select, .right, .a });
    try expectEqual(Pad.right | Pad.a, g.pad);
    g = frame(&s, &.{ .select, .right, .a, .left });
    try expectEqual(input.Rewind.enter, g.rewind);
    try expectEqual(@as(u16, 0), g.pad);
    for (0..10) |_| {
        g = frame(&s, &.{ .select, .left, .up, .a, .b });
        try expectEqual(@as(u16, 0), g.pad);
    }
}

test "input: letting go of Select resumes with held buttons suppressed" {
    var s: input.State = .{};
    try start_fast(&s);
    _ = frame(&s, &.{ .select, .left });
    _ = frame(&s, &.{ .select, .left });
    var g = frame(&s, &.{ .left, .a });
    try expectEqual(input.Rewind.exit, g.rewind);
    try expect(!g.fast and !g.open_menu);
    try expectEqual(@as(u16, 0), g.pad);
    // The held Left and A wait for their release, then play as usual.
    g = frame(&s, &.{ .left, .a });
    try expectEqual(input.Rewind.off, g.rewind);
    try expectEqual(@as(u16, 0), g.pad);
    _ = frame(&s, &.{});
    g = frame(&s, &.{.left});
    try expectEqual(Pad.left, g.pad);
    // No tap window and no Option 1 from that release, and the menu hold
    // works again.
    for (0..2 * window) |_| try expect(!opt1(frame(&s, &.{})));
    var opened = false;
    for (0..input.hold_frames) |_| {
        const h = frame(&s, &.{.select});
        try expect(!h.fast);
        opened = opened or h.open_menu;
    }
    try expect(opened);
}

test "input: Start during rewind holds the position and reaches nothing" {
    var s: input.State = .{};
    try start_fast(&s);
    _ = frame(&s, &.{ .select, .left });
    for (0..40) |_| {
        const g = frame(&s, &.{ .select, .start, .left });
        try expectEqual(input.Rewind.on, g.rewind);
        try expectEqual(@as(i2, 0), g.scrub);
        try expectEqual(@as(u16, 0), g.pad);
    }
    // Start up: a fresh Left steps again.
    _ = frame(&s, &.{.select});
    try expectEqual(@as(i2, -1), frame(&s, &.{ .select, .left }).scrub);
}

test "input: Left with Start held during fast forward does not enter rewind" {
    var s: input.State = .{};
    try start_fast(&s);
    const g = frame(&s, &.{ .select, .start, .left });
    try expectEqual(input.Rewind.off, g.rewind);
    try expect(!g.fast);
}

test "input: suppress_held ends the chorded rewind" {
    var s: input.State = .{};
    try start_fast(&s);
    _ = frame(&s, &.{ .select, .left });
    s.suppress_held();
    const g = frame(&s, &.{.select});
    try expectEqual(input.Rewind.off, g.rewind);
    try expect(!g.fast);
}
