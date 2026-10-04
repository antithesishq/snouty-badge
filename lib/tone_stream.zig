//! `tone2` for the newer badge firmware (docs/SOUND.md "Streaming audio"):
//! one voice, each `play` cancelling the last, rendered by the cart as
//! 44.1 kHz u8 samples into lib/stream_audio.zig's ring. The newer OS
//! ignores CART_TONE, and writing the old tone words would clobber the
//! ring's ptr/len/head/tail (they are the same IPC words), so a badge
//! build must use this instead of `cart.tone2`. On old firmware nothing
//! plays (its CART_VOLUME reading of the start word is harmless).
//!
//! Shapes follow the cart API's `Tone2Options.Shape` order: square,
//! triangle, sawtooth, sine (a triangle here: the speaker cannot tell),
//! major and minor (root, third and fifth triangles summed; the old OS
//! played nothing for sine/major/minor). Level is linear, 0..127 peak
//! around 128; carts map their old `volume` with `level_from_volume`.
//!
//! Timing: call `update` once per cart update. While a tone sounds it
//! keeps the ring topped up to `target` samples (~32 ms: a 60 Hz update
//! plus the OS's 512-sample DMA reads, with room for a slow frame); when
//! the tone ends it pushes a short release and then nothing, and the OS
//! pads silence. A tone started from silence reaches the speaker on the
//! OS's next DMA buffer; one that cuts a sounding tone waits behind the
//! queued samples (at most `target`). No float: phase is a u32.
//!
//! Drone: a held background voice under the tones (Snouty Zero's
//! engine), two sawtooths 1/64 apart so they beat. `drone` sets its pitch
//! and level, typically every update; both glide there (~12 ms), and a
//! level of 0 fades it out and off. Carts that never call `drone` render
//! exactly as before.
const builtin = @import("builtin");
const stream = @import("stream_audio.zig");

pub const sample_rate = stream.sample_rate;
pub const Shape = enum(u3) { square, triangle, sawtooth, sine, major, minor };

/// Queue kept while sounding (samples).
pub const target: u32 = 1400;
pub const ring_bytes = 4096;
/// Attack and release ramps (samples): no click at the edges.
const edge = 32;
const silence: i32 = 128;

pub const is_wasm = builtin.cpu.arch.isWasm();

var ring: [ring_bytes]u8 align(8) = @splat(128);
var scratch: [512]u8 = @splat(128);
var started = false;

/// Phase increments per voice (3 for a chord, 1 otherwise), 0.32 cycles.
var inc: [3]u32 = @splat(0);
var phase: [3]u32 = @splat(0);
var voices: u2 = 0;
var shape: Shape = .square;
var level: i32 = 0;
/// Samples of tone left to render; `forever` for an infinite tone.
var left: u32 = 0;
pub const forever: u32 = 0xFFFF_FFFF;
/// Samples rendered since the tone started (attack ramp).
var age: u32 = 0;
/// Release samples still to render after the tone ends.
var release_left: u32 = 0;
/// The level the release starts from (the last rendered value - 128).
var last: i32 = 0;

/// The drone: on until its level has faded to 0; phase increment and
/// level (Q8, 0..127 << 8) gliding toward their targets.
var drone_on = false;
var d_inc: u32 = 0;
var d_inc_target: u32 = 0;
var d_phase: [2]u32 = @splat(0);
var d_level: i32 = 0;
var d_level_target: i32 = 0;

/// Old `tone2` volume (0.0..1.0 as 0..100) to a linear peak level.
pub fn level_from_volume(percent: u32) u8 {
    const p: u32 = @min(percent, 100);
    return @intCast(p * 127 / 100);
}

/// Samples in `ms` milliseconds / `ticks` 60 Hz ticks.
pub fn ms(n: u32) u32 {
    return n * sample_rate / 1000;
}
pub fn ticks(n: u32) u32 {
    return n * (sample_rate / 60);
}

fn inc_for(hz_num: u64, hz_den: u64) u32 {
    return @truncate((hz_num << 32) / (hz_den * sample_rate));
}

