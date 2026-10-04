//! An emulator's sound into the badge's streaming ring (docs/EMU_SOUND.md):
//! the rate control, the resample, the ramp-out and the resume priming
//! that Snouty Lynx's M5 frontend worked out (lynx/m5-b,
//! carts/snouty-lynx/cart/src/frontend/audio.zig), shared by Snouty Boy,
//! Snouty Gear and Snouty Genesis over lib/stream_audio.zig.
//!
//! Each badge update that steps the game hands `frame` the samples the
//! core made for exactly the console time it stepped (any count up to
//! `cfg.max_src`: a Game Boy frame is ~738.4 samples, two Genesis frames
//! ~1,472). The badge's update rate and the OS's 44.1 kHz drift apart, so
//! `frame` pushes `n + (target - queued) / 8` samples, clamped to
//! `n * 7/8 .. n * 9/8`, resampled from the `n` by nearest neighbour; the
//! queue settles at `target` (2 * `cfg.nominal`) and the pitch moves only
//! as much as the drift needs. `queued` there is a running mean over ~8
//! updates (the OS takes 512 samples per DMA buffer, so the raw queue
//! jumps with the DMA phase; raw, that is an audible vibrato).
//!
//! When the game stops stepping (a menu, a scrub, Sound off) call `stop`
//! every update: one `ramp_len`-sample ramp from the last sample to
//! silence goes out, then nothing, and the OS pads with silence. The first
//! `frame` after the start or a stop pushes `cfg.nominal` samples of
//! silence first so the queue starts near the target.
//!
//! The wasm simulator has no streaming audio: there `frame` and `stop` do
//! nothing (carts keep their simulator `tone` path). Off the badge (host
//! tests) the ring is stream_audio's stand-in.
const builtin = @import("builtin");
const stream = @import("stream_audio.zig");

pub const sample_rate = stream.sample_rate;
pub const silence: u8 = 128;
/// Samples of the ramp to silence when stepping stops.
pub const ramp_len = 64;

pub const is_wasm = builtin.cpu.arch.isWasm();

pub const Config = struct {
    /// Samples one update makes at the console's nominal rate.
    nominal: u32,
    /// Most samples one `frame` may be given.
    max_src: u32,
    /// Ring size in bytes; at least 2 * nominal + max push, power of two
    /// not needed.
    ring_bytes: u32,
};

