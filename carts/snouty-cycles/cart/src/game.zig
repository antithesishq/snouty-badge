//! The game's state machine (SPEC.md section 6, PLAN.md M1 Track P): the
//! title over an attract round, the menu, HOW TO PLAY, and the GRID
//! LADDER: level intro, countdown 3-2-1-RUN, play, then LEVEL CLEAR and
//! the next level, or your derez, a life gone and the level again; with
//! no life left, CORE DUMPED. Start pauses (RESUME / RESTART LEVEL /
//! QUIT). Pure: no cart API, so host tests run it; main.zig feeds it
//! buttons and hands `view()` and `world` to the renderer.
//!
//! M2 replaces the lives with snapshots (rewind) and fills in SKIRMISH
//! and OPTIONS.
const std = @import("std");
const sim = @import("sim.zig");
const ai = @import("ai.zig");
const rng = @import("rng.zig");
const render = @import("render.zig");
const levels = @import("levels.zig");

/// `debug_state` reports these numbers (docs/RUNNING.md section 6).
pub const State = enum(u8) {
    /// The logo over the attract round.
    title,
    menu,
    howto,
    /// Level intro banner over the level's arena.
    intro,
    countdown,
    play,
    /// You derezzed (or the clock ran out): the banner, the World runs on.
    derez,
    /// LEVEL CLEAR and the score tally.
    clear,
    /// CORE DUMPED: score, level reached, session high score.
    game_over,
    paused,
};

/// Buttons, held or newly pressed this tick.
pub const Buttons = packed struct(u8) {
    up: bool = false,
    right: bool = false,
    down: bool = false,
    left: bool = false,
    a: bool = false,
    b: bool = false,
    start: bool = false,
    select: bool = false,

    fn any(b: Buttons) bool {
        return @as(u8, @bitCast(b)) != 0;
    }
};

pub const tuning = struct {
    pub const max_lives: u8 = 3;
    /// Level intro banner; A skips it after `skip_ticks`.
    pub const intro_ticks: u32 = 110;
    pub const skip_ticks: u32 = 20;
    /// 3, 2, 1: this long each (a booth wants quick restarts).
    pub const count_step_ticks: u32 = 45;
    pub const countdown_ticks: u32 = 3 * count_step_ticks;
    /// RUN stays up this long into play.
    pub const run_banner_ticks: u32 = 40;
    /// SUDDEN DEATH stays up this long once the first ring closes.
    pub const sudden_death_banner_ticks: u32 = 100;
    /// Your derez: the crash banner while the World runs on.
    pub const derez_ticks: u32 = 120;
    /// LEVEL CLEAR: the tally; A moves on after `clear_min_ticks`.
    pub const clear_ticks: u32 = 210;
    pub const clear_min_ticks: u32 = 60;
    /// The tally: the bonus line at this tick, the score counts up over
    /// `tally_count_ticks`, then "+1 LIFE".
    pub const tally_bonus_tick: u32 = 30;
    pub const tally_count_ticks: u32 = 36;
    pub const tally_life_tick: u32 = 90;
    /// CORE DUMPED: input waits this long, the title comes back after
    /// `game_over_idle_ticks` (a booth badge left alone goes back to attract).
    pub const game_over_min_ticks: u32 = 60;
    pub const game_over_idle_ticks: u32 = 20 * 60;
    /// Menu and HOW TO PLAY go back to the title after this long idle.
    pub const menu_idle_ticks: u32 = 30 * 60;
    /// Title: the attract round restarts this long after it ends.
    pub const attract_rest_ticks: u32 = 120;
    pub const blink_ticks: u32 = 32;
    /// Score (SPEC 6): a kill credited to you, a program crashing on its
    /// own, a level clear (times the ladder position).
    pub const kill_points: u32 = 500;
    pub const self_crash_points: u32 = 250;
    pub const clear_points: u32 = 1000;
    /// Autopilot 2's chance of a random move per decision (per mille).
    pub const sloppy_permille: u16 = 80;
    /// The `ai.preset` level the autopilot's brain uses (the strongest).
    pub const autopilot_preset: u8 = 12;
};

pub const colors = struct {
    pub const title_a = render.rgb(0x18E0FF);
    pub const title_b = render.rgb(0xFF7A10);
    pub const text = render.rgb(0xE0ECFF);
    pub const dim = render.rgb(0x5A6E90);
    pub const grey = render.rgb(0x3A4660);
    pub const win = render.rgb(0x60FFB0);
    pub const lose = render.rgb(0xFF4040);
    pub const warn = render.rgb(0xFFD040);
    pub const select = render.rgb(0xFFE870);
};

