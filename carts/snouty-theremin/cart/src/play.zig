//! The playing logic, once per update (SPEC section 4): hand readings or
//! the stick in, a pitch and a level for the voice out. Pure, host-tested.
//!
//! Sensor path, per new frame: the pitch hand's distance goes through a
//! three-frame median (drops single-frame spikes) and the distance map;
//! the volume hand (two-hand layout) sets the volume. Per update the pitch
//! follows its target through a one-pole smoother (half the gap per
//! update: removes the sensor's frame steps and jitter, keeps the 4-7 Hz
//! wobble of a real hand, so vibrato is the player's), then the scale
//! snap. No hand for `absent_grace` frames releases the note (a slow fade
//! in the voice, never a click); a hand returning after `jump_after`
//! updates of quiet starts at its own pitch instead of sliding from the
//! last note.
//!
//! Stick path (no sensor): Up/Down step to the next note of the scale and,
//! held past `glide_delay`, glide continuously (accelerating); Left/Right
//! hold the note. The note sustains `stick_sustain` updates after the
//! last input, then releases. A gentle automatic vibrato starts once the
//! pitch has settled (the stick has no hand wobble).
const pitch = @import("pitch.zig");
const hands = @import("hands.zig");
const voice = @import("voice.zig");
const Cents = pitch.Cents;

pub const Settings = struct {
    layout: hands.Layout = .one_hand,
    scale: pitch.Scale = .pentatonic,
    snap: pitch.Snap = .soft,
    /// Key (and the bottom of the range): 0 = C .. 11 = B.
    root: u4 = 0,
    /// The range starts at `root` in this octave (C4 is middle C).
    octave: u3 = 3,
    wave: voice.Wave = .sine,
    /// Two-hand: pitch on the left column.
    pitch_left: bool = false,

    pub const min_octave = 2;
    pub const max_octave = 5;

    /// The bottom of the range.
    pub fn low(s: Settings) Cents {
        return (@as(Cents, s.octave) + 1) * 1200 + @as(Cents, s.root) * 100;
    }
};

// ---- Knobs (SPEC section 4) ----

/// Pitch smoother: fraction of the gap closed per update (Q8).
pub const glide_q8: i32 = 128;
/// Sensor frames without a hand before the note releases (~100 ms at 30 Hz).
pub const absent_grace: u8 = 3;
/// Updates of quiet after which a new note jumps to its pitch.
pub const jump_after: u16 = 12;
/// Volume hand: this close or closer is silent, this far or further full.
pub const vol_near_mm: u16 = 60;
pub const vol_far_mm: u16 = 320;
/// Stick: updates a direction is held before gliding, glide speed (cents
/// per update, start and top), sustain after the last input.
pub const glide_delay: u16 = 15;
pub const glide_start: i32 = 8;
pub const glide_top: i32 = 40;
pub const stick_sustain: u16 = 45;
/// Stick vibrato: depth (cents), period (updates), onset delay (updates).
pub const vib_depth: i32 = 14;
pub const vib_period: u16 = 11;
pub const vib_delay: u16 = 18;

pub const Output = struct {
    cents: Cents,
    /// Q16.
    level: i32,
    /// Fading out (no hand, no stick): the voice's slow release.
    release: bool,
    /// The voice should jump to the pitch (a fresh note).
    jump: bool,
};

/// Volume (Q16) for a volume hand at `mm`; no hand is full volume, as on a
/// theremin. Squared, so the taper sounds even.
pub fn volume_for(mm: ?u16) i32 {
    const d = mm orelse return voice.full;
    const c: i32 = @min(@max(d, vol_near_mm), vol_far_mm);
    const t: i32 = @divTrunc((c - vol_near_mm) * 256, vol_far_mm - vol_near_mm); // 0..256
    return @min((t * t), voice.full);
}

