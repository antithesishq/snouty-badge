//! The Lynx's sound on the badge speaker (PLAN.md "M5 Sound: contract",
//! Track B): after every stepped frame the core's `audio_out` (735 u8
//! samples, 1/60 s at 44.1 kHz) goes into the new firmware's streaming
//! ring (lib/stream_audio.zig). Old firmware plays nothing (harmless); the
//! wasm simulator has no streaming audio, so the wasm build never starts
//! the ring and the menu hides the Sound row.
//!
//! Rate control. The badge's update rate and the OS's 44.1 kHz drift
//! apart, so each frame pushes `735 + (target - queued) / 8` samples,
//! clamped to `min_push..max_push`, resampled from the 735 by nearest
//! neighbour: the queue settles at `target` (two frames, ~33 ms) and the
//! pitch moves only as much as the drift needs (well under 1% when the
//! update rate is steady). A frame over budget lets the queue run down
//! and the next pushes catch up.
//!
//! Stopping and resuming. When the game stops stepping (the menu, a scrub,
//! the picker; Sound off counts too) one `ramp_len`-sample ramp from the
//! last sample to silence goes out and then nothing, so the OS's
//! underrun padding (silence) follows without a click. The first frame
//! after the start or a resume is preceded by 735 samples of silence, so
//! the queue starts near the target instead of underrunning at once.
//!
//! An underrun is counted when a frame finds the ring empty while sound
//! was already playing (the debug overlay shows the count and the queue).
const core = @import("core");
const stream = @import("stream_audio");

const n_frame = core.audio.samples_per_frame;
const silence = core.audio.silence;

/// Queue the rate control steers to (samples): two frames.
pub const target: i32 = 2 * n_frame;
/// Fewest and most samples one frame pushes (735 -13% / +13%).
pub const min_push: u32 = 640;
pub const max_push: u32 = 830;
/// Samples of the ramp to silence when stepping stops.
pub const ramp_len = 64;
/// Ring size: ~93 ms, room for the target plus the largest push twice.
pub const ring_bytes = 4096;

/// The streaming ring (.bss; the OS reads it from `start` until the cart
/// exits).
pub var ring: [ring_bytes]u8 align(8) = @splat(0);
/// One push's samples: a resampled frame, the silence or the ramp.
var scratch: [max_push]u8 = @splat(0);

/// The Sound menu row (settings bit 0). On at boot in this cart (Adrian
/// asked to hear it; the firmware's Start+Select box has a volume); never
/// on in wasm.
pub var enabled: bool = !is_wasm;
const is_wasm = @import("builtin").cpu.arch.isWasm();

/// The ring was handed to the OS.
var started: bool = false;
/// Frames are being pushed; false after a ramp-out (or before the first).
var playing: bool = false;
/// The last sample pushed, where the ramp starts.
var last: u8 = silence;

/// Frames that found the ring empty while playing.
pub var underruns: u32 = 0;
/// `stream.queued()` at the last frame push, before it.
pub var last_queued: u32 = 0;

/// Samples to push for a frame given the queue: `735 + (target -
/// queued) / 8`, clamped.
pub fn push_count(q_now: u32) u32 {
    const q: i32 = @intCast(@min(q_now, ring_bytes));
    const n: i32 = @as(i32, n_frame) + @divTrunc(target - q, 8);
    return @intCast(@max(@as(i32, min_push), @min(@as(i32, max_push), n)));
}

/// Nearest-neighbour resample of `src` (735) into `dst` (any length up to
/// `max_push`), 16.16 fixed point: identity at 735.
pub fn resample(src: *const [n_frame]u8, dst: []u8) void {
    const step: u32 = (n_frame << 16) / @as(u32, @intCast(dst.len));
    var pos: u32 = 0;
    for (dst) |*d| {
        d.* = src[pos >> 16];
        pos += step;
    }
}

/// `ramp_len` samples from `from` to silence, the last one exactly 128.
/// A running sum in 1/`ramp_len` steps.
pub fn ramp(from: u8, dst: *[ramp_len]u8) void {
    const d: i32 = @as(i32, silence) - from;
    var v: i32 = @as(i32, from) * ramp_len;
    for (dst) |*s| {
        v += d;
        s.* = @intCast(@divFloor(v, ramp_len));
    }
}

/// Call after every stepped frame with the console that stepped.
pub noinline fn frame(l: *const core.Lynx) void {
    if (is_wasm) return;
    if (!enabled) return stop();
    if (!started) {
        stream.start(&ring);
        started = true;
    }
    const q0 = stream.queued();
    if (!playing) {
        // The start or a resume: prime the queue with a frame of silence.
        @memset(scratch[0..n_frame], silence);
        _ = stream.push(scratch[0..n_frame]);
        playing = true;
    } else if (q0 == 0) {
        underruns +%= 1;
    }
    const q = stream.queued();
    last_queued = q;
    const n = push_count(q);
    resample(&l.audio_out, scratch[0..n]);
    _ = stream.push(scratch[0..n]);
    last = scratch[n - 1];
}

/// Call in every update that does not step the game: ramps out once.
pub noinline fn stop() void {
    if (!playing) return;
    playing = false;
    const r: *[ramp_len]u8 = scratch[0..ramp_len];
    ramp(last, r);
    _ = stream.push(r);
    last = silence;
}

/// The queue now (samples), for the overlay.
pub fn queued() u32 {
    return stream.queued();
}
