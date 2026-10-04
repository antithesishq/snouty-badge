//! frontend/flow.zig on the host (review EM-01): the button that skips the
//! splash, leaves the picker or comes with the Select hold that opens the
//! menu must not act on the next screen until it is released and pressed
//! again. A drive build with two playable files, the only kind that shows
//! the picker; the wasm build compiles the picker out, so no preview script
//! can check this.
const std = @import("std");
const testing = std.testing;
const flow = @import("flow");
const input = flow.input;
const core = @import("core");

const Button = input.Button;

/// The console side, recording what the flow asked for. The splash runs
/// until skipped; the menu acts on a fresh A or B (frontend/menu.zig: A
/// acts on the selected row, B resumes) and here closes on it. The flow
/// ignores the menu's answer on the frame it opens, so `menu_acts` is what
/// shows a press leaking in on that frame.
const Fake = struct {
    picker: flow.Picker = .{},
    playable: [2]bool = .{ true, true },
    begun: ?usize = null,
    steps: u32 = 0,
    /// Of `steps`, those asked to fast forward.
    fast_steps: u32 = 0,
    last_pad: u8 = 0,
    menu_opens: u32 = 0,
    menu_frames: u32 = 0,
    /// Menu frames that saw a fresh A or B (a row acted on, or a resume).
    menu_acts: u32 = 0,
    rewind_opens: u32 = 0,
    rewind_frames: u32 = 0,
    rewind_closes: u32 = 0,
    /// Chorded-rewind time steps taken, and their sum (0.5 s units).
    scrub_steps: u32 = 0,
    position: i32 = 0,

    pub fn splash_frame(_: *Fake, skip: bool) bool {
        return skip;
    }
    pub fn pick_frame(f: *Fake, e: input.Edge) ?usize {
        return f.picker.update(e, &f.playable);
    }
    pub fn begin_choice(f: *Fake, choice: usize) bool {
        f.begun = choice;
        return true;
    }
    pub fn play_begin(_: *Fake) void {}
    pub fn step(f: *Fake, pad: u8, _: bool, fast: bool) void {
        f.steps += 1;
        if (fast) f.fast_steps += 1;
        f.last_pad = pad;
    }
    pub fn menu_open(f: *Fake) void {
        f.menu_opens += 1;
    }
    pub fn menu_frame(f: *Fake, e: input.Edge) flow.MenuResult {
        f.menu_frames += 1;
        const act = e.pressed(.a) or e.pressed(.b);
        if (act) f.menu_acts += 1;
        return if (act) .resume_game else .stay;
    }
    pub fn menu_close(_: *Fake) void {}
    pub fn rewind_open(f: *Fake) void {
        f.rewind_opens += 1;
    }
    pub fn rewind_frame(f: *Fake, dir: i2) void {
        f.rewind_frames += 1;
        f.position += dir;
        if (dir != 0) f.scrub_steps += 1;
    }
    pub fn rewind_close(f: *Fake) void {
        f.rewind_closes += 1;
    }
    pub fn halted_frame(_: *Fake) void {}
};

const Flow = flow.Flow(Fake);

fn ctl(buttons: []const Button) input.Controls {
    var c: input.Controls = .{};
    for (buttons) |b| switch (b) {
        .start => c.start = true,
        .select => c.select = true,
        .a => c.a = true,
        .b => c.b = true,
        .up => c.up = true,
        .down => c.down = true,
        .left => c.left = true,
        .right => c.right = true,
    };
    return c;
}

fn frames(fl: *Flow, fake: *Fake, buttons: []const Button, n: u32) void {
    for (0..n) |_| fl.update(fake, ctl(buttons));
}

