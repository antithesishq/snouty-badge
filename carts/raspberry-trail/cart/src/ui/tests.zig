//! Host tests of the UI that need no cart API (track U).
const std = @import("std");
const G = @import("game");

test "ui: the game module links" {
    var g: G.Game = .{};
    G.init(&g, 7);
    G.start(&g);
    try std.testing.expect(g.printed().len > 0);
}
