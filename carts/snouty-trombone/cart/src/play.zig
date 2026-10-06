//! The playing logic, once per update (SPEC section 2): hand readings or
//! the stick in, what the voice should do out. Pure, host-tested.
//!
//! Sensor path, per new frame: the hand height goes through a three-frame
//! median and the slide map; the hand's side to side (pose centroid) sets
//! the lip. Per update the slide follows its target through a one-pole
//! smoother (half the gap per update: removes the 30 Hz frame steps and
//! sensor jitter, keeps a hand's 4-7 Hz slide vibrato), then SNAP; the lip
//! is smoothed the same way and picks the partial (horn.Embouchure, with
//! hysteresis and the lip bend). A partial change while sounding is a
//! crack (the voice's split-tone blip).
//!
//! Blowing: BLOW AUTO sounds while a hand is in range (no hand for
//! `absent_grace` frames releases), and A re-tongues; BLOW A sounds while
//! A is held. With the stick (no sensor) A always blows. Every onset is a
//! tongued attack; a note started after `jump_after` updates of quiet
//! starts at its own pitch instead of sliding from the last one.
//!
//! Stick path: Up/Down tap to the next slide position in or out, held past
//! `glide_delay` the slide moves continuously (accelerating); Left/Right
//! tap a partial down/up and, held, lip the pitch toward the next one.
const horn = @import("horn.zig");
const tof_types = @import("tof").types;
const Cents = horn.Cents;

pub const Blow = enum(u1) {
    auto,
    a,
    pub fn label(b: Blow) []const u8 {
        return if (b == .auto) "AUTO" else "A";
    }
};
pub const Snap = enum(u1) {
    off,
    soft,
    pub fn label(s: Snap) []const u8 {
        return if (s == .off) "OFF" else "SOFT";
    }
};
pub const Tone = enum(u1) {
    bright,
    mellow,
    pub fn label(t: Tone) []const u8 {
        return if (t == .bright) "BRIGHT" else "MELLOW";
    }
};

pub const Settings = struct {
    /// ZONES' boot value (also the pose estimator's and input's).
    pub const default_zones: tof_types.Layout = .stripes;

    blow: Blow = .auto,
    snap: Snap = .off,
    /// Mirror the sensor left/right (`Orientation.flip_x`).
    mirror: bool = false,
    /// Partial 1 (the pedal) on the lip's low end.
    pedal: bool = false,
    tone: Tone = .bright,
    /// ZONES: the sensor's zone layout (docs/TOF.md M5). STRIPES (8
    /// full-height stripes) resolve side to side about 3x finer than GRID
    /// (the 3x3 of the wide map); the lip span follows (hand.Config).
    zones: tof_types.Layout = default_zones,
    /// The demo hand plays (SPEC section 4).
    demo: bool = false,
};

// ---- Knobs ----

/// Slide and lip smoothers: fraction of the gap closed per update (Q8).
pub const glide_q8: i32 = 128;
pub const lip_glide_q8: i32 = 128;
/// Sensor frames without a hand before the note releases (~100 ms at 30 Hz).
pub const absent_grace: u8 = 3;
/// Updates of quiet after which a new note jumps to its pitch.
pub const jump_after: u16 = 12;
/// Stick: updates a direction is held before the slide moves on its own,
/// its speed (slide cents per update, start and top).
pub const glide_delay: u16 = 15;
pub const glide_start: i32 = 4;
pub const glide_top: i32 = 24;
/// Stick lip: updates Left/Right are held before the lip bends, the bend
/// speed (Q8 lip per update) and how far (just short of the crack).
pub const bend_delay: u16 = 12;
pub const bend_rate: i32 = 6;
pub const bend_reach: i32 = horn.lip_one / 2 + horn.hysteresis - 6;
/// Stick vibrato (the stick has no hand wobble): depth (cents), period
/// (updates), onset (updates of a held, settled note).
pub const vib_depth: i32 = 10;
pub const vib_period: u16 = 11;
pub const vib_delay: u16 = 24;

