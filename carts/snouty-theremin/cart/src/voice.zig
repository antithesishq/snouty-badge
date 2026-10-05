//! The theremin's voice (SPEC section 5): one continuous oscillator
//! rendered as 44.1 kHz unsigned 8-bit samples (128 = silence), the
//! format of the newer firmware's streaming ring (lib/stream_audio.zig).
//!
//! - Phase is a u32 that never resets, so pitch changes are clickless; the
//!   increment glides toward its target every sample (~12 ms), which
//!   turns the 60 Hz pitch updates into smooth slides.
//! - The level glides too: ~6 ms for attacks and volume moves, ~46 ms for
//!   a release (hand gone), so nothing starts or stops with a step.
//! - Saw and square are band-limited with PolyBLEP (the edges are
//!   smoothed over one sample, so high notes do not alias into noise) and
//!   pass a gentle one-pole low-pass (~5 kHz) for the small speaker; sine
//!   is a 256-entry table with linear interpolation; triangle is naive (its
//!   harmonics fall fast enough).
//! - Integer only per sample; `render` specialises its loop per waveform.
//!
//! The last `hist_len` samples rendered are kept for the scope.
const tables = @import("gen/tables.zig");

pub const Wave = enum(u2) {
    sine,
    triangle,
    saw,
    square,

    pub fn label(w: Wave) []const u8 {
        return switch (w) {
            .sine => "SINE",
            .triangle => "TRI",
            .saw => "SAW",
            .square => "SQR",
        };
    }
};

/// Full level (Q16).
pub const full: i32 = 65536;
/// Peak amplitude per waveform (of 127): equal-ish loudness, saw and
/// square carry more energy at the same peak.
const amp = [4]i32{ 120, 120, 100, 84 };
/// Low-pass shift per waveform (0 = none; 1 = a one-pole at ~4.9 kHz).
const lp_shift = [4]u5{ 0, 0, 1, 1 };
/// Per-sample glides: pitch 1/512 of the gap (11.6 ms), level 1/256
/// (5.8 ms) or, releasing, 1/2048 (46 ms).
pub const glide_shift: u6 = 9;
pub const attack_shift: u5 = 8;
pub const release_shift: u5 = 11;

pub const hist_len = 512;
/// Waveform change: duck length (samples) and its level glide (1/32).
pub const duck_len: u16 = 128;
const duck_shift: u5 = 5;

