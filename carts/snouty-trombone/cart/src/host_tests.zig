//! Root for `zig build test`: every module without a cart API dependency,
//! so their `test` blocks run on the host.
const std = @import("std");

test {
    std.testing.refAllDecls(@This());
    _ = @import("horn.zig");
    _ = @import("hand.zig");
}
