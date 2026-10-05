//! EYES sound mode (SPEC section 2): the hand's zone histogram played as
//! a single-cycle wavetable at a pitch from the hand's distance, so the
//! hand shapes the timbre (where its peak sits against the crosstalk and
//! the wall changes the waveform's harmonics) as well as the pitch.
//!
//! - `table_from_histogram`: 64 bins from just past the crosstalk peak
//!   (bins 16..79, about 0.05..3.7 m), log-compressed, floor removed, DC
//!   removed, smoothed ([1 2 1]/4, circular) and normalised to Q15.
//! - `Voice`: a continuous phase (u32, never reset) over the table with
//!   linear interpolation; pitch and level glide per sample like the
//!   theremin's voice; a new table crossfades from the current sound over
//!   `xfade_samples` (~180 ms; histogram sets arrive a few times a second)
//!   so a new set never clicks or zippers; a gentle one-pole low-pass for
//!   the small speaker.
//! - `Feeder`: tops lib/stream_audio.zig's ring up every update (a local
//!   copy of snouty-theremin's feeder: target 2048 samples, grows on a
//!   slow frame, 64-sample mute ramp). Badge builds never call
//!   `cart.tone2`. Off the badge `render_only` keeps the voice moving.
//!
//! Integer only; no cart API (host tests in host_tests.zig).
const stream = @import("stream_audio");

pub const sample_rate = stream.sample_rate;
pub const table_len = 64;
pub const first_bin = 16;
pub const full: i32 = 65536;
/// Crossfade to a new table: 65536 / xfade_step samples (~180 ms).
pub const xfade_step: i32 = 8;
pub const glide_shift: u6 = 9;
pub const attack_shift: u5 = 8;
pub const release_shift: u5 = 11;
/// Peak amplitude of 127.
const amp: i32 = 110;

pub const Table = [table_len]i16;

/// The wavetable for one zone's 128-bin histogram (24-bit counts).
pub fn table_from_histogram(bins: *const [128]u32, out: *Table) void {
    var v: [table_len]i32 = undefined;
    var lo: i32 = std.math.maxInt(i32);
    for (&v, 0..) |*x, i| {
        x.* = @intCast(log2_fix(bins[first_bin + i]));
        lo = @min(lo, x.*);
    }
    var sum: i32 = 0;
    for (&v) |*x| {
        x.* -= lo;
        sum += x.*;
    }
    const mean = @divTrunc(sum, table_len);
    var sm: [table_len]i32 = undefined;
    var peak: i32 = 1;
    for (0..table_len) |i| {
        const a = v[(i + table_len - 1) % table_len];
        const b = v[i];
        const c = v[(i + 1) % table_len];
        sm[i] = @divTrunc(a + 2 * b + c, 4) - mean;
        peak = @max(peak, @as(i32, @intCast(@abs(sm[i]))));
    }
    for (out, sm) |*o, x| o.* = @intCast(@divTrunc(x * 32000, peak));
}

fn log2_fix(v: u32) u32 {
    if (v == 0) return 0;
    const e: u32 = 31 - @clz(v);
    const frac: u32 = if (e >= 4) (v >> @intCast(e - 4)) & 0xF else (v << @intCast(4 - e)) & 0xF;
    return e * 16 + frac + 1;
}

/// Phase increment for `mm`: 880 Hz at 80 mm down three octaves to 110 Hz
/// at 1200 mm (equal-tempered in between), clamped.
pub fn inc_for_mm(mm: u32) u32 {
    const d: u32 = @min(@max(mm, 80), 1200) - 80;
    // Sixteenths of a semitone below A5.
    const st16: u32 = d * 36 * 16 / 1120;
    const oct = st16 / 192;
    const rem = st16 % 192;
    const k = rem / 16;
    const frac = rem % 16;
    const a: u64 = semitone_q16[k];
    const b: u64 = if (k + 1 < 12) semitone_q16[k + 1] else semitone_q16[0] / 2;
    const ratio = (a * (16 - frac) + b * frac) / 16; // Q16
    return @intCast((inc_880 * ratio >> 16) >> @intCast(oct));
}

/// 2^(-k/12) in Q16.
const semitone_q16 = [12]u32{ 65536, 61858, 58386, 55109, 52016, 49097, 46341, 43740, 41285, 38968, 36781, 34716 };
const inc_880: u64 = (@as(u64, 880) << 32) / sample_rate;

pub fn hz_of(inc: u32) u32 {
    return @intCast((@as(u64, inc) * sample_rate + (1 << 31)) >> 32);
}