test "flow: the button that skips the splash does not act on the picker" {
    for ([_]Button{ .a, .b, .down, .select }) |skip| {
        var fake: Fake = .{};
        var fl: Flow = .{ .pick_after_splash = true };
        frames(&fl, &fake, &.{}, 3);
        try testing.expectEqual(flow.State.splash, fl.state);

        // The press that skips the splash, then held for a while.
        frames(&fl, &fake, &.{skip}, 1);
        try testing.expectEqual(flow.State.pick, fl.state);
        frames(&fl, &fake, &.{skip}, 20);
        try testing.expectEqual(flow.State.pick, fl.state);
        try testing.expectEqual(@as(?usize, null), fake.begun);
        try testing.expectEqual(@as(usize, 0), fake.picker.cursor);
        try testing.expectEqual(@as(u32, 0), fake.steps);

        // Released, then pressed afresh: now it acts.
        frames(&fl, &fake, &.{}, 1);
        try testing.expectEqual(flow.State.pick, fl.state);
        frames(&fl, &fake, &.{skip}, 1);
        switch (skip) {
            .a => {
                try testing.expectEqual(@as(?usize, 0), fake.begun);
                try testing.expectEqual(flow.State.running, fl.state);
                // The A that chose the ROM does not reach the game either.
                try testing.expectEqual(@as(u8, 0), fake.last_pad);
                frames(&fl, &fake, &.{.a}, 1);
                try testing.expectEqual(@as(u8, 0), fake.last_pad);
                frames(&fl, &fake, &.{}, 1);
                frames(&fl, &fake, &.{.a}, 1);
                try testing.expectEqual(core.Pad.a, fake.last_pad);
            },
            .down => {
                try testing.expectEqual(flow.State.pick, fl.state);
                try testing.expectEqual(@as(usize, 1), fake.picker.cursor);
                frames(&fl, &fake, &.{}, 1);
                frames(&fl, &fake, &.{.a}, 1);
                try testing.expectEqual(@as(?usize, 1), fake.begun);
                try testing.expectEqual(flow.State.running, fl.state);
            },
            // B and Select do nothing on the picker (the badge build embeds
            // no ROM to run instead); the screen stays.
            .b, .select => {
                try testing.expectEqual(flow.State.pick, fl.state);
                try testing.expectEqual(@as(?usize, null), fake.begun);
            },
            else => unreachable,
        }
    }
}

test "flow: an A or B pressed as the Select hold opens the menu does not act on it" {
    for ([_]Button{ .a, .b }) |extra| {
        var fake: Fake = .{};
        var fl: Flow = .{};
        frames(&fl, &fake, &.{.a}, 1); // skip the splash
        frames(&fl, &fake, &.{}, 2);
        try testing.expectEqual(flow.State.running, fl.state);

        frames(&fl, &fake, &.{.select}, input.hold_frames - 1);
        try testing.expectEqual(flow.State.running, fl.state);
        // The frame the hold reaches the threshold, a fresh A/B with it.
        frames(&fl, &fake, &.{ .select, extra }, 1);
        try testing.expectEqual(flow.State.menu, fl.state);
        try testing.expectEqual(@as(u32, 1), fake.menu_opens);
        try testing.expectEqual(@as(u32, 0), fake.menu_acts);
        frames(&fl, &fake, &.{ .select, extra }, 10);
        frames(&fl, &fake, &.{extra}, 5);
        try testing.expectEqual(flow.State.menu, fl.state);

        // Released and pressed again, it closes the menu, and that press does
        // not reach the game.
        frames(&fl, &fake, &.{}, 1);
        try testing.expectEqual(flow.State.menu, fl.state);
        try testing.expectEqual(@as(u32, 0), fake.menu_acts);
        const steps = fake.steps;
        frames(&fl, &fake, &.{extra}, 1);
        try testing.expectEqual(flow.State.running, fl.state);
        try testing.expectEqual(steps + 1, fake.steps);
        try testing.expectEqual(@as(u8, 0), fake.last_pad);
        try testing.expectEqual(@as(u32, 1), fake.menu_opens);
        try testing.expectEqual(@as(u32, 1), fake.menu_acts);
    }
}

