//! Blargg CPU tests: run until the serial output says Passed or Failed.
//! Owner in M1: track A. Skeleton only.
const std = @import("std");
const core = @import("core");

test "blargg harness placeholder" {
    // Track A: for each tests/roms/cpu_instrs_XX.gb, cpu_instrs.gb and
    // instr_timing.gb, @embedFile, run frames until serial text contains
    // "Passed" (ok) or "Failed" (fail) within a generous frame budget.
    try std.testing.expect(true);
}