/// TODO(lead): Track A's `ai.preset(tier, level)` (a Brain's knobs per
/// ladder level). Until it is merged a plain `Brain.init(tier, seed)`
/// stands in. After the A merge this picks `preset` up on its own if it
/// returns an `ai.Brain`; any other shape stops the build here.
const compat = struct {
    fn brain(tier: ai.Tier, level: u8, seed: u32) ai.Brain {
        if (comptime @hasDecl(ai, "preset")) {
            if (comptime @typeInfo(@TypeOf(ai.preset)).@"fn".return_type.? != ai.Brain)
                @compileError("ai.preset returns something other than ai.Brain: adapt game.compat.brain");
            var b = ai.preset(tier, level);
            b.rng = .init(seed);
            return b;
        }
        return .init(tier, seed);
    }
};

/// The title menu (SKIRMISH and OPTIONS are M2: shown greyed, skipped).
pub const MenuItem = enum(u8) { ladder, skirmish, options, howto };
const menu_text = [4][]const u8{ "GRID LADDER  ", "SKIRMISH SOON", "OPTIONS  SOON", "HOW TO PLAY  " };
const menu_enabled = [4]bool{ true, false, false, true };

pub const PauseItem = enum(u8) { resume_play, restart, quit };
const pause_text = [3][]const u8{ "RESUME       ", "RESTART LEVEL", "QUIT         " };

