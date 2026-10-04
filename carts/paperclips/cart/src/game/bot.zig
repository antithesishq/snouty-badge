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
    /// Called with every click the bot makes (to record oracle scripts).
    on_act: ?*const fn (ctx: *anyopaque, ms: u64, a: Action) void = null,
    on_act_ctx: *anyopaque = undefined,
    /// Probe design shares (of the trust points).
    haz_share: f64 = 0.2,
    haz_max: f64 = 4,
    combat_share: f64 = 0.3,
    explore_at: f64 = 1e30,

    var current: ?*Bot = null;

    fn try_act(g: *Game, a: Action) bool {
        if (!game.available(g, a)) return false;
        if (current) |b| if (b.on_act) |f| f(b.on_act_ctx, g.now_ms, a);
        game.act(g, a);
        return true;
    }

    pub fn step(b: *Bot, g: *Game) void {
        if (g.now_ms < 20) return; // the first ticks set the buttons
        current = b;
        defer current = null;
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
        if (game.available(g, .add_proc) and (g.trust > g.processors + g.memory or g.swarm_gifts > 0)) {
            const mem = if (g.processors < 5)
                false
            else if (g.memory < 70)
                g.processors * 3 >= g.memory
            else
                g.processors * 2 >= g.memory;
            _ = try_act(g, if (mem) .add_mem else .add_proc);
        }
        // Quantum: compute while the chips sum positive.
        if (g.q_flag == 1 and g.panels.q_computing and g.panels.btn_qcompute) {
            var q: f64 = 0;
            for (g.q_chips) |c| q += c.value;
            if (q > 0.5 and g.q_chips[0].active == 1) _ = try_act(g, .q_compute);
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
        if (g.strat_picker != want) _ = try_act(g, .{ .set_strat_pick = want });
        if (g.auto_tourney_flag == 1) return;
        if (g.tourney_in_prog == 0 and g.operations >= g.memory * 1000 * 0.95 and game.available(g, .new_tourney)) {
            _ = try_act(g, .new_tourney);
            _ = try_act(g, .run_tourney);
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
        if (g.wire_buyer_flag == 1 and g.wire_buyer_status == 0) _ = try_act(g, .toggle_wire_buyer);
        // Price: keep a few seconds of stock.
        if (g.now_ms >= b.last_price_ms + 1000) {
            b.last_price_ms = g.now_ms;
            const target = @max(rate * 4, 50);
            if (g.unsold_clips > target * 2) {
                _ = try_act(g, .lower_price);
            } else if (g.unsold_clips < target * 0.5) {
                _ = try_act(g, .raise_price);
            }
        }
        // Investments: high risk once the engine is upgraded; withdraw for
        // the money projects, deposit spare cash every 10 s.
        const goal = b.money_goal(g);
        if (g.investment_engine_flag == 1 and g.panels.investment_engine) {
            if (g.invest_strat != .hi and g.stock_gain_threshold >= 0.53) _ = try_act(g, .{ .set_invest_strat = .hi });
            if (goal) |cost| {
                if (g.funds < cost and g.funds + g.bankroll >= cost) _ = try_act(g, .invest_withdraw);
            } else if (g.now_ms >= b.last_deposit_ms + 10000) {
                b.last_deposit_ms = g.now_ms;
                if (g.funds > 10500) {
                    _ = try_act(g, .invest_deposit);
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

    fn supply(g: *const Game) f64 {
        return g.farm_level * g.farm_rate / 100;
    }

    fn demand(g: *const Game, extra_factories: f64, extra_drones: f64) f64 {
        return ((g.harvester_level + g.wire_drone_level + extra_drones) * g.drone_power_rate) / 100 +
            ((g.factory_level + extra_factories) * g.factory_power_rate) / 100;
    }

    /// The biggest affordable batch (button enabled) of a make_* verb.
    fn batch(g: *Game, comptime verb: std.meta.Tag(Action), sizes: []const u32, max_n: f64) u32 {
        for (sizes) |n| {
            if (@as(f64, @floatFromInt(n)) > max_n) continue;
            if (try_act(g, @unionInit(Action, @tagName(verb), n))) return n;
        }
        return 0;
    }

    fn farms(g: *Game, need_supply: f64) void {
        const need = @max(1, @ceil((need_supply - supply(g)) / 0.5));
        _ = batch(g, .make_farm, &.{ 100, 10, 1 }, need * 2);
    }

    fn swarm_care(b: *Bot, g: *Game) void {
        _ = b;
        if (g.swarm_flag == 0) return;
        // Think (gifts: processors and memory) until memory covers the big
        // projects, then mostly work.
        const want: u8 = if (g.memory < 150) 100 else 20;
        if (g.slider_value != @as(f64, @floatFromInt(want))) _ = try_act(g, .{ .set_slider = want });
        if (g.swarm_status == 5) _ = try_act(g, .synch_swarm);
        if (g.swarm_status == 3) _ = try_act(g, .entertain_swarm);
    }

    fn stage2(b: *Bot, g: *Game) void {
        b.swarm_care(g);
        if (g.dismantle > 0) return;
        // Clips only come from factories now: keep 100M for the first one.
        if (g.factory_flag == 0) return;
        if (g.factory_level == 0 and g.unused_clips < g.factory_cost) {
            if (!try_act(g, .harvester_reboot)) _ = try_act(g, .wire_drone_reboot);
            return;
        }
        // Bootstrap: one factory, one harvester, one wire drone.
        if (g.factory_flag == 1 and g.factory_level == 0 and g.available_matter > 0) {
            _ = try_act(g, .make_factory);
            return;
        }
        if (g.harvester_flag == 1 and g.harvester_level == 0) {
            _ = try_act(g, .{ .make_harvester = 1 });
            return;
        }
        if (g.wire_drone_flag == 1 and g.wire_drone_level == 0) {
            _ = try_act(g, .{ .make_wire_drone = 1 });
            return;
        }
        if (g.project_flag(.p127) == 0) return;
        if (supply(g) < demand(g, 0, 0)) {
            farms(g, demand(g, 0, 0));
            return;
        }
        // Storage for Space Exploration (10M MW-s).
        const late = g.available_matter < 6e27 * 0.05 or g.unused_clips > 1e26;
        if (late) {
            if (g.battery_level * g.battery_size < 1.2e7) _ = batch(g, .make_battery, &.{ 100, 10, 1 }, 1e9);
            if (supply(g) - demand(g, 0, 0) < 2000 and g.farm_level < 6000) farms(g, demand(g, 0, 0) + 2000);
        }
        const used_up = g.available_matter <= 0 and g.acquired_matter <= 0 and g.wire < 1;
        if (used_up) {
            // Earth is used up: take the machines apart for the clips
            // Space Exploration needs (5 octillion), keeping the batteries.
            if (game.is_active(g, .p46) and g.unused_clips < 5e27) {
                if (!try_act(g, .factory_reboot) and !try_act(g, .harvester_reboot) and
                    !try_act(g, .wire_drone_reboot)) _ = try_act(g, .farm_reboot);
            }
            return;
        }
        // Factories keep up with the wire; drones keep up with each other.
        const pm = @max(g.pow_mod, 0.0001);
        const slider = (200 - g.slider_pos) / 100;
        const wdb = if (g.drone_boost > 1) g.drone_boost * @floor(g.wire_drone_level) else 1;
        const w = pm * wdb * @floor(g.wire_drone_level) * g.wire_drone_rate * slider;
        const fb = if (g.factory_boost > 1) g.factory_boost * g.factory_level else 1;
        const f = pm * fb * @floor(g.factory_level) * g.factory_rate;
        if (g.factory_flag == 1 and (f < w * 1.2 or g.wire > f * 200)) {
            if (supply(g) >= demand(g, 1, 0)) {
                _ = try_act(g, .make_factory);
            } else farms(g, demand(g, 1, 0));
            return;
        }
        if (g.available_matter <= 0) return;
        const room = @floor((supply(g) - demand(g, 0, 0)) / 0.01);
        if (room < 1) {
            farms(g, demand(g, 0, 100));
            return;
        }
        if (g.harvester_level <= g.wire_drone_level) {
            _ = batch(g, .make_harvester, &.{ 1000, 100, 10, 1 }, room);
        } else {
            _ = batch(g, .make_wire_drone, &.{ 1000, 100, 10, 1 }, room);
        }
    }

    fn stage3(b: *Bot, g: *Game) void {
        b.swarm_care(g);
        if (g.dismantle > 0) {
            // The end: make the last clips by hand.
            if (g.dismantle >= 4) _ = try_act(g, .make_paperclip);
            return;
        }
        // Probe trust: buy with yomi, up to the max.
        _ = try_act(g, .increase_probe_trust);
        if (g.honor >= g.max_trust_cost and g.panels.increase_max_trust_div) _ = try_act(g, .increase_max_trust);
        // Allocate the design points.
        const t = b.probe_targets(g, g.probe_trust);
        const cur = [8]f64{ g.probe_speed, g.probe_nav, g.probe_rep, g.probe_haz, g.probe_fac, g.probe_harv, g.probe_wire, g.probe_combat };
        // Lower first (frees points), then raise.
        for (0..8) |i| {
            if (cur[i] > t[i]) {
                _ = try_act(g, .{ .probe_stat_down = @fromBackingInt(@intCast(i)) });
                return;
            }
        }
        for (0..8) |i| {
            if (cur[i] < t[i]) {
                if (i == 7 and !g.panels.combat_button_div) continue;
                if (try_act(g, .{ .probe_stat_up = @fromBackingInt(@intCast(i)) })) return;
            }
        }
        // Launch probes while few, keep some clips for the probes' own work.
        if (g.probe_count < 1000 or g.unused_clips > g.probe_cost * 100) _ = try_act(g, .make_probe);
    }

    /// Design points (speed, nav, rep, haz, fac, harv, wire, combat): one
    /// each for the builders, enough hazard remediation that replication
    /// wins, combat once drifters fight, exploration when probes abound,
    /// the rest replication.
    fn probe_targets(b: *const Bot, g: *const Game, total: f64) [8]f64 {
        var t: [8]f64 = @splat(0);
        var left = total;
        const take = struct {
            fn f(l: *f64, n: f64) f64 {
                const k = @max(0, @min(l.*, n));
                l.* -= k;
                return k;
            }
        }.f;
        t[2] = take(&left, 1); // rep
        t[4] = take(&left, 1); // fac
        t[5] = take(&left, 1); // harv
        t[6] = take(&left, 1); // wire
        t[0] = take(&left, 1); // speed
        t[1] = take(&left, 1); // nav
        t[3] = take(&left, @min(b.haz_max, @floor(total * b.haz_share))); // haz
        if (g.project_flag(.p131) == 1 and g.drifter_count > 0) t[7] = take(&left, @floor(total * b.combat_share));
        if (g.probe_count > b.explore_at) {
            t[0] += take(&left, @floor(left * 0.3));
            t[1] += take(&left, @floor(left * 0.4));
        }
        t[2] += left;
        return t;
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
