//! The trombone's voice (SPEC section 3): a brass tone rendered as
//! 44.1 kHz unsigned 8-bit samples (128 = silence), the format of the
//! newer firmware's streaming ring (lib/stream_audio.zig). Integer only.
//!
//! - Source: a band-limited (PolyBLEP) sawtooth on a u32 phase that never
//!   resets (pitch moves never click). The phase increment glides toward
//!   its target every sample (~12 ms), so the slide's 60 Hz updates are a
//!   continuous glissando.
//! - Brass: a Chamberlin state-variable low-pass whose cutoff rises with
//!   the level (brass brightens as you blow), in eighth octaves through the
//!   generated coefficient table. TONE MELLOW lowers the whole range.
//! - Attack (`attack`): a "blat" — the cutoff overshoots by ~1.25 octaves
//!   and settles over ~50 ms, the pitch scoops up from ~27 cents flat over
//!   ~40 ms, and a puff of breath noise; a re-tongue while sounding dips
//!   the level for ~4 ms first, so the new attack is heard.
//! - Breath: a little noise under the tone, with the level.
//! - Crack (`crack`): the lip breaks to another partial: the new pitch at
//!   once (landing a little flat), the old one fading out under it over
//!   ~15 ms (the split tone) with a puff of noise.
//! - Plunger mute (`set_mute`): over ~70 ms the cutoff falls ~2.25 octaves
//!   and the filter's resonance rises: closed is a muffled "oo", opening
//!   is the "wah".
//!
//! The last samples' peak is kept for the bell's glow.
const tables = @import("gen/tables.zig");

/// Full level (Q16).
pub const full: i32 = 65536;

// ---- Knobs ----

/// Output peak (of 127) at full level before the soft knee.
pub const amp: i32 = 175;
/// Per-sample glides: pitch 1/512 of the gap (11.6 ms), level 1/128
/// (2.9 ms) attacking, 1/1024 (23 ms) releasing, mute 1/1024.
pub const glide_shift: u5 = 9;
pub const attack_shift: u5 = 7;
pub const release_shift: u5 = 10;
pub const mute_shift: u5 = 10;
/// Re-tongue: samples of level dip (~4 ms) and its fall rate.
pub const dip_len: u16 = 176;
const dip_shift: u5 = 5;
/// Attack: pitch scoop (inc >> 6: ~27 cents flat), cutoff boost (Q8
/// eighth octaves: 1.25 octaves), noise puff (Q15).
const scoop_shift: u5 = 6;
const boost_q8: i32 = 10 * 256;
const puff_attack: i32 = 7000;
/// Crack: the old partial's starting share (Q15), the new pitch's landing
/// scoop (inc >> 7: ~13 cents) and the noise puff.
const crack_env0: i32 = 24000;
const crack_scoop_shift: u5 = 7;
const puff_crack: i32 = 5000;
/// Breath noise at full level (Q15).
const breath: i32 = 650;
/// Cutoff range (Q8 eighth octaves above 50 Hz: index 30 = 670 Hz,
/// 49 = 3.3 kHz), soft to loud, per tone.
const bright_lo: i32 = 30 * 256;
const bright_hi: i32 = 49 * 256;
const mellow_lo: i32 = 25 * 256;
const mellow_hi: i32 = 40 * 256;
/// Plunger: how far it closes the cutoff (2.25 octaves) and the filter
/// damping open and closed (Q15: 1.04 and 0.37, a resonant "oo").
const mute_depth: i32 = 18 * 256;
const q_open: i32 = 34000;
const q_closed: i32 = 15000;
/// The cutoff index never exceeds this (Q8; ~5.4 kHz keeps the filter stable).
const max_index: i32 = 54 * 256;
/// The source pulse's width (of a cycle, as a phase): narrow is buzzy
/// brass, wider is rounder.
const duty_bright: u32 = 0x1C00_0000;
const duty_mellow: u32 = 0x1C00_0000;
/// How much of the filter's band output joins the low-pass (Q15).
const formant: i32 = 12000;
/// Output gain open and with the plunger shut (Q15): the plunger is
/// quieter as well as darker.
const level_gain: i32 = 32767;
const level_gain_closed: i32 = 15000;
/// Soft knee (Q15) before the output scaling.
const knee: i32 = 18000;

