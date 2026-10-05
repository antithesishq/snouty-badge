//! Pitch arithmetic (SPEC section 4): hand distance to cents, scale snap,
//! note names, and cents to the voice's 32-bit phase increment. No float
//! and no cart API, so the host tests run all of it.
//!
//! A pitch is `Cents`: hundredths of a semitone above MIDI note 0
//! (8.1758 Hz), so MIDI note n is n * 100 and A4 (440 Hz) is 6900.
const tables = @import("gen/tables.zig");

pub const Cents = i32;

pub const sample_rate = 44100;

/// The highest pitch the voice is asked for (MIDI 120, C9, 8.4 kHz).
pub const max_cents: Cents = 12000;

/// Hand distance to pitch: linear in millimetres and in cents, so equal
/// hand movements are equal musical intervals (the frequency is
/// exponential in distance). A hand at `near_mm` or closer plays the top
/// of the range, one at `far_mm` or further the bottom.
pub const Map = struct {
    near_mm: u16 = 60,
    far_mm: u16 = 480,
    range_cents: Cents = 3600,

    /// The pitch for a hand at `mm`, with `low` the bottom of the range.
    pub fn cents(m: Map, low: Cents, hand_mm: u16) Cents {
        const d: i32 = @as(i32, @min(@max(hand_mm, m.near_mm), m.far_mm)) - m.near_mm;
        const span: i32 = @as(i32, m.far_mm) - m.near_mm;
        return low + m.range_cents - @divTrunc(d * m.range_cents, span);
    }

    /// The distance that plays `c` (the stick's stand-in hand on screen).
    pub fn distance(m: Map, low: Cents, c: Cents) u16 {
        const top = low + m.range_cents;
        const k = @min(@max(top - c, 0), m.range_cents);
        const span: i32 = @as(i32, m.far_mm) - m.near_mm;
        return @intCast(@as(i32, m.near_mm) + @divTrunc(k * span, m.range_cents));
    }
};

pub const Scale = enum(u2) {
    off,
    chromatic,
    major,
    pentatonic,

    /// The allowed semitones above the root, one bit each.
    pub fn mask(s: Scale) u12 {
        return switch (s) {
            .off, .chromatic => 0xFFF,
            // 0 2 4 5 7 9 11
            .major => 0b1010_1011_0101,
            // 0 2 4 7 9
            .pentatonic => 0b0010_1001_0101,
        };
    }

    pub fn label(s: Scale) []const u8 {
        return switch (s) {
            .off => "FREE",
            .chromatic => "CHROM",
            .major => "MAJOR",
            .pentatonic => "PENTA",
        };
    }
};

pub const Snap = enum(u1) {
    /// Pulled toward the notes but still continuous (vibrato survives).
    soft,
    /// Always on a note, with hysteresis so a hand at a boundary does not warble.
    hard,

    pub fn label(s: Snap) []const u8 {
        return if (s == .soft) "SOFT" else "HARD";
    }
};

/// Hard snap keeps the last note until the pitch is this far past the
/// midpoint toward the next one.
pub const hysteresis_cents: Cents = 15;

fn allowed(mask: u12, semitone: i32) bool {
    const bit: u4 = @intCast(@mod(semitone, 12));
    return (mask >> bit) & 1 != 0;
}

/// The allowed notes (as cents relative to the root) around `rel`:
/// `lo <= rel < hi`, both on the scale.
fn neighbours(mask: u12, rel: Cents) struct { lo: Cents, hi: Cents } {
    var lo_n: i32 = @divFloor(rel, 100);
    while (!allowed(mask, lo_n)) lo_n -= 1;
    var hi_n: i32 = @divFloor(rel, 100) + 1;
    while (!allowed(mask, hi_n)) hi_n += 1;
    return .{ .lo = lo_n * 100, .hi = hi_n * 100 };
}

