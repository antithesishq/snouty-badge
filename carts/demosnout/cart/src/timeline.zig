//! The ordered part table and the clock that drives it (SPEC.md section 3).
//!
//! The frame clock is 120 BPM: 30 frames per beat, 120 per bar; a part lasts
//! a whole number of bars. The timeline renders the current part at its own
//! frame number `t` (frames since enter()), then veils the frame according
//! to each entry's `cut`, the hand-over to the next part: `.fade` goes to
//! black over the last `fade_frames` (plus `gap_frames` of black) and the
//! next part comes up the same way; `.dissolve` does the same with 4x4
//! blocks in Bayer order (fx.dissolve); `.seamless` has no veil on either
//! side, for a part that ends on the next part's first frame (the Ending
//! into the Intro). After the last part it loops to the first. `skip()`
//! (A/Start) and `goto()` (the picker, debug_goto) cut straight to a part's
//! frame 0, which then fades in. Every entry into a part calls its `enter()`.
//! `hold` (B outside debug builds) switches the auto-advance off: an
//! `.endless` part just keeps rendering at ever higher `t` with no
//! fade-out (every part but the Ending is periodic or settles), a `.loop`
//! part restarts at its frame 0 through its fades; releasing the hold cuts
//! to the next part as a skip does.
//!
//! `bars` and the `Clock` arithmetic are plain data and host-tested;
//! `parts` holds the function pointers (and so pulls in the cart API).
const std = @import("std");
const cart = @import("cart-api");
const fx = @import("fx.zig");
const ending = @import("parts/ending.zig");

pub const frames_per_beat = 30;
pub const frames_per_bar = 4 * frames_per_beat;
/// Frames of each fade or dissolve ramp, out of one part and into the next.
pub const fade_frames = 20;
/// Frames of full black at each side of a `.fade` or `.dissolve` boundary.
pub const gap_frames = 5;

/// How a part hands over to the next one (see the file comment).
pub const Cut = enum { fade, dissolve, seamless };

/// A part: its picker label and the three entry points of SPEC.md section 4.
pub const Part = struct {
    name: []const u8,
    init: *const fn () void,
    enter: *const fn () void,
    render: *const fn (t: u32, fb: cart.FramebufferPtr) void,

    pub fn of(comptime M: type) Part {
        return .{ .name = M.name, .init = &M.init, .enter = &M.enter, .render = &M.render };
    }
};

/// What a hold does at the end of a part (see the file comment).
pub const Hold = enum { endless, loop };

pub const Entry = struct { part: Part, bars: u8, cut: Cut = .fade, hold: Hold = .endless };

/// The show, in order (SPEC.md section 3). Order and lengths are one-line
/// changes here; `bars` below must list the same lengths.
pub const entries = [_]Entry{
    .{ .part = .of(@import("parts/intro.zig")), .bars = 3 },
    .{ .part = .of(@import("parts/plasma.zig")), .bars = 5 },
    .{ .part = .of(@import("parts/copper.zig")), .bars = 7, .cut = .dissolve },
    .{ .part = .of(@import("parts/rotozoomer.zig")), .bars = 5 },
    .{ .part = .of(@import("parts/twister.zig")), .bars = 4 },
    .{ .part = .of(@import("parts/tunnel.zig")), .bars = 4 },
    .{ .part = .of(@import("parts/metaballs.zig")), .bars = 5 },
    .{ .part = .of(@import("parts/voxel.zig")), .bars = 7, .cut = .dissolve },
    .{ .part = .of(@import("parts/head.zig")), .bars = 5 },
    .{ .part = .of(@import("parts/fire.zig")), .bars = 4 },
    .{ .part = .of(ending), .bars = 8, .cut = .seamless, .hold = .loop },
};

/// Part lengths in bars, the same as `entries` (checked at comptime in init_all), kept
/// apart so the host tests can use them without the cart API.
pub const bars = [_]u8{ 3, 5, 7, 5, 4, 4, 5, 7, 5, 4, 8 };
/// Each entry's cut, the same as `entries` (checked with `bars`).
pub const cuts = [_]Cut{ .fade, .fade, .dissolve, .fade, .fade, .fade, .fade, .dissolve, .fade, .fade, .seamless };
/// Each entry's hold behaviour, the same as `entries` (checked with `bars`).
pub const holds = [_]Hold{ .endless, .endless, .endless, .endless, .endless, .endless, .endless, .endless, .endless, .endless, .loop };
pub const count = bars.len;

