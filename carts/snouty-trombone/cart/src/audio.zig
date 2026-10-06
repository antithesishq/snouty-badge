//! Feeding the voice to the speaker on the show firmware (SPEC section 3,
//! docs/SOUND.md sections 7 and 8): the cart renders 44.1 kHz u8 samples
//! into its own ring through lib/stream_audio.zig. Badge builds never call
//! `cart.tone2` (the newer OS ignores it, and its IPC words are the ring's).
//!
//! Every update tops the ring up to `target` samples. The OS takes 512 at
//! a time, so between updates the queue drops by 512 or 1024; a `target`
//! of 2048 (46 ms) rides out one missed frame (a 33 ms update) without an
//! underrun. If an update ever finds the queue below `low_water` (a frame
//! slower than that), the target grows by 1024 up to `max_target` and only
//! creeps back after 10 s of calm: the latency gives way before the sound
//! crackles. The voice renders always (silence when not blowing), so the
//! ring never drains between notes and a note never waits behind a cold
//! start.
//!
//! Mute is a 64-sample ramp on the way into the ring (the voice and the
//! meters keep running), so muting never clicks.
//!
//! No cart API here: the wasm build (no streaming audio in the pinned
//! simulator) calls `render_only` for the meters and drives the
//! simulator's `tone` import from main.zig.
//!
//! A copy of snouty-theremin's feeder (carts do not import each other).
const stream = @import("stream_audio");
const voice = @import("voice.zig");

pub const ring_len = 4096;
pub const base_target: u32 = 2048;
pub const max_target: u32 = 3584;
pub const low_water: u32 = 256;
pub const target_step: u32 = 1024;
/// Updates without a low-water event before the target shrinks a step (128).
pub const calm_updates: u32 = 600;
/// Mute ramp: gain 0..256 moves this much per sample (64 samples end to end).
const mute_step: i32 = 4;

var ring: [ring_len]u8 align(8) = @splat(128);
var scratch: [512]u8 = @splat(128);

pub const Feeder = struct {
    started: bool = false,
    target: u32 = base_target,
    calm: u32 = 0,
    gain: i32 = 256,
    /// Updates that found the queue below `low_water` (for the bench and
    /// the debug exports).
    lows: u32 = 0,

    /// Badge path: start the ring on the first call, then top it up.
    pub fn feed(f: *Feeder, v: *voice.Voice, muted: bool) void {
        const first = !f.started;
        if (first) {
            stream.start(&ring);
            f.started = true;
        }
        const q = stream.queued();
        // The empty ring at the start is not a slow frame.
        if (!first) f.adapt(q);
        if (q >= f.target) return;
        var want = @min(f.target - q, stream.free());
        while (want > 0) {
            const n = @min(want, scratch.len);
            const chunk = scratch[0..n];
            v.render(chunk);
            f.apply_mute(chunk, muted);
            _ = stream.push(chunk);
            want -= n;
        }
    }

    fn adapt(f: *Feeder, q: u32) void {
        if (q < low_water) {
            f.lows +|= 1;
            f.target = @min(f.target + target_step, max_target);
            f.calm = 0;
        } else if (f.target > base_target) {
            f.calm += 1;
            if (f.calm >= calm_updates) {
                f.target = @max(f.target - 128, base_target);
                f.calm = 0;
            }
        }
    }

    fn apply_mute(f: *Feeder, chunk: []u8, muted: bool) void {
        const goal: i32 = if (muted) 0 else 256;
        if (f.gain == goal and goal == 256) return;
        for (chunk) |*s| {
            if (f.gain < goal) f.gain += mute_step else if (f.gain > goal) f.gain -= mute_step;
            s.* = @intCast(128 + ((@as(i32, s.*) - 128) * f.gain >> 8));
        }
    }

    /// Off the badge: render one update's worth (735 samples) so the
    /// meters move; nothing is played.
    pub fn render_only(f: *Feeder, v: *voice.Voice) void {
        _ = f;
        var left: usize = 735;
        while (left > 0) {
            const n = @min(left, scratch.len);
            v.render(scratch[0..n]);
            left -= n;
        }
    }
};

// ---- Host tests ----

const std = @import("std");
const testing = std.testing;
const horn = @import("horn.zig");