/// The soft-snap curve on t in [0, 4096]: half linear, half the S-curve
/// t^3 / (t^3 + (1-t)^3), which is flat at both notes. Monotonic, fixes
/// 0, 2048 and 4096.
pub fn soft_curve(t: i32) i32 {
    const u: i64 = t;
    const v: i64 = 4096 - u;
    const a = u * u * u;
    const b = v * v * v;
    const s: i64 = if (a + b == 0) 0 else @divTrunc(a * 4096, a + b);
    return @intCast(@divTrunc(u + s, 2));
}

/// Scale snap with memory (hard snap's hysteresis).
pub const Snapper = struct {
    last: ?Cents = null,

    pub fn reset(s: *Snapper) void {
        s.last = null;
    }

    /// `c` snapped to `scale` (relative to `root`, 0 = C .. 11 = B).
    pub fn snap(s: *Snapper, c: Cents, scale: Scale, mode: Snap, root: u4) Cents {
        if (scale == .off) {
            s.last = null;
            return c;
        }
        const mask = scale.mask();
        const base: Cents = @as(Cents, root) * 100;
        const rel = c - base;
        const n = neighbours(mask, rel);
        const span = n.hi - n.lo;
        switch (mode) {
            .hard => {
                const pick = if (rel - n.lo < n.hi - rel) n.lo else n.hi;
                if (s.last) |prev| {
                    const p = prev - base;
                    // Stay on the previous note while the pitch is within
                    // its half-interval plus the hysteresis band.
                    if (p == n.lo and rel - n.lo < @divTrunc(span, 2) + hysteresis_cents) return prev;
                    if (p == n.hi and n.hi - rel < @divTrunc(span, 2) + hysteresis_cents) return prev;
                }
                s.last = pick + base;
                return pick + base;
            },
            .soft => {
                s.last = null;
                const t: i32 = @intCast(@divTrunc(@as(i64, rel - n.lo) * 4096, span));
                return base + n.lo + @as(Cents, @intCast(@divTrunc(@as(i64, soft_curve(t)) * span, 4096)));
            },
        }
    }
};

/// The nearest equal-tempered note and how far off it `c` is.
pub const Note = struct {
    midi: i32,
    /// -50..49
    cents: i32,
};

pub fn nearest(c: Cents) Note {
    const midi = @divFloor(c + 50, 100);
    return .{ .midi = midi, .cents = c - midi * 100 };
}

const names = [12][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };

pub fn pitch_class_name(pc: u4) []const u8 {
    return names[pc];
}

/// "A4", "C#5", ... (MIDI 60 is C4) into `buf`; returns the slice used.
pub fn note_name(midi: i32, buf: *[4]u8) []const u8 {
    const m = @min(@max(midi, 0), 127);
    const n = names[@intCast(@mod(m, 12))];
    const oct = @divFloor(m, 12) - 1;
    var len: usize = 0;
    for (n) |ch| {
        buf[len] = ch;
        len += 1;
    }
    if (oct < 0) {
        buf[len] = '-';
        buf[len + 1] = '1';
        return buf[0 .. len + 2];
    }
    buf[len] = '0' + @as(u8, @intCast(oct));
    return buf[0 .. len + 1];
}

/// The 32-bit phase increment for `c` at 44.1 kHz (a step of
/// 2^32 / 44100 per Hz), from the generated semitone and cent tables.
pub fn inc_for(c: Cents) u32 {
    const k: u32 = @intCast(@min(@max(c, 0), max_cents));
    const oct = k / 1200;
    const rem = k % 1200;
    var x: u64 = tables.base_inc_q8;
    x = (x * tables.semitone_q30[rem / 100]) >> 30;
    x = (x * tables.cent_q30[rem % 100]) >> 30;
    x <<= @intCast(oct);
    return @truncate(x >> 8);
}

/// Frequency in Hz of a phase increment (rounded).
pub fn hz_of(inc: u32) u32 {
    return @intCast((@as(u64, inc) * sample_rate + (1 << 31)) >> 32);
}

