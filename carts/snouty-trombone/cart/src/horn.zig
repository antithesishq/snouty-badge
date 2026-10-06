//! The trombone itself (SPEC section 2): slide, embouchure and pitch
//! arithmetic. No float and no cart API, so the host tests run all of it.
//!
//! A pitch is `Cents`: hundredths of a semitone above MIDI note 0
//! (8.1758 Hz), so MIDI note n is n * 100 and A4 (440 Hz) is 6900.
//!
//! - The horn's fundamental (the pedal, partial 1) is Bb1 at 1st position.
//!   Partial n sounds n times its frequency (`tables.partial_cents`: the
//!   real harmonic series, so the 7th partial is 31 cents flat as on a real
//!   horn).
//! - The slide lowers everything by `slide` cents: 0 at 1st position, 100
//!   per position, 600 at 7th. It is continuous (a trombone has no frets).
//! - The embouchure is a continuous lip value over the partials (`Lip`, Q8
//!   partial units: 4.0 is 1024). The sounding partial is the nearest one
//!   with hysteresis (`Embouchure`); between partials the lip bends the
//!   pitch toward the next one ("lipping", up to `max_bend` cents) before
//!   it cracks over.
const tables = @import("gen/tables.zig");

pub const Cents = i32;

pub const sample_rate = 44100;

/// The highest pitch the voice is asked for (MIDI 120, C9, 8.4 kHz).
pub const max_cents: Cents = 12000;

/// Bb1, 58.27 Hz: the tenor trombone's pedal at 1st position.
pub const fundamental: Cents = 3400;

pub const positions = 7;
/// Slide cents per position and at 7th position.
pub const position_cents: i32 = 100;
pub const slide_max: i32 = (positions - 1) * position_cents;

/// The highest partial played, and the lowest with and without PEDAL.
pub const top_partial: u4 = 8;
pub fn lowest_partial(pedal: bool) u4 {
    return if (pedal) 1 else 2;
}

/// The pitch of `partial` with the slide out `slide` cents, bent `bend`.
pub fn pitch(partial: u4, slide: i32, bend: i32) Cents {
    return fundamental + tables.partial_cents[partial] - slide + bend;
}

/// Hand height to slide (SPEC section 2): linear in millimetres and in
/// cents across the throw, so equal hand movements are equal intervals.
/// Hand at `near_mm` or closer: 1st position (slide in); at `far_mm` or
/// further: 7th (slide out).
pub const SlideMap = struct {
    near_mm: u16 = 100,
    far_mm: u16 = 450,

    pub fn slide(m: SlideMap, hand_mm: u16) i32 {
        const d: i32 = @as(i32, @min(@max(hand_mm, m.near_mm), m.far_mm)) - m.near_mm;
        const span: i32 = @as(i32, m.far_mm) - m.near_mm;
        return @divTrunc(d * slide_max + @divTrunc(span, 2), span);
    }

    /// The hand height for a slide (the demo hand, the stick's stand-in).
    pub fn distance(m: SlideMap, s: i32) u16 {
        const k = @min(@max(s, 0), slide_max);
        const span: i32 = @as(i32, m.far_mm) - m.near_mm;
        return @intCast(@as(i32, m.near_mm) + @divTrunc(k * span + slide_max / 2, slide_max));
    }
};

/// The continuous slide position in hundredths: 100 (1st) .. 700 (7th).
pub fn position_x100(slide: i32) i32 {
    return 100 + @min(@max(slide, 0), slide_max);
}

/// The soft-snap curve on t in [0, 4096] (the theremin's): half linear,
/// half t^3 / (t^3 + (1-t)^3), which is flat at both ends. Monotonic,
/// fixes 0, 2048 and 4096.
pub fn soft_curve(t: i32) i32 {
    const u: i64 = t;
    const v: i64 = 4096 - u;
    const a = u * u * u;
    const b = v * v * v;
    const s: i64 = if (a + b == 0) 0 else @divTrunc(a * 4096, a + b);
    return @intCast(@divTrunc(u + s, 2));
}

