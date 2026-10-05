//! The cart's UI state machine (SPEC 4), free of the cart API so the host
//! tests drive it: the title, the game (reading the new lines a page at a
//! time, then the prompt box: a cursor list, the number spinner or the
//! shooting cue), the log history on Select, and the end of a game.
//! update() takes the buttons once per frame (60 fps); render.zig draws
//! what this holds. The game is the `game` module, called only through
//! G.init, G.start and G.answer.
const std = @import("std");
const G = @import("game");
const L = @import("layout.zig");
const log_mod = @import("log.zig");
const text = @import("text.zig");

pub const Buttons = packed struct(u8) {
    start: bool = false,
    select: bool = false,
    a: bool = false,
    b: bool = false,
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
};

pub const Screen = enum(u8) { title, game, history };

/// Where a game screen is: paging through new lines ("A: MORE"), at a
/// prompt, or in one of the shooting cue's three steps (SPEC 4.4).
pub const Phase = enum(u8) { more, prompt, shot_ready, shot_cue, shot_done };

/// Knobs, in one place.
pub const knobs = struct {
    /// SPEC 4.4: seconds = frames / 60 * shot_time_scale.
    pub const shot_time_scale: f64 = 0.75;
    /// "GET READY" lasts 0.6..1.4 s.
    pub const ready_min_frames: u32 = 36;
    pub const ready_max_frames: u32 = 84;
    /// The shot ends by itself after 10 s.
    pub const shot_cap_frames: u32 = 600;
    /// The result ("1.13 SEC", "MISFIRE!") stays this long before the game
    /// goes on.
    pub const shot_result_frames: u32 = 50;
    /// Held d-pad keys repeat after 0.4 s, then 10 per second.
    pub const repeat_delay: u32 = 24;
    pub const repeat_period: u32 = 6;
};

/// The shooting cue's buttons (SPEC 4.4).
pub const ShotButton = enum(u8) {
    up,
    down,
    left,
    right,
    a,
    b,

    pub fn held(sb: ShotButton, b: Buttons) bool {
        return switch (sb) {
            .up => b.up,
            .down => b.down,
            .left => b.left,
            .right => b.right,
            .a => b.a,
            .b => b.b,
        };
    }

    pub fn name(sb: ShotButton) []const u8 {
        return switch (sb) {
            .up => "UP",
            .down => "DOWN",
            .left => "LEFT",
            .right => "RIGHT",
            .a => "A",
            .b => "B",
        };
    }
};

pub const Shot = struct {
    seq: [4]ShotButton = @splat(.a),
    n: u8 = 0,
    /// The next button to press.
    idx: u8 = 0,
    /// shot_ready: frames left of "GET READY".
    ready_left: u32 = 0,
    /// Frames since the cue appeared.
    frames: u32 = 0,
    correct: bool = false,
    misfire: bool = false,
    /// The wrong button pressed (shot_done, `correct` false, no misfire).
    wrong_at: u8 = 0xFF,
    /// shot_done: frames left before the answer goes in.
    result_left: u32 = 0,

    pub fn seconds(s: *const Shot) f64 {
        return @as(f64, @floatFromInt(s.frames)) / 60.0 * knobs.shot_time_scale;
    }

    /// The scaled time in hundredths of a second, rounded (for display;
    /// frames * 1.25).
    pub fn hundredths(s: *const Shot) u32 {
        return (s.frames * 5 + 2) / 4;
    }
};

