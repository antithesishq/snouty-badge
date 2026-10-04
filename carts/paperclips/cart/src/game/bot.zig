//! A simple heuristic autoplayer: looks at the state the screen would show
//! and clicks through `game.act`, like an impatient player. Used by the
//! autoplayer tests (and handy for preview scripts and benchmarks).
//!
//! Call `step` every 100 ms of virtual time (`play` does).

const std = @import("std");
const game = @import("game.zig");
const Game = game.Game;
const P = game.P;
const Action = game.Action;

pub const Bot = struct {
    /// Manual "Make Paperclip" clicks per step while clips are scarce.
    clicks_per_step: u32 = 1,
    last_price_ms: u64 = 0,
    last_deposit_ms: u64 = 0,
    /// Stop at the end of stage 1 (no clicks after the HypnoDrones).
    stage1_only: bool = false,

    fn try_act(g: *Game, a: Action) bool {
        if (!game.enabled(g, a)) return false;
        game.act(g, a);
        return true;
    }

    pub fn step(b: *Bot, g: *Game) void {
        if (g.now_ms < 20) return; // the first ticks set the buttons
        if (b.stage1_only and g.project_flag(.p35) == 1) return;
        if (g.human_flag == 1) b.stage1(g) else if (g.space_flag == 0) b.stage2(g) else b.stage3(g);
        b.projects(g);
        b.computing(g);
        b.tournaments(g);
    }

    fn projects(b: *Bot, g: *Game) void {
        _ = b;
        // One per step and only when the cost holds now: `disabled` is the
        // last tick's, so two buys in a row could overspend (the JS lets a
        // fast double click do that too).
        for (g.active[0..g.active_len]) |a| {
            const p: P = @fromBackingInt(@intCast(a));
            const skip = switch (p) {
                .p219, .p217, .p200, .p201, .p218 => true,
                // Accept the exile only for the ending: reject (148).
                .p147 => true,
                else => false,
            };
            if (skip or !game.project_cost(g, p)) continue;
            if (try_act(g, .{ .buy_project = a })) return;
        }
    }

    fn computing(b: *Bot, g: *Game) void {
        _ = b;
        if (g.comp_flag == 0) return;
        // One per step: `disabled` only updates on the 10 ms tick, so a
        // loop here would click past the trust limit (as a fast human can).
        if (game.enabled(g, .add_proc) and (g.trust > g.processors + g.memory or g.swarm_gifts > 0)) {
            const mem = if (g.processors < 5)
                false
            else if (g.memory < 70)
                g.processors * 3 >= g.memory
            else
                g.processors * 2 >= g.memory;
            game.act(g, if (mem) .add_mem else .add_proc);
        }
        // Quantum: compute while the chips sum positive.
        if (g.q_flag == 1 and g.panels.q_computing and g.panels.btn_qcompute) {
            var q: f64 = 0;
            for (g.q_chips) |c| q += c.value;
            if (q > 0.5 and g.q_chips[0].active == 1) game.act(g, .q_compute);
        }
    }

    fn tournaments(b: *Bot, g: *Game) void {
        _ = b;
        // Spare yomi goes to the investment engine.
        const yomi_projects_done = g.project_flag(.p29) == 1 and g.project_flag(.p30) == 1 and
            g.project_flag(.p38) == 1;
        if (yomi_projects_done and g.human_flag == 1 and g.panels.investment_engine_upgrade)
            _ = try_act(g, .invest_upgrade);
        if (g.strategy_engine_flag == 0 or !g.panels.strategy_engine) return;
        // Pick the newest strategy (BEAT LAST / GREEDY do well).
        const want: u8 = switch (g.strat_count) {
            1 => 0,
            2, 3 => 1,
            4, 5, 6, 7 => 3,
            else => 7,
        };
        if (g.strat_picker != want) game.act(g, .{ .set_strat_pick = want });
        if (g.auto_tourney_flag == 1) return;
        if (g.tourney_in_prog == 0 and g.operations >= g.memory * 1000 * 0.95 and game.enabled(g, .new_tourney)) {
            game.act(g, .new_tourney);
            game.act(g, .run_tourney);
        }
    }

    /// The cost of a money project worth saving for (trust or demand),
    /// when cash plus investments plus 10 minutes of income get there.
    fn money_goal(b: *Bot, g: *Game) ?f64 {
        _ = b;
        const goals = [_]struct { p: P, cost: f64 }{
            .{ .p = .p37, .cost = 1000000 },
            .{ .p = .p38, .cost = 10000000 },
            .{ .p = .p40, .cost = 500000 },
            .{ .p = .p40b, .cost = g.bribe },
        };
        for (goals) |x| {
            if (!game.is_active(g, x.p)) continue;
            if (g.funds + g.bankroll + @max(g.avg_rev, 0) * 600 >= x.cost) return x.cost;
        }
        return null;
    }

    fn stage1(b: *Bot, g: *Game) void {
        // Make clips by hand while the machines are few.
        if (g.clipmaker_level < 50) {
            var k: u32 = 0;
            while (k < b.clicks_per_step) : (k += 1) _ = try_act(g, .make_paperclip);
        }
        // Wire.
        const rate = @max(g.clip_rate, 1);
        if (g.wire < @max(rate * 3, 500)) _ = try_act(g, .buy_wire);
        if (g.wire_buyer_flag == 1 and g.wire_buyer_status == 0) game.act(g, .toggle_wire_buyer);
        // Price: keep a few seconds of stock.
        if (g.now_ms >= b.last_price_ms + 1000) {
            b.last_price_ms = g.now_ms;
            const target = @max(rate * 4, 50);
            if (g.unsold_clips > target * 2) {
                _ = try_act(g, .lower_price);
            } else if (g.unsold_clips < target * 0.5) {
                game.act(g, .raise_price);
            }
        }
        // Investments: high risk once the engine is upgraded; withdraw for
        // the money projects, deposit spare cash every 10 s.
        const goal = b.money_goal(g);
        if (g.investment_engine_flag == 1 and g.panels.investment_engine) {
            if (g.invest_strat != .hi and g.stock_gain_threshold >= 0.53) game.act(g, .{ .set_invest_strat = .hi });
            if (goal) |cost| {
                if (g.funds < cost and g.funds + g.bankroll >= cost) game.act(g, .invest_withdraw);
            } else if (g.now_ms >= b.last_deposit_ms + 10000) {
                b.last_deposit_ms = g.now_ms;
                if (g.funds > 10500) {
                    game.act(g, .invest_deposit);
                    return;
                }
            }
        }
        if (goal != null) return; // saving
        const reserve = g.wire_cost * 2;
        const glut = g.unsold_clips > rate * 5 and g.margin <= 0.02;
        // Marketing.
        if (g.funds >= g.ad_cost + reserve) _ = try_act(g, .buy_ads);
        if (glut) return; // more machines only pile up unsold clips
        // Clippers.
        if (g.panels.auto_clipper_div and g.funds >= g.clipper_cost + reserve) _ = try_act(g, .make_clipper);
        if (g.mega_clipper_flag == 1 and g.funds >= g.mega_clipper_cost + reserve) _ = try_act(g, .make_mega_clipper);
    }

    fn stage2(b: *Bot, g: *Game) void {
        _ = b;
        _ = g;
    }

    fn stage3(b: *Bot, g: *Game) void {
        _ = b;
        _ = g;
    }
};

/// Play until `done(g)` or `limit_ms` of virtual time; returns the virtual
/// ms reached.
pub fn play(g: *Game, bot: *Bot, limit_ms: u64, comptime done: fn (*const Game) bool) u64 {
    while (g.now_ms < limit_ms and !done(g)) {
        game.advance_ms(g, 100);
        bot.step(g);
    }
    return g.now_ms;
}