pub const Voice = struct {
    phase: u32 = 0,
    inc: u32 = 0,
    inc_target: u32 = 0,
    /// Q16, 0..full.
    level: i32 = 0,
    level_target: i32 = 0,
    level_shift: u5 = attack_shift,
    /// Subtracted from the increment (the attack's and crack's scoop).
    scoop: u32 = 0,
    /// Noise puff (Q15) and cutoff boost (Q8 eighth octaves).
    puff: i32 = 0,
    boost: i32 = 0,
    /// Plunger (Q15, 0 open .. 32768 closed; `mute_q8` is it times 256,
    /// so the glide reaches the end) and its target.
    mute: i32 = 0,
    mute_q8: i32 = 0,
    mute_target: i32 = 0,
    bright: bool = true,
    /// State-variable filter state (Q15).
    low: i32 = 0,
    band: i32 = 0,
    rng: u32 = 0x1234_5678,
    /// The split tone: the old partial fading under the new.
    crack_phase: u32 = 0,
    crack_inc: u32 = 0,
    crack_env: i32 = 0,
    /// Re-tongue dip still to render, then the attack's blat.
    dip_left: u16 = 0,
    /// Peak |sample - 128| of the last samples (the bell's glow).
    peak: i32 = 0,

    /// Aim at `inc` and `level` (Q16); `release` uses the slow fade.
    pub fn set(v: *Voice, inc: u32, level: i32, release: bool) void {
        v.inc_target = inc;
        v.level_target = @min(@max(level, 0), full);
        v.level_shift = if (release) release_shift else attack_shift;
    }

    /// Jump straight to the target pitch (a new note should not slide in
    /// from the last one).
    pub fn jump(v: *Voice) void {
        v.inc = v.inc_target;
    }

    /// A tongued attack (after `set`): the blat, scoop and puff; while
    /// sounding, a short dip first.
    pub fn attack(v: *Voice) void {
        if (v.level > full / 8) {
            v.dip_left = dip_len;
        } else {
            v.blat();
        }
    }

    fn blat(v: *Voice) void {
        v.scoop = v.inc_target >> scoop_shift;
        v.boost = boost_q8;
        v.puff = puff_attack;
    }

    /// The lip cracks to another partial (after `set` with its pitch): the
    /// new pitch at once, the old one fading under it.
    pub fn crack(v: *Voice) void {
        v.crack_phase = v.phase;
        v.crack_inc = v.inc -% v.scoop;
        v.crack_env = crack_env0;
        v.inc = v.inc_target;
        v.scoop = v.inc_target >> crack_scoop_shift;
        v.puff = @max(v.puff, puff_crack);
    }

    pub fn set_mute(v: *Voice, closed: bool) void {
        v.mute_target = if (closed) 32768 else 0;
    }

    pub fn render(v: *Voice, out: []u8) void {
        v.peak -= v.peak >> 2;
        var rest = out;
        while (v.dip_left > 0 and rest.len > 0) {
            const n = @min(rest.len, v.dip_left);
            const lt = v.level_target;
            const ls = v.level_shift;
            v.level_target = 0;
            v.level_shift = dip_shift;
            v.segment(rest[0..n]);
            v.level_target = lt;
            v.level_shift = ls;
            v.dip_left -= @intCast(n);
            rest = rest[n..];
            if (v.dip_left == 0) v.blat();
        }
        v.segment(rest);
    }

    fn segment(v: *Voice, out: []u8) void {
        var phase = v.phase;
        var inc = v.inc;
        var level = v.level;
        var scoop = v.scoop;
        var puff = v.puff;
        var boost = v.boost;
        var mute_q8 = v.mute_q8;
        var low = v.low;
        var band = v.band;
        var rng = v.rng;
        var cphase = v.crack_phase;
        var cenv = v.crack_env;
        var peak = v.peak;
        const cinc = v.crack_inc;
        const target = v.inc_target;
        const lt = v.level_target;
        const ls = v.level_shift;
        const mt = v.mute_target;
        const duty: u32 = if (v.bright) duty_bright else duty_mellow;
        const lo_i: i32 = if (v.bright) bright_lo else mellow_lo;
        const span_i: i32 = (if (v.bright) bright_hi else mellow_hi) - lo_i;
        for (out) |*o| {
            const gap: i64 = @as(i64, target) - @as(i64, inc);
            inc = @intCast(@as(i64, inc) + (gap >> glide_shift));
            scoop -= (scoop >> 9) + @intFromBool(scoop != 0);
            const eff = inc -% scoop;
            level += (lt - level) >> ls;

            var x = pulse(phase, eff, duty);
            if (cenv != 0) {
                const old = pulse(cphase, cinc, duty);
                x = x - ((x * cenv) >> 16) + ((old * cenv) >> 15);
                cphase +%= cinc;
                cenv -= (cenv >> 8) + 1;
                if (cenv < 0) cenv = 0;
            }
            // Breath and the puffs: white noise, shaped by the same filter.
            rng ^= rng << 13;
            rng ^= rng >> 17;
            rng ^= rng << 5;
            const n: i32 = @as(i32, @bitCast(rng)) >> 16; // -32768..32767
            const nz = ((breath * (level >> 1)) >> 15) + puff;
            x += (n * nz) >> 15;
            puff -= (puff >> 10) + @intFromBool(puff != 0);
            boost -= (boost >> 11) + @intFromBool(boost != 0);
            mute_q8 += ((mt << 8) - mute_q8) >> mute_shift;
            const mute = mute_q8 >> 8;

            // Cutoff: brighter with level, the attack's boost, darker with
            // the plunger; resonance rises as it closes.
            var idx = lo_i + ((span_i * (level >> 8)) >> 8) + boost - ((mute_depth * mute) >> 15);
            idx = @min(@max(idx, 0), max_index);
            const ti: usize = @intCast(idx >> 8);
            const fr = idx & 255;
            const f: i64 = tables.svf_f_q15[ti] + (((tables.svf_f_q15[ti + 1] - tables.svf_f_q15[ti]) * fr) >> 8);
            const q: i64 = q_open - (((q_open - q_closed) * mute) >> 15);
            low += @intCast((f * band) >> 15);
            const high: i32 = x - low - @as(i32, @intCast((q * band) >> 15));
            band += @intCast((f * high) >> 15);
            // The low-pass plus some of the band around the cutoff: the
            // brass formant (and the plunger's vowel as it moves).
            const y = low + @as(i32, @intCast((@as(i64, band) * formant) >> 15));
            const g = level_gain - (((level_gain - level_gain_closed) * mute) >> 15);

            var s: i32 = @intCast((@as(i64, y) * ((level >> 1) * g >> 15)) >> 15);
            if (s > knee) s = knee + ((s - knee) >> 2) else if (s < -knee) s = -knee + ((s + knee) >> 2);
            const val = 128 + ((s * amp) >> 15);
            const c: u8 = @intCast(@min(@max(val, 0), 255));
            o.* = c;
            peak = @max(peak, @as(i32, @intCast(@abs(@as(i32, c) - 128))));
            phase +%= eff;
        }
        v.phase = phase;
        v.inc = inc;
        v.level = level;
        v.scoop = scoop;
        v.puff = puff;
        v.boost = boost;
        v.mute_q8 = mute_q8;
        v.mute = mute_q8 >> 8;
        v.low = low;
        v.band = band;
        v.rng = rng;
        v.crack_phase = cphase;
        v.crack_env = cenv;
        v.peak = peak;
    }
};