pub const Voice = struct {
    phase: u32 = 0,
    inc: u32 = 0,
    inc_target: u32 = 0,
    level: i32 = 0,
    level_target: i32 = 0,
    level_shift: u5 = attack_shift,
    cur: Table = @splat(0),
    next: Table = @splat(0),
    /// 0..65536 from `cur` to `next`.
    xf: i32 = full,
    lp: i32 = 0,

    pub fn set(v: *Voice, inc: u32, level: i32, release: bool) void {
        v.inc_target = inc;
        v.level_target = @min(@max(level, 0), full);
        v.level_shift = if (release) release_shift else attack_shift;
    }

    /// Jump to the target pitch (a note starting from silence).
    pub fn jump(v: *Voice) void {
        v.inc = v.inc_target;
    }

    /// Crossfade to `t`: what is sounding now becomes the start.
    pub fn set_table(v: *Voice, t: *const Table) void {
        for (&v.cur, v.next) |*c, n| {
            c.* = @intCast(c.* + ((@as(i32, n) - c.*) * (v.xf >> 2) >> 14));
        }
        v.next = t.*;
        v.xf = 0;
    }

    pub fn render(v: *Voice, out: []u8) void {
        var phase = v.phase;
        var inc = v.inc;
        var level = v.level;
        var lp = v.lp;
        var xf = v.xf;
        const target = v.inc_target;
        const lt = v.level_target;
        const ls = v.level_shift;
        for (out) |*o| {
            const gap: i64 = @as(i64, target) - @as(i64, inc);
            inc = @intCast(@as(i64, inc) + (gap >> glide_shift));
            level += (lt - level) >> ls;
            const i: usize = phase >> 26;
            const j = (i + 1) % table_len;
            // Q14 fractions keep the products inside i32.
            const frac: i32 = @intCast((phase >> 12) & 0x3FFF);
            const b0: i32 = v.next[i];
            const b = b0 + (((@as(i32, v.next[j]) - b0) * frac) >> 14);
            var y = b;
            if (xf < full) {
                const a0: i32 = v.cur[i];
                const a = a0 + (((@as(i32, v.cur[j]) - a0) * frac) >> 14);
                y = a + (((b - a) * (xf >> 2)) >> 14);
                xf += xfade_step;
            }
            lp += (y - lp) >> 1;
            const s = (lp * (level >> 1)) >> 15;
            const val = 128 + ((s * amp) >> 15);
            o.* = @intCast(@min(@max(val, 0), 255));
            phase +%= inc;
        }
        if (xf >= full) {
            xf = full;
        }
        v.phase = phase;
        v.inc = inc;
        v.level = level;
        v.lp = lp;
        v.xf = xf;
    }
};

pub const ring_len = 4096;
pub const base_target: u32 = 2048;
pub const max_target: u32 = 3584;
pub const low_water: u32 = 256;
pub const target_step: u32 = 1024;
pub const calm_updates: u32 = 600;
const mute_step: i32 = 4;

var ring: [ring_len]u8 align(8) = @splat(128);
var scratch: [512]u8 = @splat(128);