/// The place-value spinner of a .number prompt (SPEC 4.3).
pub const Spinner = struct {
    value: i32 = 0,
    min: i32 = 0,
    max: i32 = 0,
    default: i32 = 0,
    /// The caret's place: 0 the ones, 1 the tens...
    caret: u8 = 0,
    digits: u8 = 1,

    pub fn init(p: *const G.Prompt) Spinner {
        const hi = @max(p.min, p.max);
        var s: Spinner = .{ .min = p.min, .max = hi, .default = std.math.clamp(p.default, p.min, hi) };
        s.value = s.default;
        s.digits = text.digits(hi);
        s.caret = @min(s.digits - 1, 2);
        return s;
    }

    fn place(s: *const Spinner) i32 {
        var v: i32 = 1;
        var k: u8 = 0;
        while (k < s.caret) : (k += 1) v *= 10;
        return v;
    }

    /// Up (+) or Down (-) at the caret's place: carries into the higher
    /// places and clamps to min..max.
    pub fn bump(s: *Spinner, up: bool) void {
        const d = s.place();
        s.value = std.math.clamp(if (up) s.value + d else s.value - d, s.min, s.max);
    }

    /// Left: a higher place; Right: a lower one.
    pub fn move(s: *Spinner, left: bool) void {
        if (left) {
            if (s.caret + 1 < s.digits) s.caret += 1;
        } else if (s.caret > 0) s.caret -= 1;
    }

    pub fn reset(s: *Spinner) void {
        s.value = s.default;
    }
};

/// A held key: fires on the press, then after `repeat_delay` frames every
/// `repeat_period` frames.
pub const Repeat = struct {
    frames: u32 = 0,

    pub fn fire(r: *Repeat, held: bool) bool {
        if (!held) {
            r.frames = 0;
            return false;
        }
        defer r.frames += 1;
        if (r.frames == 0) return true;
        if (r.frames < knobs.repeat_delay) return false;
        return (r.frames - knobs.repeat_delay) % knobs.repeat_period == 0;
    }
};

pub const Outcome = G.Outcome;

/// The title's short line for each ending.
pub fn outcome_text(o: Outcome) []const u8 {
    return switch (o) {
        .none => "THE END",
        .arrived => "YOU MADE IT TO OREGON CITY",
        .starved => "STARVED ON THE TRAIL",
        .no_doctor_money => "NO MONEY FOR A DOCTOR",
        .no_medicine => "OUT OF MEDICAL SUPPLIES",
        .pneumonia => "DIED OF PNEUMONIA",
        .injuries => "DIED OF INJURIES",
        .winter => "LOST TO THE WINTER",
        .massacred => "MASSACRED BY RIDERS",
        .snakebite => "DIED OF SNAKEBITE",
    };
}

fn default_seed() u64 {
    return 1;
}

var game_storage: G.Game = undefined;
var log_storage: log_mod.Log = .{};