test "flow: tap then hold Select fast forwards without a tap or the menu" {
    var fake: Fake = .{};
    var fl: Flow = .{};
    frames(&fl, &fake, &.{.a}, 1); // skip the splash
    frames(&fl, &fake, &.{}, 2);
    try testing.expectEqual(flow.State.running, fl.state);

    // A single tap reaches the game only after the double-tap window: the
    // release frame and `ff_tap_window` more.
    frames(&fl, &fake, &.{.select}, 3);
    frames(&fl, &fake, &.{}, input.ff_tap_window);
    try testing.expectEqual(@as(u8, 0), fake.last_pad);
    frames(&fl, &fake, &.{}, 1);
    try testing.expectEqual(core.Pad.select, fake.last_pad);
    frames(&fl, &fake, &.{}, input.tap_frames + 2);
    try testing.expectEqual(@as(u8, 0), fake.last_pad);

    // Tap, then press and hold for three times the menu threshold: every
    // update fast forwards, Right reaches the game, no menu.
    frames(&fl, &fake, &.{.select}, 3);
    frames(&fl, &fake, &.{}, 5);
    const steps = fake.steps;
    frames(&fl, &fake, &.{.select}, 3 * input.hold_frames);
    frames(&fl, &fake, &.{ .select, .right }, 4);
    try testing.expectEqual(flow.State.running, fl.state);
    try testing.expectEqual(@as(u32, 0), fake.menu_opens);
    try testing.expectEqual(steps + 3 * input.hold_frames + 4, fake.steps);
    try testing.expectEqual(3 * input.hold_frames + 4, fake.fast_steps);
    try testing.expectEqual(core.Pad.right, fake.last_pad);

    // Let go: 1x again and no Select tap, ever.
    const fast = fake.fast_steps;
    for (0..input.ff_tap_window + input.tap_frames + 2) |_| {
        frames(&fl, &fake, &.{}, 1);
        try testing.expectEqual(@as(u8, 0), fake.last_pad);
    }
    try testing.expectEqual(fast, fake.fast_steps);

    // Start+Select during fast forward: back to 1x, Start reaches the game,
    // no menu and no tap after it.
    frames(&fl, &fake, &.{.select}, 2);
    frames(&fl, &fake, &.{}, 2);
    frames(&fl, &fake, &.{.select}, 5);
    try testing.expectEqual(fast + 5, fake.fast_steps);
    frames(&fl, &fake, &.{ .select, .start }, 2 * input.hold_frames);
    try testing.expectEqual(fast + 5, fake.fast_steps);
    try testing.expectEqual(core.Pad.start, fake.last_pad);
    try testing.expectEqual(flow.State.running, fl.state);
    for (0..input.ff_tap_window + input.tap_frames + 2) |_| {
        frames(&fl, &fake, &.{}, 1);
        try testing.expectEqual(@as(u8, 0), fake.last_pad);
    }
    try testing.expectEqual(@as(u32, 0), fake.menu_opens);

    // A single long hold still opens the menu at the threshold.
    frames(&fl, &fake, &.{.select}, input.hold_frames - 1);
    try testing.expectEqual(flow.State.running, fl.state);
    frames(&fl, &fake, &.{.select}, 1);
    try testing.expectEqual(flow.State.menu, fl.state);
}

test "flow: picker cursor starts on the first playable file and skips no row" {
    var p: flow.Picker = .{};
    const playable = [_]bool{ false, true, true };
    const none: input.Edge = .{};
    try testing.expectEqual(@as(?usize, null), p.update(none, &playable));
    try testing.expectEqual(@as(usize, 1), p.cursor);
    // A on an unplayable row does nothing.
    try testing.expectEqual(@as(?usize, null), p.update(.{ .cur = @bitCast(ctl(&.{.up})) }, &playable));
    try testing.expectEqual(@as(usize, 0), p.cursor);
    try testing.expectEqual(@as(?usize, null), p.update(.{ .cur = @bitCast(ctl(&.{.a})) }, &playable));
    // B is no way out (no embedded ROM in the badge build).
    try testing.expectEqual(@as(?usize, null), p.update(.{ .cur = @bitCast(ctl(&.{.b})) }, &playable));
}

/// Into the game, then tap Select and press it again: fast forward.
fn fast_forwarding(fl: *Flow, fake: *Fake) !void {
    frames(fl, fake, &.{.a}, 1); // skip the splash
    frames(fl, fake, &.{}, 2);
    frames(fl, fake, &.{.select}, 2);
    frames(fl, fake, &.{}, 2);
    const fast = fake.fast_steps;
    frames(fl, fake, &.{.select}, 5);
    try testing.expectEqual(fast + 5, fake.fast_steps);
}

