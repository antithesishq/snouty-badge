//! The ordered part table and the clock that drives it (SPEC.md section 3).
//!
//! The frame clock is 120 BPM: 30 frames per beat, 120 per bar; a part lasts
//! a whole number of bars. The timeline renders the current part at its own
//! frame number `t` (frames since enter()), then fades the frame: black to
//! full over the first 15 frames, full to black over the last 15. After the
//! last part it loops to the first. `skip()` (A/Start) and `goto()` (the
//! picker, debug_goto) cut straight to a part's frame 0, so only its
//! fade-in shows. Every entry into a part calls its `enter()`.
//!
//! `bars` and the `Clock` arithmetic are plain data and host-tested;
//! `parts` holds the function pointers (and so pulls in the cart API).
const std = @import("std");
const cart = @import("cart-api");
const fx = @import("fx.zig");
const placeholder = @import("parts/placeholder.zig");

pub const frames_per_beat = 30;
pub const frames_per_bar = 4 * frames_per_beat;
pub const fade_frames = 15;

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

pub const Entry = struct { part: Part, bars: u8 };

/// The show, in order (SPEC.md section 3). Order and lengths are one-line
/// changes here; `bars` below must list the same lengths.
pub const entries = [_]Entry{
    .{ .part = .of(@import("parts/intro.zig")), .bars = 3 },
    .{ .part = .of(@import("parts/plasma.zig")), .bars = 5 },
    .{ .part = .of(@import("parts/copper.zig")), .bars = 6 },
    .{ .part = .of(@import("parts/rotozoomer.zig")), .bars = 5 },
    .{ .part = .of(@import("parts/tunnel.zig")), .bars = 5 },
    .{ .part = .of(@import("parts/twister.zig")), .bars = 4 },
    .{ .part = .of(@import("parts/metaballs.zig")), .bars = 5 },
    .{ .part = .of(@import("parts/voxel.zig")), .bars = 7 },
    .{ .part = .of(@import("parts/head.zig")), .bars = 6 },
    .{ .part = .of(@import("parts/fire.zig")), .bars = 4 },
    .{ .part = .of(placeholder.Placeholder(10, "Ending")), .bars = 7 },
};

/// Part lengths in bars, the same as `entries` (checked at comptime in init_all), kept
/// apart so the host tests can use them without the cart API.
pub const bars = [_]u8{ 3, 5, 6, 5, 5, 4, 5, 7, 6, 4, 7 };
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

/// Fade level (0 black .. 16 unchanged) of frame `t` of a part `len` frames
/// long: rises over the first `fade_frames`, falls over the last.
pub fn fade_level(t: u32, len: u32) u8 {
    const in: u32 = if (t < fade_frames) (t * 16) / fade_frames else 16;
    const left = len - 1 - @min(t, len - 1); // frames after this one
    const out: u32 = if (left < fade_frames) (left * 16) / fade_frames else 16;
    return @intCast(@min(in, out));
}

/// Where the show is: part index and frame within that part.
pub const Clock = struct {
    index: u8 = 0,
    frame: u32 = 0,

    /// Next frame; true when that crossed into a new part (then frame 0).
    pub fn advance(c: *Clock) bool {
        c.frame += 1;
        if (c.frame < frames_of(c.index)) return false;
        c.index = next_index(c.index);
        c.frame = 0;
        return true;
    }

    /// Cut to frame 0 of part `i` (clamped to the last part).
    pub fn jump(c: *Clock, i: usize) void {
        c.index = @intCast(@min(i, count - 1));
        c.frame = 0;
    }

    pub fn level(c: Clock) u8 {
        return fade_level(c.frame, frames_of(c.index));
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

/// Every part's init(), once, from main.start() (after math.init_tables()).
pub fn init_all() void {
    // Checked here rather than in a file-level comptime block, which would
    // make the host tests (they import this file) analyse every part.
    comptime {
        if (entries.len != bars.len) @compileError("timeline: entries and bars differ in length");
        for (entries, bars) |e, b| if (e.bars != b) @compileError("timeline: entries and bars disagree");
    }
    inline for (entries) |e| e.part.init();
}

/// Starts the show at part `first` (clamped), e.g. badge-bench's scene_part.
pub fn start(first: u8) void {
    global_frame = 0;
    goto(first);
}

/// Draws the current frame: the part, then the timeline fade.
pub fn render(fb: cart.FramebufferPtr) void {
    entries[clock.index].part.render(clock.frame, fb);
    fx.fade(fb, clock.level());
}

/// Advances one frame, entering the next part when the current one ends.
pub fn step() void {
    global_frame +%= 1;
    if (clock.advance()) entries[clock.index].part.enter();
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
    try std.testing.expectEqual(@as(u8, 0), fade_level(0, len));
    try std.testing.expectEqual(@as(u8, 16), fade_level(15, len));
    try std.testing.expectEqual(@as(u8, 16), fade_level(len / 2, len));
    try std.testing.expectEqual(@as(u8, 16), fade_level(len - 16, len));
    try std.testing.expectEqual(@as(u8, 0), fade_level(len - 1, len));
    try std.testing.expect(fade_level(len - 8, len) < 16);
    // Monotonic in and out.
    for (1..fade_frames + 1) |t| try std.testing.expect(fade_level(@intCast(t), len) >= fade_level(@intCast(t - 1), len));
    for (len - fade_frames..len) |t| try std.testing.expect(fade_level(@intCast(t), len) <= fade_level(@intCast(t - 1), len));
}

test "clock advances through every part and loops" {
    var c: Clock = .{};
    var seen: [count]u32 = @splat(0);
    var entered: u32 = 0;
    for (0..loop_frames()) |_| {
        seen[c.index] += 1;
        if (c.advance()) entered += 1;
    }
    for (0..count) |i| try std.testing.expectEqual(frames_of(i), seen[i]);
    try std.testing.expectEqual(@as(u32, count), entered);
    try std.testing.expectEqual(@as(u8, 0), c.index);
    try std.testing.expectEqual(@as(u32, 0), c.frame);
}

test "jump and skip" {
    var c: Clock = .{};
    for (0..100) |_| _ = c.advance();
    c.jump(next_index(c.index));
    try std.testing.expectEqual(@as(u8, 1), c.index);
    try std.testing.expectEqual(@as(u32, 0), c.frame);
    try std.testing.expectEqual(@as(u8, 0), c.level());
    c.jump(200);
    try std.testing.expectEqual(@as(u8, count - 1), c.index);
    try std.testing.expectEqual(@as(u8, 0), next_index(c.index));
}