/// Start a tone (cancels any tone sounding). `hz` 0 or `samples` 0 stops.
pub fn play(hz: u32, samples: u32, peak: u8, s: Shape) void {
    if (comptime is_wasm) return;
    if (hz == 0 or samples == 0 or peak == 0) return stop();
    shape = s;
    level = peak;
    const f: u64 = hz;
    inc[0] = inc_for(f, 1);
    switch (s) {
        .major => {
            inc[1] = inc_for(f * 5, 4);
            inc[2] = inc_for(f * 3, 2);
            voices = 3;
        },
        .minor => {
            inc[1] = inc_for(f * 6, 5);
            inc[2] = inc_for(f * 3, 2);
            voices = 3;
        },
        else => voices = 1,
    }
    // A retrigger while sounding keeps the phase (sweeps stay smooth) and
    // skips the attack.
    if (left == 0 and release_left == 0) {
        phase = @splat(0);
        age = 0;
    } else {
        age = edge;
    }
    release_left = 0;
    left = samples;
}

/// Stop the tone (a short release, then silence).
pub fn stop() void {
    if (left == 0) return;
    left = 0;
    release_left = edge;
}

/// Hold the drone at `hz` and `peak` (gliding from where it is); `hz` or
/// `peak` 0 fades it out. A drone starting from off fades in at `hz`.
pub fn drone(hz: u32, peak: u8) void {
    if (comptime is_wasm) return;
    if (hz == 0 or peak == 0) return drone_stop();
    d_inc_target = inc_for(hz, 1);
    if (!drone_on) {
        d_inc = d_inc_target;
        d_level = 0;
        drone_on = true;
    }
    d_level_target = @as(i32, peak) << 8;
}

/// Fade the drone out (then it is off).
pub fn drone_stop() void {
    d_level_target = 0;
}

/// True while a tone, its release or the drone is still being rendered.
pub fn sounding() bool {
    return left > 0 or release_left > 0 or drone_on;
}

/// Call once per cart update.
pub fn update() void {
    if (comptime is_wasm) return;
    if (!sounding()) return;
    if (!started) {
        stream.start(&ring);
        started = true;
    }
    const q = stream.queued();
    if (q >= target) return;
    var want = @min(target - q, stream.free());
    while (want > 0 and sounding()) {
        const n = render(scratch[0..@min(want, scratch.len)]);
        _ = stream.push(scratch[0..n]);
        want -= n;
    }
}

fn wave(p: u32) i32 {
    const saw: i32 = @as(i32, @intCast(p >> 24)) - 128; // -128..127
    return switch (shape) {
        .square => if (p < 0x8000_0000) 127 else -127,
        .sawtooth => saw,
        // |saw| * 2 - 128: -128..126
        .triangle, .sine, .major, .minor => @as(i32, @intCast(@abs(saw))) * 2 - 128,
    };
}

/// Fill `out` until it is full or the tone and its release are done;
/// returns the count written.
fn render(out: []u8) u32 {
    for (out, 0..) |*o, k| {
        if (!sounding()) return @intCast(k);
        var v: i32 = 0;
        if (left > 0) {
            var sum: i32 = 0;
            for (0..voices) |i| {
                sum += wave(phase[i]);
                phase[i] +%= inc[i];
            }
            v = @divTrunc(sum * level, 128 * @as(i32, voices));
            if (age < edge) {
                v = @divTrunc(v * @as(i32, @intCast(age)), edge);
                age += 1;
            }
            last = v;
            if (left != forever) {
                left -= 1;
                if (left == 0) release_left = edge;
            }
        } else if (release_left > 0) {
            release_left -= 1;
            v = @divTrunc(last * @as(i32, @intCast(release_left)), edge);
        }
        if (drone_on) v += drone_sample();
        o.* = @intCast(@max(0, @min(255, silence + v)));
    }
    return @intCast(out.len);
}

