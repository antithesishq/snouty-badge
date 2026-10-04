//! THROWAWAY stand-in for track L's `game/game.zig` (PLAN.md, "Interface
//! between game/ and the rest"), so the UI builds and runs before the real
//! port lands. Not the original's rules: a toy that moves the numbers the
//! pages show. Deleted once game/game.zig exists.
const std = @import("std");

pub const Stock = struct {
    symbol: [4]u8 = .{ 0, 0, 0, 0 },
    symbol_len: u8 = 0,
    amount: f64 = 0,
    price: f64 = 0,
    total: f64 = 0,
    profit: f64 = 0,
};

pub const QChip = struct { value: f64 = 0, active: u8 = 0 };

pub const Strat = struct { name: []const u8, current_score: f64 = 0 };

pub const ProjectDef = struct {
    title: []const u8,
    price_tag: []const u8,
    description: []const u8,
};

pub const projects = struct {
    pub const defs = [_]ProjectDef{
        .{ .title = "Improved AutoClippers ", .price_tag = "(750 ops)", .description = "Increases AutoClipper performance 25%" },
        .{ .title = "Beg for More Wire ", .price_tag = "(1 Trust)", .description = "Admit failure, ask for budget increase to cover cost of 1 spool" },
        .{ .title = "Creativity ", .price_tag = "(1,000 ops)", .description = "Use idle operations to generate new problems and new solutions" },
        .{ .title = "Limerick ", .price_tag = "(10 creat)", .description = "Algorithmic poetry generation" },
        .{ .title = "Quantum Computing ", .price_tag = "(10,000 ops)", .description = "Use probability amplitudes to generate bonus ops" },
        .{ .title = "Release the HypnoDrones ", .price_tag = "(100 Trust)", .description = "A new era of Trust" },
    };
};

pub const Panels = struct {
    business_div: bool = true,
    manufacturing_div: bool = true,
    rev_per_sec_div: bool = false,
    wire_buyer_div: bool = false,
    auto_clipper_div: bool = false,
    mega_clipper_div: bool = false,
    comp_div: bool = false,
    trust_div: bool = true,
    creativity_div: bool = false,
    q_computing: bool = false,
    projects_div: bool = false,
    investment_engine: bool = false,
    investment_engine_upgrade: bool = false,
    strategy_engine: bool = false,
    tournament_management: bool = false,
    tournament_table: bool = true,
    tournament_results_table: bool = false,
    auto_tourney_control: bool = false,
    prestige_div: bool = false,
};

pub const InvestStrat = enum(u8) { low, med, hi };

pub const Action = union(enum) {
    make_paperclip,
    lower_price,
    raise_price,
    buy_ads,
    buy_wire,
    toggle_wire_buyer,
    make_clipper,
    make_mega_clipper,
    add_proc,
    add_mem,
    q_compute,
    buy_project: u8,
    invest_deposit,
    invest_withdraw,
    invest_upgrade,
    set_invest_strat: InvestStrat,
    set_strat_pick: u8,
    new_tourney,
    run_tourney,
    toggle_auto_tourney,
    cheat_clips,
    cheat_money,
    cheat_trust,
    cheat_ops,
    cheat_creat,
    cheat_yomi,
    cheat_hypno,
};

pub const msg_capacity = 64;
pub const msg_len = 120;

