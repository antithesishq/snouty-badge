//! The autoplayer: presses buttons for the player, through App.update like
//! a person would, with human-ish pauses (reading, thinking, reaction time
//! for the shooting cue, the odd misfire or wrong button). badge-bench runs
//! it for whole games back to back (`raspberry_trail_autoplay`), and the
//! preview scripts use it for full games, deaths and arrivals. No cart API.
const std = @import("std");
const G = @import("game");
const app_mod = @import("app.zig");

const App = app_mod.App;
const Buttons = app_mod.Buttons;

/// How fast it plays.
pub const Pace = enum(u8) {
    off = 0,
    /// Human: reads each page for about a second, reacts to the cue in
    /// about 0.4 s.
    human = 1,
    /// Fast: short pauses everywhere (still distinct presses).
    fast = 2,
};

/// How it plays.
pub const Policy = enum(u8) {
    /// A plausible mix.
    normal = 0,
    /// Spends to arrive: plenty of food and clothing, hunts when low.
    careful = 1,
    /// Buys no food and eats well: starves within a few turns.
    starve = 2,
    /// Hunts whenever it can (the shooting cue, again and again).
    hunter = 3,
};

/// The poke / export value: pace in bits 0..3, policy in bits 4..7.
pub fn decode(v: u32) struct { pace: Pace, policy: Policy } {
    const p: u8 = @intCast(v & 0x3);
    const q: u8 = @intCast((v >> 4) & 0x3);
    return .{ .pace = @fromBackingInt(@intCast(if (p == 3) 2 else p)), .policy = @fromBackingInt(@intCast(q)) };
}