pub fn Feed(comptime cfg: Config) type {
    return struct {
        const Self = @This();
        pub const target: i32 = 2 * @as(i32, cfg.nominal);
        pub const max_push: u32 = cfg.max_src + cfg.max_src / 8;
        pub const smooth_shift = 3;

        comptime {
            if (cfg.ring_bytes < 2 * cfg.nominal + max_push + 1)
                @compileError("audio_feed: ring too small for the target and a push");
        }

        /// The streaming ring (the OS reads it from `start` until the cart
        /// exits, so the Feed must live in .bss).
        ring: [cfg.ring_bytes]u8 align(8) = @splat(silence),
        /// One push's samples: a resampled frame, the silence or the ramp.
        scratch: [max_push]u8 = @splat(silence),
        started: bool = false,
        /// Frames are being pushed; false after a ramp-out (or before the first).
        playing: bool = false,
        /// The last sample pushed, where the ramp starts.
        last: u8 = silence,
        /// The queue's running mean in 1/16 samples.
        q_smooth: i32 = 0,
        /// Updates that found the ring empty while playing.
        underruns: u32 = 0,
        /// `stream.queued()` at the last push, before it (raw).
        last_queued: u32 = 0,

        /// Samples to push for `n` source samples given the (smoothed) queue.
        pub fn push_count(n: u32, q_now: u32) u32 {
            const q: i32 = @intCast(@min(q_now, cfg.ring_bytes));
            const ni: i32 = @intCast(n);
            const want = ni + @divTrunc(target - q, 8);
            const lo = ni - @divTrunc(ni, 8);
            const hi = ni + @divTrunc(ni, 8);
            return @intCast(@max(@max(lo, 1), @min(hi, want)));
        }

        /// Call after every update that stepped the game, with that
        /// update's samples (1..max_src).
        pub fn frame(self: *Self, src: []const u8) void {
            if (comptime is_wasm) return;
            if (src.len == 0) return;
            if (!self.started) {
                stream.start(&self.ring);
                self.started = true;
            }
            const q0 = stream.queued();
            const resumed = !self.playing;
            if (resumed) {
                @memset(self.scratch[0..cfg.nominal], silence);
                _ = stream.push(self.scratch[0..cfg.nominal]);
                self.playing = true;
            } else if (q0 == 0) {
                self.underruns +%= 1;
            }
            const q = stream.queued();
            self.last_queued = q;
            const q16: i32 = @intCast(q * 16);
            if (resumed) self.q_smooth = q16 else self.q_smooth += (q16 - self.q_smooth) >> smooth_shift;
            const n_src: u32 = @intCast(@min(src.len, cfg.max_src));
            const n = push_count(n_src, @intCast(@max(self.q_smooth, 0) >> 4));
            resample(src[0..n_src], self.scratch[0..n]);
            _ = stream.push(self.scratch[0..n]);
            self.last = self.scratch[n - 1];
        }

        /// Call in every update that does not step the game: ramps out once.
        pub fn stop(self: *Self) void {
            if (comptime is_wasm) return;
            if (!self.playing) return;
            self.playing = false;
            const r: *[ramp_len]u8 = self.scratch[0..ramp_len];
            ramp(self.last, r);
            _ = stream.push(r);
            self.last = silence;
        }

        /// The queue now (samples), for a debug overlay.
        pub fn queued(_: *const Self) u32 {
            return stream.queued();
        }
    };
}

/// Nearest-neighbour resample of `src` into `dst` (16.16 fixed point;
/// the identity when the lengths match).
pub fn resample(src: []const u8, dst: []u8) void {
    const step: u32 = @intCast((@as(u64, src.len) << 16) / dst.len);
    var pos: u32 = 0;
    for (dst) |*d| {
        d.* = src[pos >> 16];
        pos += step;
    }
}

/// `ramp_len` samples from `from` to silence, the last one exactly 128.
pub fn ramp(from: u8, dst: *[ramp_len]u8) void {
    const d: i32 = @as(i32, silence) - from;
    var v: i32 = @as(i32, from) * ramp_len;
    for (dst) |*s| {
        v += d;
        s.* = @intCast(@divFloor(v, ramp_len));
    }
}

// ---- Host tests ----

const std = @import("std");
const testing = std.testing;

test "audio_feed: push_count steers to the target and clamps" {
    const F = Feed(.{ .nominal = 738, .max_src = 760, .ring_bytes = 4096 });
    try testing.expectEqual(@as(u32, 738), F.push_count(738, 1476));
    try testing.expectEqual(@as(u32, 738 + 738 / 8), F.push_count(738, 0));
    try testing.expectEqual(@as(u32, 738 - 8), F.push_count(738, 1476 + 64));
    try testing.expectEqual(@as(u32, 738 - 738 / 8), F.push_count(738, 4095));
    // A short source (739 vs 738) moves the clamp with it.
    try testing.expectEqual(@as(u32, 739), F.push_count(739, 1476));
}

test "audio_feed: resample is the identity at equal lengths, keeps the ends" {
    var src: [738]u8 = undefined;
    for (&src, 0..) |*s, i| s.* = @truncate(i);
    var dst: [830]u8 = undefined;
    resample(&src, dst[0..738]);
    try testing.expectEqualSlices(u8, &src, dst[0..738]);
    resample(&src, &dst);
    try testing.expectEqual(src[0], dst[0]);
    try testing.expectEqual(src[737], dst[829]);
    resample(&src, dst[0..646]);
    try testing.expectEqual(src[0], dst[0]);
}