/// A band-limited sawtooth sample in Q15 (PolyBLEP may overshoot a little)
/// at `phase` with increment `inc`.
pub fn saw(phase: u32, inc: u32) i32 {
    const naive: i32 = @as(i32, @intCast(phase >> 15)) - 65536; // Q16
    return (naive - blep(phase, inc)) >> 1;
}

/// A band-limited pulse (two PolyBLEP saws `duty` apart) in Q15, zero mean.
pub inline fn pulse(phase: u32, inc: u32, duty: u32) i32 {
    return (saw(phase, inc) - saw(phase +% duty, inc)) >> 1;
}

fn sq16(x: i32) i32 {
    return @intCast((@as(i64, x) * x) >> 16);
}

/// PolyBLEP residual (Q16) for a +2 step at phase 0: -1..0 just after the
/// edge, 0..1 just before, 0 elsewhere. Divides only beside an edge.
fn blep(t: u32, dt: u32) i32 {
    if (dt == 0) return 0;
    if (t < dt) {
        const x: i32 = @intCast((@as(u64, t) << 16) / dt);
        return 2 * x - sq16(x) - 65536;
    }
    const before: u32 = 0 -% t;
    if (before <= dt) {
        const x: i32 = -@as(i32, @intCast((@as(u64, before) << 16) / dt));
        return sq16(x) + 2 * x + 65536;
    }
    return 0;
}

// ---- Host tests ----

const std = @import("std");
const testing = std.testing;
const horn = @import("horn.zig");

