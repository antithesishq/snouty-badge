//! Buttons to actions, and attract (SPEC.md section 3). Pure: main.zig
//! hands it the buttons each tick and acts on the result, so the host
//! tests drive it directly.
//!
//! - Start+Select is the OS's chord: while both are held nothing reacts.
//! - Start toggles sound on release, and only if Select never joined the
//!   hold (so the exit chord never flips the sound); Select toggles MIRROR
//!   (the sensor's left-right) the same way.
//! - B held: the inputs panel, and the stick steers the virtual hand (B + A
//!   punches). Otherwise Left/Right pick the program, Up/Down its
//!   parameter, A its palette.
//! - Attract: no sensed hand and no button for config.attract_ticks moves
//!   to the next program (and again after as long); any input resets it.
const std = @import("std");
const config = @import("config.zig");
const hand = @import("hand.zig");
const palette = @import("palette.zig");
const programs = @import("programs.zig");

pub const Buttons = struct {
    start: bool = false,
    select: bool = false,
    a: bool = false,
    b: bool = false,
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,

    fn any(s: Buttons) bool {
        return s.start or s.select or s.a or s.b or s.up or s.down or s.left or s.right;
    }
};

pub const Toast = enum { none, program, palette, param, sound, mirror };

pub const Out = struct {
    stick: hand.Stick = .{},
    /// The program changed this tick (main calls its `enter`).
    program_changed: bool = false,
    sound_changed: bool = false,
    mirror_changed: bool = false,
    attract_advanced: bool = false,
};

pub var program: u8 = 0;
pub var palettes: [programs.count]u8 = undefined;
pub var params: [programs.count]u8 = @splat(config.param_default);
pub var sound: bool = false;
/// The sensor image is mirrored left-right from the default orientation
/// (the breakout dangles on its cable and can face either way).
pub var mirror: bool = false;
pub var hud: bool = false;
pub var idle: u32 = 0;
pub var toast: Toast = .none;
pub var toast_left: u32 = 0;

var prev: Buttons = .{};
var start_held = false;
var start_spoiled = false;
var select_held = false;
var select_spoiled = false;

pub fn reset(first: u8, sound_on: bool) void {
    program = @intCast(first % programs.count);
    for (&palettes, programs.list) |*p, pr| p.* = pr.default_palette;
    params = @splat(config.param_default);
    sound = sound_on;
    hud = false;
    idle = 0;
    toast = .program;
    toast_left = config.toast_ticks;
    prev = .{};
    start_held = false;
    start_spoiled = false;
    mirror = false;
    select_held = false;
    select_spoiled = false;
}

pub fn param() u8 {
    return params[program];
}

pub fn palette_index() u8 {
    return palettes[program];
}

fn show(t: Toast) void {
    toast = t;
    toast_left = config.toast_ticks;
}

fn set_program(p: usize, out: *Out) void {
    program = @intCast(p % programs.count);
    out.program_changed = true;
    show(.program);
}