/// SNAP SOFT: the slide pulled toward the seven positions, still
/// continuous and monotonic (a slide vibrato survives).
pub fn snap_soft(slide: i32) i32 {
    const s = @min(@max(slide, 0), slide_max);
    const lo = @divFloor(s, position_cents) * position_cents;
    if (lo == slide_max) return s;
    const t = @divTrunc((s - lo) * 4096, position_cents);
    return lo + @divTrunc(soft_curve(t) * position_cents, 4096);
}

// ---- Embouchure ----

/// Lip value: Q8 partial units (partial n's centre is n * 256).
pub const lip_one: i32 = 256;

/// The lip value for a lip tension t in [0, 4096] (the hand's side to
/// side): the partials lowest..top share the range in equal bands, the
/// lowest band starting at t = 0.
pub fn lip_for(t: i32, pedal: bool) i32 {
    const lo: i32 = lowest_partial(pedal);
    const count: i32 = @as(i32, top_partial) - lo + 1;
    const tt = @min(@max(t, 0), 4096);
    return lo * lip_one - lip_one / 2 + @divTrunc(tt * count * lip_one, 4096);
}

/// Inverse of `lip_for` (the stick and the demo): t for a lip value.
pub fn t_for(lip: i32, pedal: bool) i32 {
    const lo: i32 = lowest_partial(pedal);
    const count: i32 = @as(i32, top_partial) - lo + 1;
    const t = @divTrunc((lip - lo * lip_one + lip_one / 2) * 4096, count * lip_one);
    return @min(@max(t, 0), 4096);
}

/// How far past the midpoint between two partials the lip must go before
/// the horn cracks over (Q8: 0.15 of a partial), so a lip resting on a
/// boundary does not warble.
pub const hysteresis: i32 = 38;
/// Around a partial's centre the pitch is the partial's own (Q8: 0.12).
pub const bend_dead: i32 = 31;
/// The most the lip bends the pitch before the crack (cents).
pub const max_bend: i32 = 40;

pub const Embouchure = struct {
    partial: u4 = 4,

    /// Choose the sounding partial for lip value `lip` (lowest..top);
    /// returns true when it changed (a crack, if sounding).
    pub fn update(e: *Embouchure, lip: i32, pedal: bool) bool {
        const lo = lowest_partial(pedal);
        const old = e.partial;
        if (e.partial < lo) e.partial = lo;
        const centre: i32 = @as(i32, e.partial) * lip_one;
        if (@abs(lip - centre) > lip_one / 2 + hysteresis) {
            const n = @divFloor(lip + lip_one / 2, lip_one);
            e.partial = @intCast(@min(@max(n, lo), top_partial));
        }
        return e.partial != old;
    }

    /// The lip bend (cents) for `lip` on the current partial: none near
    /// its centre, rising to `max_bend` at the crack point, toward the lip.
    pub fn bend(e: Embouchure, lip: i32) i32 {
        const d = lip - @as(i32, e.partial) * lip_one;
        const mag: i32 = @intCast(@abs(d));
        if (mag <= bend_dead) return 0;
        const edge = lip_one / 2 + hysteresis;
        const b = @divTrunc(@min(mag - bend_dead, edge - bend_dead) * max_bend, edge - bend_dead);
        return if (d < 0) -b else b;
    }
};

// ---- Notes and the phase increment ----

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

/// Concert pitch names, flats (a trombonist reads Bb, Eb, Ab).
const names = [12][]const u8{ "C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B" };

/// "Bb3", "F4", ... (MIDI 60 is C4) into `buf`; returns the slice used.
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
            1, 2 => x,
            else => @max(@min(m.v[0], m.v[1]), @min(@max(m.v[0], m.v[1]), m.v[2])),
        };
    }
};

// ---- Host tests ----

const std = @import("std");
const testing = std.testing;