pub const Output = struct {
    cents: Cents,
    /// Q16 (0 or full: a trombone at one dynamic).
    level: i32,
    /// Not blowing: the voice's release.
    release: bool,
    /// The voice should jump to the pitch (a fresh note).
    jump: bool = false,
    /// A tongued attack this update (an onset, or A re-tonguing).
    tongue: bool = false,
    /// The partial changed while sounding: the pitch it cracked from.
    crack_from: ?Cents = null,
    /// The plunger mute is held.
    mute: bool = false,
    /// Slide out (cents, 0..600) after SNAP, for the screen.
    slide: i32 = 0,
    /// Lip value (Q8 partial units) and the sounding partial.
    lip: i32 = 4 * horn.lip_one,
    partial: u4 = 4,
};

/// What the buttons say this update (main.zig fills it).
pub const Buttons = struct {
    /// A held / pressed this update.
    a: bool = false,
    a_press: bool = false,
    /// B held (the plunger).
    b: bool = false,
};

pub const full: i32 = 65536;

pub const Player = struct {
    map: horn.SlideMap = .{},
    slide_target: i32 = 0,
    slide_q8: i32 = 0,
    lip_target: i32 = 4 * horn.lip_one,
    lip_q8: i32 = (4 * horn.lip_one) << 8,
    emb: horn.Embouchure = .{},
    median: horn.Median3 = .{},
    hand: bool = false,
    absent_frames: u8 = absent_grace,
    gate: bool = false,
    quiet_ticks: u16 = jump_after,
    stick_mode: bool = false,
    // Stick state.
    prev_dir: i2 = 0,
    held_ticks: u16 = 0,
    prev_lr: i2 = 0,
    lr_ticks: u16 = 0,
    stick_partial: u4 = 4,
    stick_bend: i32 = 0,
    settled_ticks: u16 = 0,
    vib_tick: u16 = 0,
    /// Last output (the screen reads it).
    out: Output = .{ .cents = horn.pitch(4, 0, 0), .level = 0, .release = true },

    /// A new sensor frame: the hand height (null: none) and lip tension
    /// (null: hold the last).
    pub fn sensor(p: *Player, height_mm: ?u16, lip_t: ?i32, s: Settings) void {
        p.stick_mode = false;
        if (height_mm) |mm| {
            if (!p.hand and p.quiet_ticks >= jump_after) p.median.reset();
            p.absent_frames = 0;
            p.hand = true;
            p.slide_target = p.map.slide(p.median.push(mm));
        } else {
            if (p.absent_frames < 255) p.absent_frames += 1;
            if (p.absent_frames >= absent_grace) p.hand = false;
        }
        if (lip_t) |t| p.lip_target = horn.lip_for(t, s.pedal);
    }

    /// The stick, every update while there is no sensor: `dir` +1 Up
    /// (slide in), -1 Down (slide out); `lr` -1 Left (partial down),
    /// +1 Right (up).
    pub fn stick(p: *Player, dir: i2, lr: i2, s: Settings) void {
        if (!p.stick_mode) {
            p.stick_mode = true;
            p.prev_dir = 0;
            p.prev_lr = 0;
            p.stick_partial = p.emb.partial;
        }
        p.hand = false;
        // Slide: Up is in (toward 1st), Down out.
        if (dir != 0) {
            if (dir != p.prev_dir) {
                p.slide_target = step_position(p.slide_target, -@as(i32, dir));
                p.held_ticks = 0;
            } else {
                p.held_ticks +|= 1;
                if (p.held_ticks > glide_delay) {
                    const rate = @min(glide_start + @divTrunc(@as(i32, p.held_ticks - glide_delay), 2), glide_top);
                    p.slide_target -= rate * @as(i32, dir);
                }
            }
            p.slide_target = @min(@max(p.slide_target, 0), horn.slide_max);
        }
        p.prev_dir = dir;
        // Lip: a press steps the partial, holding lips toward the next.
        const lo = horn.lowest_partial(s.pedal);
        if (p.stick_partial < lo) p.stick_partial = lo;
        if (lr != 0) {
            if (lr != p.prev_lr) {
                const n: i32 = @as(i32, p.stick_partial) + lr;
                p.stick_partial = @intCast(@min(@max(n, lo), horn.top_partial));
                p.lr_ticks = 0;
                p.stick_bend = 0;
            } else {
                p.lr_ticks +|= 1;
                if (p.lr_ticks > bend_delay) p.stick_bend = @min(p.stick_bend + bend_rate, bend_reach);
            }
        } else {
            p.stick_bend = @max(p.stick_bend - 3 * bend_rate, 0);
        }
        const sign: i32 = if (lr != 0) lr else p.prev_lr;
        p.prev_lr = if (lr != 0) lr else (if (p.stick_bend > 0) p.prev_lr else 0);
        p.lip_target = @as(i32, p.stick_partial) * horn.lip_one + sign * p.stick_bend;
    }

    /// Advance one update.
    pub fn tick(p: *Player, s: Settings, b: Buttons) Output {
        // Blowing.
        const was = p.gate;
        p.gate = if (p.stick_mode) b.a else switch (s.blow) {
            .auto => p.hand or b.a,
            .a => b.a,
        };
        var out: Output = .{ .cents = p.out.cents, .level = 0, .release = !p.gate, .mute = b.b };
        if (p.gate and !was) {
            out.tongue = true;
            if (p.quiet_ticks >= jump_after) {
                // A fresh note: no slide or lip glide in from the last one.
                p.slide_q8 = p.slide_target << 8;
                p.lip_q8 = p.lip_target << 8;
                out.jump = true;
            }
        } else if (p.gate and b.a_press and !p.stick_mode and s.blow == .auto) {
            out.tongue = true;
        }
        if (p.gate) p.quiet_ticks = 0 else p.quiet_ticks +|= 1;

        // Slide and lip smoothing.
        p.slide_q8 += @divTrunc(((p.slide_target << 8) - p.slide_q8) * glide_q8, 256);
        p.lip_q8 += @divTrunc(((p.lip_target << 8) - p.lip_q8) * lip_glide_q8, 256);
        var slide = (p.slide_q8 + 128) >> 8;
        if (s.snap == .soft) slide = horn.snap_soft(slide);
        const lip = (p.lip_q8 + 128) >> 8;

        const old_pitch = p.out.cents;
        const changed = p.emb.update(lip, s.pedal);
        var c = horn.pitch(p.emb.partial, slide, p.emb.bend(lip));
        if (changed and p.gate and !out.jump and !out.tongue) out.crack_from = old_pitch;

        // A gentle vibrato on a long stick note (a hand brings its own).
        const moving = @abs((p.slide_target << 8) - p.slide_q8) > (3 << 8) or p.prev_dir != 0;
        if (p.stick_mode and p.gate and !moving) p.settled_ticks +|= 1 else p.settled_ticks = 0;
        p.vib_tick = if (p.vib_tick + 1 >= vib_period) 0 else p.vib_tick + 1;
        if (p.settled_ticks > vib_delay) {
            const ramp: i32 = @min(@as(i32, p.settled_ticks - vib_delay), vib_delay);
            c += @divTrunc(tri(p.vib_tick) * vib_depth * ramp, vib_delay * 256);
        }

        out.cents = c;
        out.level = if (p.gate) full else 0;
        out.slide = slide;
        out.lip = lip;
        out.partial = p.emb.partial;
        p.out = out;
        return out;
    }
};

