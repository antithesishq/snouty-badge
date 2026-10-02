//! Strict Z80 oracle run: `zig build test-z80-strict -Dcart=snouty-gear`.
//! The build step sets `SNOUTY_FIXTURES=required`, so a missing fixture
//! (tests/roms/z80/v1/*.json, tests/roms/zexdoc.sms, tests/roms/zexall.sms;
//! tools/fetch_test_roms.sh --single-step) is `error.FixtureMissing`, a
//! failure, not a skip; ZEXALL runs even in a Debug build. Prints how many
//! cases ran. The step's test filter keeps only the test below.
const std = @import("std");
const sst = @import("z80_single_step.zig");
const zex = @import("z80_zex.zig");

test "z80 strict: SingleStepTests, ZEXDOC, ZEXALL" {
    if (!sst.fixtures_required()) {
        std.debug.print("z80 strict: SNOUTY_FIXTURES=required is not set (run zig build test-z80-strict)\n", .{});
        return error.SkipZigTest;
    }
    // Every oracle runs and reports before the first error is returned.
    const cases = report("SingleStepTests", sst.run_suite());
    const doc = report("zexdoc.sms", zex.run_zex("zexdoc.sms"));
    const all = report("zexall.sms", zex.run_zex("zexall.sms"));
    const n_cases = try cases;
    const n_doc = try doc;
    const n_all = try all;
    std.debug.print("z80 strict: {d} SingleStepTests cases, zexdoc {d} OK, zexall {d} OK\n", .{ n_cases, n_doc, n_all });
}

fn report(name: []const u8, r: anytype) @TypeOf(r) {
    if (r) |_| {} else |e| std.debug.print("z80 strict: {s}: {s}\n", .{ name, @errorName(e) });
    return r;
}
