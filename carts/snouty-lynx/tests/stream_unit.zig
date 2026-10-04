//! cart/src/frontend/audio.zig (M5 Track B): the rate control, the
//! resample, the ramp and the stop/resume sequence, against
//! lib/stream_audio.zig's ring with a fake OS that drains 512 samples per
//! 512 samples of 44.1 kHz time, as the firmware's mixer does
//! (sycl-badge upstream 3392a1b drivers/audio.zig `mix_buffer_samples`).
const std = @import("std");
const core = @import("core");
const stream = @import("stream_audio");
const audio = @import("frontend_audio");
const testing = std.testing;

const n_frame = core.audio.samples_per_frame;

test "stream: push_count steers to the target and clamps" {
    try testing.expectEqual(@as(u32, 735), audio.push_count(1470));
    try testing.expectEqual(@as(u32, 735 + 735 / 8), audio.push_count(735));
    try testing.expectEqual(@as(u32, 735 - 8), audio.push_count(1470 + 64));
    try testing.expectEqual(audio.max_push, audio.push_count(0));
    try testing.expectEqual(audio.min_push, audio.push_count(4095));
}

test "stream: resample is the identity at 735 and nearest-neighbour otherwise" {
    var src: [n_frame]u8 = undefined;
    for (&src, 0..) |*s, i| s.* = @truncate(i);
    var dst: [audio.max_push]u8 = undefined;
    audio.resample(&src, dst[0..n_frame]);
    try testing.expectEqualSlices(u8, &src, dst[0..n_frame]);
    // Longer: every source sample at most twice, in order, first and
    // last kept.
    audio.resample(&src, dst[0..audio.max_push]);
    try testing.expectEqual(src[0], dst[0]);
    try testing.expectEqual(src[n_frame - 1], dst[audio.max_push - 1]);
    // Shorter: monotonic source indices within the frame.
    var idx: [n_frame]u16 = undefined;
    for (&idx, 0..) |*s, i| s.* = @intCast(i);
    var prev: i32 = -1;
    for (0..audio.min_push) |i| {
        const pos = (i * ((n_frame << 16) / audio.min_push)) >> 16;
        try testing.expect(@as(i32, @intCast(pos)) > prev);
        prev = @intCast(pos);
    }
    try testing.expect(prev <= n_frame - 1);
}

test "stream: the ramp ends exactly at silence from either side" {
    var r: [audio.ramp_len]u8 = undefined;
    audio.ramp(255, &r);
    try testing.expectEqual(@as(u8, 128), r[audio.ramp_len - 1]);
    try testing.expect(r[0] < 255 and r[0] >= 252);
    for (1..audio.ramp_len) |i| try testing.expect(r[i] <= r[i - 1]);
    audio.ramp(0, &r);
    try testing.expectEqual(@as(u8, 128), r[audio.ramp_len - 1]);
    for (1..audio.ramp_len) |i| try testing.expect(r[i] >= r[i - 1]);
    audio.ramp(128, &r);
    for (r) |s| try testing.expectEqual(@as(u8, 128), s);
}

/// The console only for its `audio_out` (66 KB: a static).
var lynx: core.Lynx = undefined;

/// The fake OS: one 512-sample DMA buffer per 512 samples of time.
const Os = struct {
    r: *stream.Ring,
    /// 44.1 kHz samples of time not yet turned into DMA buffers.
    time: u64 = 0,
    starved: u64 = 0,
    out: std.ArrayList(u8) = .empty,

    fn advance(os: *Os, samples: u64) !void {
        os.time += samples;
        while (os.time >= 512) : (os.time -= 512) {
            for (0..512) |_| {
                if (os.r.tail == os.r.head) {
                    os.starved += 1;
                    try os.out.append(testing.allocator, 128);
                    continue;
                }
                try os.out.append(testing.allocator, audio.ring[os.r.tail]);
                os.r.tail = if (os.r.tail + 1 == os.r.len) 0 else os.r.tail + 1;
            }
        }
    }
};

