//! frontend/input.zig's game-frame state machine: the Select long hold
//! that opens the menu, the double tap and hold that fast forwards and the
//! chorded rewind (Left during it; docs/FAST_FORWARD.md at the root),
//! driven frame by frame as main.zig drives it (`poll`, then `game_frame`).
const std = @import("std");
const input = @import("input");
const core = @import("core");
const Pad = core.Pad;

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

/// A Select tap of `n` frames, then the release frame; nothing happens.
fn tap(s: *input.State, n: usize) !void {
    for (0..n) |_| {
        const g = frame(s, &.{.select});
        try std.testing.expect(!g.fast and !g.open_menu);
    }
    const g = frame(s, &.{});
    try std.testing.expect(!g.fast and !g.open_menu);
}

test "input: Select held 30 frames opens the menu once" {
    var s: input.State = .{};
    var opened: u32 = 0;
    for (0..input.hold_frames) |i| {
        const g = frame(&s, &.{.select});
        try std.testing.expect(!g.fast);
        if (g.open_menu) {
            opened += 1;
            try std.testing.expectEqual(input.hold_frames - 1, i);
        }
    }
    try std.testing.expectEqual(@as(u32, 1), opened);
}

test "input: double tap and hold fast forwards while held, never the menu" {
    var s: input.State = .{};
    try tap(&s, 3);
    try std.testing.expect(!frame(&s, &.{}).fast);
    // The second press: fast at once, for as long as it is held, far past
    // the menu threshold; the d-pad and buttons still reach the game.
    for (0..3 * input.hold_frames) |_| {
        const g = frame(&s, &.{ .select, .right, .a });
        try std.testing.expect(g.fast);
        try std.testing.expect(!g.open_menu);
        try std.testing.expectEqual(input.Rewind.off, g.rewind);
        try std.testing.expectEqual(Pad.right | Pad.b2, g.pad);
    }
    // Release: 1x, nothing delivered, and no window opens from it.
    const g = frame(&s, &.{});
    try std.testing.expect(!g.fast and !g.open_menu);
    try std.testing.expectEqual(@as(u8, 0), g.pad);
    for (0..input.hold_frames) |_| try std.testing.expect(!frame(&s, &.{.select}).fast);
}

test "input: the second press counts on the window's last frame, not after" {
    var s: input.State = .{};
    try tap(&s, 2);
    for (0..window - 1) |_| _ = frame(&s, &.{});
    try std.testing.expect(frame(&s, &.{.select}).fast);

    s = .{};
    try tap(&s, 2);
    for (0..window) |_| _ = frame(&s, &.{});
    // Window gone: an ordinary press, the menu hold runs again.
    var opened = false;
    for (0..input.hold_frames) |_| {
        const g = frame(&s, &.{.select});
        try std.testing.expect(!g.fast);
        opened = opened or g.open_menu;
    }
    try std.testing.expect(opened);
}

test "input: a single long hold still opens the menu, no window after it" {
    var s: input.State = .{};
    var opened = false;
    for (0..input.hold_frames) |_| opened = opened or frame(&s, &.{.select}).open_menu;
    try std.testing.expect(opened);
    // main.zig suppresses held buttons when the menu opens; without that a
    // long press past the threshold still opens no tap window.
    _ = frame(&s, &.{});
    try std.testing.expect(!frame(&s, &.{.select}).fast);
}

test "input: Right goes to the game with Select, no fast forward" {
    var s: input.State = .{};
    _ = frame(&s, &.{.select});
    const g = frame(&s, &.{ .select, .right });
    try std.testing.expect(!g.fast);
    try std.testing.expectEqual(Pad.right, g.pad);
}

test "input: Start during the window or during fast forward cancels" {
    var s: input.State = .{};
    try tap(&s, 2);
    _ = frame(&s, &.{.start});
    _ = frame(&s, &.{});
    // The window is gone: this press is the menu hold, not fast forward.
    try std.testing.expect(!frame(&s, &.{.select}).fast);

    s = .{};
    try tap(&s, 2);
    try std.testing.expect(frame(&s, &.{.select}).fast);
    for (0..2 * input.hold_frames) |_| {
        const g = frame(&s, &.{ .select, .start });
        try std.testing.expect(!g.fast and !g.open_menu);
    }
    // Start up, Select still held: it does not come back, no menu either.
    for (0..2 * input.hold_frames) |_| {
        const g = frame(&s, &.{.select});
        try std.testing.expect(!g.fast and !g.open_menu);
    }
}

test "input: Start+Select still cancels the menu hold" {
    var s: input.State = .{};
    _ = frame(&s, &.{.select});
    for (0..2 * input.hold_frames) |_| {
        const g = frame(&s, &.{ .select, .start });
        try std.testing.expect(!g.open_menu and !g.fast);
    }
}

