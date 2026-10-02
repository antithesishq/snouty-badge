//! Strict 68000 oracle run: `zig build test-m68k-strict -Dcart=snouty-genesis
//! -Dcart-mode=xip`. The build step sets `SNOUTY_FIXTURES=required`, so
//! missing SingleStepTests files (tests/roms/68000/*.json.gz,
//! tools/fetch_test_roms.sh) are `error.FixtureMissing`, a failure, not a
//! skip. Runs both passes of m68k_single_step.zig (fetch window over every
//! file, bus fetch over the subset) and prints how many cases ran. The
//! step's test filter keeps only the test below.
const std = @import("std");
const sst = @import("m68k_single_step.zig");

test "m68k strict: SingleStepTests, fetch window and bus fetch" {
    if (!sst.fixtures_required()) {
        std.debug.print("m68k strict: SNOUTY_FIXTURES=required is not set (run zig build test-m68k-strict)\n", .{});
        return error.SkipZigTest;
    }
    const window = try sst.suite(true, null);
    const bus = try sst.suite(false, &sst.bus_fetch_files);
    std.debug.print("m68k strict: {d} SingleStepTests cases (fetch window), {d} (bus fetch subset)\n", .{ window, bus });
}