/// The next whole position in (`d` -1) or out (+1) from `slide`.
pub fn step_position(slide: i32, d: i32) i32 {
    const pc = horn.position_cents;
    const n = if (d > 0) @divFloor(slide, pc) + 1 else @divFloor(slide + pc - 1, pc) - 1;
    return @min(@max(n * pc, 0), horn.slide_max);
}

/// A triangle LFO, -256..256 over `vib_period` updates.
fn tri(t: u16) i32 {
    const half: i32 = vib_period / 2;
    const x: i32 = @as(i32, t);
    const up = if (x <= half) x else @as(i32, vib_period) - x;
    return @divTrunc(up * 512, half) - 256;
}

// ---- Host tests ----

const std = @import("std");
const testing = std.testing;

/// One sensor frame then two updates (30 Hz frames, 60 Hz updates).
fn frame(p: *Player, mm: ?u16, t: ?i32, s: Settings, b: Buttons) [2]Output {
    p.sensor(mm, t, s);
    const a = p.tick(s, b);
    var b2 = b;
    b2.a_press = false;
    return .{ a, p.tick(s, b2) };
}

fn t_of(partial: u4) i32 {
    return horn.t_for(@as(i32, partial) * horn.lip_one, false);
}

test "play: a hand blows a tongued note at its slide and partial" {
    var p: Player = .{};
    const s: Settings = .{};
    _ = frame(&p, null, null, s, .{});
    try testing.expectEqual(@as(i32, 0), p.out.level);
    // Hand at 3rd position (217 mm), lip on partial 4: Ab3, tongued, jumped.
    const o = frame(&p, p.map.distance(200), t_of(4), s, .{});
    try testing.expect(o[0].tongue and o[0].jump);
    try testing.expect(!o[1].tongue and !o[1].jump);
    try testing.expectEqual(@as(u4, 4), o[0].partial);
    // (The hand height is whole millimetres: a cent or two.)
    try testing.expect(@abs(horn.pitch(4, 200, 0) - o[0].cents) <= 2);
    try testing.expectEqual(full, o[0].level);
    try testing.expectEqualStrings("Ab3", blk: {
        var buf: [4]u8 = undefined;
        break :blk horn.note_name(horn.nearest(o[0].cents).midi, &buf);
    });
}