test "input: suppress_held (menu or splash) ends fast forward and the window" {
    var s: input.State = .{};
    try tap(&s, 2);
    try std.testing.expect(frame(&s, &.{.select}).fast);
    s.suppress_held();
    try std.testing.expect(!frame(&s, &.{.select}).fast);

    s = .{};
    try tap(&s, 2);
    s.suppress_held();
    _ = frame(&s, &.{});
    try std.testing.expect(!frame(&s, &.{.select}).fast);
}

// ---- Chorded rewind ----

/// Double tap and hold: the frame fast forward starts.
fn start_fast(s: *input.State) !void {
    try tap(s, 2);
    try std.testing.expect(frame(s, &.{.select}).fast);
}

test "input: Left during fast forward enters rewind and steps back at once" {
    var s: input.State = .{};
    try start_fast(&s);
    const g = frame(&s, &.{ .select, .left });
    try std.testing.expectEqual(input.Rewind.enter, g.rewind);
    try std.testing.expectEqual(@as(i2, -1), g.scrub);
    try std.testing.expect(!g.fast and !g.open_menu);
    // Held on, far past the menu threshold: rewind, never the menu.
    for (0..3 * input.hold_frames) |_| {
        const h = frame(&s, &.{.select});
        try std.testing.expectEqual(input.Rewind.on, h.rewind);
        try std.testing.expect(!h.fast and !h.open_menu);
    }
}

test "input: rewind steps with the menu's auto-repeat" {
    var s: input.State = .{};
    try start_fast(&s);
    // Left held for 61 frames from entry: a step at once, then every 15.
    var back: u32 = 0;
    for (0..61) |_| {
        const g = frame(&s, &.{ .select, .left });
        if (g.scrub < 0) back += 1;
        try std.testing.expect(g.scrub <= 0);
    }
    try std.testing.expectEqual(@as(u32, 5), back);
    // Released: no more steps; Right steps forward the same way.
    for (0..20) |_| try std.testing.expectEqual(@as(i2, 0), frame(&s, &.{.select}).scrub);
    var fwd: u32 = 0;
    for (0..16) |_| {
        if (frame(&s, &.{ .select, .right }).scrub > 0) fwd += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), fwd);
}

test "input: no button reaches the game in rewind, Left never during fast forward" {
    var s: input.State = .{};
    try start_fast(&s);
    // During fast forward Left is masked out, Right and A are not.
    var g = frame(&s, &.{ .select, .right, .a });
    try std.testing.expectEqual(Pad.right | Pad.b2, g.pad);
    g = frame(&s, &.{ .select, .right, .a, .left });
    try std.testing.expectEqual(input.Rewind.enter, g.rewind);
    try std.testing.expectEqual(@as(u8, 0), g.pad);
    for (0..10) |_| {
        g = frame(&s, &.{ .select, .left, .up, .a, .b });
        try std.testing.expectEqual(@as(u8, 0), g.pad);
    }
}

test "input: letting go of Select resumes with held buttons suppressed" {
    var s: input.State = .{};
    try start_fast(&s);
    _ = frame(&s, &.{ .select, .left });
    _ = frame(&s, &.{ .select, .left });
    var g = frame(&s, &.{ .left, .a });
    try std.testing.expectEqual(input.Rewind.exit, g.rewind);
    try std.testing.expect(!g.fast and !g.open_menu);
    try std.testing.expectEqual(@as(u8, 0), g.pad);
    // The held Left and A wait for their release, then play as usual.
    g = frame(&s, &.{ .left, .a });
    try std.testing.expectEqual(input.Rewind.off, g.rewind);
    try std.testing.expectEqual(@as(u8, 0), g.pad);
    _ = frame(&s, &.{});
    g = frame(&s, &.{.left});
    try std.testing.expectEqual(Pad.left, g.pad);
    // No tap window from that release, and the menu hold works again.
    var opened = false;
    for (0..input.hold_frames) |_| {
        const h = frame(&s, &.{.select});
        try std.testing.expect(!h.fast);
        opened = opened or h.open_menu;
    }
    try std.testing.expect(opened);
}

test "input: Start during rewind holds the position and reaches nothing" {
    var s: input.State = .{};
    try start_fast(&s);
    _ = frame(&s, &.{ .select, .left });
    for (0..40) |_| {
        const g = frame(&s, &.{ .select, .start, .left });
        try std.testing.expectEqual(input.Rewind.on, g.rewind);
        try std.testing.expectEqual(@as(i2, 0), g.scrub);
        try std.testing.expectEqual(@as(u8, 0), g.pad);
    }
    // Start up: a fresh Left steps again.
    _ = frame(&s, &.{.select});
    try std.testing.expectEqual(@as(i2, -1), frame(&s, &.{ .select, .left }).scrub);
}

test "input: Left with Start held during fast forward does not enter rewind" {
    var s: input.State = .{};
    try start_fast(&s);
    const g = frame(&s, &.{ .select, .start, .left });
    try std.testing.expectEqual(input.Rewind.off, g.rewind);
    try std.testing.expect(!g.fast);
}