/// One tick. `sensed`: a real hand is over the sensor.
pub fn step(btn: Buttons, sensed: bool) Out {
    var out: Out = .{};
    if (toast_left > 0) toast_left -= 1 else toast = .none;
    defer prev = btn;

    if (btn.start and btn.select) {
        // The OS's chord: react to nothing; both releases are spoiled.
        start_spoiled = true;
        select_spoiled = true;
        hud = false;
        return out;
    }

    // Start: toggle on release.
    if (btn.start and !prev.start) {
        start_held = true;
        start_spoiled = btn.select;
    }
    if (!btn.start and prev.start and start_held) {
        start_held = false;
        if (!start_spoiled) {
            sound = !sound;
            out.sound_changed = true;
            show(.sound);
        }
    }
    // Select: MIRROR on release, the same way.
    if (btn.select and !prev.select) {
        select_held = true;
        select_spoiled = btn.start;
    }
    if (!btn.select and prev.select and select_held) {
        select_held = false;
        if (!select_spoiled) {
            mirror = !mirror;
            out.mirror_changed = true;
            show(.mirror);
        }
    }

    hud = btn.b;
    if (btn.b) {
        out.stick = .{
            .up = btn.up,
            .down = btn.down,
            .left = btn.left,
            .right = btn.right,
            .punch = btn.a and !prev.a,
            .steer = true,
        };
    } else {
        if (btn.right and !prev.right) set_program(@as(usize, program) + 1, &out);
        if (btn.left and !prev.left) set_program(@as(usize, program) + programs.count - 1, &out);
        if (btn.up and !prev.up and params[program] < config.param_max) {
            params[program] += 1;
            show(.param);
        }
        if (btn.down and !prev.down and params[program] > 0) {
            params[program] -= 1;
            show(.param);
        }
        if (btn.a and !prev.a) {
            palettes[program] = @intCast((@as(usize, palettes[program]) + 1) % palette.count);
            show(.palette);
        }
    }

    if (btn.any() or sensed) {
        idle = 0;
    } else {
        idle += 1;
        if (idle >= config.attract_ticks) {
            idle = 0;
            set_program(@as(usize, program) + 1, &out);
            out.attract_advanced = true;
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Host tests.

const testing = std.testing;

fn tap(b: Buttons) Out {
    const o = step(b, false);
    _ = step(.{}, false);
    return o;
}

test "app: left/right switch programs, up/down the param, A the palette" {
    reset(0, false);
    try testing.expect(tap(.{ .right = true }).program_changed);
    try testing.expectEqual(@as(u8, 1), program);
    _ = tap(.{ .left = true });
    _ = tap(.{ .left = true });
    try testing.expectEqual(@as(u8, programs.count - 1), program);
    _ = tap(.{ .up = true });
    try testing.expectEqual(@as(u8, config.param_default + 1), param());
    for (0..20) |_| _ = tap(.{ .down = true });
    try testing.expectEqual(@as(u8, 0), param());
    const before = palette_index();
    _ = tap(.{ .a = true });
    try testing.expectEqual((before + 1) % palette.count, palette_index());
    // Each program keeps its own settings.
    _ = tap(.{ .right = true });
    try testing.expectEqual(@as(u8, config.param_default), param());
    // Holding a direction moves once.
    for (0..30) |_| _ = step(.{ .right = true }, false);
    try testing.expectEqual(@as(u8, 1), program);
}

test "app: nothing reacts while Start and Select are both held" {
    reset(2, false);
    const chord: Buttons = .{ .start = true, .select = true };
    // Every other button pressed under the chord does nothing.
    const others = [_]Buttons{
        .{ .start = true, .select = true, .left = true },
        .{ .start = true, .select = true, .right = true },
        .{ .start = true, .select = true, .up = true },
        .{ .start = true, .select = true, .down = true },
        .{ .start = true, .select = true, .a = true },
        .{ .start = true, .select = true, .b = true, .a = true, .left = true },
    };
    _ = step(chord, false);
    for (others) |b| {
        const o = step(b, false);
        try testing.expect(!o.program_changed and !o.sound_changed and !o.mirror_changed);
        try testing.expect(!o.stick.active() and !o.stick.steer);
        _ = step(chord, false);
    }
    try testing.expectEqual(@as(u8, 2), program);
    try testing.expectEqual(@as(u8, config.param_default), param());
    try testing.expect(!hud);
    // Releasing the chord does not toggle the sound either way round.
    _ = step(.{ .start = true }, false);
    _ = step(.{}, false);
    try testing.expect(!sound);
    _ = step(chord, false);
    _ = step(.{ .select = true }, false);
    _ = step(.{}, false);
    try testing.expect(!sound);
    // Start then Select joining: spoiled too.
    _ = step(.{ .start = true }, false);
    _ = step(chord, false);
    _ = step(.{ .start = true }, false);
    _ = step(.{}, false);
    try testing.expect(!sound);
    try testing.expect(!mirror);
}

test "app: Select toggles mirror on release, never through the chord" {
    reset(0, false);
    _ = tap(.{ .select = true });
    try testing.expect(mirror);
    _ = step(.{ .select = true }, false);
    _ = step(.{ .select = true, .start = true }, false);
    _ = step(.{}, false);
    try testing.expect(mirror);
    try testing.expect(!sound);
    _ = tap(.{ .select = true });
    try testing.expect(!mirror);
}

test "app: Start toggles sound on release" {
    reset(0, false);
    const o = step(.{ .start = true }, false);
    try testing.expect(!o.sound_changed);
    try testing.expect(step(.{}, false).sound_changed);
    try testing.expect(sound);
    _ = tap(.{ .start = true });
    try testing.expect(!sound);
}

test "app: B shows the panel and turns the stick into the hand" {
    reset(0, false);
    var o = step(.{ .b = true, .right = true }, false);
    try testing.expect(hud);
    try testing.expect(o.stick.right and o.stick.steer);
    try testing.expect(!o.program_changed);
    o = step(.{ .b = true, .a = true }, false);
    try testing.expect(o.stick.punch);
    const pal = palette_index();
    try testing.expectEqual(pal, palette_index());
    o = step(.{ .b = true, .a = true }, false);
    try testing.expect(!o.stick.punch);
    _ = step(.{}, false);
    try testing.expect(!hud);
    try testing.expectEqual(@as(u8, 0), program);
}

test "app: attract advances after 30 s idle, a hand or a button holds it" {
    reset(0, false);
    for (0..config.attract_ticks - 1) |_| try testing.expect(!step(.{}, false).attract_advanced);
    try testing.expect(step(.{}, false).attract_advanced);
    try testing.expectEqual(@as(u8, 1), program);
    // A sensed hand keeps it.
    for (0..config.attract_ticks * 2) |_| try testing.expect(!step(.{}, true).attract_advanced);
    // So does a button now and then.
    for (0..4) |_| {
        for (0..config.attract_ticks - 10) |_| _ = step(.{}, false);
        _ = step(.{ .b = true }, false);
    }
    try testing.expectEqual(@as(u8, 1), program);
    // And it keeps going round while nobody plays.
    for (0..config.attract_ticks * programs.count) |_| _ = step(.{}, false);
    try testing.expectEqual(@as(u8, 1), program);
}
