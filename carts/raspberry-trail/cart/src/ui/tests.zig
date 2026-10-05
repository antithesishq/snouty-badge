//! Host tests of the UI (no cart API): wrapping, the log, the spinner, the
//! paging, the shooting cue, the chord guard, the autoplayer and the whole
//! title -> game -> end flow against the game module.
const std = @import("std");
const G = @import("game");
const app_mod = @import("app.zig");
const autoplay = @import("autoplay.zig");
const L = @import("layout.zig");
const log_mod = @import("log.zig");

comptime {
    _ = @import("text.zig");
    _ = @import("log.zig");
    _ = @import("font.zig");
}

const App = app_mod.App;
const B = app_mod.Buttons;
const knobs = app_mod.knobs;

fn press(app: *App, b: B) void {
    app.update(b);
    app.update(.{});
}

fn seed_42() u64 {
    return 42;
}

var app_storage: App = .{};

fn fresh() *App {
    const app = &app_storage;
    app.init(&seed_42);
    return app;
}

/// Presses A through "A: MORE" pages until a prompt (or a shot) is up.
fn to_prompt(app: *App) void {
    var k: u32 = 0;
    while (app.phase == .more and k < 200) : (k += 1) press(app, .{ .a = true });
}

/// Plays the current shot right, `delay` frames before each press.
fn shoot_right(app: *App, delay: u32) void {
    while (app.phase == .shot_ready) app.update(.{});
    while (app.phase == .shot_cue) {
        for (0..delay - 1) |_| app.update(.{});
        app.update(app_mod.buttons_for(app.shot.seq[app.shot.idx]));
    }
}

/// Lets the shot's result frames run out (the answer goes to the game).
fn finish_shot(app: *App) void {
    while (app.phase == .shot_done) app.update(.{});
}

fn shot_prompt() G.Prompt {
    return .{ .kind = .shoot, .line = 6220, .question = "SHOOT!", .word = .blam };
}

// -- spinner -------------------------------------------------------------

test "spinner: carry, clamp, caret, reset" {
    const p: G.Prompt = .{ .kind = .number, .line = 860, .min = 200, .max = 300, .default = 200 };
    var s = app_mod.Spinner.init(&p);
    try std.testing.expectEqual(@as(i32, 200), s.value);
    try std.testing.expectEqual(@as(u8, 3), s.digits);
    try std.testing.expectEqual(@as(u8, 2), s.caret);
    s.move(false); // tens
    for (0..9) |_| s.bump(true);
    try std.testing.expectEqual(@as(i32, 290), s.value);
    s.move(false); // ones
    for (0..7) |_| s.bump(true);
    try std.testing.expectEqual(@as(i32, 297), s.value);
    s.move(true); // tens: 297 + 10 clamps to 300
    s.bump(true);
    try std.testing.expectEqual(@as(i32, 300), s.value);
    s.move(true);
    s.move(true); // stays on the hundreds (3 digits)
    try std.testing.expectEqual(@as(u8, 2), s.caret);
    s.bump(false); // 200
    s.bump(false); // clamps to the minimum
    try std.testing.expectEqual(@as(i32, 200), s.value);
    s.move(false);
    s.bump(true);
    s.bump(true);
    try std.testing.expectEqual(@as(i32, 220), s.value);
    s.reset();
    try std.testing.expectEqual(@as(i32, 200), s.value);
    // Carry upward: 95 + 10 at the tens is 105.
    const q: G.Prompt = .{ .kind = .number, .line = 940, .min = 0, .max = 450, .default = 95 };
    var t = app_mod.Spinner.init(&q);
    t.move(false);
    try std.testing.expectEqual(@as(u8, 1), t.caret);
    t.bump(true);
    try std.testing.expectEqual(@as(i32, 105), t.value);
    // max 0 (no cash): one digit, stuck at 0.
    const z: G.Prompt = .{ .kind = .number, .line = 2330, .min = 0, .max = 0, .default = 0 };
    var u = app_mod.Spinner.init(&z);
    u.bump(true);
    try std.testing.expectEqual(@as(i32, 0), u.value);
    try std.testing.expectEqual(@as(u8, 1), u.digits);
}

test "repeat: press, 0.4 s, then 10 per second" {
    var r: app_mod.Repeat = .{};
    var fired: u32 = 0;
    var first_repeat: ?u32 = null;
    for (0..60) |f| {
        if (r.fire(true)) {
            fired += 1;
            if (fired == 2 and first_repeat == null) first_repeat = @intCast(f);
        }
    }
    try std.testing.expectEqual(@as(?u32, knobs.repeat_delay), first_repeat);
    // 1 press + repeats at 24, 30, 36, 42, 48, 54.
    try std.testing.expectEqual(@as(u32, 7), fired);
    try std.testing.expect(!r.fire(false));
    try std.testing.expect(r.fire(true));
}