pub const Feeder = struct {
    started: bool = false,
    target: u32 = base_target,
    calm: u32 = 0,
    gain: i32 = 0,
    lows: u32 = 0,

    /// Badge path: start the ring on the first call, then top it up.
    pub fn feed(f: *Feeder, v: *Voice, muted: bool) void {
        const first = !f.started;
        if (first) {
            stream.start(&ring);
            f.started = true;
        }
        const q = stream.queued();
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

    /// Off the badge: render one update's worth so the voice moves.
    pub fn render_only(f: *Feeder, v: *Voice) void {
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

fn max_step(s: []const u8) i32 {
    var m: i32 = 0;
    for (s[1..], s[0 .. s.len - 1]) |b, a| m = @max(m, @as(i32, @intCast(@abs(@as(i32, b) - a))));
    return m;
}

/// A zone histogram like the model's: floor, crosstalk at 15, a target.
fn fake_hist(target_bin: u32, amp_t: u32) [128]u32 {
    var h: [128]u32 = @splat(200);
    for (&h, 0..) |*v, b| {
        const d15 = if (b > 15) b - 15 else 15 - b;
        if (d15 < 4) v.* += 2500 * ([_]u32{ 256, 180, 64, 12 })[d15] / 256;
        const dt = if (b > target_bin) b - target_bin else target_bin - b;
        if (dt < 4) v.* += amp_t * ([_]u32{ 256, 180, 64, 12 })[dt] / 256;
    }
    return h;
}

test "audio: tables are centred, normalised, and move with the target" {
    var t1: Table = undefined;
    var t2: Table = undefined;
    const h1 = fake_hist(22, 9000);
    const h2 = fake_hist(40, 9000);
    table_from_histogram(&h1, &t1);
    table_from_histogram(&h2, &t2);
    var sum: i32 = 0;
    var peak: i32 = 0;
    for (t1) |x| {
        sum += x;
        peak = @max(peak, @as(i32, @intCast(@abs(x))));
    }
    try testing.expect(@abs(sum) < 64 * 400);
    try testing.expectEqual(@as(i32, 32000), peak);
    // The hand's peak shows up where its bin is.
    var arg1: usize = 0;
    var arg2: usize = 0;
    for (t1, t2, 0..) |a, b, i| {
        if (a > t1[arg1]) arg1 = i;
        if (b > t2[arg2]) arg2 = i;
    }
    try testing.expectEqual(@as(usize, 22 - first_bin), arg1);
    try testing.expectEqual(@as(usize, 40 - first_bin), arg2);
}

test "audio: pitch from distance, three octaves" {
    try testing.expectEqual(@as(u32, 880), hz_of(inc_for_mm(80)));
    try testing.expectEqual(@as(u32, 440), hz_of(inc_for_mm(80 + 374))); // one octave (1120 / 3 mm)
    try testing.expect(hz_of(inc_for_mm(1200)) >= 109 and hz_of(inc_for_mm(1200)) <= 110);
    try testing.expectEqual(inc_for_mm(5000), inc_for_mm(1200));
    // Monotonic.
    var prev = inc_for_mm(80);
    var mm: u32 = 81;
    while (mm <= 1200) : (mm += 7) {
        const i = inc_for_mm(mm);
        try testing.expect(i <= prev);
        prev = i;
    }
}

test "audio: a new table crossfades without a click; silence ramps in" {
    var v: Voice = .{};
    var t1: Table = undefined;
    var t2: Table = undefined;
    table_from_histogram(&fake_hist(22, 9000), &t1);
    table_from_histogram(&fake_hist(45, 20000), &t2);
    v.set_table(&t1);
    v.set(inc_for_mm(300), full, false);
    v.jump();
    var a: [2000]u8 = undefined;
    v.render(&a);
    try testing.expect(@abs(@as(i32, a[0]) - 128) <= 1); // attack from silence
    v.level = full;
    var warm: [12000]u8 = undefined;
    v.render(&warm); // first crossfade (from the empty table) done
    try testing.expectEqual(full, v.xf);
    const before = max_step(warm[8000..]);
    v.set_table(&t2);
    var b: [12000]u8 = undefined;
    v.render(&b);
    try testing.expectEqual(full, v.xf);
    // No sample step during the fade beyond what either table makes on its own.
    var after_v = v;
    var c: [4000]u8 = undefined;
    after_v.render(&c);
    const limit = @max(before, max_step(&c)) + 4;
    try testing.expect(max_step(&b) <= limit);
    // And the phase never reset: it advanced by the increments.
    try testing.expect(v.phase != 0);
}

test "audio: release fades to silence" {
    var v: Voice = .{};
    var t1: Table = undefined;
    table_from_histogram(&fake_hist(22, 9000), &t1);
    v.set_table(&t1);
    v.set(inc_for_mm(400), full, false);
    v.jump();
    var warm: [8000]u8 = undefined;
    v.render(&warm);
    v.set(v.inc_target, 0, true);
    var rel: [sample_rate / 2]u8 = undefined;
    v.render(&rel);
    for (rel[sample_rate * 4 / 10 ..]) |s| try testing.expectEqual(@as(u8, 128), s);
}

test "audio: feeder keeps the target and never underruns at 60 Hz" {
    var r: stream.Ring = undefined;
    stream.ring = &r;
    var f: Feeder = .{};
    var v: Voice = .{};
    var t1: Table = undefined;
    table_from_histogram(&fake_hist(22, 9000), &t1);
    v.set_table(&t1);
    v.set(inc_for_mm(300), full, false);
    var consumed: u64 = 0;
    for (0..300) |i| {
        f.feed(&v, false);
        if (i > 0) try testing.expectEqual(f.target, stream.queued());
        // The OS takes 738 samples per update.
        var k: u32 = 0;
        while (k < 738 and r.tail != r.head) : (k += 1) r.tail = if (r.tail + 1 == r.len) 0 else r.tail + 1;
        consumed += k;
    }
    try testing.expectEqual(@as(u32, 0), f.lows);
    try testing.expect(consumed > 738 * 290);
}