test "horn: the harmonic series at 1st position is a trombone's open notes" {
    // Bb2 F3 Bb3 D4 F4 Ab4(flat) Bb4 for partials 2..8.
    const want = [_]i32{ 46, 53, 58, 62, 65, 68, 70 };
    for (want, 2..) |midi, n| {
        const p = nearest(pitch(@intCast(n), 0, 0));
        try testing.expectEqual(midi, p.midi);
        try testing.expect(@abs(p.cents) <= 31);
    }
    // The 7th partial is the real horn's: 31 cents flat.
    try testing.expectEqual(@as(i32, -31), nearest(pitch(7, 0, 0)).cents);
    // Each partial is n times the fundamental (within a cent).
    const f0: f64 = @floatFromInt(inc_for(fundamental));
    for (1..9) |n| {
        const r = @as(f64, @floatFromInt(inc_for(pitch(@intCast(n), 0, 0)))) / f0;
        try testing.expect(@abs(r / @as(f64, @floatFromInt(n)) - 1.0) < 0.0006);
    }
}

test "horn: positions 1..7 hit the equal-tempered semitones" {
    const m: SlideMap = .{};
    for (0..positions) |p| {
        const s: i32 = @intCast(p * 100);
        // On every partial, position p is p semitones below 1st.
        for (2..9) |n| try testing.expectEqual(pitch(@intCast(n), 0, 0) - s, pitch(@intCast(n), s, 0));
        // And the hand height for it maps back (to the millimetre).
        try testing.expect(@abs(s - m.slide(m.distance(s))) <= 1);
    }
    // 4th partial, 1st..7th: Bb3 A3 Ab3 G3 Gb3 F3 E3.
    const want = [_]i32{ 58, 57, 56, 55, 54, 53, 52 };
    for (want, 0..) |midi, p| {
        const n = nearest(pitch(4, @intCast(p * 100), 0));
        try testing.expectEqual(midi, n.midi);
        try testing.expectEqual(@as(i32, 0), n.cents);
    }
    try testing.expectEqual(@as(i32, 100), position_x100(0));
    try testing.expectEqual(@as(i32, 700), position_x100(slide_max + 50));
}

test "horn: the slide glisses monotonically and smoothly with the hand" {
    const m: SlideMap = .{};
    var prev = pitch(4, m.slide(0), 0);
    var mm: u16 = 0;
    while (mm < 600) : (mm += 1) {
        const c = pitch(4, m.slide(mm), 0);
        // Further is lower, never higher, and a millimetre moves at most
        // ~2 cents (a 350 mm throw over 600 cents): no steps.
        try testing.expect(c <= prev);
        try testing.expect(prev - c <= 2);
        prev = c;
    }
    try testing.expectEqual(@as(i32, 0), m.slide(100));
    try testing.expectEqual(slide_max, m.slide(450));
    try testing.expectEqual(@as(i32, 300), m.slide(275));
    // Soft snap: continuous, monotonic, fixes the positions, pulls in.
    var last = snap_soft(0);
    var s: i32 = 1;
    while (s <= slide_max) : (s += 1) {
        const v = snap_soft(s);
        try testing.expect(v >= last and v - last <= 3);
        if (@mod(s, 100) == 0) try testing.expectEqual(s, v);
        last = v;
    }
    const pulled = snap_soft(210);
    try testing.expect(pulled > 200 and pulled < 210);
}

test "horn: lip bands cover the partials; t and lip invert" {
    for ([_]bool{ false, true }) |pedal| {
        const lo = lowest_partial(pedal);
        try testing.expectEqual(@as(i32, lo) * lip_one - lip_one / 2, lip_for(0, pedal));
        try testing.expectEqual(@as(i32, top_partial) * lip_one + lip_one / 2, lip_for(4096, pedal));
        var n: u4 = lo;
        while (n <= top_partial) : (n += 1) {
            const lip = @as(i32, n) * lip_one;
            try testing.expect(@abs(lip_for(t_for(lip, pedal), pedal) - lip) <= 2);
        }
    }
}

