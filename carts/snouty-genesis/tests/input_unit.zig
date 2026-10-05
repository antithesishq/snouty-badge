//! frontend/input.zig's running-update state machine: the Select tap (a
//! Genesis button, held back for the fast-forward window), the long hold
//! that opens the menu and the double tap and hold that fast forwards
//! (docs/FAST_FORWARD.md at the root), driven update by update as app.zig
//! drives it (`poll`, then `game_frame`).
const std = @import("std");
const input = @import("input");
const core = @import("core");
const Pad = core.Pad;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// `tuning.ff_tap_window_updates` (frontend/tuning.zig): 200 ms at 30 Hz.
const window = 6;

const Btn = enum { start, select, a, b, up, down, left, right };

/// Controls with exactly `held` down.
fn controls(held: []const Btn) input.Controls {
    var c: input.Controls = @bitCast(@as(u16, 0));
    for (held) |b| switch (b) {
        inline else => |t| @field(c, @tagName(t)) = true,
    };
    return c;
}

/// One running update with `held` down.
fn update(s: *input.State, held: []const Btn) input.GameInput {
    s.poll(controls(held));
    return s.game_frame();
}

/// A Select tap of `n` updates, then the release update: no button, no
/// fast forward, no menu yet (the tap is held back).
fn tap(s: *input.State, n: usize) !void {
    for (0..n) |_| {
        const g = update(s, &.{.select});
        try expect(!g.fast and !g.open_menu);
        try expectEqual(@as(u16, 0), g.pad);
    }
    const g = update(s, &.{});
    try expect(!g.fast and !g.open_menu);
    try expectEqual(@as(u16, 0), g.pad);
}

test "input: Select held 15 updates opens the menu once, no tap" {
    var s: input.State = .{};
    var opened: u32 = 0;
    for (0..3 * input.hold_updates) |i| {
        const g = update(&s, &.{.select});
        try expect(!g.fast);
        try expectEqual(@as(u16, 0), g.pad);
        if (g.open_menu) {
            opened += 1;
            try expectEqual(input.hold_updates - 1, i);
        }
    }
    try expectEqual(@as(u32, 1), opened);
    // Released after the menu threshold: no tap and no window.
    for (0..2 * window) |_| try expectEqual(@as(u16, 0), update(&s, &.{}).pad);
}

test "input: a tap reaches the game when the window runs out, as the layout says" {
    defer input.layout = .b_c_a;
    for ([_]input.Layout{ .b_c_a, .b_a_c, .c_a_b }) |l| {
        input.layout = l;
        var s: input.State = .{};
        try tap(&s, 2);
        // The window's first updates: nothing yet, the d-pad passes.
        for (0..window - 1) |_| {
            const g = update(&s, &.{.left});
            try expect(!g.fast and !g.open_menu);
            try expectEqual(Pad.left, g.pad);
        }
        // Its last update delivers the tap, for `tap_frames` Genesis frames.
        for (0..input.tap_updates) |_| {
            const g = update(&s, &.{});
            try expect(!g.fast and !g.open_menu);
            try expectEqual(l.tap_bit(), g.pad);
        }
        try expectEqual(@as(u16, 0), update(&s, &.{}).pad);
    }
}

test "input: double tap and hold fast forwards while held, no tap, no menu" {
    var s: input.State = .{};
    try tap(&s, 3);
    try expectEqual(@as(u16, 0), update(&s, &.{}).pad);
    // The second press: fast at once, for as long as it is held, far past
    // the menu threshold; the d-pad and buttons still reach the game and
    // the held-back tap never does.
    for (0..3 * input.hold_updates) |_| {
        const g = update(&s, &.{ .select, .right, .a });
        try expect(g.fast);
        try expect(!g.open_menu);
        try expectEqual(Pad.right | Pad.c, g.pad);
    }
    // Release: 1x, nothing delivered, and no window opens from it.
    for (0..2 * window) |_| {
        const g = update(&s, &.{});
        try expect(!g.fast and !g.open_menu);
        try expectEqual(@as(u16, 0), g.pad);
    }
    // The next press is a plain one: the menu hold, not fast forward.
    var opened = false;
    for (0..input.hold_updates) |_| {
        const g = update(&s, &.{.select});
        try expect(!g.fast);
        opened = opened or g.open_menu;
    }
    try expect(opened);
}

