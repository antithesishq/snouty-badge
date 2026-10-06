//! Where hand readings come from (SPEC section 2 and 4).
//!
//! `sensor_frame` below is the TMF8820 (sensor.zig: lib/tof.zig on the
//! Qwiic port); it returns null until the sensor measures, and always in
//! the simulator and the host tests.
//!
//! `Input.poll` picks the source each update: the sensor as soon as a
//! frame arrives, back to the stick after `sensor_timeout` updates
//! without one (a breakout unplugged mid-tune). The demo hand (`fake` on:
//! the DEMO menu row, the wasm export `debug_set_fake_sensor`, the
//! badge-bench poke `snouty_trombone_fake`) renders a synthetic hand
//! (lib/tof_synth.zig) through the same path, so the sensor code runs in
//! the simulator and the bench; it also "presses" A (re-tongues) and B
//! (the plunger) on cue.
//!
//! The demo's tune: lip slurs up and down the harmonic series at 4th
//! position (a bugle call on G), a long glissando on the 5th partial out
//! to 7th position and back, then the sad trombone (D4 Db4 C4 B3, a
//! plunger "wah" on each, the last one long with slide vibrato and
//! wah-wah-wah), a rest, and round again.
const tof = @import("tof");
const tof_types = tof.types;
const sensor = @import("sensor.zig");
const horn = @import("horn.zig");
const hand = @import("hand.zig");
pub const Frame = tof_types.Frame;