/// Three-sample median: removes a single-frame spike from the sensor
/// without the lag of a longer average.
pub const Median3 = struct {
    v: [3]u16 = .{ 0, 0, 0 },
    n: u2 = 0,
    i: u2 = 0,

    pub fn reset(m: *Median3) void {
        m.n = 0;
        m.i = 0;
    }

    pub fn push(m: *Median3, x: u16) u16 {
        m.v[m.i] = x;
        m.i = if (m.i == 2) 0 else m.i + 1;
        if (m.n < 3) m.n += 1;
        return switch (m.n) {
            1 => x,
            // Two readings: the older one is as likely as the new; take the new.
            2 => x,
            else => med(m.v[0], m.v[1], m.v[2]),
        };
    }

    fn med(a: u16, b: u16, c: u16) u16 {
        return @max(@min(a, b), @min(@max(a, b), c));
    }
};

// ---- Host tests ----

const std = @import("std");
const testing = std.testing;

test "pitch: distance maps linearly in cents over the range, clamped at both ends" {
    const m: Map = .{};
    const low: Cents = 4800; // C3
    try testing.expectEqual(low + 3600, m.cents(low, 60));
    try testing.expectEqual(low + 3600, m.cents(low, 10));
    try testing.expectEqual(low, m.cents(low, 480));
    try testing.expectEqual(low, m.cents(low, 900));
    // Halfway in mm is halfway in cents (an octave and a half).
    try testing.expectEqual(low + 1800, m.cents(low, 270));
    // Closer is higher, everywhere.
    var prev: Cents = std.math.maxInt(Cents);
    var d: u16 = 0;
    while (d < 600) : (d += 7) {
        const c = m.cents(low, d);
        try testing.expect(c <= prev);
        prev = c;
    }
    // mm() inverts cents() to within a millimetre.
    var c: Cents = low;
    while (c <= low + 3600) : (c += 37) {
        const back = m.cents(low, m.distance(low, c));
        try testing.expect(@abs(back - c) <= 9);
    }
}

test "pitch: phase increment matches the equal-tempered frequency" {
    // A4 = 440 Hz: 440 * 2^32 / 44100 = 42852281.5
    const a4 = inc_for(6900);
    try testing.expect(@abs(@as(i64, a4) - 42852281) < 43); // 1 ppm-ish
    try testing.expectEqual(@as(u32, 440), hz_of(a4 + 100));
    // An octave doubles it; a semitone is 2^(1/12); one cent 2^(1/1200).
    try testing.expect(@abs(@as(i64, inc_for(8100)) - 2 * @as(i64, a4)) < 4);
    const c4: f64 = @floatFromInt(inc_for(6000));
    const want_c4: f64 = 261.6255653 * 4294967296.0 / 44100.0;
    try testing.expect(@abs(c4 - want_c4) / want_c4 < 1e-6);
    var c: Cents = 3000;
    while (c < 10000) : (c += 1) {
        const r: f64 = @as(f64, @floatFromInt(inc_for(c + 1))) / @as(f64, @floatFromInt(inc_for(c)));
        try testing.expect(@abs(r - 1.000577790) < 2e-6);
    }
    // Clamped, never wraps.
    try testing.expectEqual(inc_for(0), inc_for(-500));
    try testing.expectEqual(inc_for(max_cents), inc_for(max_cents + 900));
}

test "pitch: note names and nearest note" {
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("A4", note_name(69, &buf));
    try testing.expectEqualStrings("C4", note_name(60, &buf));
    try testing.expectEqualStrings("C#5", note_name(73, &buf));
    try testing.expectEqualStrings("B2", note_name(47, &buf));
    try testing.expectEqual(Note{ .midi = 69, .cents = 12 }, nearest(6912));
    try testing.expectEqual(Note{ .midi = 70, .cents = -50 }, nearest(6950));
    try testing.expectEqual(Note{ .midi = 69, .cents = 49 }, nearest(6949));
    try testing.expectEqual(Note{ .midi = 69, .cents = -50 }, nearest(6850));
}