pub const Player = struct {
    map: pitch.Map = .{},
    target: Cents = 6000,
    smooth_q8: i32 = 6000 << 8,
    vol: i32 = voice.full,
    vol_target: i32 = voice.full,
    gate: bool = false,
    absent_frames: u8 = 0,
    quiet_ticks: u16 = jump_after,
    want_jump: bool = false,
    median: pitch.Median3 = .{},
    snapper: pitch.Snapper = .{},
    // Stick state.
    stick_mode: bool = false,
    prev_dir: i2 = 0,
    held_ticks: u16 = 0,
    sustain: u16 = 0,
    settled_ticks: u16 = 0,
    vib_tick: u16 = 0,
    /// Last output (the screen reads it).
    out: Output = .{ .cents = 6000, .level = 0, .release = true, .jump = false },

    fn onset(p: *Player, c: Cents) void {
        if (!p.gate and p.quiet_ticks >= jump_after) {
            p.smooth_q8 = c << 8;
            p.want_jump = true;
            p.snapper.reset();
        }
        p.gate = true;
    }

    /// A new sensor frame's hands.
    pub fn sensor(p: *Player, h: hands.Hands, s: Settings) void {
        p.stick_mode = false;
        if (h.pitch_mm) |mm| {
            p.absent_frames = 0;
            if (!p.gate and p.quiet_ticks >= jump_after) p.median.reset();
            const m = p.median.push(mm);
            p.target = p.map.cents(s.low(), m);
            p.onset(p.target);
        } else {
            if (p.absent_frames < 255) p.absent_frames += 1;
            if (p.absent_frames >= absent_grace) p.gate = false;
        }
        p.vol_target = if (s.layout == .two_hand) volume_for(h.volume_mm) else voice.full;
    }

    /// The stick, every update while there is no sensor: `dir` +1 Up,
    /// -1 Down; `hold` Left or Right.
    pub fn stick(p: *Player, dir: i2, hold: bool, s: Settings) void {
        if (!p.stick_mode) {
            p.stick_mode = true;
            p.prev_dir = 0;
        }
        const low = s.low();
        const high = low + p.map.range_cents;
        if (dir != 0) {
            if (dir != p.prev_dir) {
                p.target = step(p.target, dir, s);
                p.held_ticks = 0;
            } else {
                p.held_ticks +|= 1;
                if (p.held_ticks > glide_delay) {
                    const rate = @min(glide_start + @as(i32, p.held_ticks - glide_delay), glide_top);
                    p.target += rate * @as(i32, dir);
                }
            }
            p.target = @min(@max(p.target, low), high);
            p.sustain = stick_sustain;
            p.onset(p.target);
        } else if (hold) {
            p.sustain = stick_sustain;
            p.onset(p.target);
        } else if (p.sustain > 0) {
            p.sustain -= 1;
        } else {
            p.gate = false;
        }
        p.prev_dir = dir;
        p.vol_target = voice.full;
    }

    /// Advance one update.
    pub fn tick(p: *Player, s: Settings) Output {
        const goal: i32 = p.target << 8;
        p.smooth_q8 += @divTrunc((goal - p.smooth_q8) * glide_q8, 256);
        p.vol += (p.vol_target - p.vol) >> 1;
        if (p.gate) p.quiet_ticks = 0 else p.quiet_ticks +|= 1;

        var c = p.snapper.snap(p.smooth_q8 >> 8, s.scale, s.snap, s.root);
        if (p.stick_mode) {
            const settled = @abs(goal - p.smooth_q8) < (5 << 8) and p.prev_dir == 0;
            if (settled) p.settled_ticks +|= 1 else p.settled_ticks = 0;
            p.vib_tick = if (p.vib_tick + 1 >= vib_period) 0 else p.vib_tick + 1;
            if (p.settled_ticks > vib_delay) {
                // Fade the depth in over another vib_delay updates.
                const ramp: i32 = @min(@as(i32, p.settled_ticks - vib_delay), vib_delay);
                c += @divTrunc(tri(p.vib_tick) * vib_depth * ramp, vib_delay * 256);
            }
        } else {
            p.settled_ticks = 0;
        }
        p.out = .{
            .cents = c,
            .level = if (p.gate) p.vol else 0,
            .release = !p.gate,
            .jump = p.want_jump,
        };
        p.want_jump = false;
        return p.out;
    }
};

/// A triangle LFO, -256..256 over `vib_period` updates.
fn tri(t: u16) i32 {
    const half: i32 = vib_period / 2;
    const x: i32 = @as(i32, t);
    const up = if (x <= half) x else @as(i32, vib_period) - x; // 0..half
    return @divTrunc(up * 512, half) - 256;
}

/// The next note of the scale above (`dir` +1) or below (-1) the note
/// nearest `c`; semitones when the scale is off.
pub fn step(c: Cents, dir: i2, s: Settings) Cents {
    const mask = s.scale.mask();
    var n = pitch.nearest(c).midi;
    while (true) {
        n += dir;
        const rel: u4 = @intCast(@mod(n - @as(i32, s.root), 12));
        if ((mask >> rel) & 1 != 0) return n * 100;
    }
}

// ---- Host tests ----

const std = @import("std");
const testing = std.testing;

fn hand(mm: ?u16) hands.Hands {
    return .{ .pitch_mm = mm };
}