/// The sensor's latest frame, or null (none yet, no sensor, or the driver
/// is still booting). Called once per update with `micros_since_boot`.
pub fn sensor_frame(now_us: u64) ?Frame {
    return sensor.frame(now_us);
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
    /// Demo hand on.
    fake: bool = false,
    /// The update the demo hand started at (its tune starts there).
    fake_from: u32 = 0,
    /// The zone layout the demo hand renders (ZONES).
    layout: tof_types.Layout = .stripes,

    pub fn set_fake(in: *Input, on: bool, tick: u32) void {
        if (!in.fake and on) in.fake_from = tick & ~@as(u32, 1);
        in.fake = on;
    }

    /// The new frame this update, if any; updates `source`.
    pub fn poll(in: *Input, now_us: u64, tick: u32) ?Frame {
        const got = if (in.fake) fake_frame(tick -% in.fake_from, in.layout) else sensor_frame(now_us);
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

    /// The demo's buttons this update (none when the demo is off).
    pub fn fake_buttons(in: *const Input, tick: u32) DemoButtons {
        if (!in.fake) return .{};
        return demo_buttons(tick -% in.fake_from);
    }
};

// ---- The demo hand ----

pub const DemoButtons = struct { a: bool = false, b: bool = false };

const Mute = enum { open, wah, wahwah };

/// One step of the demo tune: `frames` sensor frames (30 Hz) with the hand
/// gliding from slide `from` to `to` (cents), at `x` mm (the partial, see
/// `hand.x_for`), re-tongued (A) on its first frame, with the plunger pattern.
const Step = struct {
    frames: u16,
    from: i16 = 0,
    to: i16 = 0,
    partial: u4 = 5,
    hand: bool = true,
    tongue: bool = false,
    mute: Mute = .open,
    vibrato: bool = false,
};

fn hold(frames: u16, slide: i16, partial: u4) Step {
    return .{ .frames = frames, .from = slide, .to = slide, .partial = partial };
}

const tune = [_]Step{
    .{ .frames = 15, .hand = false },
    // Bugle call on the 4th position's partials (D3 G3 B3 D4 ...): lip slurs.
    hold(12, 300, 3),
    hold(9, 300, 4),
    hold(9, 300, 5),
    hold(18, 300, 6),
    hold(9, 300, 5),
    hold(9, 300, 4),
    hold(24, 300, 3),
    .{ .frames = 8, .hand = false },
    // The glissando on the 5th partial: 1st position out to 7th and back.
    .{ .frames = 12, .from = 0, .to = 0, .tongue = true },
    .{ .frames = 45, .from = 0, .to = 600 },
    .{ .frames = 6, .from = 600, .to = 600 },
    .{ .frames = 30, .from = 600, .to = 0 },
    .{ .frames = 12, .from = 0, .to = 0 },
    .{ .frames = 10, .hand = false },
    // The sad trombone: wah, wah, wah, waaah.
    .{ .frames = 13, .from = 0, .to = 0, .tongue = true, .mute = .wah },
    .{ .frames = 13, .from = 100, .to = 100, .tongue = true, .mute = .wah },
    .{ .frames = 13, .from = 200, .to = 200, .tongue = true, .mute = .wah },
    .{ .frames = 66, .from = 300, .to = 300, .tongue = true, .mute = .wahwah, .vibrato = true },
    .{ .frames = 36, .hand = false },
};

fn tune_frames() u32 {
    var n: u32 = 0;
    for (tune) |s| n += s.frames;
    return n;
}

const Where = struct { step: *const Step, within: u32 };

fn where(n: u32) Where {
    var k = n % tune_frames();
    for (&tune) |*s| {
        if (k < s.frames) return .{ .step = s, .within = k };
        k -= s.frames;
    }
    unreachable;
}

/// The demo hand's scene: a flat hand, a ceiling at 1.3 m.
const scene_base: tof.synth.Scene = .{ .fov_x_deg = 41, .fov_y_deg = 52, .noise_mm = 1.5, .background_mm = @splat(1300) };

/// One synthetic frame every other update (30 Hz), seen through `layout`.
/// The hand's x for a partial is the middle of that partial's lip band at
/// its height (hand.x_for: the lip is an angle, so x scales with height).
pub fn fake_frame(tick: u32, layout: tof_types.Layout) ?Frame {
    if (tick % 2 != 0) return null;
    const n = tick / 2;
    const w = where(n);
    const s = w.step;
    var f: Frame = .{ .seq = n, .time_us = 1_000_000 + @as(u64, tick) * 16_667 };
    var scene = scene_base;
    if (s.hand) {
        const map: horn.SlideMap = .{};
        const slide: i32 = s.from + @divTrunc((@as(i32, s.to) - s.from) * @as(i32, @intCast(w.within)), @max(@as(i32, s.frames) - 1, 1));
        var z: f32 = @floatFromInt(map.distance(slide));
        // Slide vibrato: +-6 mm at 5 Hz.
        if (s.vibrato and w.within > 8) {
            const tri = [6]f32{ 0, 5, 5, 0, -5, -5 };
            z += tri[w.within % 6];
        }
        const span = (hand.Config{}).span(layout);
        scene.hand = .{ .x_mm = hand.x_for(s.partial, false, z, span), .z_mm = z, .pitch = 0.04 };
    } else {
        scene.hand = null;
    }
    scene.layout = layout;
    var seed: u32 = n *% 2654435761 +% 12345;
    tof.synth.render(&scene, .{}, &f, null, &seed);
    return f;
}

/// The demo's A (a one-frame tap on a tongued step's first frame) and B
/// (the plunger: shut for the first frames of a "wah", then open; the long
/// note shuts and opens twice more).
pub fn demo_buttons(tick: u32) DemoButtons {
    const w = where(tick / 2);
    const s = w.step;
    var b: DemoButtons = .{ .a = s.tongue and w.within == 0 };
    b.b = switch (s.mute) {
        .open => false,
        .wah => w.within < 4,
        .wahwah => w.within < 4 or (w.within >= 18 and w.within < 26) or (w.within >= 34 and w.within < 44),
    };
    return b;
}

// ---- Host tests ----

const std = @import("std");
const testing = std.testing;
const play = @import("play.zig");

test "input: no sensor and no demo is the stick" {
    var in: Input = .{};
    for (0..10) |t| try testing.expectEqual(@as(?Frame, null), in.poll(0, @intCast(t)));
    try testing.expectEqual(Source.stick, in.source);
}

test "input: frames switch to the sensor, a long silence back to the stick" {
    var in: Input = .{ .fake = true };
    var got: u32 = 0;
    for (0..20) |t| {
        if (in.poll(0, @intCast(t)) != null) got += 1;
    }
    try testing.expectEqual(@as(u32, 10), got);
    try testing.expectEqual(Source.sensor, in.source);
    in.fake = false;
    var t: u32 = 20;
    while (t <= 18 + sensor_timeout) : (t += 1) _ = in.poll(0, t);
    try testing.expectEqual(Source.sensor, in.source);
    _ = in.poll(0, t);
    try testing.expectEqual(Source.stick, in.source);
}

// The whole demo through the real path (hand.zig, the pose, the player):
// the notes it plays, one per tongued or slurred step.
test "input: the demo hand plays its tune through the sensor path, both layouts" {
    for ([_]tof_types.Layout{ .grid, .stripes }) |l| try demo_tune(l);
}

fn demo_tune(layout: tof_types.Layout) !void {
    var est: tof.pose.Estimator = .{ .config = hand.pose_config };
    est.set_layout(layout);
    var p: play.Player = .{};
    const s: play.Settings = .{};
    var prev: DemoButtons = .{};
    // The note sounding in the middle of each step (or none), per step.
    var heard: [tune.len]?i32 = @splat(null);
    var cracks: u32 = 0;
    var tongues: u32 = 0;
    var muted_ticks: u32 = 0;
    const total = tune_frames() * 2;
    var tick: u32 = 0;
    while (tick < total) : (tick += 1) {
        if (fake_frame(tick, layout)) |f| {
            try testing.expectEqual(layout, f.layout);
            const pose = est.update(&f, null, .{});
            const r = hand.read(&pose, .{});
            p.sensor(r.height_mm, r.lip_t, s);
        }
        const b = demo_buttons(tick);
        const o = p.tick(s, .{ .a = b.a, .a_press = b.a and !prev.a, .b = b.b });
        prev = b;
        if (o.crack_from != null) cracks += 1;
        if (o.tongue) tongues += 1;
        if (o.mute) muted_ticks += 1;
        const w = where(tick / 2);
        const idx = (@intFromPtr(w.step) - @intFromPtr(&tune[0])) / @sizeOf(Step);
        if (w.within == w.step.frames * 3 / 4 and tick % 2 == 0) {
            heard[idx] = if (o.release) null else horn.nearest(o.cents).midi;
        }
    }
    // Bugle call at 4th position: D3 G3 B3 D4 B3 G3 D3.
    const bugle = [_]i32{ 50, 55, 59, 62, 59, 55, 50 };
    for (bugle, 1..) |m, i| try testing.expectEqual(@as(?i32, m), heard[i]);
    // Glissando: D4 at 1st, Ab3 at 7th (5th partial), back to D4.
    try testing.expectEqual(@as(?i32, 62), heard[9]);
    try testing.expectEqual(@as(?i32, 56), heard[11]);
    try testing.expectEqual(@as(?i32, 62), heard[13]);
    // Sad trombone: D4 Db4 C4 B3.
    for ([_]i32{ 62, 61, 60, 59 }, 15..) |m, i| try testing.expectEqual(@as(?i32, m), heard[i]);
    // Rests are silent.
    try testing.expectEqual(@as(?i32, null), heard[0]);
    try testing.expectEqual(@as(?i32, null), heard[tune.len - 1]);
    // Slurs crack (six in the bugle call, a few more moving between
    // phrases), the tongued notes tongue, the plunger works.
    try testing.expect(cracks >= 6 and cracks <= 14);
    try testing.expect(tongues >= 6);
    try testing.expect(muted_ticks > 60);
}
