//! The game's state machine (SPEC.md section 6; M0's minimal loop): the
//! title over an attract round, then you against one T1 program, rounds
//! looping: countdown 3-2-1-RUN, play, the round-over banner, the next
//! round. Start pauses. Pure: no cart API, so host tests run it; main.zig
//! feeds it buttons and hands `view()` and `world` to the renderer.
//!
//! M1 replaces the fixed opponent with the ladder (levels.zig), adds the
//! menus, scoring details, effects and sudden death; M2 the snapshots.
const std = @import("std");
const sim = @import("sim.zig");
const ai = @import("ai.zig");
const rng = @import("rng.zig");
const render = @import("render.zig");

pub const State = enum(u8) {
    title,
    countdown,
    play,
    round_over,
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
};

pub const tuning = struct {
    /// 3, 2, 1: one second each.
    pub const countdown_ticks: u32 = 180;
    /// RUN stays up this long into play.
    pub const run_banner_ticks: u32 = 40;
    /// The round-over banner, while the loser's wall fades.
    pub const round_over_ticks: u32 = 150;
    /// Title: the attract round restarts this long after it ends.
    pub const attract_rest_ticks: u32 = 120;
    pub const blink_ticks: u32 = 32;
    /// Score (SPEC 6): a kill credited to you, a program crashing on its
    /// own, a round won (times the level number).
    pub const kill_points: u32 = 500;
    pub const self_crash_points: u32 = 250;
    pub const clear_points: u32 = 1000;
    /// Autopilot 2's chance of a random move per decision (per mille).
    pub const sloppy_permille: u16 = 80;
};

/// M0's one opponent: ladder level 3 (SPEC 6: 1x T1). M1 swaps in levels.zig.
pub const level_name = "PASCAL";
pub const level_number: u32 = 3;
const opponents: u8 = 1;

pub const Outcome = enum(u8) { none, win, lose, draw };

pub const colors = struct {
    pub const title_a = render.rgb(0x18E0FF);
    pub const title_b = render.rgb(0xFF7A10);
    pub const text = render.rgb(0xE0ECFF);
    pub const dim = render.rgb(0x5A6E90);
    pub const win = render.rgb(0x60FFB0);
    pub const lose = render.rgb(0xFF4040);
    pub const warn = render.rgb(0xFFD040);
};

