//! M7 track pack host tests (docs/PACKS.md): the format parser, the loader,
//! the fuzzing of truncated and bit-flipped packs, props, crust and the
//! link race on the test pack. New for Snouty GCP. `host_tests.zig` imports
//! this one file, so the pack modules' tests are added here.
const std = @import("std");

test {
    _ = @import("pack_format.zig");
    _ = @import("pack_content_test.zig");
}