test "play: the slide glisses smoothly and monotonically with the hand" {
    var p: Player = .{};
    const s: Settings = .{};
    _ = frame(&p, 100, t_of(5), s, .{});
    var last = p.out.cents;
    var mm: u16 = 100;
    // Lower the hand 6 mm per frame: a long gliss down, no cracks, no steps.
    while (mm < 450) : (mm += 6) {
        const o = frame(&p, mm, t_of(5), s, .{});
        for (o) |q| {
            try testing.expect(q.cents <= last);
            try testing.expect(last - q.cents <= 12);
            try testing.expectEqual(@as(?Cents, null), q.crack_from);
            last = q.cents;
        }
    }
    for (0..20) |_| _ = frame(&p, 450, t_of(5), s, .{});
    try testing.expectEqual(horn.pitch(5, horn.slide_max, 0), p.out.cents);
}

test "play: a dropped frame keeps the note; an absent hand releases it" {
    var p: Player = .{};
    const s: Settings = .{};
    for (0..5) |_| _ = frame(&p, 200, t_of(4), s, .{});
    const d = frame(&p, null, null, s, .{});
    try testing.expect(!d[1].release);
    _ = frame(&p, 200, t_of(4), s, .{});
    var o: [2]Output = undefined;
    for (0..absent_grace) |_| o = frame(&p, null, null, s, .{});
    try testing.expect(o[1].release);
    try testing.expectEqual(@as(i32, 0), o[1].level);
}

test "play: moving the lip cracks between partials only while sounding" {
    var p: Player = .{};
    const s: Settings = .{};
    for (0..6) |_| _ = frame(&p, 100, t_of(4), s, .{});
    try testing.expectEqual(@as(u4, 4), p.out.partial);
    // Lip over to partial 5: one crack, from the old pitch.
    var cracks: u32 = 0;
    for (0..8) |_| {
        for (frame(&p, 100, t_of(5), s, .{})) |q| {
            if (q.crack_from) |from| {
                cracks += 1;
                try testing.expect(from < q.cents);
            }
        }
    }
    try testing.expectEqual(@as(u32, 1), cracks);
    try testing.expectEqual(horn.pitch(5, 0, 0), p.out.cents);
    // Silent (BLOW A, A up): the partial follows without a crack.
    const sa: Settings = .{ .blow = .a };
    for (0..8) |_| for (frame(&p, 100, t_of(3), sa, .{})) |q| try testing.expectEqual(@as(?Cents, null), q.crack_from);
    try testing.expectEqual(@as(u4, 3), p.out.partial);
}