pub const Game = struct {
    state: State,
    /// Ticks in the current state.
    timer: u32,
    /// Ticks since init.
    ticks: u32,
    /// Round number in this match (1-based; 0 on the title).
    round: u32,
    wins: u32,
    losses: u32,
    score: u32,
    outcome: Outcome,
    /// The crash the round-over banner names.
    crash: sim.Crash,
    /// 0: the player drives. 1: T1 drives the player (debug_autopilot,
    /// badge-bench). 2: T1 with `tuning.sloppy_permille` random moves, so
    /// rounds end sooner (the bench and GIF runs).
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
        g.score = 0;
        g.to_title();
    }

    fn to_title(g: *Game) void {
        g.state = .title;
        g.timer = 0;
        g.ticks = 0;
        g.round = 0;
        g.wins = 0;
        g.losses = 0;
        g.outcome = .none;
        g.crash = .none;
        g.start_world(4);
    }

    fn start_world(g: *Game, n: u8) void {
        const s = g.seeds.next();
        g.world.init(.{ .n_cycles = n }, s);
        for (&g.brains, 0..) |*b, i| b.* = .init(.avoid, rng.mix(s, @intCast(i)));
        g.repaint = true;
    }

    fn start_round(g: *Game) void {
        g.round += 1;
        g.state = .countdown;
        g.timer = 0;
        g.outcome = .none;
        g.crash = .none;
        g.start_world(1 + opponents);
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
            .title => g.update_title(pressed),
            .countdown => {
                if (dpad(pressed)) |d| g.world.set_heading(0, d);
                if (g.timer >= tuning.countdown_ticks) {
                    g.state = .play;
                    g.timer = 0;
                }
            },
            .play => {
                if (pressed.start) {
                    g.state = .paused;
                    g.timer = 0;
                    return;
                }
                var in: [sim.max_cycles]sim.Input = @splat(.idle);
                if (g.autopilot != 0) {
                    g.brains[0].mistake_permille = if (g.autopilot == 2) tuning.sloppy_permille else 0;
                    in[0] = ai.decide(&g.brains[0], &g.world, 0);
                } else {
                    if (dpad(pressed)) |d| in[0].press = .of(d);
                    in[0].boost = held.a;
                    in[0].brake = held.b;
                }
                for (1..g.world.cfg.n_cycles) |i| in[i] = ai.decide(&g.brains[i], &g.world, i);
                g.world.step(in);
                g.score_events();
                if (g.world.result != .running) g.end_round();
            },
            .round_over => {
                g.world.step(@splat(.idle));
                if (g.timer >= tuning.round_over_ticks) g.start_round();
            },
            .paused => {
                if (pressed.start) {
                    g.state = .play;
                    g.timer = tuning.run_banner_ticks;
                } else if (pressed.b) {
                    g.to_title();
                }
            },
        }
    }

    fn update_title(g: *Game, pressed: Buttons) void {
        if (pressed.a or pressed.b or pressed.start or pressed.select) {
            g.score = 0;
            g.wins = 0;
            g.losses = 0;
            g.round = 0;
            g.start_round();
            return;
        }
        // The attract round: four programs, restarted after each ends.
        const w = &g.world;
        if (w.result == .running) {
            var in: [sim.max_cycles]sim.Input = @splat(.idle);
            for (0..w.cfg.n_cycles) |i| in[i] = ai.decide(&g.brains[i], w, i);
            w.step(in);
            if (w.result != .running) g.timer = 0;
        } else {
            w.step(@splat(.idle));
            if (g.timer >= tuning.attract_rest_ticks) {
                g.timer = 0;
                g.start_world(4);
            }
        }
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

    fn end_round(g: *Game) void {
        const w = &g.world;
        g.state = .round_over;
        g.timer = 0;
        const me = &w.cycles[0];
        if (w.result == .won and w.winner == 0) {
            g.outcome = .win;
            g.wins += 1;
            g.score += tuning.clear_points * level_number;
            // Name how the (last) program went down.
            for (w.cycles[1..w.cfg.n_cycles]) |c| {
                if (c.died_tick == w.tick) g.crash = c.crash;
            }
        } else if (w.result == .won) {
            g.outcome = .lose;
            g.losses += 1;
            g.crash = me.crash;
        } else {
            g.outcome = .draw;
            g.crash = if (w.timed_out) .none else me.crash;
        }
    }

    /// What to draw besides the World.
    pub fn view(g: *const Game) render.View {
        var v: render.View = .{};
        switch (g.state) {
            .title => {
                v.hud.left = .of("SNOUTY CYCLES", 1, colors.text);
                var b: render.Banner = .{ .iris = true, .cy = 66 };
                b.add("SNOUTY", 2, colors.title_a);
                b.add("CYCLES", 2, colors.title_b);
                const on = (g.ticks / tuning.blink_ticks) % 2 == 0;
                b.add("PRESS A", 1, if (on) colors.text else colors.dim);
                v.banner = b;
            },
            .countdown => {
                g.hud(&v);
                var b: render.Banner = .{};
                const n = 3 - @min(2, g.timer / 60);
                const digit = [1]u8{'0' + @as(u8, @intCast(n))};
                // Narrow, so the start cells beside it stay in view.
                b.add(&digit, 3, colors.warn);
                b.add(level_name, 1, colors.text);
                v.banner = b;
            },
            .play => {
                g.hud(&v);
                if (g.timer < tuning.run_banner_ticks) {
                    var b: render.Banner = .{};
                    b.add("RUN", 2, colors.win);
                    v.banner = b;
                }
            },
            .round_over => {
                g.hud(&v);
                var b: render.Banner = .{};
                switch (g.outcome) {
                    .win => b.add("YOU WIN", 2, colors.win),
                    .lose => b.add("YOU LOSE", 2, colors.lose),
                    else => b.add("DRAW", 2, colors.warn),
                }
                b.add(if (g.crash == .none) "TIME" else g.crash.name(), 1, colors.warn);
                var buf: [20]u8 = undefined;
                b.add(tally(&buf, g.wins, g.losses), 1, colors.text);
                v.banner = b;
            },
            .paused => {
                g.hud(&v);
                var b: render.Banner = .{};
                b.add("PAUSED", 2, colors.text);
                b.add("START: RESUME", 1, colors.text);
                b.add("B: QUIT", 1, colors.dim);
                v.banner = b;
            },
        }
        return v;
    }

    fn hud(g: *const Game, v: *render.View) void {
        var buf: [20]u8 = undefined;
        var n: usize = 0;
        n += copy(buf[n..], level_name ++ " R");
        n += decimal(buf[n..], g.round, 1);
        v.hud.left = .of(buf[0..n], 1, colors.text);
        n = decimal(&buf, g.score, 6);
        v.hud.right = .of(buf[0..n], 1, colors.text);
    }
};

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

