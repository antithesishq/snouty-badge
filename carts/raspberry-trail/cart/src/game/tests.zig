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