test "pitch: hard snap picks scale notes" {
    var s: Snapper = .{};
    // Chromatic: nearest semitone.
    try testing.expectEqual(@as(Cents, 6900), s.snap(6930, .chromatic, .hard, 0));
    s.reset();
    try testing.expectEqual(@as(Cents, 7000), s.snap(6960, .chromatic, .hard, 0));
    // C major has no C#: 6130 (C#4 + 30) goes to D4.
    s.reset();
    try testing.expectEqual(@as(Cents, 6200), s.snap(6130, .major, .hard, 0));
    s.reset();
    try testing.expectEqual(@as(Cents, 6000), s.snap(6090, .major, .hard, 0));
    // C pentatonic has no F: between E (6400) and G (6700) the midpoint is 6550.
    s.reset();
    try testing.expectEqual(@as(Cents, 6400), s.snap(6540, .pentatonic, .hard, 0));
    s.reset();
    try testing.expectEqual(@as(Cents, 6700), s.snap(6560, .pentatonic, .hard, 0));
    // Root A: A major has C#; and every output is on the scale.
    s.reset();
    try testing.expectEqual(@as(Cents, 6100), s.snap(6110, .major, .hard, 9));
    var c: Cents = 4000;
    while (c < 8000) : (c += 13) {
        s.reset();
        const out = s.snap(c, .pentatonic, .hard, 9);
        try testing.expect(@mod(out, 100) == 0);
        try testing.expect(allowed(Scale.pentatonic.mask(), @divFloor(out, 100) - 9));
        try testing.expect(@abs(out - c) <= 150);
    }
    // Off passes through.
    try testing.expectEqual(@as(Cents, 6913), s.snap(6913, .off, .hard, 0));
}

test "pitch: hard snap hysteresis holds a note across a jittering boundary" {
    var s: Snapper = .{};
    try testing.expectEqual(@as(Cents, 6900), s.snap(6940, .chromatic, .hard, 0));
    // Jitter around the midpoint 6950: stays on A4 until past 6965.
    for ([_]Cents{ 6952, 6948, 6958, 6963, 6951 }) |c|
        try testing.expectEqual(@as(Cents, 6900), s.snap(c, .chromatic, .hard, 0));
    try testing.expectEqual(@as(Cents, 7000), s.snap(6967, .chromatic, .hard, 0));
    // And back down only below 6935.
    try testing.expectEqual(@as(Cents, 7000), s.snap(6940, .chromatic, .hard, 0));
    try testing.expectEqual(@as(Cents, 6900), s.snap(6933, .chromatic, .hard, 0));
    // A big jump is never held.
    try testing.expectEqual(@as(Cents, 7500), s.snap(7480, .chromatic, .hard, 0));
}

test "pitch: soft snap is continuous, monotonic and fixes the notes" {
    var s: Snapper = .{};
    try testing.expectEqual(@as(i32, 0), soft_curve(0));
    try testing.expectEqual(@as(i32, 2048), soft_curve(2048));
    try testing.expectEqual(@as(i32, 4096), soft_curve(4096));
    for ([_]Scale{ .chromatic, .major, .pentatonic }) |scale| {
        var prev: Cents = s.snap(5000, scale, .soft, 2);
        var c: Cents = 5001;
        while (c < 7500) : (c += 1) {
            const out = s.snap(c, scale, .soft, 2);
            try testing.expect(out >= prev);
            // No jumps: a cent in moves at most 3 out (the curve's slope
            // tops out at 2 halfway between notes, plus rounding).
            try testing.expect(out - prev <= 3);
            if (@mod(c - 200, 100) == 0 and allowed(scale.mask(), @divFloor(c - 200, 100)))
                try testing.expectEqual(c, out);
            prev = out;
        }
    }
    // Near a note it pulls in: 10 cents sharp of A4 comes out ~5 sharp.
    const near = s.snap(6910, .chromatic, .soft, 0);
    try testing.expect(near > 6900 and near < 6908);
}

test "pitch: median of three drops a one-frame spike" {
    var m: Median3 = .{};
    try testing.expectEqual(@as(u16, 200), m.push(200));
    try testing.expectEqual(@as(u16, 202), m.push(202));
    try testing.expectEqual(@as(u16, 202), m.push(900));
    try testing.expectEqual(@as(u16, 204), m.push(204));
    try testing.expectEqual(@as(u16, 206), m.push(206));
    m.reset();
    try testing.expectEqual(@as(u16, 50), m.push(50));
}