pub const Voice = struct {
    phase: u32 = 0,
    inc: u32 = 0,
    inc_target: u32 = 0,
    /// Q16, 0..full.
    level: i32 = 0,
    level_target: i32 = 0,
    level_shift: u5 = attack_shift,
    wave: Wave = .sine,
    /// Low-pass state (Q15).
    lp: i32 = 0,
    hist: [hist_len]u8 = @splat(128),
    /// Next write position in `hist` (the oldest sample).
    hist_pos: u16 = 0,
    /// A waveform change waiting for the duck to finish.
    next_wave: Wave = .sine,
    duck_left: u16 = 0,

    /// Aim at `inc` and `level` (Q16); `release` uses the slow fade.
    pub fn set(v: *Voice, inc: u32, level: i32, release: bool) void {
        v.inc_target = inc;
        v.level_target = @min(@max(level, 0), full);
        v.level_shift = if (release) release_shift else attack_shift;
    }

    /// Jump straight to the target pitch (a note starting from silence
    /// should not slide in from the last one).
    pub fn jump(v: *Voice) void {
        v.inc = v.inc_target;
    }

    /// Change waveform. While sounding, the level ducks for `duck_len`
    /// samples (~3 ms) first, so the shape change does not click.
    pub fn set_wave(v: *Voice, w: Wave) void {
        if (w == v.wave and v.duck_left == 0) return;
        if (v.level < 512) {
            v.wave = w;
            v.duck_left = 0;
            return;
        }
        v.next_wave = w;
        if (v.duck_left == 0) v.duck_left = duck_len;
    }

    pub fn render(v: *Voice, out: []u8) void {
        var rest = out;
        while (v.duck_left > 0 and rest.len > 0) {
            const n = @min(rest.len, v.duck_left);
            const lt = v.level_target;
            const ls = v.level_shift;
            v.level_target = 0;
            v.level_shift = duck_shift;
            v.dispatch(rest[0..n]);
            v.level_target = lt;
            v.level_shift = ls;
            v.duck_left -= @intCast(n);
            rest = rest[n..];
            if (v.duck_left == 0) v.wave = v.next_wave;
        }
        v.dispatch(rest);
        // Keep the newest samples for the scope.
        const keep = @min(out.len, hist_len);
        for (out[out.len - keep ..]) |s| {
            v.hist[v.hist_pos] = s;
            v.hist_pos = if (v.hist_pos + 1 == hist_len) 0 else v.hist_pos + 1;
        }
    }

    fn dispatch(v: *Voice, out: []u8) void {
        switch (v.wave) {
            inline else => |w| v.render_wave(w, out),
        }
    }

    fn render_wave(v: *Voice, comptime w: Wave, out: []u8) void {
        const a = amp[@backingInt(w)];
        const k = lp_shift[@backingInt(w)];
        var phase = v.phase;
        var inc = v.inc;
        var level = v.level;
        var lp = v.lp;
        const target = v.inc_target;
        const lt = v.level_target;
        const ls = v.level_shift;
        for (out) |*o| {
            const gap: i64 = @as(i64, target) - @as(i64, inc);
            inc = @intCast(@as(i64, inc) + (gap >> glide_shift));
            level += (lt - level) >> ls;
            const y = osc(w, phase, inc);
            if (k == 0) lp = y else lp += (y - lp) >> k;
            const s = (lp * (level >> 1)) >> 15;
            const val = 128 + ((s * a) >> 15);
            o.* = @intCast(@min(@max(val, 0), 255));
            phase +%= inc;
        }
        v.phase = phase;
        v.inc = inc;
        v.level = level;
        v.lp = lp;
    }
};

/// One oscillator sample in Q15 (-32768..32767, PolyBLEP may overshoot a
/// little) at `phase` with increment `inc`.
pub fn osc(comptime w: Wave, phase: u32, inc: u32) i32 {
    switch (w) {
        .sine => {
            const i = phase >> 24;
            const frac: i32 = @intCast((phase >> 8) & 0xFFFF);
            const p0: i32 = tables.sine[i];
            const p1: i32 = tables.sine[i + 1];
            return p0 + (((p1 - p0) * frac) >> 16);
        },
        .triangle => {
            // |saw| folded: -32768 at phase 0, +32767 at half.
            const saw: i32 = @as(i32, @intCast(phase >> 16)) - 32768;
            return @as(i32, @intCast(@abs(saw))) * 2 - 32768;
        },
        .saw => {
            const naive: i32 = @as(i32, @intCast(phase >> 15)) - 65536; // Q16
            return (naive - blep(phase, inc)) >> 1;
        },
        .square => {
            const naive: i32 = if (phase < 0x8000_0000) 65536 else -65536;
            return (naive + blep(phase, inc) - blep(phase +% 0x8000_0000, inc)) >> 1;
        },
    }
}

fn sq16(x: i32) i32 {
    return @intCast((@as(i64, x) * x) >> 16);
}

/// PolyBLEP residual (Q16) for a +2 step at phase 0: -1..0 just after the
/// edge, 0..1 just before, 0 elsewhere.
fn blep(t: u32, dt: u32) i32 {
    if (dt == 0) return 0;
    if (t < dt) {
        const x: i32 = @intCast((@as(u64, t) << 16) / dt); // 0..65535
        return 2 * x - sq16(x) - 65536;
    }
    const before: u32 = 0 -% t; // distance to the edge
    if (before <= dt) {
        const x: i32 = -@as(i32, @intCast((@as(u64, before) << 16) / dt)); // -65536..0
        return sq16(x) + 2 * x + 65536;
    }
    return 0;
}