/// One sensor frame then two updates (30 Hz frames, 60 Hz updates).
fn frame(p: *Player, h: hands.Hands, s: Settings) [2]Output {
    p.sensor(h, s);
    return .{ p.tick(s), p.tick(s) };
}

test "play: a hand starts a note at its pitch, closer is higher" {
    var p: Player = .{};
    const s: Settings = .{ .scale = .off };
    _ = frame(&p, hand(null), s);
    try testing.expectEqual(@as(i32, 0), p.out.level);
    const o = frame(&p, hand(270), s);
    try testing.expect(o[0].jump);
    try testing.expect(!o[1].jump);
    try testing.expectEqual(s.low() + 1800, o[0].cents);
    try testing.expectEqual(voice.full, o[0].level);
    // Move closer: the pitch rises, smoothly over several updates.
    var last = o[1].cents;
    for (0..6) |_| {
        const q = frame(&p, hand(165), s);
        try testing.expect(q[0].cents >= last and q[1].cents >= q[0].cents);
        last = q[1].cents;
    }
    try testing.expect(@abs(last - (s.low() + 2700)) <= 3);
}

test "play: a dropped frame does not cut the note; an absent hand fades it" {
    var p: Player = .{};
    const s: Settings = .{ .scale = .off };
    for (0..5) |_| _ = frame(&p, hand(200), s);
    // One frame without the hand: still sounding.
    const d = frame(&p, hand(null), s);
    try testing.expect(!d[1].release and d[1].level > 0);
    _ = frame(&p, hand(200), s);
    // absent_grace frames: released (level 0, the voice's slow fade).
    var o: [2]Output = undefined;
    for (0..absent_grace) |_| o = frame(&p, hand(null), s);
    try testing.expect(o[1].release);
    try testing.expectEqual(@as(i32, 0), o[1].level);
    // The pitch holds where it was while the note fades.
    try testing.expectEqual(s.low() + p.map.cents(0, 200), o[1].cents);
}

test "play: the voice fades out with no click when the hand goes" {
    var p: Player = .{};
    var v: voice.Voice = .{};
    const s: Settings = .{ .scale = .off };
    var buf: [735]u8 = undefined;
    var prev: ?u8 = null;
    var worst: i32 = 0;
    for (0..50) |i| {
        if (i % 2 == 0) p.sensor(hand(if (i < 20) 220 else null), s);
        const o = p.tick(s);
        v.set(pitch.inc_for(o.cents), o.level, o.release);
        if (o.jump) v.jump();
        v.render(&buf);
        if (prev) |q| worst = @max(worst, @as(i32, @intCast(@abs(@as(i32, buf[0]) - q))));
        for (buf[1..], buf[0..734]) |b, a| worst = @max(worst, @as(i32, @intCast(@abs(@as(i32, b) - a))));
        prev = buf[734];
    }
    // The sine at this pitch (~490 Hz) moves at most ~8.4 per sample.
    try testing.expect(worst <= 10);
    // And it is silent by the end.
    try testing.expectEqual(@as(u8, 128), buf[734]);
}

test "play: a hand returning after quiet jumps, a quick return glides" {
    var p: Player = .{};
    const s: Settings = .{ .scale = .off };
    for (0..4) |_| _ = frame(&p, hand(400), s);
    for (0..absent_grace) |_| _ = frame(&p, hand(null), s);
    // Back at once (well inside jump_after): no jump, it glides up.
    const quick = frame(&p, hand(100), s);
    try testing.expect(!quick[0].jump);
    try testing.expect(quick[0].cents < p.map.cents(s.low(), 100));
    for (0..absent_grace) |_| _ = frame(&p, hand(null), s);
    for (0..10) |_| _ = frame(&p, hand(null), s);
    const late = frame(&p, hand(400), s);
    try testing.expect(late[0].jump);
    try testing.expectEqual(p.map.cents(s.low(), 400), late[0].cents);
}