fn tally(buf: *[20]u8, wins: u32, losses: u32) []const u8 {
    var n: usize = 0;
    n += copy(buf[n..], "YOU ");
    n += decimal(buf[n..], wins, 1);
    n += copy(buf[n..], " - ");
    n += decimal(buf[n..], losses, 1);
    n += copy(buf[n..], " CPU");
    return buf[0..n];
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
var tg: Game = undefined;

test "decimal formatting" {
    var b: [12]u8 = undefined;
    try testing.expectEqualStrings("000500", b[0..decimal(&b, 500, 6)]);
    try testing.expectEqualStrings("7", b[0..decimal(&b, 7, 1)]);
    try testing.expectEqualStrings("1234567", b[0..decimal(&b, 1234567, 6)]);
}

test "title, countdown, play, round over, next round on autopilot" {
    const g = &tg;
    g.init(1);
    g.autopilot = 2;
    for (0..30) |_| g.update(.{}, .{});
    try testing.expectEqual(State.title, g.state);
    g.update(.{ .a = true }, .{ .a = true });
    try testing.expectEqual(State.countdown, g.state);
    try testing.expectEqual(@as(u32, 1), g.round);
    var t: u32 = 0;
    while (g.round < 3 and t < 30 * 60 * 60) : (t += 1) g.update(.{}, .{});
    try testing.expectEqual(@as(u32, 3), g.round);
    try testing.expect(g.wins + g.losses <= 2);
    try testing.expectEqual(State.countdown, g.state);
}

test "start pauses and resumes; Start+Select together is ignored" {
    const g = &tg;
    g.init(2);
    g.update(.{ .a = true }, .{ .a = true });
    for (0..tuning.countdown_ticks) |_| g.update(.{}, .{});
    try testing.expectEqual(State.play, g.state);
    g.update(.{ .start = true, .select = true }, .{ .start = true });
    try testing.expectEqual(State.play, g.state);
    g.update(.{ .start = true }, .{ .start = true });
    try testing.expectEqual(State.paused, g.state);
    const tick = g.world.tick;
    for (0..10) |_| g.update(.{}, .{});
    try testing.expectEqual(tick, g.world.tick);
    g.update(.{ .start = true }, .{ .start = true });
    try testing.expectEqual(State.play, g.state);
}

test "countdown presses set the first heading" {
    const g = &tg;
    g.init(3);
    g.update(.{ .a = true }, .{ .a = true });
    g.update(.{ .up = true }, .{ .up = true });
    try testing.expectEqual(sim.Dir.up, g.world.cycles[0].dir);
}