// ---- Host tests ----

const std = @import("std");
const testing = std.testing;
const pitch = @import("pitch.zig");

fn max_step(s: []const u8) i32 {
    var m: i32 = 0;
    for (s[1..], s[0 .. s.len - 1]) |b, a| m = @max(m, @as(i32, @intCast(@abs(@as(i32, b) - a))));
    return m;
}

test "voice: silent at level 0, ramps in without a step" {
    var v: Voice = .{};
    v.set(pitch.inc_for(6900), 0, false);
    v.jump();
    var buf: [512]u8 = undefined;
    v.render(&buf);
    for (buf) |s| try testing.expectEqual(@as(u8, 128), s);
    // Full level from silence: the first samples are tiny, the attack
    // takes a few ms, and no sample-to-sample step exceeds what a full
    // 440 Hz sine does anyway (2 pi 440 / 44100 * 120 = 7.5).
    v.set(pitch.inc_for(6900), full, false);
    var att: [2048]u8 = undefined;
    v.render(&att);
    try testing.expect(@abs(@as(i32, att[0]) - 128) <= 1);
    try testing.expect(max_step(&att) <= 8);
    var hi: u8 = 0;
    for (att[1500..]) |s| hi = @max(hi, s);
    try testing.expect(hi >= 128 + 115);
}

test "voice: phase stays continuous through a pitch change" {
    var v: Voice = .{};
    v.set(pitch.inc_for(6900), full, false);
    v.jump();
    v.level = full;
    var a: [1000]u8 = undefined;
    v.render(&a);
    const p_before = v.phase;
    const inc_before = v.inc;
    // An octave up, mid-cycle: the next sample continues from where the
    // phase was (no reset) and the slope stays within a 880 Hz sine's.
    v.set(pitch.inc_for(8100), full, false);
    var b: [3000]u8 = undefined;
    v.render(&b);
    // The phase advanced by the sum of the increments: no reset.
    var expect_phase = p_before;
    {
        var w: Voice = .{ .inc = inc_before, .inc_target = pitch.inc_for(8100) };
        for (0..3000) |_| {
            const gap: i64 = @as(i64, w.inc_target) - @as(i64, w.inc);
            w.inc = @intCast(@as(i64, w.inc) + (gap >> glide_shift));
            expect_phase +%= w.inc;
        }
    }
    try testing.expectEqual(expect_phase, v.phase);
    var joined: [4000]u8 = undefined;
    @memcpy(joined[0..1000], &a);
    @memcpy(joined[1000..], &b);
    // 2 pi 880 / 44100 * 120 = 15.0
    try testing.expect(max_step(&joined) <= 16);
    // The increment glides: after one sample it moved 1/512 of the gap.
    try testing.expect(inc_before < v.inc);
    try testing.expect(@abs(@as(i64, v.inc) - pitch.inc_for(8100)) < pitch.inc_for(8100) / 100);
}

test "voice: release fades to silence slowly, never clicks" {
    var v: Voice = .{};
    v.wave = .saw;
    v.set(pitch.inc_for(6000), full, false);
    v.jump();
    var warm: [4096]u8 = undefined;
    v.render(&warm);
    v.set(v.inc_target, 0, true);
    var rel: [44100 / 2]u8 = undefined;
    v.render(&rel);
    // 46 ms time constant: still sounding after 20 ms, gone by 400 ms.
    var hi: i32 = 0;
    for (rel[0..882]) |s| hi = @max(hi, @as(i32, @intCast(@abs(@as(i32, s) - 128))));
    try testing.expect(hi > 40);
    for (rel[44100 * 4 / 10 ..]) |s| try testing.expectEqual(@as(u8, 128), s);
    try testing.expectEqual(@as(i32, 0), v.level);
}

