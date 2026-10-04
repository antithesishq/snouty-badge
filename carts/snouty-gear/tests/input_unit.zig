//! frontend/input.zig's game-frame state machine: the Select long hold
//! that opens the menu and the double tap and hold that fast forwards
//! (docs/FAST_FORWARD.md at the root), driven frame by frame as main.zig
//! drives it (`poll`, then `game_frame`).
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
