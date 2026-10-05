//! Host test entry point for the shared library code in lib/ (`zig build test`).
test {
    _ = @import("romfs.zig");
    _ = @import("iris_mark.zig");
    _ = @import("hint.zig");
    _ = @import("stream_audio.zig");
    _ = @import("audio_feed.zig");
    _ = @import("tone_stream.zig");
    _ = @import("link.zig");
    _ = @import("i2c_rp2350.zig");
    _ = @import("tof.zig");
    _ = @import("tests/romfs_unit.zig");
    _ = @import("tests/link_unit.zig");
    _ = @import("tests/tof_unit.zig");
}