pub const Game = struct {
    state: State,
    /// Ticks in the current state.
    timer: u32,
    /// Ticks since init.
    ticks: u32,
    /// Ladder position (1-based; 13 is BASIC on the second loop), 0 off
    /// the ladder.
    level: u32,
    lives: u8,
    score: u32,
    /// The score when this attempt at the level began (RESTART LEVEL).
    score_level_start: u32,
    /// Session high score (RAM only, SPEC 6) and whether this game set it.
    high: u32,
    new_high: bool,
    /// Worlds started this game (attempts), levels cleared, lives lost.
    rounds: u32,
    clears: u32,
    deaths: u32,
    menu_sel: MenuItem,
    pause_sel: PauseItem,
    /// Your crash (the derez banner); .none with `timed_out`.
    crash: sim.Crash,
    timed_out: bool,
    /// The level clear: score before the bonus, and a life won back.
    tally_from: u32,
    life_back: bool,
    /// World tick when the first sudden-death ring closed (0: not yet).
    sudden_death_tick: u32,
    /// Attract rounds played (picks the attract arena), and the World tick
    /// the current one ended on.
    attract_rounds: u32,
    attract_end: u32,
    /// 0: the player drives. 1: T1 drives the player (debug_autopilot,
    /// badge-bench). 2: T1 with `tuning.sloppy_permille` random moves.
    /// 3: T3 SEARCH (the ladder bot; plays T1 until Track A lands).
    autopilot: u8,
    seeds: rng.Xorshift,
    brains: [sim.max_cycles]ai.Brain,
    /// Set when the screen must be repainted whole (new World, new scene);
    /// main.zig clears it after telling the renderer.
    repaint: bool,
    world: sim.World,

    /// In place: the Game holds a 38 KB World.
    pub fn init(g: *Game, seed: u32) void {
        g.seeds = .init(seed);
        g.autopilot = 0;
        g.high = 0;
        g.score = 0;
        g.attract_rounds = 0;
        g.to_title();
    }

    fn to_title(g: *Game) void {
        g.state = .title;
        g.timer = 0;
        g.ticks = 0;
        g.level = 0;
        g.lives = 0;
        g.rounds = 0;
        g.clears = 0;
        g.deaths = 0;
        g.menu_sel = .ladder;
        g.crash = .none;
        g.timed_out = false;
        g.start_attract();
    }

    fn start_attract(g: *Game) void {
        const s = g.seeds.next();
        g.world.init(.{
            .n_cycles = 4,
            .grinding = true,
            .energy = true,
            .rubber = sim.tuning.rubber_max,
            .sudden_death = true,
            .layout = @intCast(g.attract_rounds % (levels.layouts_used + 1)),
        }, s);
        g.attract_rounds += 1;
        // T2 programs once Track A lands (until then they play T1).
        for (&g.brains, 0..) |*b, i| b.* = compat.brain(.territory, 6, rng.mix(s, @intCast(i)));
        g.sudden_death_tick = 0;
        g.repaint = true;
    }

    /// A new ladder game from position n (debug_set_level jumps here).
    pub fn new_game(g: *Game, n: u32) void {
        g.level = @max(n, 1);
        g.lives = tuning.max_lives;
        g.score = 0;
        g.new_high = false;
        g.rounds = 0;
        g.clears = 0;
        g.deaths = 0;
        g.start_level(true);
    }

    fn autopilot_tier(g: *const Game) ai.Tier {
        return if (g.autopilot == 3) .search else .avoid;
    }

    /// A fresh World for the current level: the intro first, or straight
    /// to the countdown (a retry).
    fn start_level(g: *Game, intro: bool) void {
        const r = levels.get(g.level);
        const s = g.seeds.next();
        g.world.init(r.config(), s);
        g.brains[0] = compat.brain(g.autopilot_tier(), tuning.autopilot_preset, rng.mix(s, 0));
        for (r.programs(), 1..) |p, i| g.brains[i] = compat.brain(p.tier, p.preset, rng.mix(s, @intCast(i)));
        g.state = if (intro) .intro else .countdown;
        g.timer = 0;
        g.crash = .none;
        g.timed_out = false;
        g.sudden_death_tick = 0;
        g.score_level_start = g.score;
        g.rounds += 1;
        g.repaint = true;
    }

    pub fn round(g: *const Game) levels.Round {
        return levels.get(g.level);
    }

    pub fn update(g: *Game, held: Buttons, pressed_raw: Buttons) void {
        // Newer firmware opens its settings box on Start+Select over the
        // running cart: react to neither while both are held.
        var pressed = pressed_raw;
        if (held.start and held.select) {
            pressed.start = false;
            pressed.select = false;
        }
        g.ticks +%= 1;
        g.timer += 1;
        switch (g.state) {
            .title => {
                if (pressed.any()) return g.goto(.menu);
                g.run_attract();
            },
            .menu => {
                g.run_attract();
                g.update_menu(pressed);
            },
            .howto => {
                g.run_attract();
                if (pressed.any()) return g.goto(.menu);
                if (g.timer >= tuning.menu_idle_ticks) g.to_title();
            },
            .intro => {
                if (dpad(pressed)) |d| g.world.set_heading(0, d);
                if (g.timer >= tuning.intro_ticks or (pressed.a and g.timer >= tuning.skip_ticks)) g.goto(.countdown);
            },
            .countdown => {
                if (dpad(pressed)) |d| g.world.set_heading(0, d);
                if (g.timer >= tuning.countdown_ticks) g.goto(.play);
            },
            .play => {
                if (pressed.start) {
                    g.pause_sel = .resume_play;
                    return g.goto(.paused);
                }
                g.step_world(held, pressed, true);
                g.after_step();
            },
            .derez => {
                g.step_world(.{}, .{}, false);
                if (g.timer >= tuning.derez_ticks) g.after_derez();
            },
            .clear => {
                g.world.step(@splat(.idle));
                if (g.timer >= tuning.clear_ticks or (pressed.a and g.timer >= tuning.clear_min_ticks)) {
                    g.level += 1;
                    g.start_level(true);
                }
            },
            .game_over => {
                g.world.step(@splat(.idle));
                if (g.timer >= tuning.game_over_min_ticks) {
                    if (pressed.a) return g.new_game(1);
                    if (pressed.b or pressed.start or pressed.select) return g.to_title();
                }
                if (g.timer >= tuning.game_over_idle_ticks) g.to_title();
            },
            .paused => g.update_pause(pressed),
        }
    }

    fn goto(g: *Game, s: State) void {
        g.state = s;
        g.timer = 0;
    }

    fn update_menu(g: *Game, p: Buttons) void {
        if (p.up or p.down) {
            // Step over the greyed items.
            var i: u8 = @backingInt(g.menu_sel);
            while (true) {
                i = if (p.down) (i + 1) % 4 else (i + 3) % 4;
                if (menu_enabled[i]) break;
            }
            g.menu_sel = @fromBackingInt(i);
            g.timer = 0;
        }
        if (p.a or p.start) {
            switch (g.menu_sel) {
                .ladder => g.new_game(1),
                .howto => g.goto(.howto),
                .skirmish, .options => {},
            }
            return;
        }
        if (p.b or p.select) return g.goto(.title);
        if (g.timer >= tuning.menu_idle_ticks) g.to_title();
    }

    fn update_pause(g: *Game, p: Buttons) void {
        if (p.up or p.down) {
            const i: u8 = @backingInt(g.pause_sel);
            g.pause_sel = @fromBackingInt(if (p.down) (i + 1) % 3 else (i + 2) % 3);
        }
        if (p.start or p.b) return g.resume_play();
        if (p.a) switch (g.pause_sel) {
            .resume_play => g.resume_play(),
            .restart => {
                g.score = g.score_level_start;
                g.start_level(false);
            },
            .quit => {
                g.high = @max(g.high, g.score);
                g.to_title();
            },
        };
    }

    fn resume_play(g: *Game) void {
        g.state = .play;
        // No RUN banner again.
        g.timer = tuning.run_banner_ticks;
    }

    /// The attract round: four programs, restarted after each ends.
    fn run_attract(g: *Game) void {
        const w = &g.world;
        if (w.result == .running) {
            var in: [sim.max_cycles]sim.Input = @splat(.idle);
            for (0..w.cfg.n_cycles) |i| in[i] = ai.decide(&g.brains[i], w, i);
            w.step(in);
            if (w.result != .running) g.attract_end = w.tick;
        } else {
            w.step(@splat(.idle));
            if (w.tick - g.attract_end >= tuning.attract_rest_ticks) g.start_attract();
        }
    }

    /// One World tick of the ladder: the player (you or the autopilot)
    /// and the programs. `player` false once you have derezzed.
    fn step_world(g: *Game, held: Buttons, pressed: Buttons, player: bool) void {
        const w = &g.world;
        var in: [sim.max_cycles]sim.Input = @splat(.idle);
        if (player and w.cycles[0].state == .alive) {
            if (g.autopilot != 0) {
                const b = &g.brains[0];
                if (b.tier != g.autopilot_tier()) b.* = compat.brain(g.autopilot_tier(), tuning.autopilot_preset, b.rng.state);
                if (g.autopilot == 2) b.mistake_permille = tuning.sloppy_permille;
                in[0] = ai.decide(b, w, 0);
            } else {
                if (dpad(pressed)) |d| in[0].press = .of(d);
                in[0].boost = held.a;
                in[0].brake = held.b;
            }
        }
        for (1..w.cfg.n_cycles) |i| in[i] = ai.decide(&g.brains[i], w, i);
        w.step(in);
        if (g.sudden_death_tick == 0 and w.sudden_death_ring != 0) g.sudden_death_tick = w.tick;
    }

    /// After a play tick: points, and the end of the level either way.
    fn after_step(g: *Game) void {
        const w = &g.world;
        g.score_events();
        if (w.cycles[0].state != .alive) {
            g.crash = w.cycles[0].crash;
            g.timed_out = false;
            g.lives -|= 1;
            g.deaths += 1;
            return g.goto(.derez);
        }
        if (w.result == .won and w.winner == 0) return g.level_clear();
        if (w.result == .draw) {
            // The clock ran out with you riding (no sudden death): the
            // level again, no life lost.
            g.crash = .none;
            g.timed_out = true;
            return g.goto(.derez);
        }
    }

    fn after_derez(g: *Game) void {
        if (g.lives == 0) {
            g.new_high = g.score > g.high;
            g.high = @max(g.high, g.score);
            return g.goto(.game_over);
        }
        g.start_level(false);
    }

    fn level_clear(g: *Game) void {
        g.tally_from = g.score;
        g.score += tuning.clear_points * g.level;
        g.clears += 1;
        g.life_back = g.lives < tuning.max_lives;
        if (g.life_back) g.lives += 1;
        g.goto(.clear);
    }

    /// Points for crashes as they happen (SPEC 6).
    fn score_events(g: *Game) void {
        for (g.world.events[0..g.world.n_events]) |e| {
            if (e.kind != .crash or e.cycle == 0) continue;
            const kind: sim.Crash = @fromBackingInt(@intCast(e.a));
            if (e.b == 0) {
                g.score += tuning.kill_points;
            } else if (kind != .race_condition and kind != .deadlock) {
                g.score += tuning.self_crash_points;
            }
        }
    }

    // ------------------------------------------------------------ view

    /// What to draw besides the World.
    pub fn view(g: *const Game) render.View {
        var v: render.View = .{};
        const blink_on = (g.ticks / tuning.blink_ticks) % 2 == 0;
        switch (g.state) {
            .title => {
                g.title_hud(&v);
                var b: render.Banner = .{ .iris = true, .cy = 67 };
                b.add("SNOUTY", 2, colors.title_a);
                b.add("CYCLES", 2, colors.title_b);
                b.add("LIGHT CYCLES", 1, colors.text);
                b.add("CPU CYCLES", 1, colors.dim);
                b.add("PRESS A", 1, if (blink_on) colors.select else colors.grey);
                v.banner = b;
            },
            .menu => {
                g.title_hud(&v);
                var b: render.Banner = .{};
                b.add("SNOUTY CYCLES", 1, colors.title_a);
                b.add("", 1, colors.text);
                for (menu_text, 0..) |t, i| {
                    const sel = i == @backingInt(g.menu_sel);
                    var buf: [20]u8 = undefined;
                    const s = cursor_line(&buf, sel, t);
                    b.add(s, 1, if (!menu_enabled[i]) colors.grey else if (sel) colors.select else colors.text);
                }
                v.banner = b;
            },
            .howto => {
                g.title_hud(&v);
                var b: render.Banner = .{};
                b.add("HOW TO PLAY", 1, colors.title_a);
                b.add("D-PAD   STEER", 1, colors.text);
                b.add("A HOLD  BOOST", 1, colors.text);
                b.add("B HOLD  BRAKE", 1, colors.text);
                b.add("RIDE CLOSE TO A", 1, colors.dim);
                b.add("WALL: GRIND SPEED", 1, colors.dim);
                b.add("BE THE LAST RIDING", 1, colors.win);
                b.add("START   PAUSE", 1, colors.text);
                v.banner = b;
            },
            .intro => {
                g.hud(&v);
                v.banner = g.intro_banner();
            },
            .countdown => {
                g.hud(&v);
                var b: render.Banner = .{};
                const n = 3 - @min(2, g.timer / tuning.count_step_ticks);
                const digit = [1]u8{'0' + @as(u8, @intCast(n))};
                // Narrow, so the start cells beside it stay in view.
                b.add(&digit, 3, colors.warn);
                b.add(g.round().name(), 1, colors.text);
                v.banner = b;
            },
            .play => {
                g.hud(&v);
                v.tags = 0b1110;
                if (g.timer < tuning.run_banner_ticks) {
                    var b: render.Banner = .{};
                    b.add("RUN", 2, colors.win);
                    v.banner = b;
                } else if (g.sudden_death_tick != 0 and g.world.tick - g.sudden_death_tick < tuning.sudden_death_banner_ticks) {
                    var b: render.Banner = .{ .cy = 40 };
                    const on = (g.world.tick / 8) % 2 == 0;
                    b.add("SUDDEN", 2, if (on) colors.lose else colors.warn);
                    b.add("DEATH", 2, if (on) colors.lose else colors.warn);
                    v.banner = b;
                }
            },
            .derez => {
                g.hud(&v);
                v.tags = 0b1110;
                v.banner = g.derez_banner();
            },
            .clear => {
                g.hud(&v);
                v.tags = 0b1110;
                v.banner = g.clear_banner();
                // The HUD score counts up with the tally.
                var buf: [20]u8 = undefined;
                const n = decimal(&buf, g.tally_score(), 6);
                v.hud.right = .of(buf[0..n], 1, colors.text);
            },
            .game_over => {
                g.hud(&v);
                v.banner = g.game_over_banner(blink_on);
            },
            .paused => {
                g.hud(&v);
                var b: render.Banner = .{};
                b.add("PAUSED", 2, colors.text);
                b.add("", 1, colors.text);
                for (pause_text, 0..) |t, i| {
                    const sel = i == @backingInt(g.pause_sel);
                    var buf: [20]u8 = undefined;
                    b.add(cursor_line(&buf, sel, t), 1, if (sel) colors.select else colors.text);
                }
                v.banner = b;
            },
        }
        return v;
    }

    fn title_hud(g: *const Game, v: *render.View) void {
        v.hud.left = .of("SNOUTY CYCLES", 1, colors.dim);
        var buf: [20]u8 = undefined;
        var n = copy(&buf, "HI ");
        n += decimal(buf[n..], g.high, 6);
        v.hud.right = .of(buf[0..n], 1, colors.dim);
    }

    /// The ladder HUD: level, life pips, energy bar, score.
    fn hud(g: *const Game, v: *render.View) void {
        var buf: [20]u8 = undefined;
        const r = g.round();
        var n = decimal(&buf, r.number(), 2);
        n += copy(buf[n..], " ");
        n += copy(buf[n..], r.name());
        v.hud.left = .of(buf[0..n], 1, colors.text);
        n = decimal(&buf, g.score, 6);
        v.hud.right = .of(buf[0..n], 1, colors.text);
        v.hud.lives = g.lives;
        v.hud.max_lives = tuning.max_lives;
        const me = &g.world.cycles[0];
        v.hud.energy = if (me.state == .alive) me.energy else 0;
        v.hud.bar_mode = if (me.state != .alive) 0 else if (me.boost) 1 else if (me.brake) 2 else 0;
    }

    fn intro_banner(g: *const Game) render.Banner {
        const r = g.round();
        var b: render.Banner = .{};
        var buf: [20]u8 = undefined;
        var n: usize = 0;
        if (r.loop != 0) {
            n += copy(buf[n..], "LOOP ");
            n += decimal(buf[n..], r.loop + 1, 1);
            n += copy(buf[n..], " ");
        }
        n += copy(buf[n..], "LEVEL ");
        n += decimal(buf[n..], r.number(), 1);
        b.add(buf[0..n], 1, colors.dim);
        const name = r.name();
        b.add(name, if (name.len <= 6) 3 else 2, colors.title_a);
        const progs = r.programs().len;
        n = decimal(&buf, @intCast(progs), 1);
        n += copy(buf[n..], if (progs == 1) " PROGRAM" else " PROGRAMS");
        b.add(buf[0..n], 1, colors.title_b);
        if (r.speed_pct != 100) {
            n = copy(&buf, "SPEED ");
            n += decimal(buf[n..], r.speed_pct, 1);
            n += copy(buf[n..], "%");
            b.add(buf[0..n], 1, colors.warn);
        }
        return b;
    }

    fn derez_banner(g: *const Game) render.Banner {
        // Away from the crash, so the burst stays in view.
        const me = &g.world.cycles[0];
        var b: render.Banner = .{ .cy = if (me.y < sim.grid_h / 2) 92 else 44 };
        if (g.timed_out) {
            b.add("TIME UP", 2, colors.warn);
            b.add("AGAIN", 1, colors.text);
            return b;
        }
        const name = g.crash.name();
        if (name.len <= 9) {
            b.add(name, 2, colors.lose);
        } else {
            // Two big lines: "ACCESS" / "VIOLATION".
            const sp = std.mem.indexOfScalar(u8, name, ' ') orelse name.len;
            b.add(name[0..sp], 2, colors.lose);
            if (sp < name.len) b.add(name[sp + 1 ..], 2, colors.lose);
        }
        var buf: [20]u8 = undefined;
        switch (g.lives) {
            0 => b.add("NO LIVES LEFT", 1, colors.warn),
            1 => b.add("LAST LIFE", 1, colors.warn),
            else => {
                var n = decimal(&buf, g.lives, 1);
                n += copy(buf[n..], " LIVES LEFT");
                b.add(buf[0..n], 1, colors.text);
            },
        }
        return b;
    }

    /// The score shown during the tally: counting up after the bonus line.
    fn tally_score(g: *const Game) u32 {
        if (g.state != .clear) return g.score;
        if (g.timer < tuning.tally_bonus_tick) return g.tally_from;
        const t = g.timer - tuning.tally_bonus_tick;
        if (t >= tuning.tally_count_ticks) return g.score;
        return g.tally_from + (g.score - g.tally_from) * t / tuning.tally_count_ticks;
    }

    fn clear_banner(g: *const Game) render.Banner {
        const r = g.round();
        var b: render.Banner = .{};
        b.add(r.name(), 1, colors.text);
        b.add("CLEAR", 3, colors.win);
        var buf: [20]u8 = undefined;
        if (g.timer >= tuning.tally_bonus_tick) {
            var n = copy(&buf, "BONUS +");
            n += decimal(buf[n..], g.score - g.tally_from, 1);
            b.add(buf[0..n], 1, colors.warn);
            n = copy(&buf, "SCORE ");
            n += decimal(buf[n..], g.tally_score(), 6);
            b.add(buf[0..n], 1, colors.text);
        }
        if (g.life_back and g.timer >= tuning.tally_life_tick) {
            const on = (g.timer / 8) % 2 == 0;
            b.add("+1 LIFE", 1, if (on) colors.title_a else colors.text);
        }
        return b;
    }

    fn game_over_banner(g: *const Game, blink_on: bool) render.Banner {
        var b: render.Banner = .{};
        b.add("CORE", 2, colors.lose);
        b.add("DUMPED", 2, colors.lose);
        var buf: [20]u8 = undefined;
        var n = copy(&buf, "SCORE ");
        n += decimal(buf[n..], g.score, 6);
        b.add(buf[0..n], 1, colors.text);
        const r = g.round();
        n = copy(&buf, "LEVEL ");
        n += decimal(buf[n..], r.number(), 1);
        n += copy(buf[n..], " ");
        n += copy(buf[n..], r.name());
        b.add(buf[0..n], 1, colors.dim);
        if (g.new_high) {
            b.add("NEW HIGH SCORE", 1, if (blink_on) colors.warn else colors.select);
        } else {
            n = copy(&buf, "HIGH ");
            n += decimal(buf[n..], g.high, 6);
            b.add(buf[0..n], 1, colors.dim);
        }
        if (g.timer >= tuning.game_over_min_ticks) b.add("A RETRY  B MENU", 1, colors.title_a);
        return b;
    }
};