pub const Bot = struct {
    pace: Pace = .off,
    policy: Policy = .normal,
    rng: u64 = 0x9E3779B97F4A7C15,
    /// Frames to wait before the next press.
    wait: u32 = 0,
    /// What the screen showed at the last step: a change means a new
    /// thing to read or decide (a longer pause).
    key: u64 = 0,
    /// The target for the current prompt (number value or 0-based row).
    target: i32 = 0,
    /// This shot goes wrong at button `fail_at` (0xFF: never); a misfire
    /// when `misfire` is set.
    fail_at: u8 = 0xFF,
    misfire: bool = false,
    presses: u32 = 0,

    pub fn set(b: *Bot, v: u32, seed: u64) void {
        const d = decode(v);
        b.* = .{ .pace = d.pace, .policy = d.policy, .rng = seed | 1 };
    }

    fn rand(b: *Bot, n: u32) u32 {
        var x = b.rng;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        b.rng = x;
        const r: u32 = @truncate((x *% 0x2545F4914F6CDD1D) >> 32);
        return @intCast((@as(u64, r) * n) >> 32);
    }

    fn between(b: *Bot, lo: u32, hi: u32) u32 {
        return lo + b.rand(hi - lo + 1);
    }

    /// Scales a human delay for the pace.
    fn delay(b: *Bot, lo: u32, hi: u32) u32 {
        const d = b.between(lo, hi);
        return switch (b.pace) {
            .fast => @max(2, d / 6),
            else => d,
        };
    }

    fn state_key(app: *const App) u64 {
        var k: u64 = @backingInt(app.screen);
        k = k * 8 + @backingInt(app.phase);
        k = k * 65536 + (app.answers & 0xFFFF);
        k = k * 65536 + (app.seen & 0xFFFF);
        k = k * 8 + app.shot.idx;
        k = k * 1024 + (app.games_started & 0x3FF);
        k = k * 2 + @intFromBool(app.help);
        return k;
    }

    /// The buttons for this frame (all released between presses).
    pub fn step(b: *Bot, app: *const App) Buttons {
        if (b.pace == .off) return .{};
        // Never hold anything two frames running: every press is an edge.
        if (@as(u8, @bitCast(app.prev)) != 0) return .{};
        const k = state_key(app);
        if (k != b.key) {
            b.key = k;
            b.on_new_state(app);
        }
        if (b.wait > 0) {
            b.wait -= 1;
            return .{};
        }
        const out = b.decide(app);
        if (@as(u8, @bitCast(out)) != 0) b.presses += 1;
        return out;
    }

    /// A new screen: how long to look at it, and the plan for a prompt.
    fn on_new_state(b: *Bot, app: *const App) void {
        switch (app.screen) {
            .title => b.wait = b.delay(50, 110),
            .history, .credits => b.wait = b.delay(20, 40),
            .game => switch (app.phase) {
                .more => b.wait = b.reading_delay(app),
                .prompt => {
                    b.wait = b.reading_delay(app) / 2 + b.delay(15, 40);
                    b.plan(app);
                },
                .shot_ready => {
                    b.misfire = b.rand(100) < 3;
                    b.fail_at = if (b.rand(100) < 5) @intCast(b.rand(app.shot.n)) else 0xFF;
                    b.wait = if (b.misfire) b.between(5, 30) else 1_000_000;
                },
                .shot_cue => {
                    // Reaction to the cue, then each next button.
                    b.wait = if (app.shot.idx == 0) b.cue_delay(20, 40) else b.cue_delay(8, 18);
                },
                .shot_done => b.wait = 1_000_000,
                .scene => b.wait = b.delay(90, 150),
            },
        }
    }

    /// The shooting cue keeps human timing at every pace (it is the game).
    fn cue_delay(b: *Bot, lo: u32, hi: u32) u32 {
        return b.between(lo, hi);
    }

    /// About 4 frames per visible row, at least half a second.
    fn reading_delay(b: *Bot, app: *const App) u32 {
        const new_rows: u32 = @min(app.view_end -| app.batch_start, 12);
        return b.delay(30 + new_rows * 4, 60 + new_rows * 6);
    }

    fn decide(b: *Bot, app: *const App) Buttons {
        if (app.help) return .{ .b = true };
        switch (app.screen) {
            .title => {
                b.wait = b.delay(30, 60);
                if (app.title_cursor != .new_game) return .{ .up = true };
                return .{ .a = true };
            },
            .history, .credits => return .{ .b = true },
            .game => {},
        }
        const p = app.prompt();
        switch (app.phase) {
            .more, .scene => {
                b.wait = b.delay(10, 20);
                return .{ .a = true };
            },
            .shot_ready => {
                if (!b.misfire) return .{};
                b.wait = 1_000_000;
                return .{ .b = true };
            },
            .shot_cue => {
                const want = app.shot.seq[app.shot.idx];
                if (app.shot.idx == b.fail_at) {
                    b.wait = 1_000_000;
                    const wrong: app_mod.ShotButton = @fromBackingInt(@intCast((@backingInt(want) + 1 + b.rand(5)) % 6));
                    return app_mod.buttons_for(wrong);
                }
                b.wait = 1_000_000; // until the next button's state change
                return app_mod.buttons_for(want);
            },
            .shot_done => return .{},
            .prompt => {},
        }
        switch (p.kind) {
            .yes_no, .choice => {
                const t: u8 = @intCast(b.target);
                if (app.cursor == t) {
                    b.wait = b.delay(10, 20);
                    return .{ .a = true };
                }
                b.wait = b.delay(6, 14);
                return if (app.cursor > t) .{ .up = true } else .{ .down = true };
            },
            .number => {
                const s = app.spin;
                const diff = b.target - s.value;
                if (diff == 0) {
                    b.wait = b.delay(10, 20);
                    return .{ .a = true };
                }
                // The highest place that does not overshoot.
                const mag: u32 = @abs(diff);
                var place: u8 = 0;
                var pw: u32 = 1;
                while (place + 1 < s.digits and pw * 10 <= mag) {
                    pw *= 10;
                    place += 1;
                }
                b.wait = b.delay(5, 12);
                if (s.caret < place) return .{ .left = true };
                if (s.caret > place) return .{ .right = true };
                return if (diff > 0) .{ .up = true } else .{ .down = true };
            },
            .game_over => {
                b.wait = b.delay(30, 60);
                return .{ .a = true };
            },
            .shoot => return .{},
        }
    }

    /// Picks the answer to aim for.
    fn plan(b: *Bot, app: *const App) void {
        const p = app.prompt();
        const h = app.hud;
        switch (p.kind) {
            .yes_no => {
                // The instructions: mostly no. The funeral: anything.
                b.target = if (p.line == 190) (if (b.rand(100) < 15) 0 else 1) else @intCast(b.rand(2));
            },
            .choice => b.target = b.choose(p, h),
            .number => {
                const want: i32 = b.amount(p, h);
                const hi = @max(p.min, p.max);
                b.target = std.math.clamp(want, p.min, hi);
                // Round to tens: a person rarely dials the ones.
                if (b.target > 20) b.target = std.math.clamp(@divTrunc(b.target, 10) * 10, p.min, hi);
            },
            else => b.target = 0,
        }
    }

    fn option(p: *const G.Prompt, prefix: []const u8) ?i32 {
        var k: u8 = 0;
        while (k < p.n_options) : (k += 1) {
            if (std.mem.startsWith(u8, p.options[k], prefix)) return k;
        }
        return null;
    }

    fn choose(b: *Bot, p: *const G.Prompt, h: G.Hud) i32 {
        const n: u32 = @max(p.n_options, 1);
        const hunt = option(p, "HUNT");
        const fort = option(p, "STOP") orelse option(p, "FORT");
        const cont = option(p, "CONT");
        if (hunt != null or fort != null or cont != null) {
            const can_hunt = hunt != null and h.bullets > 39;
            switch (b.policy) {
                .hunter => if (can_hunt) return hunt.?,
                .starve => return cont orelse 0,
                else => {},
            }
            const low_food = h.food < (if (b.policy == .careful) @as(i32, 60) else 35);
            if (low_food and can_hunt and b.rand(100) < 70) return hunt.?;
            if (fort) |f| {
                const need = h.clothing < 40 or h.misc < 15 or h.food < 50;
                if (h.cash > 20 and need and b.rand(100) < 80) return f;
            }
            if (can_hunt and b.rand(100) < 20) return hunt.?;
            return cont orelse @intCast(n - 1);
        }
        return switch (p.line) {
            // The marksman question: mostly the middle.
            760 => @intCast(@min(n - 1, if (b.policy == .careful) 1 else b.rand(100) / 25 + @as(u32, if (b.rand(2) == 0) 1 else 0))),
            // Eating: poorly when short, well when rich.
            2770 => blk: {
                if (b.policy == .starve) break :blk @intCast(n - 1);
                if (h.food > 100) break :blk @intCast(@min(n - 1, 2));
                if (h.food < 30) break :blk 0;
                break :blk @intCast(@min(n - 1, 1));
            },
            else => @intCast(b.rand(n)),
        };
    }

    fn amount(b: *Bot, p: *const G.Prompt, h: G.Hud) i32 {
        _ = h;
        const r = b;
        const careful = b.policy == .careful;
        return switch (p.line) {
            860 => if (careful) 260 else @intCast(r.between(200, 300)),
            940 => switch (b.policy) {
                .starve => 0,
                .careful => 200,
                else => @intCast(r.between(60, 200)),
            },
            990 => if (careful) 50 else @intCast(r.between(20, 90)),
            1040 => if (careful) 100 else @intCast(r.between(20, 90)),
            1090 => if (careful) 70 else @intCast(r.between(10, 60)),
            // Fort purchases: food first, then the rest by need.
            2330 => if (b.policy == .starve) 0 else @intCast(@divTrunc(@max(p.max, 0), @as(i32, @intCast(r.between(2, 5))))),
            else => p.default,
        };
    }
};