/// Length of part `i` in frames.
pub fn frames_of(i: usize) u32 {
    return @as(u32, bars[i]) * frames_per_bar;
}

/// One pass through every part, in frames.
pub fn loop_frames() u32 {
    var n: u32 = 0;
    for (0..count) |i| n += frames_of(i);
    return n;
}

/// Visibility (0 black .. 256 untouched) `n` frames from a veiled edge of
/// a part (n = 0 is its first or last frame): `gap_frames` of black, then a
/// linear ramp from 16 (the first fade level that is not black) to 256
/// over `fade_frames`.
pub fn ramp(n: u32) u16 {
    if (n < gap_frames) return 0;
    return @intCast(@min(256, 16 + ((n - gap_frames) * 240) / fade_frames));
}

/// The veil over one frame: which transition draws it and how visible the
/// part is (0 black .. 256 untouched).
pub const Veil = struct { cut: Cut, vis: u16 };

/// Veil of frame `t` of a part `len` frames long that was entered through
/// cut `in` (the previous entry's, or `.fade` after a jump) and leaves
/// through its own cut `out`.
pub fn veil(t: u32, len: u32, in: Cut, out: Cut) Veil {
    const left = len - 1 - @min(t, len - 1); // frames after this one
    const vin: u16 = if (in == .seamless) 256 else ramp(t);
    const vout: u16 = if (out == .seamless) 256 else ramp(left);
    return if (vin <= vout) .{ .cut = in, .vis = vin } else .{ .cut = out, .vis = vout };
}

/// fx.fade level (0 black .. 16 unchanged) of frame `t` of a plain faded
/// part `len` frames long.
pub fn fade_level(t: u32, len: u32) u8 {
    return @intCast(veil(t, len, .fade, .fade).vis >> 4);
}

/// Where the show is: part index and frame within that part.
pub const Clock = struct {
    index: u8 = 0,
    frame: u32 = 0,
    /// The cut this part was entered through: the previous entry's when the
    /// show ran into it, `.fade` after a jump.
    entered_by: Cut = .fade,

    /// Next frame; true when that (re-)entered a part (then frame 0). While
    /// `held` an `.endless` part runs on past its length and a `.loop` part
    /// restarts, fading in.
    pub fn advance(c: *Clock, held: bool) bool {
        c.frame += 1;
        if (c.frame < frames_of(c.index)) return false;
        if (held) {
            if (holds[c.index] == .endless) return false;
            c.frame = 0;
            c.entered_by = .fade;
            return true;
        }
        c.entered_by = cuts[c.index];
        c.index = next_index(c.index);
        c.frame = 0;
        return true;
    }

    /// Cut to frame 0 of part `i` (clamped to the last part).
    pub fn jump(c: *Clock, i: usize) void {
        c.index = @intCast(@min(i, count - 1));
        c.frame = 0;
        c.entered_by = .fade;
    }

    /// While `held` an `.endless` part never fades out and a `.loop` part
    /// fades (never cuts seamlessly) into its own restart.
    pub fn veil_now(c: Clock, held: bool) Veil {
        var out = cuts[c.index];
        if (held) out = switch (holds[c.index]) {
            .endless => .seamless,
            .loop => if (out == .seamless) .fade else out,
        };
        return veil(c.frame, frames_of(c.index), c.entered_by, out);
    }
};

pub fn next_index(i: u8) u8 {
    return if (i + 1 >= count) 0 else i + 1;
}

// ---------------------------------------------------------------------------
// The live timeline (cart only).

var clock: Clock = .{};
/// Frames since start(), across parts and loops.
pub var global_frame: u32 = 0;
/// Auto-advance off (B outside debug builds): see the file comment.
pub var hold: bool = false;