test "voice: every waveform stays in range with a bounded slope, sweeping" {
    inline for (.{ Wave.sine, Wave.triangle, Wave.saw, Wave.square }) |w| {
        var v: Voice = .{ .wave = w };
        v.set(pitch.inc_for(4800), full, false);
        v.jump();
        v.level = full;
        var c: pitch.Cents = 4800;
        var buf: [735]u8 = undefined;
        var prev_last: ?u8 = null;
        while (c < 8400) : (c += 60) {
            v.set(pitch.inc_for(c), full, false);
            v.render(&buf);
            if (prev_last) |p| {
                // Across the chunk boundary nothing jumps either.
                try testing.expect(@abs(@as(i32, buf[0]) - p) < 200);
            }
            prev_last = buf[734];
        }
    }
}

test "voice: band-limited saw has no full-height step even at high pitch" {
    var v: Voice = .{ .wave = .saw };
    v.set(pitch.inc_for(9600), full, false); // C7, 2093 Hz
    v.jump();
    v.level = full;
    var buf: [4410]u8 = undefined;
    v.render(&buf);
    // A naive saw drops the whole 200 in one sample; PolyBLEP plus the
    // low-pass spreads it.
    try testing.expect(max_step(&buf) < 150);
    // Still a saw: it reaches near both peaks.
    var lo: u8 = 255;
    var hi: u8 = 0;
    for (buf[1000..]) |s| {
        lo = @min(lo, s);
        hi = @max(hi, s);
    }
    try testing.expect(hi > 128 + 60 and lo < 128 - 60);
}

test "voice: oscillators are periodic and centred" {
    inline for (.{ Wave.sine, Wave.triangle, Wave.saw, Wave.square }) |w| {
        var sum: i64 = 0;
        const inc: u32 = 1 << 24; // 256 samples a cycle
        var p: u32 = 0;
        for (0..256) |_| {
            sum += osc(w, p, inc);
            p +%= inc;
        }
        // Mean near zero (within 1% of full scale).
        try testing.expect(@abs(@divTrunc(sum, 256)) < 400);
    }
    // The sine table hits its peaks.
    try testing.expectEqual(@as(i32, 32767), osc(.sine, 0x4000_0000, 0));
    try testing.expectEqual(@as(i32, -32767), osc(.sine, 0xC000_0000, 0));
}

test "voice: changing waveform while sounding ducks instead of clicking" {
    var v: Voice = .{};
    v.set(pitch.inc_for(6900), full, false);
    v.jump();
    v.level = full;
    var a: [300]u8 = undefined;
    v.render(&a);
    v.set_wave(.square);
    try testing.expectEqual(Wave.sine, v.wave);
    var b: [2000]u8 = undefined;
    v.render(&b);
    try testing.expectEqual(Wave.square, v.wave);
    // Around the switch (sample duck_len) the output is near silence.
    for (b[duck_len - 4 .. duck_len + 4]) |s| try testing.expect(@abs(@as(i32, s) - 128) <= 6);
    // No step anywhere bigger than the low-passed square's own edges.
    var joined: [2300]u8 = undefined;
    @memcpy(joined[0..300], &a);
    @memcpy(joined[300..], &b);
    var worst_duck: i32 = 0;
    for (joined[1 .. 300 + duck_len + 8], joined[0 .. 300 + duck_len + 7]) |y, x|
        worst_duck = @max(worst_duck, @as(i32, @intCast(@abs(@as(i32, y) - x))));
    try testing.expect(worst_duck <= 8);
    // A silent voice switches at once.
    var q: Voice = .{};
    q.set_wave(.saw);
    try testing.expectEqual(Wave.saw, q.wave);
}

test "voice: history keeps the newest samples for the scope" {
    var v: Voice = .{};
    v.set(pitch.inc_for(6900), full, false);
    var buf: [700]u8 = undefined;
    v.render(&buf);
    // 700 rendered into 512: positions wrapped, the newest at hist_pos - 1.
    const newest = v.hist[(v.hist_pos + hist_len - 1) % hist_len];
    try testing.expectEqual(buf[699], newest);
    try testing.expectEqual(buf[700 - 512], v.hist[v.hist_pos]);
}