/// What the OS does: take up to 512 queued samples per 512 samples of
/// time, padding a short ring with silence; appends to `out`.
const FakeOs = struct {
    r: *stream.Ring,
    clock: u64 = 0,
    next_mix: u64 = 0,
    underruns: u32 = 0,
    started: bool = false,

    fn advance(os: *FakeOs, samples: u64, out: *std.ArrayList(u8)) !void {
        os.clock += samples;
        while (os.next_mix + 512 <= os.clock) : (os.next_mix += 512) {
            var got: u32 = 0;
            while (got < 512 and os.r.tail != os.r.head) : (got += 1) {
                try out.append(testing.allocator, ring[os.r.tail]);
                os.r.tail = if (os.r.tail + 1 == os.r.len) 0 else os.r.tail + 1;
            }
            if (got > 0) os.started = true;
            if (got < 512 and os.started) {
                os.underruns += 1;
                for (got..512) |_| try out.append(testing.allocator, 128);
            }
        }
    }
};

fn setup(r: *stream.Ring) void {
    stream.ring = r;
}

test "audio: steady 60 Hz updates never underrun and keep the target" {
    var r: stream.Ring = undefined;
    setup(&r);
    var f: Feeder = .{};
    var v: voice.Voice = .{};
    v.set(horn.inc_for(6900), voice.full, false);
    var os: FakeOs = .{ .r = &r };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    for (0..600) |i| {
        f.feed(&v, false);
        if (i > 0) try testing.expectEqual(f.target, stream.queued());
        // 16.74 ms per update, as the OS paces a 60 Hz cart.
        try os.advance(738, &out);
    }
    try testing.expectEqual(@as(u32, 0), os.underruns);
    try testing.expectEqual(@as(u32, 0), f.lows);
    try testing.expectEqual(base_target, f.target);
    // What came out is the voice's own continuous tone, sample for sample.
    var w: voice.Voice = .{};
    w.set(horn.inc_for(6900), voice.full, false);
    var direct: [4096]u8 = undefined;
    w.render(&direct);
    try testing.expectEqualSlices(u8, &direct, out.items[0..4096]);
}

test "audio: one slow frame (35 ms) does not underrun; a very slow one grows the target" {
    var r: stream.Ring = undefined;
    setup(&r);
    var f: Feeder = .{};
    var v: voice.Voice = .{};
    v.set(horn.inc_for(6000), voice.full, false);
    var os: FakeOs = .{ .r = &r };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    for (0..120) |i| {
        f.feed(&v, false);
        try os.advance(if (i == 60) 1544 else 738, &out);
    }
    try testing.expectEqual(@as(u32, 0), os.underruns);
    // A 60 ms stall: the ring runs dry once, the next update sees it and
    // raises the target, and later stalls of that size are absorbed.
    f.feed(&v, false);
    try os.advance(2646, &out);
    f.feed(&v, false);
    try testing.expect(f.target > base_target);
    try testing.expectEqual(@as(u32, 1), f.lows);
    const runs_before = os.underruns;
    for (0..60) |_| {
        f.feed(&v, false);
        try os.advance(738, &out);
    }
    f.feed(&v, false);
    try os.advance(2646, &out);
    f.feed(&v, false);
    try os.advance(738, &out);
    try testing.expectEqual(runs_before, os.underruns);
    // Calm for 10 s: back toward the base target.
    for (0..calm_updates * 8) |_| {
        f.feed(&v, false);
        try os.advance(738, &out);
    }
    try testing.expectEqual(base_target, f.target);
}

test "audio: mute ramps down and back up without a step" {
    var r: stream.Ring = undefined;
    setup(&r);
    var f: Feeder = .{};
    var v: voice.Voice = .{};
    v.set(horn.inc_for(5700), voice.full, false);
    v.jump();
    v.level = voice.full;
    var os: FakeOs = .{ .r = &r };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    for (0..30) |i| {
        f.feed(&v, i >= 10 and i < 20);
        try os.advance(738, &out);
    }
    // While muted (after the ramp and the queue ahead of it): silence.
    var silent: u32 = 0;
    for (out.items) |s| {
        if (s == 128) silent += 1;
    }
    try testing.expect(silent > 735 * 5);
    // The ramp adds no edge bigger than the brass tone's own.
    var worst: i32 = 0;
    for (out.items[1..], out.items[0 .. out.items.len - 1]) |b, a|
        worst = @max(worst, @as(i32, @intCast(@abs(@as(i32, b) - a))));
    try testing.expect(worst <= 100);
    try testing.expectEqual(@as(i32, 256), f.gain);
}
