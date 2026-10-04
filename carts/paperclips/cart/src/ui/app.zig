//! The cart's UI state machine, free of the cart API so host tests can drive
//! it: the title (with its code), the game pages with their cursor, the
//! message log, the HypnoDrones flash and the M1 "stage 2" wall. update()
//! takes the buttons and advances the game's virtual clock; render.zig
//! draws what this holds.
const std = @import("std");
const G = @import("game");
const pages = @import("pages.zig");
const text = @import("text.zig");
const layout = @import("layout.zig");

pub const Page = pages.Page;

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

pub const Screen = enum(u8) { title, game, log, wall };

/// Knobs (SPEC section 3).
pub const knobs = struct {
    /// Held A/B on repeat rows: first repeat after this many frames (0.4 s)...
    pub const repeat_delay: u32 = 24;
    /// ...then this many presses per second.
    pub const repeat_rate: u32 = 8;
    /// Held Up/Down: cursor repeat delay and period, in frames.
    pub const nav_delay: u32 = 18;
    pub const nav_period: u32 = 5;
    /// Ticker: frames per pair of lines when a message wraps past two.
    pub const ticker_page_frames: u32 = 100;
    /// Footer: frames per line step when a description is longer than it.
    pub const footer_step_frames: u32 = 75;
    /// The HypnoDrones flash: steps of 32 ms (the original's longBlink).
    pub const hypno_steps: u32 = 120;
};

/// Whether the game module plays past the HypnoDrones (track L's stage 2).
/// Until it does, the cart stops there with the M1 wall.
pub const stage2_ready = @hasDecl(G, "stage2_ready") and G.stage2_ready;

/// Up Up Down Down Left Right Left Right B A, on the title.
const konami = [_]std.meta.FieldEnum(Buttons){ .up, .up, .down, .down, .left, .right, .left, .right, .b, .a };

