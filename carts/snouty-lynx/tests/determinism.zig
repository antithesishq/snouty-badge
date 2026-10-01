//! determinism: keyframe replay and undo round trips on raycast (M3 Track A). M3 prep: placeholder so tests/all.zig already imports it.
const std = @import("std");
const core = @import("core");

test "determinism: placeholder (M3)" {
    try std.testing.expect(@hasDecl(core, "undo"));
}