// -- shot timing -----------------------------------------------------------

test "shot: seconds = frames / 60 * 0.75, 10 s cap" {
    var s: app_mod.Shot = .{ .frames = 96 };
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), s.seconds(), 1e-12);
    try std.testing.expectEqual(@as(u32, 120), s.hundredths());
    s.frames = 600;
    try std.testing.expectEqual(@as(f64, 7.5), s.seconds());
}

test "shot: a sharp player, a misfire, a wrong button, the cap" {
    const app = fresh();
    app.screen = .game;
    // Drive the cue directly with a shoot prompt (the stub's first shot
    // is covered by the flow test).
    app.game.prompt = shot_prompt();

    // 1. Right presses: correct, frames counted from the cue.
    var k: u32 = 0;
    while (k < 50) : (k += 1) {
        start_shot_for_test(app);
        try std.testing.expectEqual(app_mod.Phase.shot_ready, app.phase);
        // (the press and its release already ran two frames of it)
        try std.testing.expect(app.shot.ready_left + 2 >= knobs.ready_min_frames and app.shot.ready_left + 2 <= knobs.ready_max_frames);
        try std.testing.expectEqual(@as(u8, 4), app.shot.n);
        // No two buttons in a row the same.
        for (1..app.shot.n) |i| try std.testing.expect(app.shot.seq[i] != app.shot.seq[i - 1]);
    }
    start_shot_for_test(app);
    shoot_right(app, 20);
    try std.testing.expectEqual(app_mod.Phase.shot_done, app.phase);
    try std.testing.expect(app.shot.correct);
    try std.testing.expectEqual(@as(u32, 80), app.shot.frames);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), app.shot.seconds(), 1e-12);

    // 2. A press during GET READY: a misfire.
    start_shot_for_test(app);
    app.update(.{});
    app.update(.{ .a = true });
    try std.testing.expectEqual(app_mod.Phase.shot_done, app.phase);
    try std.testing.expect(app.shot.misfire and !app.shot.correct);

    // 3. A wrong button after a right one.
    start_shot_for_test(app);
    while (app.phase == .shot_ready) app.update(.{});
    press(app, app_mod.buttons_for(app.shot.seq[0]));
    const want = app.shot.seq[1];
    const wrong: app_mod.ShotButton = @fromBackingInt(@intCast((@backingInt(want) + 1) % 6));
    app.update(app_mod.buttons_for(wrong));
    try std.testing.expectEqual(app_mod.Phase.shot_done, app.phase);
    try std.testing.expect(!app.shot.correct and !app.shot.misfire);
    try std.testing.expectEqual(@as(u8, 1), app.shot.wrong_at);

    // 4. Two buttons at once count as wrong.
    start_shot_for_test(app);
    while (app.phase == .shot_ready) app.update(.{});
    var both = app_mod.buttons_for(app.shot.seq[0]);
    both.a = true;
    both.b = true;
    app.update(both);
    try std.testing.expect(!app.shot.correct);

    // 5. Start/Select presses are not shooting buttons; nothing for 10 s:
    //    the shot ends correct with 7.5 s.
    start_shot_for_test(app);
    press(app, .{ .start = true });
    try std.testing.expectEqual(app_mod.Phase.shot_ready, app.phase);
    while (app.phase == .shot_ready) app.update(.{});
    for (0..knobs.shot_cap_frames - 1) |_| app.update(.{});
    try std.testing.expectEqual(app_mod.Phase.shot_cue, app.phase);
    app.update(.{});
    try std.testing.expectEqual(app_mod.Phase.shot_done, app.phase);
    try std.testing.expect(app.shot.correct);
    try std.testing.expectEqual(@as(f64, 7.5), app.shot.seconds());
}

/// Puts the app at the start of a shot for the current (shoot) prompt.
fn start_shot_for_test(app: *App) void {
    app.update(.{}); // release whatever the last step held
    app.batch_start = app.log.total;
    app.batch_end = app.log.total;
    app.seen = app.log.total;
    // enter_prompt via the public paging path: a batch with no rows.
    app.phase = .more;
    app.view_end = app.log.total;
    press(app, .{ .a = true }); // "A: MORE" with nothing left shows the prompt
}

// -- paging and the log ----------------------------------------------------