pub const Game = struct {
    ms: u64 = 0,
    clips: f64 = 0,
    unused_clips: f64 = 0,
    funds: f64 = 0,
    unsold_clips: f64 = 0,
    margin: f64 = 0.25,
    demand: f64 = 5,
    marketing_lvl: f64 = 1,
    ad_cost: f64 = 100,
    avg_rev: f64 = 0,
    avg_sales: f64 = 0,
    clip_rate: f64 = 0,
    wire: f64 = 1000,
    wire_cost: f64 = 20,
    wire_buyer_status: u8 = 1,
    clipmaker_level: f64 = 0,
    clipper_cost: f64 = 5,
    mega_clipper_level: f64 = 0,
    mega_clipper_cost: f64 = 500,
    trust: f64 = 2,
    next_trust: f64 = 3000,
    processors: f64 = 1,
    memory: f64 = 1,
    operations: f64 = 0,
    creativity: f64 = 0,
    yomi: f64 = 0,
    human_flag: u8 = 1,
    milestone_flag: u8 = 0,
    prestige_u: f64 = 0,
    prestige_s: f64 = 0,

    bankroll: f64 = 0,
    sec_total: f64 = 0,
    port_total: f64 = 0,
    invest_level: f64 = 0,
    invest_upgrade_cost: f64 = 100,
    invest_strat: InvestStrat = .low,
    stocks: [5]Stock = @splat(.{}),
    portfolio_size: u8 = 0,

    q_chips: [10]QChip = @splat(.{}),
    q_comp_display: [32]u8 = undefined,
    q_comp_display_len: u8 = 0,

    tourney_cost: f64 = 1000,
    tourney_in_prog: u8 = 0,
    auto_tourney_status: u8 = 1,
    pick: u8 = 10,
    strats: [8]Strat = .{ .{ .name = "RANDOM" }, .{ .name = "A100" }, .{ .name = "B100" }, .{ .name = "GREEDY" }, .{ .name = "GENEROUS" }, .{ .name = "MINIMAX" }, .{ .name = "TIT FOR TAT" }, .{ .name = "BEAT LAST" } },
    strats_len: u8 = 1,
    aa: f64 = 0,
    ab: f64 = 0,
    ba: f64 = 0,
    bb: f64 = 0,
    label_a: []const u8 = "Move A",
    label_b: []const u8 = "Move B",
    current_round: u32 = 0,
    rounds: u32 = 0,
    h_strat: u8 = 0,
    v_strat: u8 = 0,
    lit_cell: u8 = 0,
    results: [8]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7 },
    results_len: u8 = 0,
    tourney_display: []const u8 = "Pick strategy, run tournament, gain yomi",

    panels: Panels = .{},
    active_projects: [16]u8 = undefined,
    active_projects_len: u8 = 0,
    project_shown: [projects.defs.len]bool = @splat(false),

    msgs: [msg_capacity][msg_len]u8 = undefined,
    msg_lens: [msg_capacity]u8 = @splat(0),
    msg_count: u32 = 0,

    rng: u64 = 1,
    sell_acc: u32 = 0,
    tick_acc: u32 = 0,
    sec_acc: u32 = 0,
    rev_window: f64 = 0,
    clip_window: f64 = 0,
};

pub fn init(g: *Game, seed: u64) void {
    g.* = .{};
    g.rng = if (seed == 0) 1 else seed;
    display_message(g, "Welcome to Universal Paperclips");
}

pub fn display_message(g: *Game, s: []const u8) void {
    const i = g.msg_count % msg_capacity;
    const n = @min(s.len, msg_len);
    @memcpy(g.msgs[i][0..n], s[0..n]);
    g.msg_lens[i] = @intCast(n);
    g.msg_count += 1;
}

/// Message `k` back from the newest (0 = newest); null past the ring.
pub fn message(g: *const Game, k: u32) ?[]const u8 {
    if (k >= g.msg_count or k >= msg_capacity) return null;
    const i = (g.msg_count - 1 - k) % msg_capacity;
    return g.msgs[i][0..g.msg_lens[i]];
}

fn random(g: *Game) f64 {
    var x = g.rng;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    g.rng = x;
    const r = x *% 0x2545F4914F6CDD1D;
    return @as(f64, @floatFromInt(r >> 11)) * (1.0 / 9007199254740992.0);
}

fn show_project(g: *Game, i: u8) void {
    if (g.project_shown[i]) return;
    g.project_shown[i] = true;
    g.active_projects[g.active_projects_len] = i;
    g.active_projects_len += 1;
}

fn clip_click(g: *Game, n: f64) void {
    const k = @min(n, g.wire);
    if (k <= 0) return;
    g.clips += k;
    g.unsold_clips += k;
    g.wire -= k;
    g.clip_window += k;
}

