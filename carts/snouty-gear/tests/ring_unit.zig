//! Unit tests for core/ring.zig, the scrubber's keyframe ring bookkeeping
//! (SPEC.md section 10). Ported from Snouty Boy's tests/ring_unit.zig in M3
//! (the ring is copied verbatim, SPEC.md section 7), so the same behaviour
//! is pinned on both carts. The payload (a page store) lives in
//! cart/src/frontend/rewind.zig; these tests check only which keyframe ages
//! and log bytes it would touch.
const std = @import("std");
const core = @import("core");
const expectEqual = std.testing.expectEqual;

const R = core.ring.Ring(4, 30);

fn play(r: *R, frames: u32) void {
    for (0..frames) |_| _ = r.record();
}

test "ring: snapshots every interval, count capped" {
    var r: R = .{};
    r.reset();
    var snaps: u32 = 0;
    for (0..30 * 6) |i| {
        const rec = r.record();
        try expectEqual(i % R.log_len, rec.log_index);
        try expectEqual(@as(usize, 0), rec.drop_newest);
        if (rec.snapshot) snaps += 1;
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
    r.reset();
    try expectEqual(@as(u8, 0), r.history_fraction());
    play(&r, 1);
    try expectEqual(@as(u8, 1), r.history_fraction());
    play(&r, 44); // 45 of 90 frames
    try expectEqual(@as(u8, 3), r.history_fraction());
}

test "ring: step back and forward, ends" {
    var r: R = .{};
    r.reset();
    play(&r, 100); // keyframes at 0, 30, 60, 90; live 100
    try expectEqual(false, r.can_step(1));
    // Left from live lands on the newest keyframe (frame 90).
    try expectEqual(R.Step{ .restore = 0 }, r.step(-1).?);
    try expectEqual(@as(u32, 10), r.depth_frames());
    _ = r.step(-1).?;
    _ = r.step(-1).?;
    try expectEqual(R.Step{ .restore = 3 }, r.step(-1).?);
    try expectEqual(@as(u32, 100), r.depth_frames());
    try expectEqual(false, r.can_step(-1));
    try expectEqual(@as(?R.Step, null), r.step(-1));
    // Right back to age 0, then to live with a replay of frames 90..100.
    _ = r.step(1).?;
    _ = r.step(1).?;
    try expectEqual(R.Step{ .restore = 0 }, r.step(1).?);
    const s = r.step(1).?;
    try expectEqual(@as(u32, 90), s.replay.from);
    try expectEqual(@as(u32, 100), s.replay.to);
    try expectEqual(@as(?usize, null), r.cursor);
    try expectEqual(@as(u32, 0), r.depth_frames());
}

test "ring: left from a keyframe-aligned live skips the identical keyframe" {
    var r: R = .{};
    r.reset();
    play(&r, 60);
    _ = r.step(-1).?;
    try expectEqual(@as(u32, 30), r.depth_frames());
    try expectEqual(@as(usize, 1), r.cursor.?);
}

test "ring: playing from a parked keyframe truncates the future" {
    var r: R = .{};
    r.reset();
    play(&r, 100);
    _ = r.step(-1); // 90
    _ = r.step(-1); // 60
    const rec = r.record();
    // The keyframe at 90 goes; the pad for frame 60 is logged, the old
    // frames 61..100 are gone.
    try expectEqual(@as(usize, 1), rec.drop_newest);
    try expectEqual(R.log_index(60), rec.log_index);
    try expectEqual(@as(u32, 61), r.live);
    try expectEqual(@as(usize, 3), r.count);
    try expectEqual(@as(u32, 60), r.head_frame());
    try expectEqual(false, r.can_step(1));
    // The next keyframe is frame 90 again.
    play(&r, 28);
    try expectEqual(true, r.record().snapshot);
    try expectEqual(@as(u32, 90), r.head_frame());
    try expectEqual(@as(usize, 4), r.count);
}

test "ring: store eviction shrinks the count from the old end" {
    var r: R = .{};
    r.reset();
    play(&r, 95); // keyframes at 0, 30, 60, 90
    r.set_count(2); // the store kept 60 and 90
    try expectEqual(@as(u32, 35), r.history_frames());
    try expectEqual(@as(u32, 60), r.frame_of_age(1));
    _ = r.step(-1).?;
    try expectEqual(R.Step{ .restore = 1 }, r.step(-1).?);
    try expectEqual(false, r.can_step(-1));
    // Pool exhausted entirely: restart with one keyframe at live.
    _ = r.step(1).?;
    _ = r.step(1).?;
    play(&r, 25);
    try expectEqual(@as(u32, 120), r.live);
    r.restart_at_live();
    try expectEqual(@as(usize, 1), r.count);
    try expectEqual(@as(u32, 0), r.history_frames());
    try expectEqual(false, r.can_step(-1));
}

test "ring: losing the history leaves nothing to step to until the next keyframe" {
    var r: R = .{};
    r.reset();
    play(&r, 65);
    r.lose_history();
    try expectEqual(@as(u32, 0), r.history_frames());
    try expectEqual(false, r.can_step(-1));
    try expectEqual(false, r.can_step(1));
    try expectEqual(@as(?R.Step, null), r.step(-1));
    play(&r, 24);
    try expectEqual(true, r.record().snapshot); // frame 90
    try expectEqual(@as(usize, 1), r.count);
    r.set_count(1);
    play(&r, 1);
    try expectEqual(R.Step{ .restore = 0 }, r.step(-1).?);
    try expectEqual(false, r.can_step(-1));
}

test "ring: the log covers the whole reachable span" {
    var r: R = .{};
    r.reset();
    play(&r, 30 * 10 + 29);
    const oldest = r.frame_of_age(r.count - 1);
    var f = oldest;
    while (f < r.live) : (f += 1) try expectEqual(true, r.has_pad(f));
    try expectEqual(false, r.has_pad(r.live));
    try expectEqual(false, r.has_pad(r.live - R.log_len - 1));
}

// ---- Run-time keyframe count (the store is laid out at start) ----

/// A frontend-like shape: 12 keyframes at most, one every 30 frames.
const M = core.ring.Ring(12, 30);

test "ring: init clamps the keyframe count to 2..max_keyframes" {
    try expectEqual(@as(usize, 2), M.init(0).n);
    try expectEqual(@as(usize, 2), M.init(1).n);
    try expectEqual(@as(usize, 2), M.init(2).n);
    try expectEqual(@as(usize, 3), M.init(3).n);
    try expectEqual(@as(usize, 12), M.init(12).n);
    try expectEqual(@as(usize, 12), M.init(1000).n);
    // The default is the maximum.
    try expectEqual(@as(usize, 12), (M{}).n);
}

test "ring: n keyframes at most, for n = 2, 3 and max" {
    for ([_]usize{ 2, 3, M.max_keyframes }) |n| {
        var r = M.init(n);
        r.reset();
        try expectEqual(n, r.n); // reset keeps the keyframe count
        var snaps: usize = 0;
        // Not a multiple of 30, so the newest keyframe is a real step back.
        for (0..30 * 40 + 5) |_| {
            if (r.record().snapshot) {
                snaps += 1;
                try std.testing.expect(r.count <= n);
            }
        }
        try expectEqual(@as(usize, 40), snaps);
        try expectEqual(n, r.count);
        try expectEqual(@as(u32, @intCast((n - 1) * 30 + 5)), r.history_frames());
        try expectEqual(@as(u8, 5), r.history_fraction());
        // Stepping back reaches exactly n keyframes.
        var steps: usize = 0;
        while (r.step(-1)) |st| {
            steps += 1;
            try std.testing.expect(st.restore < n);
        }
        try expectEqual(n, steps);
    }
}

test "ring: history fraction with fewer keyframes than max" {
    // n = 3: the full span is 2 gaps = 60 frames, not 11 * 30.
    var r = M.init(3);
    r.reset();
    try expectEqual(@as(u8, 0), r.history_fraction());
    for (0..12) |_| _ = r.record();
    try expectEqual(@as(u8, 1), r.history_fraction()); // 12 of 60
    for (0..18) |_| _ = r.record();
    try expectEqual(@as(u8, 3), r.history_fraction()); // 30 of 60
    for (0..30) |_| _ = r.record();
    try expectEqual(@as(u8, 5), r.history_fraction()); // 60 of 60
    for (0..29) |_| _ = r.record();
    try expectEqual(@as(u8, 5), r.history_fraction()); // capped
    // n = 2: one gap of 30 frames.
    var t = M.init(2);
    t.reset();
    for (0..6) |_| _ = t.record();
    try expectEqual(@as(u8, 1), t.history_fraction());
    for (0..9) |_| _ = t.record();
    try expectEqual(@as(u8, 3), t.history_fraction()); // 15 of 30
}

test "ring: the log never overwrites a needed byte when n < max" {
    // Model the frontend's log: `log[log_index(f)]` remembers which frame
    // wrote it. After every record, every frame from the oldest reachable
    // keyframe to live must still be there, including across truncation
    // from a parked keyframe.
    for ([_]usize{ 2, 3, 7, M.max_keyframes }) |n| {
        var r = M.init(n);
        r.reset();
        var log: [M.log_len]u32 = @splat(std.math.maxInt(u32));
        var seed: u32 = @intCast(n);
        for (0..30 * 60) |_| {
            seed = seed *% 1_664_525 +% 1_013_904_223;
            // Now and then park a few keyframes back and play on from there.
            if ((seed >> 24) % 97 == 0) {
                for (0..(seed >> 8) % 4 + 1) |_| _ = r.step(-1);
            }
            const f = r.position();
            const rec = r.record();
            log[rec.log_index] = f;
            try std.testing.expect(r.count <= n);
            var g = r.frame_of_age(r.count - 1);
            while (g < r.live) : (g += 1) {
                try std.testing.expect(r.has_pad(g));
                try expectEqual(g, log[M.log_index(g)]);
            }
        }
    }
}
