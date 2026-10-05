//! The engine side of the oracle (SPEC section 6): reads an answer script,
//! plays it through the `game` module and prints the transcript.
//! PLAN-COMMIT PLACEHOLDER: track L writes it.
const std = @import("std");
const G = @import("game");

pub fn main() !void {
    var g: G.Game = .{};
    G.init(&g, 1);
    G.start(&g);
    std.debug.print("placeholder: {d} lines\n", .{g.printed().len});
}