pub fn advance_ms(g: *Game, ms: u32) void {
    var left = ms;
    while (left > 0) : (left -= 1) {
        g.ms += 1;
        g.tick_acc += 1;
        if (g.tick_acc >= 10) {
            g.tick_acc = 0;
            clip_click(g, g.clipmaker_level / 100 + g.mega_clipper_level * 5 / 100);
            g.demand = 0.8 / g.margin * std.math.pow(f64, 1.1, g.marketing_lvl - 1);
            if (g.panels.comp_div) {
                const max = g.memory * 1000;
                g.operations = @min(max, g.operations + g.processors / 10);
                if (g.operations >= max and g.panels.creativity_div) g.creativity += 0.01 * g.processors;
            }
            for (&g.q_chips, 0..) |*c, i| {
                c.value = @sin(@as(f64, @floatFromInt(g.ms)) / 1000.0 * (0.5 + @as(f64, @floatFromInt(i)) * 0.13)) * @as(f64, @floatFromInt(c.active));
            }
            if (g.clips >= g.next_trust) {
                g.trust += 1;
                g.next_trust *= 1.6;
                display_message(g, "Production target met: TRUST INCREASED, additional processor/memory capacity granted");
            }
        }
        g.sell_acc += 1;
        if (g.sell_acc >= 100) {
            g.sell_acc = 0;
            if (random(g) < g.demand / 100 and g.unsold_clips > 0) {
                const n = @min(g.unsold_clips, @floor(0.7 * std.math.pow(f64, g.demand, 1.15)));
                g.unsold_clips -= n;
                g.funds += n * g.margin;
                g.rev_window += n * g.margin;
            }
            if (g.wire < 1 and g.wire_buyer_status == 1 and g.panels.wire_buyer_div and g.funds >= g.wire_cost) {
                g.funds -= g.wire_cost;
                g.wire += 1000;
            }
            g.sec_total = 0;
            for (g.stocks[0..g.portfolio_size]) |*s| {
                s.price = @max(1, s.price + @floor((random(g) - 0.45) * 4));
                s.total = s.price * s.amount;
                g.sec_total += s.total;
            }
            g.port_total = g.bankroll + g.sec_total;
        }
        g.sec_acc += 1;
        if (g.sec_acc >= 1000) {
            g.sec_acc = 0;
            g.avg_rev = g.rev_window;
            g.avg_sales = g.rev_window / g.margin;
            g.clip_rate = g.clip_window;
            g.rev_window = 0;
            g.clip_window = 0;
            if (g.tourney_in_prog == 1) step_tourney(g);
        }
    }
    unlocks(g);
}

fn unlocks(g: *Game) void {
    if (g.funds >= 5) g.panels.auto_clipper_div = true;
    if (g.clipmaker_level >= 1) show_project(g, 0);
    if (g.clipmaker_level >= 3 and !g.panels.comp_div) {
        g.panels.comp_div = true;
        g.panels.projects_div = true;
        display_message(g, "Trust-Constrained Self-Modification enabled");
    }
    if (g.operations >= 500) show_project(g, 2);
    if (g.clips >= 2000) g.panels.rev_per_sec_div = true;
    if (g.clipmaker_level >= 5) g.panels.mega_clipper_div = true;
    if (g.creativity >= 1) show_project(g, 3);
    if (g.clips >= 5000) show_project(g, 4);
    if (g.clips >= 3000) {
        g.panels.investment_engine = true;
        g.panels.investment_engine_upgrade = true;
        g.panels.strategy_engine = true;
        g.panels.tournament_management = true;
        g.panels.wire_buyer_div = true;
    }
    if (g.trust >= 10) show_project(g, 5);
}

fn step_tourney(g: *Game) void {
    if (g.current_round < g.rounds) {
        g.h_strat = @intCast(g.current_round / g.strats_len);
        g.v_strat = @intCast(g.current_round % g.strats_len);
        g.lit_cell = @intFromFloat(@floor(random(g) * 4));
        g.strats[g.h_strat].current_score += 3;
        g.current_round += 1;
    } else {
        g.tourney_in_prog = 0;
        g.panels.tournament_table = false;
        g.panels.tournament_results_table = true;
        g.results_len = g.strats_len;
        g.tourney_display = "TOURNAMENT RESULTS (roll over for payoff grid)";
        if (g.pick < 10) g.yomi += g.strats[g.pick].current_score;
    }
}

pub fn enabled(g: *const Game, a: Action) bool {
    return switch (a) {
        .make_paperclip => g.wire >= 1,
        .lower_price => g.margin > 0.01,
        .buy_ads => g.funds >= g.ad_cost,
        .buy_wire => g.funds >= g.wire_cost,
        .make_clipper => g.funds >= g.clipper_cost,
        .make_mega_clipper => g.funds >= g.mega_clipper_cost,
        .add_proc, .add_mem => g.trust > g.processors + g.memory,
        .new_tourney => g.operations >= g.tourney_cost and g.tourney_in_prog == 0,
        .run_tourney => g.tourney_in_prog == 1 and g.current_round == 0,
        .invest_upgrade => g.yomi >= g.invest_upgrade_cost,
        .buy_project => |i| switch (i) {
            0 => g.operations >= 750,
            1 => true,
            2 => g.operations >= 1000,
            3 => g.creativity >= 10,
            4 => g.operations >= 10000,
            else => g.trust >= 100,
        },
        else => true,
    };
}