test "play: smoothing removes jitter but keeps hand vibrato" {
    const s: Settings = .{ .scale = .off };
    // Jitter: +-6 mm of noise on a still hand at 250 mm.
    {
        var p: Player = .{};
        var rng = std.Random.DefaultPrng.init(7);
        const r = rng.random();
        var in_sq: i64 = 0;
        var out_sq: i64 = 0;
        const centre = p.map.cents(s.low(), 250);
        for (0..300) |i| {
            const noise: i32 = r.intRangeAtMost(i32, -6, 6);
            const mm: u16 = @intCast(250 + noise);
            const o = frame(&p, hand(mm), s);
            if (i < 20) continue;
            const din = p.map.cents(s.low(), mm) - centre;
            in_sq += din * din;
            for (o) |q| out_sq += @divTrunc((q.cents - centre) * (q.cents - centre), 2);
        }
        // At least halves the jitter's power.
        try testing.expect(out_sq * 2 < in_sq);
    }
    // Vibrato: a 5 Hz, +-5 mm wobble keeps over half its depth.
    {
        var p: Player = .{};
        var lo: Cents = std.math.maxInt(Cents);
        var hi: Cents = std.math.minInt(Cents);
        for (0..120) |i| {
            const t: f64 = @as(f64, @floatFromInt(i)) / 30.0;
            const mm: u16 = @intFromFloat(250.0 + 5.0 * @sin(2 * std.math.pi * 5.0 * t));
            const o = frame(&p, hand(mm), s);
            if (i < 30) continue;
            for (o) |q| {
                lo = @min(lo, q.cents);
                hi = @max(hi, q.cents);
            }
        }
        const in_depth = p.map.cents(s.low(), 245) - p.map.cents(s.low(), 255);
        try testing.expect((hi - lo) * 2 > in_depth);
    }
}

test "play: two-hand volume follows the volume hand; one-hand ignores it" {
    var p: Player = .{};
    var s: Settings = .{ .layout = .two_hand, .scale = .off };
    var o: [2]Output = undefined;
    for (0..6) |_| o = frame(&p, .{ .pitch_mm = 200, .volume_mm = 60 }, s);
    try testing.expect(o[1].level < 100);
    for (0..6) |_| o = frame(&p, .{ .pitch_mm = 200, .volume_mm = 190 }, s);
    try testing.expect(o[1].level > voice.full / 5 and o[1].level < voice.full * 2 / 5);
    // No volume hand: full, like a theremin.
    for (0..6) |_| o = frame(&p, .{ .pitch_mm = 200, .volume_mm = null }, s);
    try testing.expect(o[1].level > voice.full * 9 / 10);
    s.layout = .one_hand;
    for (0..6) |_| o = frame(&p, .{ .pitch_mm = 200, .volume_mm = 60 }, s);
    try testing.expect(o[1].level > voice.full * 9 / 10);
    try testing.expectEqual(@as(i32, 0), volume_for(30));
    try testing.expectEqual(voice.full, volume_for(500));
}

test "play: the stick steps through the scale, glides when held, sustains, releases" {
    var p: Player = .{};
    const s: Settings = .{ .scale = .major, .snap = .hard };
    p.target = s.low(); // C3
    p.smooth_q8 = p.target << 8;
    // Tap Up: D3, then E3, then F3 (major).
    for ([_]Cents{ 5000, 5200, 5300 }) |want| {
        p.stick(1, false, s);
        _ = p.tick(s);
        try testing.expectEqual(want, p.target);
        for (0..8) |_| {
            p.stick(0, false, s);
            _ = p.tick(s);
        }
    }
    try testing.expect(p.gate);
    // Settled and snapped: the output is on F3 give or take the vibrato.
    try testing.expect(@abs(p.out.cents - 5300) <= vib_depth);
    // Hold Up: after glide_delay it climbs on its own.
    for (0..60) |_| {
        p.stick(1, false, s);
        _ = p.tick(s);
    }
    try testing.expect(p.target > 5300 + 600);
    // Clamped at the top of the range.
    for (0..200) |_| {
        p.stick(1, false, s);
        _ = p.tick(s);
    }
    try testing.expectEqual(s.low() + p.map.range_cents, p.target);
    // Let go: sustains, then releases.
    for (0..stick_sustain) |_| {
        p.stick(0, false, s);
        try testing.expect(!p.tick(s).release);
    }
    p.stick(0, false, s);
    try testing.expect(p.tick(s).release);
    // Left/Right hold keeps it going without moving.
    p.stick(0, true, s);
    const o = p.tick(s);
    try testing.expect(!o.release);
}

test "play: the range follows the key and octave" {
    try testing.expectEqual(@as(Cents, 4800), (Settings{}).low());
    try testing.expectEqual(@as(Cents, 5700), (Settings{ .root = 9 }).low());
    try testing.expectEqual(@as(Cents, 6000), (Settings{ .octave = 4 }).low());
    try testing.expectEqual(@as(Cents, 6200), step(6000, 1, .{ .scale = .pentatonic }));
    try testing.expectEqual(@as(Cents, 5700), step(6000, -1, .{ .scale = .pentatonic }));
    try testing.expectEqual(@as(Cents, 6100), step(6020, 1, .{ .scale = .off }));
}