/// Every part's init(), once, from main.start() (after math.init_tables()).
pub fn init_all() void {
    // Checked here rather than in a file-level comptime block, which would
    // make the host tests (they import this file) analyse every part.
    comptime {
        if (entries.len != bars.len or cuts.len != bars.len or holds.len != bars.len) @compileError("timeline: entries, bars, cuts and holds differ in length");
        for (entries, bars, cuts, holds) |e, b, k, h| if (e.bars != b or e.cut != k or e.hold != h) @compileError("timeline: entries disagree with bars, cuts or holds");
        if (ending.length != frames_of(count - 1)) @compileError("timeline: ending.length is not the Ending's entry length");
    }
    inline for (entries) |e| e.part.init();
}

/// Starts the show at part `first` (clamped), e.g. badge-bench's scene_part.
pub fn start(first: u8) void {
    global_frame = 0;
    goto(first);
}

/// Draws the current frame: the part, then the timeline's veil.
pub fn render(fb: cart.FramebufferPtr) void {
    entries[clock.index].part.render(clock.frame, fb);
    const v = clock.veil_now(hold);
    switch (v.cut) {
        .fade, .seamless => fx.fade(fb, @intCast(v.vis >> 4)),
        .dissolve => fx.dissolve(fb, @intCast(v.vis >> 2)),
    }
}

/// Advances one frame, entering the next part when the current one ends.
pub fn step() void {
    global_frame +%= 1;
    if (clock.advance(hold)) entries[clock.index].part.enter();
}

/// B outside debug builds: toggles the hold. Releasing it on a part that
/// has run past its length moves on at the next step, as a skip does.
pub fn set_hold(on: bool) void {
    hold = on;
}

/// A/Start: cut to the next part's frame 0 (no fade-out, fade-in kept).
pub fn skip() void {
    goto(next_index(clock.index));
}

/// Cut to frame 0 of part `i` and enter it.
pub fn goto(i: usize) void {
    clock.jump(i);
    entries[clock.index].part.enter();
}

pub fn current() u8 {
    return clock.index;
}

pub fn part_frame() u32 {
    return clock.frame;
}

pub fn name(i: usize) []const u8 {
    return entries[i].part.name;
}

test "bars to frames and the loop" {
    try std.testing.expectEqual(@as(usize, 11), count);
    try std.testing.expectEqual(@as(u32, 360), frames_of(0));
    try std.testing.expectEqual(@as(u32, 600), frames_of(1));
    var total_bars: u32 = 0;
    for (bars) |b| total_bars += b;
    try std.testing.expectEqual(@as(u32, 57), total_bars);
    try std.testing.expectEqual(@as(u32, 57 * 120), loop_frames());
    // 114 s at 60 fps.
    try std.testing.expectEqual(@as(u32, 114 * 60), loop_frames());
}

test "fade levels" {
    const len = frames_of(0);
    const edge = gap_frames + fade_frames; // first fully visible frame
    try std.testing.expectEqual(@as(u8, 0), fade_level(0, len));
    for (0..gap_frames) |t| try std.testing.expectEqual(@as(u8, 0), fade_level(@intCast(t), len));
    try std.testing.expectEqual(@as(u8, 1), fade_level(gap_frames, len));
    try std.testing.expectEqual(@as(u8, 16), fade_level(edge, len));
    try std.testing.expectEqual(@as(u8, 16), fade_level(len / 2, len));
    try std.testing.expectEqual(@as(u8, 16), fade_level(len - 1 - edge, len));
    try std.testing.expect(fade_level(len - edge, len) < 16);
    try std.testing.expectEqual(@as(u8, 0), fade_level(len - 1, len));
    try std.testing.expectEqual(@as(u8, 0), fade_level(len - gap_frames, len));
    // Monotonic in and out.
    for (1..edge + 1) |t| try std.testing.expect(fade_level(@intCast(t), len) >= fade_level(@intCast(t - 1), len));
    for (len - edge..len) |t| try std.testing.expect(fade_level(@intCast(t), len) <= fade_level(@intCast(t - 1), len));
}

test "clock advances through every part and loops" {
    var c: Clock = .{};
    var seen: [count]u32 = @splat(0);
    var entered: u32 = 0;
    for (0..loop_frames()) |_| {
        seen[c.index] += 1;
        if (c.advance(false)) entered += 1;
    }
    for (0..count) |i| try std.testing.expectEqual(frames_of(i), seen[i]);
    try std.testing.expectEqual(@as(u32, count), entered);
    try std.testing.expectEqual(@as(u8, 0), c.index);
    try std.testing.expectEqual(@as(u32, 0), c.frame);
}