test "play: BLOW A sounds only with A; AUTO re-tongues on A" {
    var p: Player = .{};
    const sa: Settings = .{ .blow = .a };
    var o = frame(&p, 200, t_of(4), sa, .{});
    try testing.expect(o[1].release);
    o = frame(&p, 200, t_of(4), sa, .{ .a = true, .a_press = true });
    try testing.expect(o[0].tongue and !o[0].release);
    o = frame(&p, 200, t_of(4), sa, .{ .a = true });
    try testing.expect(!o[0].tongue and !o[0].release);
    // AUTO: the hand blows; an A press is a fresh attack without moving.
    var q: Player = .{};
    const s: Settings = .{};
    for (0..4) |_| _ = frame(&q, 200, t_of(4), s, .{});
    const before = q.out.cents;
    o = frame(&q, 200, t_of(4), s, .{ .a = true, .a_press = true });
    try testing.expect(o[0].tongue and !o[0].jump);
    try testing.expectEqual(before, o[0].cents);
    // B holds the plunger.
    o = frame(&q, 200, t_of(4), s, .{ .b = true });
    try testing.expect(o[0].mute);
}

test "play: the stick taps positions, glides when held, steps partials" {
    var p: Player = .{};
    const s: Settings = .{};
    const blow: Buttons = .{ .a = true };
    // Tap Down three times: 4th position.
    for (0..3) |_| {
        p.stick(-1, 0, s);
        _ = p.tick(s, blow);
        for (0..6) |_| {
            p.stick(0, 0, s);
            _ = p.tick(s, blow);
        }
    }
    try testing.expectEqual(@as(i32, 300), p.slide_target);
    for (0..20) |_| {
        p.stick(0, 0, s);
        _ = p.tick(s, blow);
    }
    // Settled on G3 (4th partial, 4th position), give or take the vibrato.
    try testing.expect(@abs(p.out.cents - horn.pitch(4, 300, 0)) <= vib_depth);
    // Tap Right: 5th partial (B3), a crack on the way.
    p.stick(0, 1, s);
    var o = p.tick(s, blow);
    var cracked = o.crack_from != null;
    for (0..10) |_| {
        p.stick(0, 0, s);
        o = p.tick(s, blow);
        cracked = cracked or o.crack_from != null;
    }
    try testing.expect(cracked);
    try testing.expectEqual(@as(u4, 5), o.partial);
    // Hold Right: lips up toward the 6th without cracking.
    for (0..60) |i| {
        p.stick(0, 1, s);
        o = p.tick(s, blow);
        if (i > 4) try testing.expectEqual(@as(u4, 6), o.partial);
    }
    try testing.expect(o.cents > horn.pitch(6, 300, 0) + 30);
    // Hold Up: the slide comes in on its own, all the way to 1st.
    for (0..120) |_| {
        p.stick(1, 0, s);
        _ = p.tick(s, blow);
    }
    try testing.expectEqual(@as(i32, 0), p.slide_target);
    // No A: silent.
    p.stick(0, 0, s);
    try testing.expect(p.tick(s, .{}).release);
    try testing.expectEqual(@as(i32, 200), step_position(130, 1));
    try testing.expectEqual(@as(i32, 100), step_position(130, -1));
    try testing.expectEqual(@as(i32, 0), step_position(100, -1));
    try testing.expectEqual(horn.slide_max, step_position(horn.slide_max, 1));
}

test "play: SNAP SOFT pulls the slide toward the positions" {
    var p: Player = .{};
    const s: Settings = .{ .snap = .soft };
    for (0..30) |_| _ = frame(&p, p.map.distance(215), t_of(4), s, .{});
    const off = p.out.slide - 200;
    try testing.expect(off > 0 and off < 15);
}