test "input: the second press counts on the window's last update, not after" {
    var s: input.State = .{};
    try tap(&s, 2);
    for (0..window - 1) |_| _ = update(&s, &.{});
    try expect(update(&s, &.{.select}).fast);

    s = .{};
    try tap(&s, 2);
    for (0..window - 1) |_| _ = update(&s, &.{});
    // The window ran out: the tap goes to the game, and a press now starts
    // the menu timer instead.
    try expectEqual(Pad.a, update(&s, &.{}).pad);
    const g = update(&s, &.{.select});
    try expect(!g.fast);
    try expectEqual(Pad.a, g.pad); // the tap's second update
    try expect(s.holding);
}

test "input: Start cancels in the window and during fast forward" {
    // In the window: the tap is dropped, the next Select is a plain press.
    var s: input.State = .{};
    try tap(&s, 2);
    _ = update(&s, &.{.start});
    for (0..2 * window) |_| {
        const g = update(&s, &.{});
        try expect(!g.fast);
        try expectEqual(@as(u16, 0), g.pad);
    }
    try expect(!update(&s, &.{.select}).fast);
    try expect(s.holding);

    // During fast forward: back to 1x at once (Start goes to the game, as
    // it always does), Select's release delivers nothing.
    s = .{};
    try tap(&s, 2);
    try expect(update(&s, &.{.select}).fast);
    try expect(update(&s, &.{.select}).fast);
    const g = update(&s, &.{ .select, .start });
    try expect(!g.fast and !g.open_menu);
    try expectEqual(Pad.start, g.pad);
    for (0..2 * input.hold_updates) |_| {
        const h = update(&s, &.{.select});
        try expect(!h.fast and !h.open_menu);
    }
    for (0..2 * window) |_| {
        const h = update(&s, &.{});
        try expect(!h.fast);
        try expectEqual(@as(u16, 0), h.pad);
    }
}

test "input: suppress_held forgets the window, the tap and fast forward" {
    // A window open: nothing is delivered later.
    var s: input.State = .{};
    try tap(&s, 2);
    s.suppress_held();
    for (0..2 * window) |_| try expectEqual(@as(u16, 0), update(&s, &.{}).pad);

    // A tap being delivered: cut short.
    s = .{};
    try tap(&s, 2);
    for (0..window) |_| _ = update(&s, &.{});
    s.suppress_held();
    try expectEqual(@as(u16, 0), update(&s, &.{}).pad);

    // Fast forward: off, and the held Select and A wait for their release.
    s = .{};
    try tap(&s, 2);
    try expect(update(&s, &.{ .select, .a }).fast);
    s.suppress_held();
    try expect(!s.fast and s.tap_window == 0 and !s.holding);
    for (0..2 * input.hold_updates) |_| {
        const g = update(&s, &.{ .select, .a });
        try expect(!g.fast and !g.open_menu);
        try expectEqual(@as(u16, 0), g.pad);
    }
}

// ---- Chorded rewind (Left during fast forward) ----

/// A double tap whose second press is held: fast forward on, `held` down
/// with Select from the second press on.
fn fast_with(s: *input.State, held: []const Btn) !void {
    try tap(s, 2);
    var buf: [8]Btn = undefined;
    buf[0] = .select;
    @memcpy(buf[1..][0..held.len], held);
    try expect(update(s, buf[0 .. held.len + 1]).fast);
}

test "input: Left during fast forward enters rewind and steps back at once" {
    var s: input.State = .{};
    try fast_with(&s, &.{});
    try expect(update(&s, &.{.select}).fast);
    const g = update(&s, &.{ .select, .left });
    try expectEqual(input.Rewind.enter, g.rewind);
    try expectEqual(@as(i2, -1), g.scrub);
    try expect(!g.fast and !g.open_menu);
    try expectEqual(@as(u16, 0), g.pad);
    // Held far past the menu threshold: rewind, never the menu.
    for (0..3 * input.hold_updates) |_| {
        const h = update(&s, &.{.select});
        try expectEqual(input.Rewind.on, h.rewind);
        try expect(!h.open_menu and !h.fast);
    }
}