pub const App = struct {
    screen: Screen = .title,
    phase: Phase = .more,
    game: *G.Game = &game_storage,
    log: *log_mod.Log = &log_storage,
    /// Where a new game's seed comes from (main.zig: the clock on the
    /// badge, cart.rand() on wasm); called when A starts a game.
    seed_source: *const fn () u64 = &default_seed,
    seed: u64 = 1,
    /// UI-side randomness (the shooting cue), seeded per game.
    rng: u64 = 1,

    /// The current batch of new rows is [batch_start, batch_end) in the
    /// log; rows before `seen` have been shown; the log view ends at
    /// `view_end`.
    batch_start: u32 = 0,
    batch_end: u32 = 0,
    seen: u32 = 0,
    view_end: u32 = 0,

    /// The HUD (a copy: the game reuses its text buffer).
    hud: G.Hud = .{},
    date_buf: [24]u8 = undefined,

    /// .choice / .yes_no: the cursor row (0-based).
    cursor: u8 = 0,
    spin: Spinner = .{},
    shot: Shot = .{},
    /// The log history's scroll, in rows up from the newest.
    hist_scroll: u32 = 0,

    prev: Buttons = .{},
    rep_up: Repeat = .{},
    rep_down: Repeat = .{},
    rep_left: Repeat = .{},
    rep_right: Repeat = .{},
    select_armed: bool = false,

    frame: u32 = 0,
    /// Frames since the screen or phase last changed (blinks, the title).
    phase_frames: u32 = 0,
    /// Counters for the debug exports and the tests.
    answers: u32 = 0,
    shots: u32 = 0,
    shots_hit: u32 = 0,
    shots_wrong: u32 = 0,
    misfires: u32 = 0,
    games_started: u32 = 0,
    games_over: u32 = 0,
    arrivals: u32 = 0,
    deaths: u32 = 0,
    /// The last finished game's ending (kept through the next game).
    last_outcome: Outcome = .none,

    pub fn init(app: *App, seed_source: *const fn () u64) void {
        app.* = .{ .seed_source = seed_source };
        app.log.reset();
    }

    pub fn prompt(app: *const App) *const G.Prompt {
        return &app.game.prompt;
    }

    pub fn date_text(app: *const App) []const u8 {
        const n = @min(app.hud.date_text.len, app.date_buf.len);
        return app.date_buf[0..n];
    }

    /// The bottom of the log area for the current phase.
    pub fn log_bottom(app: *const App) i32 {
        return switch (app.phase) {
            .more => L.height - L.footer_h,
            else => L.height - L.prompt_height(app.prompt()),
        };
    }

    /// Starts a game (the title's A).
    pub fn new_game(app: *App) void {
        app.seed = app.seed_source();
        if (app.seed == 0) app.seed = 1;
        app.rng = app.seed ^ 0x6A09E667F3BCC909;
        if (app.rng == 0) app.rng = 1;
        G.init(app.game, app.seed);
        app.log.reset();
        app.hud = .{};
        app.copy_hud();
        app.screen = .game;
        app.games_started += 1;
        G.start(app.game);
        app.ingest();
    }

    pub fn update(app: *App, now: Buttons) void {
        app.frame +%= 1;
        app.phase_frames +|= 1;
        // The cue's clock counts this frame before its presses: a press on
        // the first frame after the cue is 1/60 s.
        if (app.screen == .game and app.phase == .shot_cue) app.shot.frames += 1;
        const before = app.prev;
        app.prev = now;
        // The OS owns Start+Select (exit, or its settings box): no button
        // does anything while both are held.
        if (now.start and now.select) {
            app.select_armed = false;
            app.rep_up = .{};
            app.rep_down = .{};
            app.rep_left = .{};
            app.rep_right = .{};
            app.tick_timers();
            return;
        }
        const pressed = edges(now, before);
        // Select acts on release, so that Select-then-Start (the chord)
        // never opens the history.
        if (pressed.select) app.select_armed = true;
        const select_click = app.select_armed and !now.select and before.select;
        if (!now.select) app.select_armed = false;

        switch (app.screen) {
            .title => if (pressed.a) app.new_game(),
            .history => app.history_input(now, pressed, select_click),
            .game => {
                if (select_click and app.phase != .shot_cue and app.phase != .shot_ready) {
                    app.screen = .history;
                    app.hist_scroll = 0;
                    return;
                }
                app.game_input(now, pressed);
            },
        }
        app.tick_timers();
    }

    /// The shooting cue's clocks run every frame, chord or not (time
    /// passes either way).
    fn tick_timers(app: *App) void {
        if (app.screen != .game) return;
        switch (app.phase) {
            .shot_ready => {
                if (app.shot.ready_left > 0) app.shot.ready_left -= 1;
                if (app.shot.ready_left == 0) app.set_phase(.shot_cue);
            },
            .shot_cue => if (app.shot.frames >= knobs.shot_cap_frames) app.end_shot(true),
            .shot_done => {
                if (app.shot.result_left > 0) app.shot.result_left -= 1;
                if (app.shot.result_left == 0) app.send_shot();
            },
            else => {},
        }
    }

    fn set_phase(app: *App, p: Phase) void {
        app.phase = p;
        app.phase_frames = 0;
    }

    fn history_input(app: *App, now: Buttons, pressed: Buttons, select_click: bool) void {
        if (pressed.a or pressed.b or select_click) {
            app.screen = .game;
            return;
        }
        const span = app.view_end - app.log.oldest();
        if (app.rep_up.fire(now.up) and app.hist_scroll + 1 < span) app.hist_scroll += 1;
        if (app.rep_down.fire(now.down) and app.hist_scroll > 0) app.hist_scroll -= 1;
    }

    fn game_input(app: *App, now: Buttons, pressed: Buttons) void {
        const p = app.prompt();
        switch (app.phase) {
            .more => if (pressed.a) {
                app.seen = app.view_end;
                app.next_page();
            },
            .prompt => switch (p.kind) {
                .yes_no, .choice => {
                    const n: u8 = if (p.kind == .yes_no) 2 else @max(p.n_options, 1);
                    if (app.rep_up.fire(now.up)) app.cursor = if (app.cursor == 0) n - 1 else app.cursor - 1;
                    if (app.rep_down.fire(now.down)) app.cursor = if (app.cursor + 1 >= n) 0 else app.cursor + 1;
                    if (pressed.a) {
                        if (p.kind == .yes_no)
                            app.send(.{ .yes_no = app.cursor == 0 })
                        else
                            app.send(.{ .choice = app.cursor + 1 });
                    }
                },
                .number => {
                    if (app.rep_up.fire(now.up)) app.spin.bump(true);
                    if (app.rep_down.fire(now.down)) app.spin.bump(false);
                    if (app.rep_left.fire(now.left)) app.spin.move(true);
                    if (app.rep_right.fire(now.right)) app.spin.move(false);
                    if (pressed.b) app.spin.reset();
                    if (pressed.a) app.send(.{ .number = app.spin.value });
                },
                .game_over => if (pressed.a) {
                    app.screen = .title;
                    app.phase_frames = 0;
                },
                .shoot => {},
            },
            .shot_ready => {
                // Any shooting button before the cue is a misfire.
                if (any_shot_button(pressed)) {
                    app.shot.misfire = true;
                    app.end_shot(false);
                }
            },
            .shot_cue => app.shot_input(pressed),
            .shot_done => {},
        }
    }

    fn shot_input(app: *App, pressed: Buttons) void {
        if (!any_shot_button(pressed)) return;
        const want = app.shot.seq[app.shot.idx];
        var others = pressed;
        others.start = false;
        others.select = false;
        switch (want) {
            .up => others.up = false,
            .down => others.down = false,
            .left => others.left = false,
            .right => others.right = false,
            .a => others.a = false,
            .b => others.b = false,
        }
        if (any_shot_button(others) or !want.held(pressed)) {
            app.shot.wrong_at = app.shot.idx;
            app.end_shot(false);
            return;
        }
        app.shot.idx += 1;
        if (app.shot.idx == app.shot.n) app.end_shot(true);
    }

    fn end_shot(app: *App, correct: bool) void {
        app.shot.correct = correct;
        app.shot.result_left = knobs.shot_result_frames;
        app.set_phase(.shot_done);
    }

    fn send_shot(app: *App) void {
        const s = app.shot;
        app.shots += 1;
        if (s.misfire) app.misfires += 1 else if (!s.correct) app.shots_wrong += 1 else app.shots_hit += 1;
        app.send(.{ .shoot = .{ .correct = s.correct, .seconds = if (s.correct) s.seconds() else 0 } });
    }

    /// Echoes the answer into the log, feeds it to the game and takes in
    /// what the game printed next.
    fn send(app: *App, a: G.Answer) void {
        app.echo(a);
        app.answers += 1;
        G.answer(app.game, a);
        app.ingest();
    }

    fn echo(app: *App, a: G.Answer) void {
        const p = app.prompt();
        var buf: [40]u8 = undefined;
        const s: []const u8 = switch (a) {
            .yes_no => |y| if (y) "> YES" else "> NO",
            .choice => |c| std.fmt.bufPrint(&buf, "> {s}", .{p.options[c - 1]}) catch "",
            .number => |v| std.fmt.bufPrint(&buf, "> ${d}", .{v}) catch "",
            .shoot => blk: {
                const sh = app.shot;
                const w = p.word.text();
                if (sh.misfire) break :blk std.fmt.bufPrint(&buf, "> {s}: MISFIRE", .{w}) catch "";
                if (!sh.correct) break :blk std.fmt.bufPrint(&buf, "> {s}: WRONG BUTTON", .{w}) catch "";
                const h = sh.hundredths();
                break :blk std.fmt.bufPrint(&buf, "> {s} {d}.{d:0>2} SEC", .{ w, h / 100, h % 100 }) catch "";
            },
            .game_over => "",
        };
        if (s.len > 0) _ = app.log.line(s, .answer, .left);
        app.log.gap();
    }

    fn copy_hud(app: *App) void {
        app.hud = app.game.hud;
        const n = @min(app.hud.date_text.len, app.date_buf.len);
        @memcpy(app.date_buf[0..n], app.hud.date_text[0..n]);
    }

    /// Takes the lines the game printed since the last answer into the
    /// log (dropping what the HUD and the prompt box show) and starts
    /// paging through them.
    fn ingest(app: *App) void {
        app.copy_hud();
        const lg = app.log;
        app.batch_start = lg.total;
        for (app.game.printed()) |ln| {
            switch (ln.tag) {
                .question, .mileage, .status_header, .status_values => {},
                .date => lg.rule(),
                .warning, .death => _ = lg.line(ln.text, .warn, .indent),
                .arrival => _ = lg.line(ln.text, .good, .indent),
                .letter => _ = lg.line(ln.text, .ink, .center),
                else => _ = lg.line(ln.text, .ink, .indent),
            }
        }
        // A rule can land before the first new row: it belongs to the batch.
        app.batch_end = lg.total;
        app.batch_start = @max(@min(app.batch_start, app.batch_end), lg.oldest());
        app.seen = app.batch_start;
        app.next_page();
    }

    /// Shows the rest of the batch with the prompt if it fits above the
    /// prompt box, else the next page with "A: MORE".
    fn next_page(app: *App) void {
        const lg = app.log;
        const room_prompt = L.height - L.prompt_height(app.prompt()) - L.log_top;
        if (lg.height(app.seen, app.batch_end) <= room_prompt) {
            app.view_end = app.batch_end;
            app.seen = app.batch_end;
            app.enter_prompt();
            return;
        }
        const room_more = L.height - L.footer_h - L.log_top;
        app.view_end = lg.fit_from(app.seen, app.batch_end, room_more);
        app.set_phase(.more);
    }

    fn enter_prompt(app: *App) void {
        const p = app.prompt();
        app.set_phase(.prompt);
        switch (p.kind) {
            .yes_no => app.cursor = 0,
            .choice => app.cursor = if (p.default_choice >= 1 and p.default_choice <= p.n_options) p.default_choice - 1 else 0,
            .number => app.spin = Spinner.init(p),
            .shoot => app.start_shot(p.word),
            .game_over => {
                app.games_over += 1;
                app.last_outcome = p.outcome;
                if (p.outcome == .arrived) app.arrivals += 1 else app.deaths += 1;
            },
        }
    }

    fn start_shot(app: *App, word: G.Word) void {
        var s: Shot = .{};
        s.n = @intCast(word.text().len);
        var k: u8 = 0;
        while (k < s.n) : (k += 1) {
            while (true) {
                const b: ShotButton = @fromBackingInt(@intCast(app.rand_below(6)));
                if (k == 0 or b != s.seq[k - 1]) {
                    s.seq[k] = b;
                    break;
                }
            }
        }
        s.ready_left = knobs.ready_min_frames + app.rand_below(knobs.ready_max_frames - knobs.ready_min_frames + 1);
        app.shot = s;
        app.set_phase(.shot_ready);
    }

    /// xorshift64* (UI-side randomness, apart from the game's RND).
    pub fn rand_below(app: *App, n: u32) u32 {
        var x = app.rng;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        app.rng = x;
        const r: u32 = @truncate((x *% 0x2545F4914F6CDD1D) >> 32);
        return @intCast((@as(u64, r) * n) >> 32);
    }
};

fn edges(now: Buttons, prev: Buttons) Buttons {
    const n: u8 = @bitCast(now);
    const p: u8 = @bitCast(prev);
    return @bitCast(n & ~p);
}

pub fn any_shot_button(b: Buttons) bool {
    return b.up or b.down or b.left or b.right or b.a or b.b;
}

/// The button for a ShotButton (tests and the autoplayer).
pub fn buttons_for(sb: ShotButton) Buttons {
    return switch (sb) {
        .up => .{ .up = true },
        .down => .{ .down = true },
        .left => .{ .left = true },
        .right => .{ .right = true },
        .a => .{ .a = true },
        .b => .{ .b = true },
    };
}