test "stream: the queue settles at the target under drift, stop ramps, resume primes" {
    var r: stream.Ring = .{ .ptr = 0, .len = 0, .head = 0, .tail = 0 };
    stream.ring = &r;
    @memset(&lynx.audio_out, 200);

    // Off (the default build): a frame neither starts the ring nor pushes.
    audio.enabled = false;
    audio.frame(&lynx);
    try testing.expectEqual(@as(u32, 0), r.len);
    audio.enabled = true;
    var os: Os = .{ .r = &r };
    defer os.out.deinit(testing.allocator);

    // The first frame starts the ring: a frame of silence, then the frame.
    audio.frame(&lynx);
    try testing.expectEqual(@as(u32, 4096), r.len);
    try testing.expectEqual(@as(u32, @truncate(@intFromPtr(&audio.ring))), r.ptr);
    try testing.expectEqual(@as(u32, n_frame + audio.max_push - 4), stream.queued());

    // 600 frames of a badge running 0.5% slow (an update every 16.75 ms):
    // the OS reads 44,100 samples a second regardless.
    // The queue before each push, averaged over the last 300 frames,
    // sits at the target (the 512-sample DMA reads make it jitter).
    const per_update: u64 = 44100 * 16750 / 1_000_000;
    var sum: u64 = 0;
    var lo: u32 = 4096;
    for (0..600) |i| {
        try os.advance(per_update);
        audio.frame(&lynx);
        if (i >= 300) {
            sum += audio.last_queued;
            lo = @min(lo, audio.last_queued);
        }
    }
    try testing.expectEqual(@as(u32, 0), audio.underruns);
    try testing.expectEqual(@as(u64, 0), os.starved);
    const mean = sum / 300;
    try testing.expect(mean > 1470 - 64 and mean < 1470 + 64);
    try testing.expect(lo > 512);
    const q = stream.queued();

    // Stop: one ramp, then nothing more however long the menu stays.
    audio.stop();
    const after_ramp = stream.queued();
    try testing.expectEqual(q + audio.ramp_len, after_ramp);
    audio.stop();
    try testing.expectEqual(after_ramp, stream.queued());
    os.out.clearRetainingCapacity();
    try os.advance(44100);
    try testing.expectEqual(@as(u32, 0), stream.queued());
    // The drained stream ends in the ramp down to 128, then the OS's
    // padding.
    const heard = os.out.items;
    const ramp_end = std.mem.indexOfScalar(u8, heard, 128).?;
    try testing.expectEqual(@as(u8, 200), heard[ramp_end - audio.ramp_len]);
    for (heard[ramp_end..]) |s| try testing.expectEqual(@as(u8, 128), s);

    // Resume: a frame of silence first, no underrun counted.
    audio.frame(&lynx);
    try testing.expectEqual(@as(u32, 0), audio.underruns);
    try testing.expectEqual(@as(u32, n_frame + audio.max_push - 4), stream.queued());

    // A badge stalled for 100 ms drains the queue: the next frame counts
    // an underrun.
    try os.advance(4410);
    audio.frame(&lynx);
    try testing.expectEqual(@as(u32, 1), audio.underruns);

    // Sound off: one ramp out, nothing more.
    audio.enabled = false;
    const q_off = stream.queued();
    audio.frame(&lynx);
    try testing.expectEqual(q_off + audio.ramp_len, stream.queued());
    audio.frame(&lynx);
    try testing.expectEqual(q_off + audio.ramp_len, stream.queued());
    audio.enabled = true;

    // A 441 Hz square wave across frame edges (period 100 samples, phase
    // carried from frame to frame) on a badge 0.5% fast: the OS hears it
    // at 441 Hz within the rate control's wobble, with no glitch where
    // frames join (every run between edges is ~50 samples long).
    const fast: u64 = 44100 * 16583 / 1_000_000;
    var phase: u32 = 0;
    const starved0 = os.starved;
    for (0..240) |_| {
        for (&lynx.audio_out) |*o| {
            o.* = if (phase < 50) 192 else 64;
            phase = (phase + 1) % 100;
        }
        audio.frame(&lynx);
        try os.advance(fast);
    }
    try testing.expectEqual(starved0, os.starved);
    const tail = os.out.items[os.out.items.len - 44100 ..];
    // Runs between edges; the first (cut by the window) is not counted.
    var rising: u32 = 0;
    var run: u32 = 0;
    var edges: u32 = 0;
    var shortest: u32 = 1000;
    var longest: u32 = 0;
    for (tail[1..], tail[0 .. tail.len - 1]) |cur, prev| {
        run += 1;
        if (cur != prev) {
            if (cur > prev) rising += 1;
            if (edges > 0) {
                shortest = @min(shortest, run);
                longest = @max(longest, run);
            }
            edges += 1;
            run = 0;
        }
    }
    // The badge runs 0.5% fast, so the game's time does too: 441 Hz *
    // 735 / 731.3 = 443 Hz, as the rate control must give.
    try testing.expect(rising >= 441 and rising <= 446);
    try testing.expect(shortest >= 49 and longest <= 51);
}
