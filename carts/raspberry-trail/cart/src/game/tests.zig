//! The engine's host tests (track L). `zig build test -Dcart=raspberry-trail`.
const std = @import("std");
const G = @import("game.zig");

test {
    _ = @import("rng.zig");
}

test "engine: starts at the instructions question" {
    var g: G.Game = .{};
    G.init(&g, 1);
    G.start(&g);
    try std.testing.expectEqual(G.PromptKind.yes_no, g.prompt.kind);
    try std.testing.expectEqual(@as(u16, 190), g.prompt.line);
}

/// Checks the prompt is well formed (SPEC 3.3, interface comments).
fn check_prompt(g: *const G.Game) !void {
    const p = &g.prompt;
    try std.testing.expect(!g.overflow);
    try std.testing.expect(g.n_lines <= G.max_lines);
    try std.testing.expect(p.question.len <= 52);
    switch (p.kind) {
        .choice => {
            try std.testing.expect(p.n_options >= 2 and p.n_options <= 5);
            for (p.options[0..p.n_options]) |o| try std.testing.expect(o.len > 0 and o.len <= 22);
            try std.testing.expect(p.default_choice >= 1 and p.default_choice <= p.n_options);
            try std.testing.expect(p.question.len > 0);
        },
        .number => {
            try std.testing.expect(p.min <= p.default and p.default <= p.max);
            try std.testing.expect(p.question.len > 0);
        },
        .yes_no, .shoot => try std.testing.expect(p.question.len > 0),
        .game_over => try std.testing.expect(p.outcome != .none),
    }
    if (p.kind != .game_over) try std.testing.expect(p.line != 0);
}

/// A random answer for the current prompt, sometimes out of range. In
/// `slow` games the bot dawdles (cheap oxen, lots of food, always hunts,
/// shoots well) so that some games last into the winter.
fn bot_answer(g: *const G.Game, r: *std.Random.DefaultPrng, slow: bool) G.Answer {
    const rand = r.random();
    const p = &g.prompt;
    if (slow) switch (p.line) {
        860 => return .{ .number = 200 },
        940 => return .{ .number = 300 },
        990 => return .{ .number = 100 },
        1040 => return .{ .number = 60 },
        1090 => return .{ .number = 40 },
        2100 => return .{ .choice = 2 },
        2180 => return .{ .choice = 1 },
        2770 => return .{ .choice = 2 },
        3000 => return .{ .choice = 3 },
        6220 => return .{ .shoot = .{ .correct = true, .seconds = 1 + rand.float(f64) } },
        else => {},
    };
    return switch (p.kind) {
        .yes_no => .{ .yes_no = rand.boolean() },
        .choice => .{ .choice = if (rand.uintLessThan(u8, 10) == 0) rand.uintLessThan(u8, 10) else 1 + rand.uintLessThan(u8, p.n_options) },
        .number => blk: {
            const k = rand.uintLessThan(u8, 20);
            if (k == 0) break :blk .{ .number = rand.intRangeAtMost(i32, -50, 1000) };
            if (k == 1) break :blk .{ .number = p.max };
            const span: i32 = @min(p.max - p.min, 150);
            break :blk .{ .number = p.min + rand.intRangeAtMost(i32, 0, @max(0, span)) };
        },
        .shoot => .{ .shoot = .{ .correct = rand.uintLessThan(u8, 8) != 0, .seconds = @as(f64, @floatFromInt(rand.uintLessThan(u32, 6000))) / 1000.0 } },
        .game_over => .game_over,
    };
}

test "engine: bot plays 10000 seeded games to game over" {
    var g: G.Game = .{};
    var outcomes = std.EnumArray(G.Outcome, u32).initFill(0);
    var seed: u64 = 0;
    while (seed < 10000) : (seed += 1) {
        var r = std.Random.DefaultPrng.init(seed ^ 0xA5A5);
        G.init(&g, seed);
        G.start(&g);
        const slow = seed % 4 == 0;
        var steps: u32 = 0;
        while (g.prompt.kind != .game_over) : (steps += 1) {
            try check_prompt(&g);
            try std.testing.expect(steps < 5000);
            G.answer(&g, bot_answer(&g, &r, slow));
        }
        try check_prompt(&g);
        outcomes.getPtr(g.prompt.outcome).* += 1;
    }
    // Every ending happens somewhere in 10000 random games. Pneumonia is
    // never the outcome: 5120 is reached only from 5080 and 5110 (which
    // name their own cause) and from the wolves at 4400 (K8=1, injuries).
    var it = outcomes.iterator();
    while (it.next()) |e| {
        if (e.key == .none or e.key == .pneumonia) {
            try std.testing.expectEqual(@as(u32, 0), e.value.*);
            continue;
        }
        std.debug.print("{s}: {d}\n", .{ @tagName(e.key), e.value.* });
        try std.testing.expect(e.value.* > 0);
    }
}
