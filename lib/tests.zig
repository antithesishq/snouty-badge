//! Host test entry point for the shared library code in lib/ (`zig build test`).
test {
    _ = @import("romfs.zig");
    _ = @import("iris_mark.zig");
    _ = @import("hint.zig");
    _ = @import("stream_audio.zig");
    _ = @import("audio_feed.zig");
    _ = @import("tone_stream.zig");
    _ = @import("tests/romfs_unit.zig");
}
