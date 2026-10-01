//! golden: scripted runs of the shipped ROM and the lynx-tests carts, frame hashes (M1 Track C fills, integration pins). M1 prep: placeholder so tests/all.zig already imports it.
const std = @import("std");
const core = @import("core");

test "golden: placeholder (M1)" {
    try std.testing.expect(@hasDecl(core, "Lynx"));
}