test "paging: a long batch pages with A: MORE, then the prompt" {
    const app = fresh();
    press(app, .{ .a = true }); // title -> game: the instructions question
    try std.testing.expectEqual(app_mod.Screen.game, app.screen);
    try std.testing.expectEqual(app_mod.Phase.prompt, app.phase);
    try std.testing.expectEqual(G.PromptKind.yes_no, app.prompt().kind);

    // Fill the log with a long batch by hand and page through it.
    var k: u32 = 0;
    const start = app.log.total;
    while (k < 40) : (k += 1) _ = app.log.line("A LINE OF THE INSTRUCTIONS", .ink, .left);
    app.batch_start = start;
    app.batch_end = app.log.total;
    app.seen = start;
    app.phase = .more;
    app.view_end = start;
    press(app, .{ .a = true }); // shows the first page
    var pages: u32 = 0;
    while (app.phase == .more) : (pages += 1) {
        // Each page fits above the footer.
        try std.testing.expect(app.log.height(app.seen, app.view_end) <= L.height - L.footer_h - L.log_top);
        press(app, .{ .a = true });
    }
    try std.testing.expect(pages >= 3);
    try std.testing.expectEqual(app_mod.Phase.prompt, app.phase);
    try std.testing.expectEqual(app.batch_end, app.view_end);
}

test "log history: Select opens on release, Up/Down scroll, B closes" {
    const app = fresh();
    press(app, .{ .a = true });
    var k: u32 = 0;
    while (k < 30) : (k += 1) _ = app.log.line("HISTORY", .ink, .left);
    app.view_end = app.log.total;
    app.update(.{ .select = true });
    try std.testing.expectEqual(app_mod.Screen.game, app.screen); // not on press
    app.update(.{});
    try std.testing.expectEqual(app_mod.Screen.history, app.screen);
    press(app, .{ .up = true });
    press(app, .{ .up = true });
    try std.testing.expectEqual(@as(u32, 2), app.hist_scroll);
    press(app, .{ .down = true });
    try std.testing.expectEqual(@as(u32, 1), app.hist_scroll);
    // Held Up repeats, and stops at the oldest row.
    for (0..2000) |_| app.update(.{ .up = true });
    app.update(.{});
    try std.testing.expectEqual(app.view_end - app.log.oldest() - 1, app.hist_scroll);
    press(app, .{ .b = true });
    try std.testing.expectEqual(app_mod.Screen.game, app.screen);
}

// -- chord guard ------------------------------------------------------------

test "chord: nothing happens while Start and Select are both held" {
    const app = fresh();
    // On the title, A with the chord held does not start a game.
    app.update(.{ .start = true, .select = true });
    app.update(.{ .start = true, .select = true, .a = true });
    try std.testing.expectEqual(app_mod.Screen.title, app.screen);
    app.update(.{});
    press(app, .{ .a = true });
    try std.testing.expectEqual(app_mod.Screen.game, app.screen);
    // Select pressed, then Start (the chord), both released: no history.
    app.update(.{ .select = true });
    app.update(.{ .select = true, .start = true });
    app.update(.{ .start = true });
    app.update(.{});
    try std.testing.expectEqual(app_mod.Screen.game, app.screen);
    // The cursor does not move under the chord.
    const c = app.cursor;
    app.update(.{ .start = true, .select = true, .down = true });
    app.update(.{ .start = true, .select = true });
    try std.testing.expectEqual(c, app.cursor);
    // A held through the chord's release does not answer (an edge is needed).
    const answers = app.answers;
    app.update(.{ .start = true, .select = true, .a = true });
    app.update(.{ .a = true });
    try std.testing.expectEqual(answers, app.answers);
}

// -- the whole flow ---------------------------------------------------------

test "flow: title -> game -> every prompt kind -> end -> title" {
    const app = fresh();
    try std.testing.expectEqual(app_mod.Screen.title, app.screen);
    press(app, .{ .a = true });
    try std.testing.expectEqual(@as(u32, 1), app.games_started);
    var guard: u32 = 0;
    var seen_kinds: [5]bool = @splat(false);
    while (app.screen == .game and guard < 400) : (guard += 1) {
        to_prompt(app);
        const p = app.prompt();
        seen_kinds[@backingInt(p.kind)] = true;
        switch (app.phase) {
            .shot_ready, .shot_cue => {
                shoot_right(app, 12);
                finish_shot(app);
                continue;
            },
            else => {},
        }
        switch (p.kind) {
            .yes_no => press(app, .{ .down = true }), // NO
            .choice => {},
            .number => {
                // Dial +1 at the tens and enter.
                press(app, .{ .right = true });
                press(app, .{ .up = true });
            },
            .game_over => {
                try std.testing.expectEqual(@as(u32, 1), app.games_over);
                try std.testing.expect(app.last_outcome != .none or p.outcome == .none);
            },
            .shoot => unreachable,
        }
        press(app, .{ .a = true });
    }
    try std.testing.expectEqual(app_mod.Screen.title, app.screen);
    try std.testing.expect(seen_kinds[@backingInt(G.PromptKind.yes_no)]);
    try std.testing.expect(seen_kinds[@backingInt(G.PromptKind.game_over)]);
    try std.testing.expect(app.answers >= 3);
    // The log never shows the status table or the questions.
    var i = app.log.oldest();
    while (i < app.log.total) : (i += 1) {
        const r = app.log.get(i);
        if (r.kind != .text) continue;
        try std.testing.expect(!std.mem.startsWith(u8, r.str(), "FOOD "));
        try std.testing.expect(!std.mem.startsWith(u8, r.str(), "TOTAL MILEAGE"));
        try std.testing.expect(!std.mem.startsWith(u8, r.str(), "DO YOU NEED"));
    }
    // And again: a second game starts from the title.
    press(app, .{ .a = true });
    try std.testing.expectEqual(@as(u32, 2), app.games_started);
}