/// "> " before the selected item, two spaces before the others, so the
/// items line up under one centre.
fn cursor_line(buf: *[20]u8, sel: bool, t: []const u8) []const u8 {
    var n = copy(buf, if (sel) "> " else "  ");
    n += copy(buf[n..], t);
    return buf[0..n];
}

/// The heading pressed this tick, if any (one per tick; the turn queue
/// keeps a fast double tap across two ticks).
fn dpad(p: Buttons) ?sim.Dir {
    if (p.up) return .up;
    if (p.right) return .right;
    if (p.down) return .down;
    if (p.left) return .left;
    return null;
}

fn copy(dst: []u8, s: []const u8) usize {
    const n = @min(dst.len, s.len);
    @memcpy(dst[0..n], s[0..n]);
    return n;
}

/// `v` in decimal, zero-padded to `width` digits, into dst.
pub fn decimal(dst: []u8, v: u32, width: usize) usize {
    var tmp: [10]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (true) {
        tmp[n] = '0' + @as(u8, @intCast(x % 10));
        n += 1;
        x /= 10;
        if (x == 0) break;
    }
    while (n < width and n < tmp.len) : (n += 1) tmp[n] = '0';
    const m = @min(n, dst.len);
    for (0..m) |i| dst[i] = tmp[n - 1 - i];
    return m;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
var tg: Game = undefined;

const press_a: Buttons = .{ .a = true };

fn tap(g: *Game, b: Buttons) void {
    g.update(b, b);
}

fn idle(g: *Game, n: u32) void {
    for (0..n) |_| g.update(.{}, .{});
}

/// Runs until `state` (or the tick cap); returns whether it got there.
fn run_until(g: *Game, state: State, cap: u32) bool {
    var t: u32 = 0;
    while (g.state != state and t < cap) : (t += 1) g.update(.{}, .{});
    return g.state == state;
}

test "decimal formatting" {
    var b: [12]u8 = undefined;
    try testing.expectEqualStrings("000500", b[0..decimal(&b, 500, 6)]);
    try testing.expectEqualStrings("7", b[0..decimal(&b, 7, 1)]);
    try testing.expectEqualStrings("1234567", b[0..decimal(&b, 1234567, 6)]);
}

test "title, menu, GRID LADDER: intro, countdown, play" {
    const g = &tg;
    g.init(1);
    idle(g, 30);
    try testing.expectEqual(State.title, g.state);
    tap(g, press_a);
    try testing.expectEqual(State.menu, g.state);
    try testing.expectEqual(MenuItem.ladder, g.menu_sel);
    tap(g, press_a);
    try testing.expectEqual(State.intro, g.state);
    try testing.expectEqual(@as(u32, 1), g.level);
    try testing.expectEqual(tuning.max_lives, g.lives);
    try testing.expectEqual(@as(u8, 2), g.world.cfg.n_cycles);
    // A skips the intro once it has been up a moment.
    idle(g, tuning.skip_ticks);
    tap(g, press_a);
    try testing.expectEqual(State.countdown, g.state);
    idle(g, tuning.countdown_ticks);
    try testing.expectEqual(State.play, g.state);
}

test "the menu steps over the greyed items; B goes back; HOW TO PLAY and back" {
    const g = &tg;
    g.init(2);
    tap(g, press_a);
    tap(g, .{ .down = true });
    try testing.expectEqual(MenuItem.howto, g.menu_sel);
    tap(g, .{ .down = true });
    try testing.expectEqual(MenuItem.ladder, g.menu_sel);
    tap(g, .{ .up = true });
    try testing.expectEqual(MenuItem.howto, g.menu_sel);
    tap(g, press_a);
    try testing.expectEqual(State.howto, g.state);
    tap(g, .{ .b = true });
    try testing.expectEqual(State.menu, g.state);
    tap(g, .{ .b = true });
    try testing.expectEqual(State.title, g.state);
}

test "a derez costs a life and retries the level; none left is CORE DUMPED" {
    const g = &tg;
    g.init(3);
    g.new_game(1);
    var deaths: u32 = 0;
    var t: u32 = 0;
    // No input: you ride straight into something every time.
    while (g.state != .game_over and t < 60 * 60 * 5) : (t += 1) {
        const before = g.lives;
        g.update(.{}, .{});
        if (g.lives < before) {
            deaths += 1;
            try testing.expectEqual(State.derez, g.state);
            try testing.expect(g.crash != .none);
        }
        if (g.state == .clear) {
            // The program crashed first; carry on to the next level.
            continue;
        }
    }
    try testing.expectEqual(State.game_over, g.state);
    try testing.expect(deaths >= tuning.max_lives);
    try testing.expectEqual(@as(u8, 0), g.lives);
    try testing.expectEqual(g.score, g.high);
    // Input waits a moment, then A retries from level 1.
    tap(g, press_a);
    try testing.expectEqual(State.game_over, g.state);
    idle(g, tuning.game_over_min_ticks);
    tap(g, press_a);
    try testing.expectEqual(State.intro, g.state);
    try testing.expectEqual(@as(u32, 1), g.level);
    try testing.expectEqual(tuning.max_lives, g.lives);
}

test "autopilot clears BASIC: tally, a life back, the next level" {
    const g = &tg;
    // Until Track A lands BASIC's program plays T1 like the autopilot, so
    // some seeds lose: look for a clear over a few.
    var cleared = false;
    var seed: u32 = 1;
    while (!cleared and seed <= 12) : (seed += 1) {
        g.init(seed);
        g.autopilot = 1;
        g.new_game(1);
        g.lives = 2;
        var t: u32 = 0;
        while (g.level == 1 and g.state != .game_over and t < 60 * 60 * 10) : (t += 1) {
            g.update(.{}, .{});
            if (g.state == .clear and g.timer == 1) {
                try testing.expect(g.life_back);
                try testing.expect(g.lives >= 2 and g.lives <= tuning.max_lives);
                try testing.expect(g.score >= g.tally_from + tuning.clear_points);
                // The tally counts up from the old score.
                try testing.expectEqual(g.tally_from, g.tally_score());
            }
        }
        if (g.level == 2) {
            cleared = true;
            try testing.expectEqual(State.intro, g.state);
            try testing.expectEqual(@as(u32, 1), g.clears);
        }
    }
    try testing.expect(cleared);
}

test "pause: RESUME, RESTART LEVEL restores the level's score, QUIT; Start+Select ignored" {
    const g = &tg;
    g.init(5);
    g.new_game(3);
    try testing.expect(run_until(g, .play, 1000));
    g.update(.{ .start = true, .select = true }, .{ .start = true });
    try testing.expectEqual(State.play, g.state);
    tap(g, .{ .start = true });
    try testing.expectEqual(State.paused, g.state);
    const tick = g.world.tick;
    idle(g, 10);
    try testing.expectEqual(tick, g.world.tick);
    tap(g, .{ .start = true });
    try testing.expectEqual(State.play, g.state);
    // RESTART LEVEL: the score goes back to the level's start.
    g.score += 777;
    tap(g, .{ .start = true });
    tap(g, .{ .down = true });
    try testing.expectEqual(PauseItem.restart, g.pause_sel);
    tap(g, press_a);
    try testing.expectEqual(State.countdown, g.state);
    try testing.expectEqual(@as(u32, 0), g.score);
    try testing.expectEqual(@as(u32, 3), g.level);
    // QUIT.
    try testing.expect(run_until(g, .play, 1000));
    tap(g, .{ .start = true });
    tap(g, .{ .up = true });
    try testing.expectEqual(PauseItem.quit, g.pause_sel);
    tap(g, press_a);
    try testing.expectEqual(State.title, g.state);
}

test "countdown presses set the first heading" {
    const g = &tg;
    g.init(6);
    g.new_game(1);
    g.update(.{ .up = true }, .{ .up = true });
    try testing.expectEqual(sim.Dir.up, g.world.cycles[0].dir);
}

/// Every banner and HUD the game makes, for the margin test below.
fn check_view(g: *const Game) !void {
    const v = g.view();
    if (v.banner) |b| {
        if (!b.fits()) {
            for (b.lines[0..b.n]) |l| std.debug.print("banner line '{s}' x{d}\n", .{ l.str(), l.scale });
            return error.BannerTooWide;
        }
        const r = b.rect();
        try testing.expect(r.x0 >= render.margin and r.x1 <= render.screen_w - render.margin);
        try testing.expect(r.y0 >= render.arena_y and r.y1 <= render.screen_h - render.margin);
    }
    for ([_]render.Line{ v.hud.left, v.hud.right }) |l| try testing.expect(l.len * render.font5.advance <= 72);
}

test "every banner fits inside the 2 px screen margin" {
    const g = &tg;
    g.init(7);
    try check_view(g);
    tap(g, press_a);
    try check_view(g);
    tap(g, .{ .down = true });
    tap(g, press_a);
    try check_view(g);
    // Every level's intro, countdown, play, clear, derez, game over, pause.
    var n: u32 = 1;
    while (n <= 14) : (n += 1) {
        g.new_game(n);
        try check_view(g);
        g.state = .countdown;
        try check_view(g);
        g.state = .clear;
        g.tally_from = 0;
        g.score = 999_999;
        g.life_back = true;
        g.timer = tuning.tally_life_tick;
        try check_view(g);
        g.state = .game_over;
        g.new_high = n % 2 == 0;
        g.timer = tuning.game_over_min_ticks;
        try check_view(g);
        g.state = .paused;
        try check_view(g);
    }
    g.state = .derez;
    for (std.enums.values(sim.Crash)) |c| {
        g.crash = c;
        for (0..4) |lives| {
            g.lives = @intCast(lives);
            try check_view(g);
        }
    }
    g.timed_out = true;
    try check_view(g);
    g.state = .play;
    g.timer = tuning.run_banner_ticks;
    g.sudden_death_tick = g.world.tick;
    try check_view(g);
}