test "horn: partial hysteresis holds across a jittering boundary" {
    var e: Embouchure = .{ .partial = 4 };
    // Lip at 4.5 (the boundary to 5) jittering +-0.1: never cracks.
    for ([_]i32{ 1152, 1170, 1130, 1180, 1150, 1185 }) |lip| try testing.expect(!e.update(lip, false));
    try testing.expectEqual(@as(u4, 4), e.partial);
    // Past 4.5 + hysteresis: cracks up to 5, and back needs the same margin.
    try testing.expect(e.update(4 * 256 + 128 + hysteresis + 1, false));
    try testing.expectEqual(@as(u4, 5), e.partial);
    try testing.expect(!e.update(4 * 256 + 128 - 20, false));
    try testing.expect(e.update(4 * 256 + 128 - hysteresis - 1, false));
    try testing.expectEqual(@as(u4, 4), e.partial);
    // A big jump goes straight to the nearest partial; clamped to the range.
    try testing.expect(e.update(8 * 256 + 600, false));
    try testing.expectEqual(@as(u4, 8), e.partial);
    try testing.expect(e.update(0, false));
    try testing.expectEqual(@as(u4, 2), e.partial);
    try testing.expect(e.update(0, true));
    try testing.expectEqual(@as(u4, 1), e.partial);
    // Turning PEDAL off lifts a pedal note to the lowest partial.
    try testing.expect(e.update(256, false));
    try testing.expectEqual(@as(u4, 2), e.partial);
}

test "horn: a slow lip sweep cracks exactly once per boundary, bends between" {
    var e: Embouchure = .{ .partial = 2 };
    var cracks: u32 = 0;
    var last_pitch = pitch(e.partial, 0, e.bend(lip_for(0, false)));
    var t: i32 = 0;
    while (t <= 4096) : (t += 4) {
        const lip = lip_for(t, false);
        const cracked = e.update(lip, false);
        const b = e.bend(lip);
        try testing.expect(@abs(b) <= max_bend);
        const c = pitch(e.partial, 0, b);
        if (cracked) {
            cracks += 1;
            // A crack only happens past the boundary plus the hysteresis.
            const centre: i32 = @as(i32, e.partial - 1) * lip_one;
            try testing.expect(lip - centre > lip_one / 2 + hysteresis);
            try testing.expect(c > last_pitch);
        } else {
            // Between cracks the bend only rises (lipping up), smoothly.
            try testing.expect(c >= last_pitch and c - last_pitch <= 2);
        }
        last_pitch = c;
    }
    try testing.expectEqual(@as(u32, 6), cracks);
    try testing.expectEqual(@as(u4, 8), e.partial);
    // At a partial's centre there is no bend; at the crack point the most.
    try testing.expectEqual(@as(i32, 0), (Embouchure{ .partial = 5 }).bend(5 * 256 + 20));
    try testing.expectEqual(max_bend, (Embouchure{ .partial = 5 }).bend(5 * 256 + 128 + hysteresis));
    try testing.expectEqual(-max_bend, (Embouchure{ .partial = 5 }).bend(5 * 256 - 200));
}

test "horn: note names in flats, nearest note, phase increment" {
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("Bb3", note_name(58, &buf));
    try testing.expectEqualStrings("Ab4", note_name(68, &buf));
    try testing.expectEqualStrings("E2", note_name(40, &buf));
    try testing.expectEqualStrings("Bb1", note_name(34, &buf));
    try testing.expectEqual(Note{ .midi = 69, .cents = 12 }, nearest(6912));
    try testing.expectEqual(Note{ .midi = 70, .cents = -50 }, nearest(6950));
    // A4 = 440 Hz: 440 * 2^32 / 44100 = 42852281.5
    try testing.expect(@abs(@as(i64, inc_for(6900)) - 42852281) < 43);
    try testing.expectEqual(@as(u32, 58), hz_of(inc_for(fundamental)));
    try testing.expectEqual(inc_for(0), inc_for(-500));
}

test "horn: median of three drops a one-frame spike" {
    var m: Median3 = .{};
    try testing.expectEqual(@as(u16, 200), m.push(200));
    try testing.expectEqual(@as(u16, 202), m.push(202));
    try testing.expectEqual(@as(u16, 202), m.push(900));
    try testing.expectEqual(@as(u16, 204), m.push(204));
}
