//! Unit tests for core/ring.zig, the scrubber's keyframe ring bookkeeping
//! (SPEC.md 10.1). The payload lives in cart/src/frontend/rewind.zig; these
//! tests check only which slots and log bytes it would touch.
const std = @import("std");
const core = @import("core");
const expectEqual = std.testing.expectEqual;

const R = core.ring.Ring(4, 30);

fn play(r: *R, frames: u32) void {
    for (0..frames) |_| _ = r.record();
}

test "ring: snapshots every interval and wraps" {
    var r: R = .{};
    try expectEqual(@as(usize, 0), r.reset());
    var snaps: u32 = 0;
    for (0..30 * 6) |i| {
        const rec = r.record();
        try expectEqual(i % R.log_len, rec.log_index);
        if (rec.snapshot_slot) |s| {
            snaps += 1;
            try expectEqual(@as(usize, snaps % 4), s);
        }
    }
    try expectEqual(@as(u32, 6), snaps);
    try expectEqual(@as(usize, 4), r.count);
    try expectEqual(@as(u32, 180), r.live);
    // Oldest reachable keyframe is frame 90.
    try expectEqual(@as(u32, 90), r.history_frames());
    try expectEqual(@as(u8, 5), r.history_fraction());
}

test "ring: history fraction grows by fifths" {
    var r: R = .{};
    _ = r.reset();
    try expectEqual(@as(u8, 0), r.history_fraction());
    play(&r, 1);
    try expectEqual(@as(u8, 1), r.history_fraction());
    play(&r, 44); // 45 of 90 frames
    try expectEqual(@as(u8, 3), r.history_fraction());
}

test "ring: step back and forward, ends" {
    var r: R = .{};
    _ = r.reset();
    play(&r, 100); // keyframes at 0, 30, 60, 90; live 100
    try expectEqual(false, r.can_step(1));
    // Left from live lands on the newest keyframe (frame 90).
    try expectEqual(R.Step{ .restore = r.slot_of_age(0) }, r.step(-1).?);
    try expectEqual(@as(u32, 10), r.depth_frames());
    _ = r.step(-1).?;
    _ = r.step(-1).?;
    _ = r.step(-1).?;
    try expectEqual(@as(u32, 100), r.depth_frames());
    try expectEqual(false, r.can_step(-1));
    try expectEqual(@as(?R.Step, null), r.step(-1));
    // Right back to age 0, then to live with a replay of frames 90..100.
    _ = r.step(1).?;
    _ = r.step(1).?;
    _ = r.step(1).?;
    const s = r.step(1).?;
    try expectEqual(@as(u32, 90), s.replay.from);
    try expectEqual(@as(u32, 100), s.replay.to);
    try expectEqual(@as(?usize, null), r.cursor);
    try expectEqual(@as(u32, 0), r.depth_frames());
}

test "ring: left from a keyframe-aligned live skips the identical keyframe" {
    var r: R = .{};
    _ = r.reset();
    play(&r, 60);
    _ = r.step(-1).?;
    try expectEqual(@as(u32, 30), r.depth_frames());
    try expectEqual(@as(usize, 1), r.cursor.?);
}

test "ring: playing from a parked keyframe truncates the future" {
    var r: R = .{};
    _ = r.reset();
    play(&r, 100);
    _ = r.step(-1); // 90
    _ = r.step(-1); // 60
    const parked_slot = r.slot_of_age(1);
    const rec = r.record();
    // The pad for frame 60 is logged, the old frames 61..100 are gone.
    try expectEqual(R.log_index(60), rec.log_index);
    try expectEqual(@as(u32, 61), r.live);
    try expectEqual(@as(usize, 3), r.count);
    try expectEqual(parked_slot, r.slot_of_age(0));
    try expectEqual(false, r.can_step(1));
    // The next keyframe (frame 90) reuses the slot after frame 60's.
    play(&r, 28);
    try expectEqual((parked_slot + 1) % 4, r.record().snapshot_slot.?);
    try expectEqual(@as(u32, 90), r.head_frame());
}

test "ring: the log covers the whole reachable span" {
    var r: R = .{};
    _ = r.reset();
    play(&r, 30 * 10 + 29);
    const oldest = r.frame_of_age(r.count - 1);
    var f = oldest;
    while (f < r.live) : (f += 1) try expectEqual(true, r.has_pad(f));
    try expectEqual(false, r.has_pad(r.live));
    try expectEqual(false, r.has_pad(r.live - R.log_len - 1));
}
