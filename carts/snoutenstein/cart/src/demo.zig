//! Attract-mode demo playback (SPEC.md 11, PLAN.md M5). A demo is a fixed
//! seed plus a run-length input log, generated into `demos/build_farm.zig`
//! by `tools/gen_demo.py`; this module is the cursor over it. Pure Zig, no
//! cart-api: `zig test cart/src/demo.zig` runs on the host.
const std = @import("std");
const state = @import("state.zig");
pub const data = @import("demos/build_farm.zig");

pub const Run = data.Run;
pub const level_index: u8 = data.level_index;
pub const seed: u32 = data.seed;
pub const total_ticks: u32 = data.total_ticks;
pub const final_hash: u32 = data.final_hash;

const Cursor = struct {
    run: usize = 0,
    /// Ticks of `runs[run]` already handed out.
    done: u16 = 0,
    played: u32 = 0,

    fn next(self: *Cursor, runs: []const Run) ?state.Buttons {
        while (self.run < runs.len and self.done >= runs[self.run].ticks) {
            self.run += 1;
            self.done = 0;
        }
        if (self.run >= runs.len) return null;
        self.done += 1;
        self.played += 1;
        return @bitCast(runs[self.run].buttons);
    }
};

var cur: Cursor = .{};

pub fn reset() void {
    cur = .{};
}

/// The input for the next tick, or null once the log is exhausted.
pub fn next() ?state.Buttons {
    return cur.next(&data.runs);
}

pub fn finished() bool {
    return cur.run >= data.runs.len or (cur.run == data.runs.len - 1 and cur.done >= data.runs[cur.run].ticks);
}

pub fn ticks_played() u32 {
    return cur.played;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "runs sum to total_ticks and next hands out exactly that many" {
    var sum: u32 = 0;
    for (data.runs) |r| sum += r.ticks;
    try testing.expectEqual(data.total_ticks, sum);
    reset();
    var n: u32 = 0;
    while (next()) |_| n += 1;
    try testing.expectEqual(data.total_ticks, n);
    try testing.expect(finished());
    try testing.expectEqual(@as(?state.Buttons, null), next());
}

test "two-run fixture decodes in order" {
    const fixture = [_]Run{ .{ .buttons = 0x0004, .ticks = 2 }, .{ .buttons = 0x0120, .ticks = 1 } };
    var c: Cursor = .{};
    const a1 = c.next(&fixture).?;
    try testing.expect(a1.a and !a1.up);
    const a2 = c.next(&fixture).?;
    try testing.expect(a2.a);
    const b = c.next(&fixture).?;
    try testing.expect(b.up and b.right and !b.a);
    try testing.expectEqual(@as(?state.Buttons, null), c.next(&fixture));
    try testing.expectEqual(@as(u32, 3), c.played);
}

test "seed is non-zero so sim.init does not fall back to the default" {
    try testing.expect(data.seed != 0);
    try testing.expect(data.total_ticks <= 3 * 3600);
}
