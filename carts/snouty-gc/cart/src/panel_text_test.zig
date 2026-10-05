//! Host tests for the text drawn inside the 152 px panels of the main menu
//! and its PICKUPS page: every line fits 18 characters of the 8x8 font
//! (menu_text.zig, pickup_text.zig), the page's grid is the roll tiers,
//! its cursor wraps, and the "who rolls it" lines agree with the odds.
const std = @import("std");
const world = @import("world.zig");
const tuning = @import("tuning.zig");
const pickups = @import("pickups.zig");
const roster_text = @import("roster_text.zig");
const menu_text = @import("menu_text.zig");
const pickup_text = @import("pickup_text.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// 152 px of panel, 8 px a character, a 4 px margin a side: 18.
const panel_chars = 18;

fn fits(line: []const u8) !void {
    if (line.len == 0 or line.len > panel_chars) {
        std.debug.print("panel line of {d} chars (max {d}): \"{s}\"\n", .{ line.len, panel_chars, line });
        return error.TestUnexpectedResult;
    }
    // The 8x8 font has glyphs for printable ASCII only.
    for (line) |ch| try expect(ch >= 32 and ch < 127);
}

test "panel text fits: the main menu's hints" {
    for (menu_text.all) |line| try fits(line);
}

test "panel text fits: every PICKUPS page line" {
    for (pickup_text.entries, 0..) |e, i| {
        try fits(roster_text.pickup_name(@fromBackingInt(@intCast(i))));
        for (e.lines) |line| try fits(line);
        try fits(e.who);
    }
}

test "PICKUPS grid: a row per roll tier, PROMPT INJECTION left out" {
    try expectEqual(@as(usize, 15), pickup_text.count);
    var n: usize = 0;
    for (pickup_text.row_start, pickup_text.row_len, 0..) |start, len, r| {
        try expect(len <= pickup_text.cols);
        try expectEqual(n, start);
        for (start..start + len) |i| {
            const p: world.Pickup = @fromBackingInt(@intCast(i));
            try expectEqual(@as(u8, @intCast(r)), @backingInt(pickups.tier_of(p)));
            try expectEqual(@as(u8, @intCast(r)), pickup_text.row_of(@intCast(i)));
        }
        n += len;
    }
    try expectEqual(@as(usize, pickup_text.count), n);
}

test "PICKUPS cursor wraps and stays on the grid" {
    const move = pickup_text.move;
    try expectEqual(@as(u8, 4), move(0, -1, 0)); // PREFETCH left: SPAGHETTI CODE
    try expectEqual(@as(u8, 0), move(4, 1, 0));
    try expectEqual(@as(u8, 10), move(5, -1, 0)); // FORK BOMB left: RACE CONDITION
    try expectEqual(@as(u8, 11), move(0, 0, -1)); // up from row A: row C
    try expectEqual(@as(u8, 0), move(11, 0, 1)); // down from row C: row A
    try expectEqual(@as(u8, 14), move(10, 0, 1)); // column 5 onto row C's last
    try expectEqual(@as(u8, 4), move(10, 0, -1)); // and row A's last
    try expectEqual(@as(u8, 6), move(1, 0, 1)); // same column
    // Every move from every cell lands on a cell; each cell is reachable.
    var seen: u16 = 0;
    for (0..pickup_text.count) |i| {
        for ([_][2]i8{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } }) |d| {
            const j = move(@intCast(i), d[0], d[1]);
            try expect(j < pickup_text.count);
            seen |= @as(u16, 1) << @intCast(j);
        }
    }
    try expectEqual(@as(u16, 0x7FFF), seen);
}

test "PICKUPS who-rolls-it lines agree with the roll odds" {
    // Tier A peaks at 1st and 2nd, C at 5th and 6th, B over 3rd..5th.
    const o = tuning.roll_odds;
    for (0..6) |r| {
        if (r >= 2) try expect(o[r][0] < o[1][0]);
        if (r < 4) try expect(o[r][2] < o[4][2]);
        if (r < 2 or r == 5) try expect(o[r][1] <= o[2][1] and o[r][1] <= o[3][1] and o[r][1] <= o[4][1]);
    }
    try expect(o[0][0] > o[1][0] and o[5][2] > o[4][2]);
    // ZERO-DAY only for 5th and 6th, once a race.
    var w = world.World{};
    w.rng = 1;
    for (0..2000) |_| {
        for (1..5) |rank| try expect(pickups.roll_pickup(&w, @intCast(rank), true) != .zero_day);
        try expect(pickups.roll_pickup(&w, 6, false) != .zero_day);
    }
    try std.testing.expectEqualStrings("5TH/6TH ONLY, ONCE", pickup_text.entries[@backingInt(world.Pickup.zero_day)].who);
}
