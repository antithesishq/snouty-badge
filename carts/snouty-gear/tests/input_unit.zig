//! frontend/input.zig's game-frame state machine: the Select long hold
//! that opens the menu and the Select+Right fast-forward chord
//! (docs/FAST_FORWARD.md at the root), driven frame by frame as main.zig
//! drives it (`poll`, then `game_frame`).
const std = @import("std");
const input = @import("input");
const core = @import("core");
const Pad = core.Pad;

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

test "input: Select then Right fast forwards while both are held, no menu" {
    var s: input.State = .{};
    _ = frame(&s, &.{.select});
    var g = frame(&s, &.{ .select, .right });
    try std.testing.expect(g.fast);
    // Held far past the menu threshold: still fast, the menu never opens,
    // and Right never reaches the game (A still does).
    for (0..3 * input.hold_frames) |_| {
        g = frame(&s, &.{ .select, .right, .a });
        try std.testing.expect(g.fast);
        try std.testing.expect(!g.open_menu);
        try std.testing.expectEqual(Pad.b2, g.pad);
    }
}

test "input: letting go of Right returns to 1x and the hold counts from zero" {
    var s: input.State = .{};
    _ = frame(&s, &.{.select});
    for (0..20) |_| try std.testing.expect(frame(&s, &.{.select}).open_menu == false);
    for (0..40) |_| try std.testing.expect(frame(&s, &.{ .select, .right }).fast);
    // Right up: 1x at once; the menu opens a full hold later, not earlier.
    for (0..input.hold_frames - 1) |_| {
        const g = frame(&s, &.{.select});
        try std.testing.expect(!g.fast);
        try std.testing.expect(!g.open_menu);
    }
    try std.testing.expect(frame(&s, &.{.select}).open_menu);
}

test "input: Right again during the renewed hold fast forwards again" {
    var s: input.State = .{};
    _ = frame(&s, &.{.select});
    try std.testing.expect(frame(&s, &.{ .select, .right }).fast);
    try std.testing.expect(!frame(&s, &.{.select}).fast);
    try std.testing.expect(frame(&s, &.{ .select, .right }).fast);
}

test "input: letting go of Select ends it, no tap, Right waits for a release" {
    var s: input.State = .{};
    _ = frame(&s, &.{.select});
    _ = frame(&s, &.{ .select, .right });
    var g = frame(&s, &.{.right});
    try std.testing.expect(!g.fast);
    try std.testing.expect(!g.open_menu);
    // The Right of the chord does not walk the game once Select is gone.
    try std.testing.expectEqual(@as(u8, 0), g.pad);
    g = frame(&s, &.{.right});
    try std.testing.expectEqual(@as(u8, 0), g.pad);
    _ = frame(&s, &.{});
    g = frame(&s, &.{.right});
    try std.testing.expectEqual(Pad.right, g.pad);
    try std.testing.expect(!g.fast);
}

test "input: Right held before Select is game input, Select then opens the menu" {
    var s: input.State = .{};
    _ = frame(&s, &.{.right});
    var opened = false;
    for (0..input.hold_frames) |_| {
        const g = frame(&s, &.{ .right, .select });
        try std.testing.expect(!g.fast);
        try std.testing.expectEqual(Pad.right, g.pad);
        opened = opened or g.open_menu;
    }
    try std.testing.expect(opened);
}

test "input: Start+Select still cancels the hold and ends fast forward" {
    var s: input.State = .{};
    // The hold: Start cancels it, the menu never opens.
    _ = frame(&s, &.{.select});
    for (0..2 * input.hold_frames) |_| {
        const g = frame(&s, &.{ .select, .start });
        try std.testing.expect(!g.open_menu);
        try std.testing.expect(!g.fast);
    }
    // A Right pressed into the OS chord does not start fast forward.
    try std.testing.expect(!frame(&s, &.{ .select, .start, .right }).fast);

    // Fast forward: Start ends it and it does not come back while Select
    // and Right stay held.
    s = .{};
    _ = frame(&s, &.{.select});
    try std.testing.expect(frame(&s, &.{ .select, .right }).fast);
    for (0..2 * input.hold_frames) |_| {
        const g = frame(&s, &.{ .select, .right, .start });
        try std.testing.expect(!g.fast);
        try std.testing.expect(!g.open_menu);
    }
    for (0..2 * input.hold_frames) |_| {
        const g = frame(&s, &.{ .select, .right });
        try std.testing.expect(!g.fast);
        try std.testing.expect(!g.open_menu);
    }
}

test "input: suppress_held (menu or splash) ends fast forward" {
    var s: input.State = .{};
    _ = frame(&s, &.{.select});
    try std.testing.expect(frame(&s, &.{ .select, .right }).fast);
    s.suppress_held();
    try std.testing.expect(!frame(&s, &.{ .select, .right }).fast);
}