test "jump and skip" {
    var c: Clock = .{};
    for (0..100) |_| _ = c.advance(false);
    c.jump(next_index(c.index));
    try std.testing.expectEqual(@as(u8, 1), c.index);
    try std.testing.expectEqual(@as(u32, 0), c.frame);
    try std.testing.expectEqual(@as(u16, 0), c.veil_now(false).vis);
    c.jump(200);
    try std.testing.expectEqual(@as(u8, count - 1), c.index);
    try std.testing.expectEqual(@as(u8, 0), next_index(c.index));
}

test "veils: seamless cuts skip the fade on both sides, jumps fade in" {
    const len = frames_of(1);
    // A plain part fades both ways.
    try std.testing.expectEqual(@as(u16, 0), veil(0, len, .fade, .fade).vis);
    try std.testing.expectEqual(@as(u16, 256), veil(len / 2, len, .fade, .fade).vis);
    try std.testing.expectEqual(@as(u16, 0), veil(len - 1, len, .fade, .fade).vis);
    // Leaving through a seamless cut: no fade-out; entering through one: no fade-in.
    try std.testing.expectEqual(@as(u16, 256), veil(len - 1, len, .fade, .seamless).vis);
    try std.testing.expectEqual(@as(u16, 256), veil(0, len, .seamless, .fade).vis);
    // The side that is darker picks the transition.
    try std.testing.expectEqual(Cut.dissolve, veil(len - 2, len, .fade, .dissolve).cut);
    try std.testing.expectEqual(Cut.dissolve, veil(1, len, .dissolve, .fade).cut);
    // The live clock: the loop enters part 0 through the last entry's cut.
    var c: Clock = .{};
    for (0..loop_frames()) |_| _ = c.advance(false);
    try std.testing.expectEqual(@as(u8, 0), c.index);
    try std.testing.expectEqual(cuts[count - 1], c.entered_by);
    c.jump(0);
    try std.testing.expectEqual(Cut.fade, c.entered_by);
    try std.testing.expectEqual(@as(u16, 0), c.veil_now(false).vis);
}

test "hold: endless parts run on, loop parts restart, release moves on" {
    // Plasma is endless: past its length the frame keeps counting, no
    // fade-out, no enter().
    var c: Clock = .{};
    c.jump(1);
    const len = frames_of(1);
    for (0..len + 200) |_| try std.testing.expect(!c.advance(true));
    try std.testing.expectEqual(@as(u8, 1), c.index);
    try std.testing.expectEqual(len + 200, c.frame);
    // Held, the part stays fully visible and never auto-advances (asserted
    // above for every frame of the overrun). Which Cut tags the veil on a
    // 256/256 tie is veil()'s business (it returns the incoming cut), and
    // render() treats .fade and .seamless alike at full visibility, so the
    // tag is not asserted here.
    try std.testing.expectEqual(@as(u16, 256), c.veil_now(true).vis);
    // Released: the next step moves on, entered through the part's own cut.
    try std.testing.expect(c.advance(false));
    try std.testing.expectEqual(@as(u8, 2), c.index);
    try std.testing.expectEqual(@as(u32, 0), c.frame);
    try std.testing.expectEqual(cuts[1], c.entered_by);
    // The Ending loops: it fades out (not the seamless cut) and restarts on
    // frame 0, fading in.
    c.jump(count - 1);
    const end_len = frames_of(count - 1);
    for (0..end_len - 1) |_| try std.testing.expect(!c.advance(true));
    try std.testing.expectEqual(end_len - 1, c.frame);
    try std.testing.expectEqual(@as(u16, 0), c.veil_now(true).vis);
    try std.testing.expectEqual(Cut.fade, c.veil_now(true).cut);
    try std.testing.expectEqual(@as(u16, 256), c.veil_now(false).vis);
    try std.testing.expect(c.advance(true));
    try std.testing.expectEqual(@as(u8, count - 1), c.index);
    try std.testing.expectEqual(@as(u32, 0), c.frame);
    try std.testing.expectEqual(Cut.fade, c.entered_by);
}