test "input: rewind steps with the menu's auto-repeat, Right forward" {
    var s: input.State = .{};
    try fast_with(&s, &.{});
    try expectEqual(@as(i2, -1), update(&s, &.{ .select, .left }).scrub);
    // Left held: the next step after `repeat_updates`, then every as many.
    var steps: u32 = 0;
    for (0..3 * input.Repeat.repeat_updates) |i| {
        const g = update(&s, &.{ .select, .left });
        try expectEqual(input.Rewind.on, g.rewind);
        if (g.scrub != 0) {
            try expectEqual(@as(i2, -1), g.scrub);
            try expectEqual(@as(usize, 0), (i + 1) % input.Repeat.repeat_updates);
            steps += 1;
        }
    }
    try expectEqual(@as(u32, 3), steps);
    _ = update(&s, &.{.select});
    try expectEqual(@as(i2, 1), update(&s, &.{ .select, .right }).scrub);
    try expectEqual(@as(i2, 0), update(&s, &.{ .select, .right }).scrub);
}

test "input: Left never reaches the game in fast forward or rewind; Right does in fast forward" {
    var s: input.State = .{};
    try fast_with(&s, &.{});
    const g = update(&s, &.{ .select, .right, .b });
    try expect(g.fast);
    try expectEqual(Pad.right | Pad.b, g.pad);
    // In rewind nothing reaches the game.
    try expectEqual(input.Rewind.enter, update(&s, &.{ .select, .left }).rewind);
    for (0..20) |_| {
        const h = update(&s, &.{ .select, .left, .right, .a, .b, .up });
        try expectEqual(@as(u16, 0), h.pad);
    }
}

test "input: a Left held when fast forward starts is reserved, not rewind" {
    var s: input.State = .{};
    _ = update(&s, &.{.left});
    try fast_with(&s, &.{.left});
    for (0..20) |_| {
        const g = update(&s, &.{ .select, .left });
        try expect(g.fast);
        try expectEqual(input.Rewind.off, g.rewind);
        try expectEqual(@as(u16, 0), g.pad);
    }
    // Let go and press again: that fresh press enters rewind.
    _ = update(&s, &.{.select});
    try expectEqual(input.Rewind.enter, update(&s, &.{ .select, .left }).rewind);
}

test "input: letting go of Select resumes with held buttons suppressed" {
    var s: input.State = .{};
    try fast_with(&s, &.{});
    _ = update(&s, &.{ .select, .left });
    _ = update(&s, &.{ .select, .left, .right });
    const g = update(&s, &.{ .left, .right });
    try expectEqual(input.Rewind.exit, g.rewind);
    try expect(!g.fast and !g.open_menu);
    try expectEqual(@as(u16, 0), g.pad);
    // Play at 1x; Left and Right wait for their release.
    for (0..10) |_| {
        const h = update(&s, &.{ .left, .right });
        try expectEqual(input.Rewind.off, h.rewind);
        try expect(!h.fast);
        try expectEqual(@as(u16, 0), h.pad);
    }
    _ = update(&s, &.{});
    try expectEqual(Pad.left, update(&s, &.{.left}).pad);
    // No window from that release: a Select press is a plain one.
    try expect(!update(&s, &.{.select}).fast);
    try expect(s.holding);
}

test "input: Start in rewind keeps the position, nothing reaches the game" {
    var s: input.State = .{};
    try fast_with(&s, &.{});
    _ = update(&s, &.{ .select, .left });
    for (0..3 * input.Repeat.repeat_updates) |_| {
        const g = update(&s, &.{ .select, .left, .start });
        try expectEqual(input.Rewind.on, g.rewind);
        try expectEqual(@as(i2, 0), g.scrub);
        try expectEqual(@as(u16, 0), g.pad);
    }
    // Start up again: still rewinding, a fresh Left steps.
    try expectEqual(@as(i2, 0), update(&s, &.{ .select, .left }).scrub);
    _ = update(&s, &.{.select});
    try expectEqual(@as(i2, -1), update(&s, &.{ .select, .left }).scrub);
    // suppress_held ends it.
    s.suppress_held();
    try expect(!s.rewinding);
    const g = update(&s, &.{ .select, .left });
    try expectEqual(input.Rewind.off, g.rewind);
    try expectEqual(@as(u16, 0), g.pad);
}