test "flow: the number prompt answers the spinner's value" {
    const app = fresh();
    press(app, .{ .a = true });
    var guard: u32 = 0;
    while (guard < 50 and !(app.phase == .prompt and app.prompt().kind == .number)) : (guard += 1) {
        to_prompt(app);
        if (app.phase == .prompt and app.prompt().kind == .number) break;
        if (app.prompt().kind == .game_over) return error.NoNumberPrompt;
        press(app, .{ .a = true });
    }
    try std.testing.expectEqual(G.PromptKind.number, app.prompt().kind);
    const p = app.prompt().*;
    try std.testing.expectEqual(p.default, app.spin.value);
    press(app, .{ .up = true });
    const want = app.spin.value;
    try std.testing.expect(want >= p.min and want <= @max(p.min, p.max));
    press(app, .{ .b = true });
    try std.testing.expectEqual(p.default, app.spin.value);
    press(app, .{ .up = true });
    const answers = app.answers;
    press(app, .{ .a = true });
    try std.testing.expectEqual(answers + 1, app.answers);
    // The echo row shows the amount.
    var found = false;
    var i = app.log.oldest();
    var buf: [64]u8 = undefined;
    var qb: [64]u8 = undefined;
    const echo = try std.fmt.bufPrint(&buf, "> {s} ${d}", .{ app_mod.short_question(p.question, &qb), want });
    while (i < app.log.total) : (i += 1) {
        if (std.mem.eql(u8, app.log.get(i).str(), echo)) found = true;
    }
    try std.testing.expect(found);
}

test "echo: the short question" {
    var qb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("OXEN", app_mod.short_question("SPEND ON OXEN?", &qb));
    try std.testing.expectEqualStrings("FORT: AMMUNITION", app_mod.short_question("FORT: SPEND ON AMMUNITION?", &qb));
    try std.testing.expectEqualStrings("A FANCY FUNERAL", app_mod.short_question("A FANCY FUNERAL?", &qb));
}

// -- autoplay ----------------------------------------------------------------

test "autoplay: plays whole games through the buttons and restarts" {
    const policies = [_]u32{ 0x01, 0x12, 0x22, 0x32 };
    for (policies) |v| {
        const app = fresh();
        var bot: autoplay.Bot = .{};
        bot.set(v, 99);
        var frames: u32 = 0;
        while (app.games_over < 3 and frames < 400_000) : (frames += 1) {
            const b = bot.step(app);
            app.update(b);
        }
        try std.testing.expect(app.games_over >= 3);
        try std.testing.expect(app.games_started >= 3);
        if (v >> 4 == 3) try std.testing.expect(app.shots >= 1);
    }
}

test "autoplay: stats (prints)" {
    if (true) return error.SkipZigTest;
    const policies = [_]u32{ 0x02, 0x12, 0x22, 0x32 };
    for (policies) |v| {
        const app = fresh();
        var bot: autoplay.Bot = .{};
        bot.set(v, 7);
        var frames: u64 = 0;
        var outcomes: [10]u32 = @splat(0);
        var last: u32 = 0;
        while (app.games_over < 40 and frames < 20_000_000) : (frames += 1) {
            app.update(bot.step(app));
            if (app.games_over != last) {
                last = app.games_over;
                outcomes[@backingInt(app.last_outcome)] += 1;
            }
        }
        std.debug.print("policy {x}: {d} games, {d} frames/game, shots {d} hit {d} wrong {d} misfire {d}, outcomes {any}\n", .{ v, app.games_over, frames / @max(app.games_over, 1), app.shots, app.shots_hit, app.shots_wrong, app.misfires, outcomes });
    }
}
