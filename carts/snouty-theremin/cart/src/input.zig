//! Where hand readings come from (SPEC section 3).
//!
//! THE SENSOR INTEGRATION POINT is `sensor_frame` below: the TMF8820
//! driver (lib/tof.zig, docs/TOF.md M0) is not on this branch yet, so it
//! returns null and the cart plays from the stick. Wiring the driver is
//! that one function plus its module import in ../../build.zig
//! (`add_modules`); nothing else in the cart changes.
//!
//! `Input.poll` picks the source each update: the sensor as soon as a
//! frame arrives, back to the stick after `sensor_timeout` updates
//! without one (a breakout unplugged mid-song). The demo hand
//! (`fake` != 0: badge-bench pokes and the wasm debug export) produces
//! choreographed frames through the same path, so the sensor UI and code
//! run in the simulator and the bench.
const tof_types = @import("tof_types");
const pitch = @import("pitch.zig");
pub const Frame = tof_types.Frame;

/// Return a sensor frame that is new since the last call, or null (none
/// yet, no sensor, or the driver is still booting). Called once per
/// update with `micros_since_boot`; this is where the driver's
/// `poll(now_us)` goes, e.g.
///
///     tof_state.poll(now_us);
///     return tof_state.take_frame();   // null unless a new one landed
pub fn sensor_frame(now_us: u64) ?Frame {
    _ = now_us;
    return null;
}

pub const Source = enum(u1) { stick, sensor };

/// Updates without a sensor frame before the stick takes over (1.5 s).
pub const sensor_timeout: u32 = 90;

pub const Input = struct {
    source: Source = .stick,
    /// The update of the last sensor frame.
    last_tick: u32 = 0,
    last_seq: ?u32 = null,
    /// Sensor frames taken (all time).
    frames: u32 = 0,
    /// Demo hand: 0 off, 1 one hand, 2 two hands (`set_fake`).
    fake: u8 = 0,
    /// The update the demo hand started at (its melody starts there).
    fake_from: u32 = 0,

    pub fn set_fake(in: *Input, mode: u8, tick: u32) void {
        if (in.fake == 0 and mode != 0) in.fake_from = tick & ~@as(u32, 1);
        in.fake = mode;
    }

    /// The new frame this update, if any; updates `source`.
    pub fn poll(in: *Input, now_us: u64, tick: u32) ?Frame {
        const got = sensor_frame(now_us) orelse if (in.fake != 0) fake_frame(in.fake, tick -% in.fake_from) else null;
        if (got) |f| {
            if (in.last_seq == null or in.last_seq.? != f.seq) {
                in.last_seq = f.seq;
                in.last_tick = tick;
                in.frames +%= 1;
                in.source = .sensor;
                return f;
            }
        }
        if (in.source == .sensor and tick -% in.last_tick > sensor_timeout) in.source = .stick;
        return null;
    }
};

// ---- The demo hand ----

/// A melody for the demo hand, in MIDI notes for the default key and
/// octave (C3..C6); 0 is a rest (hand away). Each entry lasts `beat`
/// sensor frames (30 Hz).
const demo_notes = [_]u8{ 64, 64, 65, 67, 67, 65, 64, 62, 60, 60, 62, 64, 64, 0, 62, 62, 0, 0 };
const beat = 12;
const demo_low: pitch.Cents = 4800;