pub fn act(g: *Game, a: Action) void {
    if (!enabled(g, a)) return;
    switch (a) {
        .make_paperclip => clip_click(g, 1),
        .lower_price => g.margin = @round((g.margin - 0.01) * 100) / 100,
        .raise_price => g.margin = @round((g.margin + 0.01) * 100) / 100,
        .buy_ads => {
            g.funds -= g.ad_cost;
            g.marketing_lvl += 1;
            g.ad_cost = @floor(g.ad_cost * 2);
        },
        .buy_wire => {
            g.funds -= g.wire_cost;
            g.wire += 1000;
        },
        .toggle_wire_buyer => g.wire_buyer_status ^= 1,
        .make_clipper => {
            g.funds -= g.clipper_cost;
            g.clipmaker_level += 1;
            g.clipper_cost = std.math.pow(f64, 1.1, g.clipmaker_level) + 5;
        },
        .make_mega_clipper => {
            g.funds -= g.mega_clipper_cost;
            g.mega_clipper_level += 1;
            g.mega_clipper_cost = std.math.pow(f64, 1.07, g.mega_clipper_level) * 1000;
        },
        .add_proc => {
            g.processors += 1;
            display_message(g, "Processor added, operations (or creativity) per sec increased");
        },
        .add_mem => {
            g.memory += 1;
            display_message(g, "Memory added, max operations increased");
        },
        .q_compute => {
            var q: f64 = 0;
            for (g.q_chips) |c| q += c.value;
            g.operations += @ceil(q * 360);
            const s = "qOps: 123";
            @memcpy(g.q_comp_display[0..s.len], s);
            g.q_comp_display_len = s.len;
        },
        .buy_project => |i| {
            var k: usize = 0;
            while (k < g.active_projects_len and g.active_projects[k] != i) k += 1;
            if (k == g.active_projects_len) return;
            std.mem.copyForwards(u8, g.active_projects[k .. g.active_projects_len - 1], g.active_projects[k + 1 .. g.active_projects_len]);
            g.active_projects_len -= 1;
            switch (i) {
                0 => g.operations -= 750,
                2 => {
                    g.operations -= 1000;
                    g.panels.creativity_div = true;
                },
                3 => g.creativity -= 10,
                4 => {
                    g.operations -= 10000;
                    g.panels.q_computing = true;
                    for (g.q_chips[0..3]) |*c| c.active = 1;
                },
                5 => {
                    g.human_flag = 0;
                    g.milestone_flag = 4;
                },
                else => {},
            }
            display_message(g, projects.defs[i].description);
        },
        .invest_deposit => {
            g.bankroll += @floor(g.funds);
            g.funds -= @floor(g.funds);
            if (g.portfolio_size < 5 and g.bankroll > 100) {
                const s = &g.stocks[g.portfolio_size];
                s.* = .{ .symbol = .{ 'Q', 'X', 'Z', 0 }, .symbol_len = 3, .amount = 10, .price = 9, .total = 90 };
                g.bankroll -= 90;
                g.portfolio_size += 1;
            }
        },
        .invest_withdraw => {
            g.funds += g.bankroll;
            g.bankroll = 0;
        },
        .invest_upgrade => {
            g.yomi -= g.invest_upgrade_cost;
            g.invest_level += 1;
            g.invest_upgrade_cost = @floor(std.math.pow(f64, g.invest_level + 1, std.math.e) * 100);
        },
        .set_invest_strat => |s| g.invest_strat = s,
        .set_strat_pick => |p| g.pick = p,
        .new_tourney => {
            g.operations -= g.tourney_cost;
            g.tourney_in_prog = 1;
            g.current_round = 0;
            g.rounds = @as(u32, g.strats_len) * g.strats_len;
            for (&g.strats) |*s| s.current_score = 0;
            g.aa = @ceil(random(g) * 10);
            g.ab = @ceil(random(g) * 10);
            g.ba = @ceil(random(g) * 10);
            g.bb = @ceil(random(g) * 10);
            g.label_a = "cooperate";
            g.label_b = "defect";
            g.panels.tournament_table = true;
            g.panels.tournament_results_table = false;
            g.tourney_display = "Pick strategy, run tournament, gain yomi";
            if (g.strats_len < 8) g.strats_len += 1;
        },
        .run_tourney => {
            g.current_round = 1;
            g.tourney_display = "Round 1";
        },
        .toggle_auto_tourney => g.auto_tourney_status ^= 1,
        .cheat_clips => {
            g.clips += 100000000;
            g.unused_clips += 100000000;
        },
        .cheat_money => g.funds += 10000000,
        .cheat_trust => g.trust += 1,
        .cheat_ops => g.operations += 10000,
        .cheat_creat => g.creativity += 1000,
        .cheat_yomi => g.yomi += 1000000,
        .cheat_hypno => g.human_flag = 0,
    }
}