fn max_step(s: []const u8) i32 {
    var m: i32 = 0;
    for (s[1..], s[0 .. s.len - 1]) |b, a| m = @max(m, @as(i32, @intCast(@abs(@as(i32, b) - a))));
    return m;
}

/// Mean |second difference|: how much high-frequency content there is.
fn roughness(s: []const u8) i64 {
    var sum: i64 = 0;
    for (2..s.len) |i| sum += @intCast(@abs(@as(i64, s[i]) - 2 * @as(i64, s[i - 1]) + s[i - 2]));
    return @divTrunc(sum * 1000, @as(i64, @intCast(s.len)));
}

fn rms(s: []const u8) i64 {
    var sum: i64 = 0;
    for (s) |x| sum += (@as(i64, x) - 128) * (@as(i64, x) - 128);
    return std.math.sqrt(@as(u64, @intCast(@divTrunc(sum, @as(i64, @intCast(s.len))))));
}

/// The nearest whole-cycle period (samples) of `s` around `inc`'s, by
/// autocorrelation: the pitch actually sounding.
fn period_of(s: []const u8, guess: f64) f64 {
    var best: f64 = 0;
    var best_lag: usize = 0;
    const lo: usize = @intFromFloat(guess * 0.8);
    const hi: usize = @intFromFloat(guess * 1.25);
    for (lo..hi) |lag| {
        var acc: f64 = 0;
        for (0..s.len - lag) |i| acc += (@as(f64, @floatFromInt(s[i])) - 128) * (@as(f64, @floatFromInt(s[i + lag])) - 128);
        if (acc > best) {
            best = acc;
            best_lag = lag;
        }
    }
    return @floatFromInt(best_lag);
}

test "voice: silent at level 0, the attack ramps in without a click" {
    var v: Voice = .{};
    v.set(horn.inc_for(5800), 0, true);
    v.jump();
    var buf: [1024]u8 = undefined;
    v.render(&buf);
    for (buf) |s| try testing.expectEqual(@as(u8, 128), s);
    v.set(horn.inc_for(5800), full, false);
    v.attack();
    var att: [4410]u8 = undefined;
    v.render(&att);
    // The first sample is near silence and nothing jumps more than the
    // tone's own steepest edge once it is loud.
    try testing.expect(@abs(@as(i32, att[0]) - 128) <= 2);
    var early: i32 = 0;
    for (att[0..32]) |s| early = @max(early, @as(i32, @intCast(@abs(@as(i32, s) - 128))));
    try testing.expect(early < 60);
    // Loud after 100 ms, and the blat: the first 40 ms are brighter than
    // the settled tone.
    try testing.expect(rms(att[2205..]) > 30);
    var settled: [4410]u8 = undefined;
    v.render(&settled);
    try testing.expect(roughness(att[200..1800]) > roughness(settled[200..1800]));
}

test "voice: the pitch sounding is the pitch asked, at every partial" {
    for (2..9) |n| {
        var v: Voice = .{};
        const c = horn.pitch(@intCast(n), 300, 0);
        v.set(horn.inc_for(c), full, false);
        v.jump();
        var warm: [8820]u8 = undefined;
        v.render(&warm);
        var buf: [4410]u8 = undefined;
        v.render(&buf);
        const hz: f64 = @floatFromInt(horn.hz_of(horn.inc_for(c)));
        const want = 44100.0 / hz;
        const got = period_of(&buf, want);
        try testing.expect(@abs(got - want) <= 1.0 + want * 0.01);
    }
}

test "voice: a slide gliss is continuous, a release fades to silence" {
    var v: Voice = .{};
    v.set(horn.inc_for(horn.pitch(4, 0, 0)), full, false);
    v.jump();
    var buf: [735]u8 = undefined;
    v.render(&buf);
    // Seven positions down over 0.5 s at 60 Hz updates: never a big jump
    // between consecutive samples beyond the saw's band-limited edge.
    var worst: i32 = 0;
    var prev: u8 = buf[734];
    for (0..30) |i| {
        v.set(horn.inc_for(horn.pitch(4, @intCast(i * 20), 0)), full, false);
        v.render(&buf);
        worst = @max(worst, @as(i32, @intCast(@abs(@as(i32, buf[0]) - prev))));
        worst = @max(worst, max_step(&buf));
        prev = buf[734];
    }
    try testing.expect(worst < 90);
    // Release: still sounding at 10 ms, silent by 300 ms, exactly 128.
    v.set(v.inc_target, 0, true);
    var rel: [44100 / 2]u8 = undefined;
    v.render(&rel);
    try testing.expect(rms(rel[0..441]) > 15);
    for (rel[44100 * 3 / 10 ..]) |s| try testing.expectEqual(@as(u8, 128), s);
}