test "audio_feed: the ramp ends exactly at silence from either side" {
    var r: [ramp_len]u8 = undefined;
    ramp(255, &r);
    try testing.expectEqual(@as(u8, 128), r[ramp_len - 1]);
    for (1..ramp_len) |i| try testing.expect(r[i] <= r[i - 1]);
    ramp(0, &r);
    try testing.expectEqual(@as(u8, 128), r[ramp_len - 1]);
    for (1..ramp_len) |i| try testing.expect(r[i] >= r[i - 1]);
}

/// The fake OS: one 512-sample DMA buffer per 512 samples of time, as the
/// firmware's mixer (sycl-badge upstream 3392a1b drivers/audio.zig).
fn Os(comptime F: type) type {
    return struct {
        r: *stream.Ring,
        f: *F,
        time: u64 = 0,
        starved: u64 = 0,
        read: u64 = 0,

        fn advance(os: *@This(), samples: u64) void {
            os.time += samples;
            while (os.time >= 512) : (os.time -= 512) {
                for (0..512) |_| {
                    if (os.r.tail == os.r.head) {
                        os.starved += 1;
                        continue;
                    }
                    os.read += 1;
                    os.r.tail = if (os.r.tail + 1 == os.r.len) 0 else os.r.tail + 1;
                }
            }
        }
    };
}

fn drift_run(comptime nominal: u32, src_len: u32, update_us: u64) !void {
    const F = Feed(.{ .nominal = nominal, .max_src = nominal + 32, .ring_bytes = 8192 });
    const S = struct {
        var f: F = .{};
    };
    S.f = .{};
    var r: stream.Ring = undefined;
    stream.ring = &r;
    var os: Os(F) = .{ .r = &r, .f = &S.f };
    var src: [nominal + 32]u8 = @splat(200);
    S.f.frame(src[0..src_len]);
    try testing.expectEqual(@as(u32, 8192), r.len);
    var sum: u64 = 0;
    var lo: u32 = 1 << 30;
    // Microsecond time with the fraction carried, so 16,742 us is exact.
    var t_num: u64 = 0;
    for (0..900) |i| {
        t_num += update_us * 44100;
        os.advance(t_num / 1_000_000);
        t_num %= 1_000_000;
        S.f.frame(src[0..src_len]);
        if (i >= 400) {
            sum += S.f.last_queued;
            lo = @min(lo, S.f.last_queued);
        }
    }
    try testing.expectEqual(@as(u32, 0), S.f.underruns);
    try testing.expectEqual(@as(u64, 0), os.starved);
    const mean = sum / 500;
    try testing.expect(mean > 2 * nominal - 96 and mean < 2 * nominal + 96);
    try testing.expect(lo > 256);

    // Stop: one ramp, nothing more.
    const h = r.head;
    S.f.stop();
    try testing.expectEqual(@as(u32, (h + ramp_len) % 8192), r.head);
    S.f.stop();
    try testing.expectEqual(@as(u32, (h + ramp_len) % 8192), r.head);
    // Resume primes with nominal samples of silence before the frame.
    os.advance(44100);
    try testing.expectEqual(@as(u32, 0), stream.queued());
    S.f.frame(src[0..src_len]);
    try testing.expect(stream.queued() >= nominal + src_len - src_len / 8);
}

test "audio_feed: Game Boy frames on the real 59.74 Hz LCD" {
    // 70,224 dots at 4.194304 MHz = 738.4 samples; LCD vsync 16.74 ms.
    try drift_run(738, 738, 16_742);
    try drift_run(738, 739, 16_742);
}

test "audio_feed: Game Gear frames on a badge 1% fast and 1% slow" {
    try drift_run(736, 736, 16_574);
    try drift_run(736, 736, 16_909);
}

test "audio_feed: Genesis two-frame updates at 30 Hz" {
    try drift_run(1472, 1472, 33_484);
}