test "flow: Left during fast forward rewinds until Select is let go" {
    var fake: Fake = .{};
    var fl: Flow = .{};
    try fast_forwarding(&fl, &fake);

    // Right reaches the game while fast forwarding; Left never does.
    frames(&fl, &fake, &.{ .select, .right }, 2);
    try testing.expectEqual(core.Pad.right, fake.last_pad);
    frames(&fl, &fake, &.{.select}, 1);

    // Left: the game freezes and steps back once at once.
    const steps = fake.steps;
    frames(&fl, &fake, &.{ .select, .left }, 1);
    try testing.expectEqual(flow.State.rewind, fl.state);
    try testing.expectEqual(@as(u32, 1), fake.rewind_opens);
    try testing.expectEqual(@as(i32, -1), fake.position);
    // Held: another step back every `repeat_frames` (4 a second).
    frames(&fl, &fake, &.{ .select, .left }, 2 * input.repeat_frames);
    try testing.expectEqual(@as(i32, -3), fake.position);
    frames(&fl, &fake, &.{.select}, 3);
    try testing.expectEqual(@as(i32, -3), fake.position);
    // Right steps forward, Left and Right taps once each.
    frames(&fl, &fake, &.{ .select, .right }, 1);
    frames(&fl, &fake, &.{.select}, 1);
    frames(&fl, &fake, &.{ .select, .left }, 1);
    frames(&fl, &fake, &.{.select}, 1);
    frames(&fl, &fake, &.{ .select, .left }, 1);
    try testing.expectEqual(@as(i32, -4), fake.position);
    // Nothing reaches the game: A, B, Up, Start (the OS chord with the held
    // Select) neither step it nor end the rewind, and the position stays.
    frames(&fl, &fake, &.{ .select, .a, .b, .up }, 3);
    frames(&fl, &fake, &.{ .select, .start }, 40);
    frames(&fl, &fake, &.{.select}, 2);
    try testing.expectEqual(flow.State.rewind, fl.state);
    try testing.expectEqual(steps, fake.steps);
    try testing.expectEqual(@as(i32, -4), fake.position);
    try testing.expectEqual(@as(u32, 0), fake.menu_opens);

    // Let go of Select with Left still held: resume in the same update with
    // nothing on the pad; the held Left waits for a release.
    frames(&fl, &fake, &.{.left}, 1);
    try testing.expectEqual(flow.State.running, fl.state);
    try testing.expectEqual(@as(u32, 1), fake.rewind_closes);
    try testing.expectEqual(steps + 1, fake.steps);
    try testing.expectEqual(@as(u8, 0), fake.last_pad);
    const fast = fake.fast_steps;
    for (0..input.ff_tap_window + input.tap_frames + 2) |_| {
        frames(&fl, &fake, &.{.left}, 1);
        try testing.expectEqual(@as(u8, 0), fake.last_pad);
    }
    try testing.expectEqual(fast, fake.fast_steps);
    frames(&fl, &fake, &.{}, 1);
    frames(&fl, &fake, &.{.left}, 1);
    try testing.expectEqual(core.Pad.left, fake.last_pad);
    try testing.expectEqual(@as(i32, -4), fake.position);

    // The menu still opens on a long hold afterwards.
    frames(&fl, &fake, &.{}, 1);
    frames(&fl, &fake, &.{.select}, input.hold_frames);
    try testing.expectEqual(flow.State.menu, fl.state);
}

test "flow: a Left held into fast forward stays the rewind key" {
    var fake: Fake = .{};
    var fl: Flow = .{};
    frames(&fl, &fake, &.{.a}, 1);
    frames(&fl, &fake, &.{}, 2);
    // Walking left, then the double tap and hold: Left is masked while
    // fast forwarding and, not pressed afresh, does not rewind.
    frames(&fl, &fake, &.{.left}, 2);
    try testing.expectEqual(core.Pad.left, fake.last_pad);
    frames(&fl, &fake, &.{ .left, .select }, 2);
    frames(&fl, &fake, &.{.left}, 2);
    frames(&fl, &fake, &.{ .left, .select }, 10);
    try testing.expectEqual(flow.State.running, fl.state);
    try testing.expectEqual(@as(u32, 10), fake.fast_steps);
    try testing.expectEqual(@as(u8, 0), fake.last_pad);
    // Released and pressed again inside the hold: the rewind.
    frames(&fl, &fake, &.{.select}, 1);
    frames(&fl, &fake, &.{ .left, .select }, 1);
    try testing.expectEqual(flow.State.rewind, fl.state);
    try testing.expectEqual(@as(i32, -1), fake.position);
    // Select let go at once: resume, no tap.
    frames(&fl, &fake, &.{}, input.ff_tap_window + input.tap_frames + 2);
    try testing.expectEqual(flow.State.running, fl.state);
    try testing.expectEqual(@as(u8, 0), fake.last_pad);
}