/// One drone sample (-127..127), stepping the glides; turns the drone off
/// once its level has faded to 0.
fn drone_sample() i32 {
    // 1/256 of the pitch gap and 1/512 of the level gap per sample. The
    // arithmetic shift floors, so a falling level reaches 0 exactly.
    const gap: i64 = @as(i64, d_inc_target) - @as(i64, d_inc);
    d_inc = @intCast(@as(i64, d_inc) + (gap >> 8));
    d_level += (d_level_target - d_level) >> 9;
    if (d_level == 0 and d_level_target == 0) {
        drone_on = false;
        return 0;
    }
    const a: i32 = @as(i32, @intCast(d_phase[0] >> 24)) - 128;
    const b: i32 = @as(i32, @intCast(d_phase[1] >> 24)) - 128;
    d_phase[0] +%= d_inc;
    d_phase[1] +%= d_inc +% (d_inc >> 6);
    return @divTrunc((a + b) * (d_level >> 8), 256);
}

// ---- Host tests ----

const std = @import("std");
const testing = std.testing;

fn reset_for_test(r: *stream.Ring) void {
    stream.ring = r;
    started = false;
    left = 0;
    release_left = 0;
    drone_on = false;
    d_level_target = 0;
}

test "tone_stream: a square tone fills to the target, ends in a release, then nothing" {
    var r: stream.Ring = undefined;
    reset_for_test(&r);
    update();
    try testing.expect(!started);
    play(441, ms(50), 100, .square);
    update();
    try testing.expectEqual(@as(u32, target), stream.queued());
    // 441 Hz at 44.1 kHz: 100 samples per cycle, half high after the attack.
    try testing.expectEqual(@as(u8, 128 + 99), ring[40]);
    try testing.expectEqual(@as(u8, 128 - 99), ring[60]);
    // The OS reads everything; the remaining 805 samples + release follow.
    r.tail = r.head;
    update();
    try testing.expectEqual(@as(u32, ms(50) - target + edge), stream.queued());
    try testing.expect(!sounding());
    try testing.expectEqual(@as(u8, 128), ring[(r.head + ring_bytes - 1) % ring_bytes]);
    r.tail = r.head;
    update();
    try testing.expectEqual(@as(u32, 0), stream.queued());
}

test "tone_stream: chords and sweeps stay in range; stop releases" {
    var r: stream.Ring = undefined;
    reset_for_test(&r);
    play(55, forever, 127, .minor);
    update();
    for (ring[0..target]) |s| try testing.expect(s >= 1 and s <= 255);
    const ph = phase[0];
    // A retrigger keeps the phase.
    play(70, forever, 127, .square);
    try testing.expectEqual(ph, phase[0]);
    stop();
    try testing.expect(sounding());
    r.tail = r.head;
    update();
    try testing.expect(!sounding());
    try testing.expectEqual(@as(u32, edge), stream.queued());
}

test "tone_stream: level_from_volume and time helpers" {
    try testing.expectEqual(@as(u8, 76), level_from_volume(60));
    try testing.expectEqual(@as(u8, 127), level_from_volume(150));
    try testing.expectEqual(@as(u32, 735), ticks(1));
    try testing.expectEqual(@as(u32, 4410), ms(100));
}

test "tone_stream: the drone holds the ring, mixes under a tone, fades out and off" {
    var r: stream.Ring = undefined;
    reset_for_test(&r);
    drone(110, 40);
    try testing.expect(sounding());
    // Held: every update tops the ring up again.
    for (0..4) |_| {
        update();
        try testing.expectEqual(@as(u32, target), stream.queued());
        r.tail = r.head;
    }
    // Faded in by now: peaks near the level, never past it.
    var lo: u8 = 255;
    var hi: u8 = 0;
    for (ring) |s| {
        lo = @min(lo, s);
        hi = @max(hi, s);
    }
    try testing.expect(hi >= 128 + 15 and hi <= 128 + 40);
    try testing.expect(lo <= 128 - 15 and lo >= 128 - 41);
    // A full-level tone on top stays in range.
    play(880, ms(20), 127, .square);
    update();
    r.tail = r.head;
    // Pitch glides to the new target.
    drone(220, 40);
    update();
    try testing.expectEqual(inc_for(220, 1), d_inc_target);
    try testing.expect(d_inc > inc_for(200, 1));
    r.tail = r.head;
    // Off: the level fades to 0 within a ring's worth, then nothing.
    drone_stop();
    update();
    r.tail = r.head;
    update();
    try testing.expect(!sounding());
    r.tail = r.head;
    update();
    try testing.expectEqual(@as(u32, 0), stream.queued());
}