test "voice: a crack jumps to the new partial with a short split tone" {
    var v: Voice = .{};
    const c4 = horn.pitch(4, 0, 0);
    const c5 = horn.pitch(5, 0, 0);
    v.set(horn.inc_for(c4), full, false);
    v.jump();
    var warm: [8820]u8 = undefined;
    v.render(&warm);
    v.set(horn.inc_for(c5), full, false);
    v.crack();
    try testing.expectEqual(horn.inc_for(c5), v.inc);
    try testing.expect(v.crack_env > 0);
    var split: [2205]u8 = undefined;
    v.render(&split);
    // Gone within 50 ms, and the new pitch is what sounds afterwards.
    try testing.expectEqual(@as(i32, 0), v.crack_env);
    var after: [4410]u8 = undefined;
    v.render(&after);
    const want = 44100.0 / @as(f64, @floatFromInt(horn.hz_of(horn.inc_for(c5))));
    try testing.expect(@abs(period_of(&after, want) - want) <= 1.5);
    // The split is not a click: bounded steps.
    try testing.expect(max_step(&split) < 100);
}

test "voice: the plunger closes darker and opens again (the wah)" {
    var v: Voice = .{};
    v.set(horn.inc_for(horn.pitch(4, 0, 0)), full, false);
    v.jump();
    var open: [8820]u8 = undefined;
    v.render(&open);
    v.render(&open);
    v.set_mute(true);
    var closing: [4410]u8 = undefined;
    v.render(&closing);
    var closed: [4410]u8 = undefined;
    v.render(&closed);
    try testing.expect(v.mute > 32000);
    // Much less high-frequency content muted, still clearly sounding.
    try testing.expect(roughness(&closed) * 2 < roughness(open[4410..]));
    try testing.expect(rms(&closed) > 12);
    // About 70 ms to close: halfway there after 20 ms, nearly shut by 100.
    var w: Voice = .{};
    w.set_mute(true);
    var tmp: [882]u8 = undefined;
    w.render(&tmp);
    try testing.expect(w.mute > 12000 and w.mute < 26000);
    v.set_mute(false);
    var reopen: [4410]u8 = undefined;
    v.render(&reopen);
    try testing.expect(v.mute < 1500);
    try testing.expect(roughness(reopen[2205..]) > roughness(&closed));
}

test "voice: a re-tongue dips and blats again" {
    var v: Voice = .{};
    v.set(horn.inc_for(5800), full, false);
    v.jump();
    var warm: [8820]u8 = undefined;
    v.render(&warm);
    v.attack();
    try testing.expectEqual(dip_len, v.dip_left);
    var buf: [2205]u8 = undefined;
    v.render(&buf);
    try testing.expectEqual(@as(u16, 0), v.dip_left);
    // The dip: quiet around its end, loud again after.
    try testing.expect(rms(buf[dip_len - 40 .. dip_len]) < @divTrunc(rms(warm[4000..8000]), 2));
    try testing.expect(rms(buf[1200..]) > 30);
    try testing.expect(v.boost > 0);
}

test "voice: stays in range, rarely clips, everywhere in the horn" {
    for ([_]bool{ true, false }) |bright| for ([_]bool{ false, true }) |muted| {
        var v: Voice = .{ .bright = bright };
        v.set_mute(muted);
        var clipped: u32 = 0;
        var total: u32 = 0;
        var buf: [735]u8 = undefined;
        var c: i32 = horn.pitch(1, horn.slide_max, -40);
        v.set(horn.inc_for(c), full, false);
        v.jump();
        v.attack();
        while (c < horn.pitch(8, 0, 40)) : (c += 25) {
            v.set(horn.inc_for(c), full, false);
            v.render(&buf);
            for (buf) |s| {
                if (s == 0 or s == 255) clipped += 1;
            }
            total += buf.len;
        }
        try testing.expect(clipped * 200 < total);
    };
}

test "voice: saw is periodic and centred" {
    var sum: i64 = 0;
    const inc: u32 = 1 << 24;
    var p: u32 = 0;
    for (0..256) |_| {
        sum += saw(p, inc);
        p +%= inc;
    }
    try testing.expect(@abs(@divTrunc(sum, 256)) < 400);
}