pub const App = struct {
    screen: Screen = .title,
    game: G.Game = undefined,
    playing: bool = false,
    cheats: bool = false,
    /// Frames since the cheat code was entered (title message).
    cheat_flash: u32 = 0,
    konami_pos: u8 = 0,
    konami_hist: [konami.len]std.meta.FieldEnum(Buttons) = @splat(.start),
    seed: u64 = 1,

    page: Page = .business,
    cursor_id: [pages.page_count]u16 = @splat(0xFFFF),
    cursor_ix: [pages.page_count]u16 = @splat(0),
    scroll: [pages.page_count]u16 = @splat(0),
    news: [pages.page_count]bool = @splat(false),
    was_visible: [pages.page_count]bool = @splat(false),
    seen: std.StaticBitSet(pages.max_ids) = .empty,
    scan_next: u8 = 0,

    prev: Buttons = .{},
    held_frames_a: u32 = 0,
    held_frames_b: u32 = 0,
    repeat_acc: u32 = 0,
    nav_frames: u32 = 0,
    start_armed: bool = false,
    select_armed: bool = false,

    frame: u32 = 0,
    clock_phase: u8 = 0,
    /// Frame counter for the footer's line stepping (reset on cursor move).
    footer_frames: u32 = 0,
    log_scroll: u32 = 0,
    ticker_count: u32 = 0,
    ticker_frames: u32 = 0,
    /// Frames since a new message arrived (render flashes the ticker).
    msg_age: u32 = 1000,
    hypno_ms: u32 = 0,
    hypno_on: bool = false,
    human_prev: bool = true,

    rows: pages.RowList = .{},
    arena: text.Arena = .{},
    /// A count of how many presses reached the game (debug export).
    presses: u32 = 0,

    pub fn init(app: *App, seed: u64) void {
        app.* = .{};
        app.seed = if (seed == 0) 1 else seed;
    }

    /// Starts a game (the title's A).
    pub fn new_game(app: *App) void {
        G.init(&app.game, app.seed);
        app.playing = true;
        app.screen = .game;
        app.page = .business;
        app.cursor_id = @splat(0xFFFF);
        app.cursor_ix = @splat(0);
        app.scroll = @splat(0);
        app.news = @splat(false);
        app.seen = .empty;
        app.human_prev = true;
        app.clock_phase = 0;
        app.ticker_count = msg_count(&app.game);
        // Whatever exists at the start is not news.
        for (0..pages.page_count) |i| {
            const p: Page = @enumFromInt(i);
            app.was_visible[i] = pages.visible(&app.game, p, app.cheats);
            if (app.was_visible[i]) app.scan(p, false);
        }
        app.rebuild();
    }

    pub fn update(app: *App, now: Buttons) void {
        const pressed = edges(now, app.prev);
        defer app.prev = now;
        app.frame +%= 1;
        if (app.cheat_flash < 1000) app.cheat_flash += 1;
        if (app.msg_age < 1000) app.msg_age += 1;

        // Start and Select act on release, and not at all while both are
        // held: the newer OS opens its settings box on Start+Select.
        const chord = now.start and now.select;
        if (pressed.start) app.start_armed = !now.select;
        if (pressed.select) app.select_armed = !now.start;
        if (chord) {
            app.start_armed = false;
            app.select_armed = false;
        }
        const start_click = app.start_armed and !now.start and app.prev.start;
        const select_click = app.select_armed and !now.select and app.prev.select;
        if (!now.start) app.start_armed = false;
        if (!now.select) app.select_armed = false;

        switch (app.screen) {
            .title => app.title_input(pressed),
            .game => app.game_input(now, pressed, start_click, select_click),
            .log => app.log_input(now, pressed, start_click),
            .wall => if (start_click) {
                app.screen = .log;
                app.log_scroll = 0;
            },
        }

        if (app.playing) app.tick();
    }

    fn title_input(app: *App, pressed: Buttons) void {
        inline for (@typeInfo(Buttons).@"struct".field_names) |name| {
            if (@field(pressed, name)) app.konami_step(@field(std.meta.FieldEnum(Buttons), name));
        }
        if (app.konami_pos == konami.len) {
            app.konami_pos = 0;
            app.konami_hist = @splat(.start);
            app.cheats = true;
            app.cheat_flash = 0;
            return;
        }
        if (pressed.a) {
            if (!app.playing) app.new_game() else app.screen = .game;
        }
    }

    fn konami_step(app: *App, btn: std.meta.FieldEnum(Buttons)) void {
        std.mem.copyForwards(std.meta.FieldEnum(Buttons), app.konami_hist[0 .. konami.len - 1], app.konami_hist[1..]);
        app.konami_hist[konami.len - 1] = btn;
        if (std.mem.eql(std.meta.FieldEnum(Buttons), &app.konami_hist, &konami)) app.konami_pos = konami.len;
    }

    fn game_input(app: *App, now: Buttons, pressed: Buttons, start_click: bool, select_click: bool) void {
        if (start_click) {
            app.screen = .log;
            app.log_scroll = 0;
            return;
        }
        if (select_click) app.jump_to_news();
        if (pressed.left) app.switch_page(-1);
        if (pressed.right) app.switch_page(1);

        const rows = app.rows.slice();
        const pi = @intFromEnum(app.page);
        var ix: usize = app.cursor_ix[pi];
        if (rows.len > 0 and ix >= rows.len) ix = rows.len - 1;

        // Up/Down with hold repeat.
        const nav_held = now.up or now.down;
        if (nav_held) app.nav_frames += 1 else app.nav_frames = 0;
        const nav_fire = app.nav_frames == 1 or (app.nav_frames > knobs.nav_delay and (app.nav_frames - knobs.nav_delay) % knobs.nav_period == 0);
        if (nav_fire and rows.len > 0) {
            if (now.down and !now.up) ix = step_down(rows, ix);
            if (now.up and !now.down) ix = step_up(rows, ix);
            app.set_cursor(ix);
        }

        if (rows.len == 0) return;
        const row = rows[ix];

        // A: press, and repeat while held on repeat rows.
        if (now.a) app.held_frames_a += 1 else app.held_frames_a = 0;
        if (now.b) app.held_frames_b += 1 else app.held_frames_b = 0;
        if (pressed.a) {
            app.repeat_acc = 0;
            if (row.act) |act| app.press(act, row.enabled);
        } else if (now.a and row.repeat and app.held_frames_a > knobs.repeat_delay) {
            if (row.act) |act| app.repeat(act, row.enabled);
        }
        if (pressed.b) {
            app.repeat_acc = 0;
            if (row.act_b) |act| app.press(act, row.enabled_b);
        } else if (now.b and !now.a and row.repeat and app.held_frames_b > knobs.repeat_delay) {
            if (row.act_b) |act| app.repeat(act, row.enabled_b);
        }
    }

    fn repeat(app: *App, act: G.Action, enabled: bool) void {
        app.repeat_acc += knobs.repeat_rate;
        while (app.repeat_acc >= 60) {
            app.repeat_acc -= 60;
            app.press(act, enabled);
        }
    }

    fn press(app: *App, act: G.Action, enabled: bool) void {
        // The row's enabled flag was computed for the frame on screen; ask
        // again in case an earlier press this frame changed it.
        if (!enabled or !G.enabled(&app.game, act)) return;
        G.act(&app.game, act);
        app.presses += 1;
    }

    fn log_input(app: *App, now: Buttons, pressed: Buttons, start_click: bool) void {
        if (start_click or pressed.b) {
            app.screen = if (app.playing and !app.at_wall()) .game else if (app.playing) .wall else .title;
            return;
        }
        const nav_held = now.up or now.down;
        if (nav_held) app.nav_frames += 1 else app.nav_frames = 0;
        const nav_fire = app.nav_frames == 1 or (app.nav_frames > knobs.nav_delay and (app.nav_frames - knobs.nav_delay) % 2 == 0);
        if (nav_fire) {
            if (now.up) app.log_scroll += 1;
            if (now.down and app.log_scroll > 0) app.log_scroll -= 1;
        }
    }

    pub fn at_wall(app: *const App) bool {
        return !stage2_ready and app.game.human_flag == 0;
    }

    /// One frame of game time: 17, 17, 16 ms (60 fps), then the derived
    /// UI state (news marks, rows to draw).
    fn tick(app: *App) void {
        if (app.hypno_on) {
            app.hypno_ms += frame_ms(app.clock_phase);
            if (app.hypno_ms >= knobs.hypno_steps * 32) app.hypno_on = false;
        }
        if (!app.at_wall()) {
            G.advance_ms(&app.game, frame_ms(app.clock_phase));
        }
        app.clock_phase = (app.clock_phase + 1) % 3;

        const human = app.game.human_flag == 1;
        if (app.human_prev and !human) {
            app.hypno_on = true;
            app.hypno_ms = 0;
        }
        app.human_prev = human;
        if (app.at_wall() and !app.hypno_on and app.screen == .game) app.screen = .wall;

        const mc = msg_count(&app.game);
        if (mc != app.ticker_count) {
            app.ticker_count = mc;
            app.ticker_frames = 0;
            app.msg_age = 0;
        } else app.ticker_frames += 1;
        app.footer_frames += 1;

        // Pages that appeared or vanished; keep the current page valid.
        for (0..pages.page_count) |i| {
            const p: Page = @enumFromInt(i);
            const v = pages.visible(&app.game, p, app.cheats);
            if (v and !app.was_visible[i]) app.news[i] = true;
            if (!v) app.news[i] = false;
            app.was_visible[i] = v;
        }
        if (!app.was_visible[@intFromEnum(app.page)]) app.switch_page(1);

        // One other page per frame is rebuilt to look for new rows.
        var tries: usize = 0;
        while (tries < pages.page_count) : (tries += 1) {
            app.scan_next = @intCast((app.scan_next + 1) % pages.page_count);
            const p: Page = @enumFromInt(app.scan_next);
            if (p != app.page and app.was_visible[app.scan_next]) {
                app.scan(p, true);
                break;
            }
        }
        app.rebuild();
    }

    /// Builds page `p` and marks its new rows (news when `mark`).
    fn scan(app: *App, p: Page, mark: bool) void {
        app.arena.reset();
        pages.build(&app.game, p, &app.rows, &app.arena);
        for (app.rows.slice()) |r| {
            if (r.id >= pages.max_ids) continue;
            if (!app.seen.isSet(r.id)) {
                app.seen.set(r.id);
                if (mark) app.news[@intFromEnum(p)] = true;
            }
        }
        if (p == .projects) app.forget_gone_projects();
    }

    /// A project that left the list counts as new if it comes back
    /// ("Beg for More Wire" does).
    fn forget_gone_projects(app: *App) void {
        var present: std.StaticBitSet(pages.max_ids - pages.project_id_base) = .empty;
        for (app.rows.slice()) |r| {
            if (r.id >= pages.project_id_base and r.id < pages.max_ids) present.set(r.id - pages.project_id_base);
        }
        var i: usize = pages.project_id_base;
        while (i < pages.max_ids) : (i += 1) {
            if (app.seen.isSet(i) and !present.isSet(i - pages.project_id_base)) app.seen.unset(i);
        }
    }

    /// Rebuilds the current page's rows for drawing and input, and keeps
    /// the cursor on the same row (by id) as rows come and go.
    pub fn rebuild(app: *App) void {
        app.arena.reset();
        pages.build(&app.game, app.page, &app.rows, &app.arena);
        const pi = @intFromEnum(app.page);
        app.news[pi] = false;
        const rows = app.rows.slice();
        for (rows) |r| if (r.id < pages.max_ids) app.seen.set(r.id);
        if (app.page == .projects) app.forget_gone_projects();
        if (rows.len == 0) return;
        var ix: usize = @min(app.cursor_ix[pi], rows.len - 1);
        var found = false;
        for (rows, 0..) |r, i| if (r.id == app.cursor_id[pi]) {
            ix = i;
            found = true;
            break;
        };
        if (!found) {
            // The row went away (or first visit): the nearest selectable
            // row at or after the old position, else before it.
            if (!rows[ix].selectable()) {
                var j = ix;
                while (j < rows.len and !rows[j].selectable()) j += 1;
                if (j < rows.len) ix = j else {
                    j = ix;
                    while (j > 0 and !rows[j].selectable()) j -= 1;
                    if (rows[j].selectable()) ix = j;
                }
            }
        }
        app.cursor_ix[pi] = @intCast(ix);
        app.cursor_id[pi] = rows[ix].id;
        app.keep_visible();
    }

    fn set_cursor(app: *App, ix: usize) void {
        const pi = @intFromEnum(app.page);
        const rows = app.rows.slice();
        if (ix != app.cursor_ix[pi]) app.footer_frames = 0;
        app.cursor_ix[pi] = @intCast(ix);
        app.cursor_id[pi] = rows[ix].id;
        app.keep_visible();
    }

    /// The rows area's height in lines, less the footer when the selected
    /// row has a detail to show.
    pub fn list_lines(app: *const App) usize {
        const rows = app.rows.slice();
        const pi = @intFromEnum(app.page);
        if (rows.len > 0 and app.page_has_details()) {
            _ = pi;
            return layout.rows_visible - layout.footer_lines - 1;
        }
        return layout.rows_visible;
    }

    pub fn page_has_details(app: *const App) bool {
        for (app.rows.slice()) |r| if (r.detail.len > 0) return true;
        return false;
    }

    /// Scrolls so the cursor row is on screen; and the cursor stays on the
    /// last row when the list shrinks.
    fn keep_visible(app: *App) void {
        const pi = @intFromEnum(app.page);
        const rows = app.rows.slice();
        if (rows.len == 0) return;
        const area = app.list_lines();
        var top: usize = 0;
        for (rows[0..app.cursor_ix[pi]]) |r| top += r.lines;
        const bottom = top + rows[app.cursor_ix[pi]].lines;
        var total: usize = 0;
        for (rows) |r| total += r.lines;
        var s: usize = app.scroll[pi];
        if (top < s) s = top;
        if (bottom > s + area) s = bottom - area;
        // Show the rows after the last selectable one when the cursor is
        // near the end (readouts below a button).
        if (total > area and s > total - area) s = total - area;
        app.scroll[pi] = @intCast(s);
    }

    pub fn switch_page(app: *App, dir: i32) void {
        var i: i32 = @intFromEnum(app.page);
        var k: usize = 0;
        while (k < pages.page_count) : (k += 1) {
            i = @mod(i + dir, @as(i32, pages.page_count));
            if (app.was_visible[@intCast(i)]) break;
        }
        app.page = @enumFromInt(@as(u8, @intCast(i)));
        app.footer_frames = 0;
        app.rebuild();
    }

    /// Select: the next page (after the current one) with news.
    fn jump_to_news(app: *App) void {
        var i: usize = @intFromEnum(app.page);
        var k: usize = 0;
        while (k < pages.page_count) : (k += 1) {
            i = (i + 1) % pages.page_count;
            if (app.news[i] and app.was_visible[i]) {
                app.page = @enumFromInt(@as(u8, @intCast(i)));
                app.footer_frames = 0;
                app.rebuild();
                return;
            }
        }
    }

    pub fn any_news(app: *const App) bool {
        for (app.news, 0..) |n, i| if (n and app.was_visible[i] and i != @intFromEnum(app.page)) return true;
        return false;
    }

    /// Visible pages, in order, and the current page's position among them.
    pub fn page_position(app: *const App) struct { index: usize, count: usize } {
        var idx: usize = 0;
        var count: usize = 0;
        for (app.was_visible, 0..) |v, i| {
            if (!v) continue;
            if (i == @intFromEnum(app.page)) idx = count;
            count += 1;
        }
        return .{ .index = idx, .count = count };
    }
};

fn step_down(rows: []const pages.Row, ix: usize) usize {
    var j = ix + 1;
    while (j < rows.len) : (j += 1) if (rows[j].selectable()) return j;
    return if (ix + 1 < rows.len) ix + 1 else ix;
}

fn step_up(rows: []const pages.Row, ix: usize) usize {
    var j = ix;
    while (j > 0) {
        j -= 1;
        if (rows[j].selectable()) return j;
    }
    return if (ix > 0) ix - 1 else ix;
}

fn edges(now: Buttons, prev: Buttons) Buttons {
    const n: u8 = @bitCast(now);
    const p: u8 = @bitCast(prev);
    return @bitCast(n & ~p);
}

/// 60 fps in whole milliseconds: 17, 17, 16 (50 ms per three frames).
pub fn frame_ms(phase: u8) u32 {
    return if (phase == 2) 16 else 17;
}

pub fn msg_count(g: *const G.Game) u32 {
    return g.msg_count;
}

pub fn message(g: *const G.Game, k: u32) ?[]const u8 {
    return G.message(g, k);
}
pub const pages_count = @import("pages.zig").page_count;
