//! Host test entry point for Snouty Beam (`zig build test`, `zig build test-beam`).
test {
    _ = @import("proto.zig");
    _ = @import("proto_test.zig");
}