/// One choreographed frame every other update (30 Hz). The pitch hand
/// sits over the screen's right column, glides between notes over a few
/// frames and wobbles at ~5.5 Hz (+-3 mm) like a real hand; mode 2 adds a
/// volume hand over the left column that dips at the end of each phrase.
pub fn fake_frame(mode: u8, tick: u32) ?Frame {
    if (tick % 2 != 0) return null;
    const n = tick / 2; // frame number
    const map: pitch.Map = .{};
    const step = (n / beat) % demo_notes.len;
    const within = n % beat;
    var f: Frame = .{ .seq = n, .time_us = @as(u64, tick) * 16_667 };
    // Background: the ceiling, too far to be a hand.
    for (&f.zones) |*z| z.near = .{ .mm = 1350, .confidence = 40 };
    const note = demo_notes[step];
    if (note != 0) {
        var mm: i32 = map.distance(demo_low, @as(pitch.Cents, note) * 100);
        // Glide in from the previous note over the first 3 frames.
        const prev = demo_notes[(step + demo_notes.len - 1) % demo_notes.len];
        if (prev != 0 and within < 3) {
            const pm: i32 = map.distance(demo_low, @as(pitch.Cents, prev) * 100);
            mm = pm + @divTrunc((mm - pm) * @as(i32, @intCast(within + 1)), 4);
        }
        mm += wobble(n);
        const hand_mm: u16 = @intCast(mm);
        for (0..3) |r| {
            const off = [3]u16{ 6, 0, 9 };
            f.zones[r * 3 + 2].near = .{ .mm = hand_mm + off[r], .confidence = 210 };
            // The middle column catches the hand's edge, weaker and further.
            if (mode == 1) f.zones[r * 3 + 1].near = .{ .mm = hand_mm + 35 + off[r], .confidence = 70 };
        }
    }
    if (mode == 2) {
        // Volume hand: high (loud) most of the phrase, sinking on the last
        // beats of each 6-note group.
        const group = step % 6;
        const vol_mm: u16 = if (group >= 4) @intCast(110 + (beat - within) * 10) else 300;
        for (0..3) |r| f.zones[r * 3].near = .{ .mm = vol_mm + @as(u16, @intCast(r)) * 4, .confidence = 190 };
    }
    return f;
}

/// -3..3 mm at ~5.5 Hz (a 30 Hz frame counter).
fn wobble(n: u32) i32 {
    const tri = [11]i8{ 0, 1, 2, 3, 2, 1, 0, -1, -2, -3, -2 };
    return tri[(n * 2) % 11];
}

// ---- Host tests ----

const std = @import("std");
const testing = std.testing;
const hands = @import("hands.zig");

test "input: no sensor and no demo is the stick" {
    var in: Input = .{};
    for (0..10) |t| try testing.expectEqual(@as(?Frame, null), in.poll(0, @intCast(t)));
    try testing.expectEqual(Source.stick, in.source);
}

test "input: frames switch to the sensor, a long silence back to the stick" {
    var in: Input = .{ .fake = 1 };
    var got: u32 = 0;
    for (0..20) |t| {
        if (in.poll(0, @intCast(t)) != null) got += 1;
    }
    try testing.expectEqual(@as(u32, 10), got);
    try testing.expectEqual(Source.sensor, in.source);
    in.fake = 0;
    // The last frame came at update 18.
    var t: u32 = 20;
    while (t <= 18 + sensor_timeout) : (t += 1) _ = in.poll(0, t);
    try testing.expectEqual(Source.sensor, in.source);
    _ = in.poll(0, t);
    try testing.expectEqual(Source.stick, in.source);
    // And straight back when frames return.
    in.fake = 2;
    _ = in.poll(0, (t + 2) & ~@as(u32, 1)); // the demo hand sends on even updates
    try testing.expectEqual(Source.sensor, in.source);
}

test "input: the demo hand reads as the right hands in both layouts" {
    // Frame 0: the first note (E4) on the right column.
    const f = fake_frame(2, 0).?;
    const one = hands.read(&f, .{});
    const map: pitch.Map = .{};
    try testing.expect(one.pitch_mm != null);
    try testing.expect(@abs(@as(i32, one.pitch_mm.?) - map.distance(demo_low, 6400)) <= 4);
    const two = hands.read(&f, .{ .layout = .two_hand });
    try testing.expect(@abs(@as(i32, two.pitch_mm.?) - map.distance(demo_low, 6400)) <= 4);
    try testing.expectEqual(@as(?u16, 300), two.volume_mm);
    // A rest: no pitch hand.
    const rest = fake_frame(1, 2 * 13 * beat).?;
    try testing.expectEqual(@as(?u16, null), hands.read(&rest, .{}).pitch_mm);
    // Odd updates have no frame.
    try testing.expectEqual(@as(?Frame, null), fake_frame(1, 1));
}
