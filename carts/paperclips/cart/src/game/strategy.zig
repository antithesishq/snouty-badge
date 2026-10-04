//! main.js STRATEGY: strategic modeling tournaments, including the
//! `round()` setTimeout chain (runRound, 50 ms clearGrid, 50 ms roundLoop).

const std = @import("std");
const game = @import("game.zig");
const Game = game.Game;
const fmt = @import("fmt.zig");

pub const max_strats = 8;
pub const names = [max_strats][]const u8{ "RANDOM", "A100", "B100", "GREEDY", "GENEROUS", "MINIMAX", "TIT FOR TAT", "BEAT LAST" };
pub const choice_a_names = [_][]const u8{ "cooperate", "swerve", "macro", "fight", "bet", "raise_price", "opera", "go", "heads", "particle", "discrete", "peace", "search", "lead", "accept", "accept", "attack" };
pub const choice_b_names = [_][]const u8{ "defect", "straight", "micro", "back_down", "fold", "lower_price", "football", "stay", "tails", "wave", "continuous", "war", "evaluate", "follow", "reject", "deny", "decay" };

/// The `tourneyDisplay` text.
pub const Report = enum(u8) {
    pick, // "Pick strategy, run tournament, gain yomi"
    round, // "Round <tourney_report_round>"
    results_payoff, // "TOURNAMENT RESULTS (roll over for payoff grid)"
    results_grid, // "TOURNAMENT RESULTS (roll over for grid)"

    pub fn text(r: Report) []const u8 {
        return switch (r) {
            .pick => "Pick strategy, run tournament, gain yomi",
            .round => "Round ",
            .results_payoff => "TOURNAMENT RESULTS (roll over for payoff grid)",
            .results_grid => "TOURNAMENT RESULTS (roll over for grid)",
        };
    }
};

/// The grey payoff cell during a round (`payoffCellXX` background).
pub const Cell = enum(u8) { none, aa, ab, ba, bb };

fn find_biggest_payoff(g: *const Game) u8 {
    if (g.aa >= g.ab and g.aa >= g.ba and g.aa >= g.bb) return 1;
    if (g.ab >= g.aa and g.ab >= g.ba and g.ab >= g.bb) return 2;
    if (g.ba >= g.aa and g.ba >= g.ab and g.ba >= g.bb) return 3;
    return 4;
}

fn what_beats_last(g: *const Game, my_pos: f64) f64 {
    const opps: f64 = if (my_pos == 1) 2 else 1;
    if (opps == 1 and g.h_move_prev == 1) {
        return if (g.aa > g.ba) 1 else 2;
    } else if (opps == 1 and g.h_move_prev == 2) {
        return if (g.ab > g.bb) 1 else 2;
    } else if (opps == 2 and g.v_move_prev == 1) {
        return if (g.aa > g.ba) 1 else 2;
    } else {
        return if (g.ab > g.bb) 1 else 2;
    }
}

fn pick_move(g: *Game, s: usize) f64 {
    switch (s) {
        0 => {
            const r = g.rand();
            return if (r < 0.5) 1 else 2;
        },
        1 => return 1,
        2 => return 2,
        3 => return if (find_biggest_payoff(g) < 3) 1 else 2,
        4 => {
            const x = find_biggest_payoff(g);
            return if (x == 1 or x == 3) 1 else 2;
        },
        5 => {
            const x = find_biggest_payoff(g);
            return if (x == 1 or x == 3) 2 else 1;
        },
        6 => {
            g.w = if (g.strat_pos[s] == 1) g.v_move_prev else g.h_move_prev;
            return g.w;
        },
        else => return what_beats_last(g, g.strat_pos[s]),
    }
}

fn pick_strats(g: *Game, round_num: f64) void {
    const len: f64 = @floatFromInt(g.strat_count);
    if (round_num < len) {
        g.h = 0;
        g.v = round_num;
    } else {
        g.strat_counter += 1;
        if (g.strat_counter >= len) g.strat_counter = g.strat_counter - len;
        g.h = @floor(round_num / len);
        g.v = g.strat_counter;
    }
    g.v_strat = @intFromFloat(g.v);
    g.h_strat = @intFromFloat(g.h);
    g.strat_pos[g.h_strat] = 1;
    g.strat_pos[g.v_strat] = 2;
    g.strat_names_shown = true;
}

fn generate_grid(g: *Game) void {
    g.aa = @ceil(g.rand() * 10);
    g.ab = @ceil(g.rand() * 10);
    g.ba = @ceil(g.rand() * 10);
    g.bb = @ceil(g.rand() * 10);
    g.grid_labels = @intFromFloat(@floor(g.rand() * @as(f64, choice_a_names.len)));
    g.grid_labels_set = true;
}

pub fn toggle_auto_tourney(g: *Game) void {
    g.auto_tourney_status = if (g.auto_tourney_status == 1) 0 else 1;
}

pub fn new_tourney(g: *Game) void {
    g.results_flag = 0;
    g.panels.tournament_table = true;
    g.panels.tournament_results_table = false;
    g.high = 0;
    g.tourney_in_prog = 1;
    g.current_round = 0;
    const len: f64 = @floatFromInt(g.strat_count);
    g.rounds = len * len;
    for (0..g.strat_count) |i| g.strat_score[i] = 0;
    g.strat_counter = 0;
    g.standard_ops = g.standard_ops - g.tourney_cost;
    g.tourney_lvl += 1;
    generate_grid(g);
    g.set_disabled(.btn_run_tournament, false);
    g.strat_names_shown = false;
    g.tourney_report = .pick;
}

pub fn run_tourney(g: *Game) void {
    g.set_disabled(.btn_run_tournament, true);
    if (g.current_round < g.rounds) {
        round(g, g.current_round);
    } else {
        g.tourney_in_prog = 0;
        pick_winner(g);
        calculate_place_score(g);
        calculate_show_score(g);
        declare_winner(g);
    }
}

fn pick_winner(g: *Game) void {
    const n = g.strat_count;
    var temp: [max_strats]u8 = undefined;
    var temp_len: usize = n;
    for (0..n) |i| temp[i] = @intCast(i);
    g.results_len = 0;
    for (0..n) |_| {
        var temp_high: f64 = 0;
        var ptr: usize = 0;
        for (0..temp_len) |i| {
            if (g.strat_score[temp[i]] > temp_high) {
                ptr = i;
                temp_high = g.strat_score[temp[i]];
            }
        }
        g.results[g.results_len] = temp[ptr];
        g.results_len += 1;
        var k = ptr + 1;
        while (k < temp_len) : (k += 1) temp[k - 1] = temp[k];
        temp_len -= 1;
    }
    for (0..n) |i| {
        if (g.strat_score[i] > g.high) {
            g.winner_ptr = @floatFromInt(i);
            g.high = g.strat_score[i];
        }
    }
}

fn calculate_place_score(g: *Game) void {
    g.place_score = 0;
    var i: usize = 1;
    while (i < g.results_len) : (i += 1) {
        if (g.strat_score[g.results[i]] < g.strat_score[g.results[i - 1]]) {
            g.place_score = g.strat_score[g.results[i]];
            break;
        }
    }
}

fn calculate_show_score(g: *Game) void {
    g.show_score = 0;
    var i: usize = 1;
    while (i < g.results_len) : (i += 1) {
        if (g.strat_score[g.results[i]] < g.place_score) {
            g.show_score = g.strat_score[g.results[i]];
            break;
        }
    }
}

fn declare_winner(g: *Game) void {
    if (g.pick < 10) {
        const p: usize = @intFromFloat(g.pick);
        g.tourney_report = .results_payoff;
        g.yomi = g.yomi + g.strat_score[p] * g.yomi_boost;
        if (g.milestone_flag < 15) {
            var b: [160]u8 = undefined;
            var o = fmt.Out.init(&b);
            o.str(names[p]);
            o.str(" scored ");
            fmt.write_num(&o, g.strat_score[p]);
            o.str(" in the tournament. Yomi increased by ");
            fmt.write_num(&o, g.strat_score[p] * g.yomi_boost);
            g.display_message(o.slice());
        }
        const wp: usize = @intFromFloat(g.winner_ptr);
        if (g.project_flag(.p128) == 1 and g.strat_score[wp] == g.strat_score[p]) {
            g.yomi = g.yomi + 20000;
            if (g.milestone_flag < 15) g.display_message("Selected strategy won the tournament (or tied for first). +20,000 yomi");
        } else if (g.project_flag(.p128) == 1 and g.place_score == g.strat_score[p]) {
            g.yomi = g.yomi + 15000;
            if (g.milestone_flag < 15) g.display_message("Selected strategy finished in (or tied for) second place. +15,000 yomi");
        } else if (g.project_flag(.p128) == 1 and g.show_score == g.strat_score[p]) {
            g.yomi = g.yomi + 10000;
            if (g.milestone_flag < 15) g.display_message("Selected strategy finished in (or tied for) third place. +10,000 yomi");
        } else {
            g.tourney_report = .results_grid;
        }
        // populateTourneyReport: the UI reads g.results / g.strat_score.
        g.results_shown = g.results_len;
        g.results_bold = @intCast(p);
        // displayTourneyReport
        g.results_flag = 1;
        g.strat_names_shown = false;
        g.panels.tournament_table = false;
        g.panels.tournament_results_table = true;
    }
}

pub fn reveal_grid(g: *Game) void {
    if (g.results_flag == 1) {
        g.results_timer = 0;
        g.panels.tournament_table = true;
        g.panels.tournament_results_table = false;
    }
}

pub fn reveal_results(g: *Game) void {
    if (g.results_flag == 1) {
        g.panels.tournament_table = false;
        g.panels.tournament_results_table = true;
    }
}

fn calc_payoff(g: *Game, hm: f64, vm: f64) void {
    const hi: usize = @intFromFloat(g.h);
    const vi: usize = @intFromFloat(g.v);
    if (hm == 1 and vm == 1) {
        g.payoff_cell = .aa;
        g.strat_score[hi] = g.strat_score[hi] + g.aa;
        g.strat_score[vi] = g.strat_score[vi] + g.aa;
    } else if (hm == 1 and vm == 2) {
        g.payoff_cell = .ab;
        g.strat_score[hi] = g.strat_score[hi] + g.ab;
        g.strat_score[vi] = g.strat_score[vi] + g.ba;
    } else if (hm == 2 and vm == 1) {
        g.payoff_cell = .ba;
        g.strat_score[hi] = g.strat_score[hi] + g.ba;
        g.strat_score[vi] = g.strat_score[vi] + g.ab;
    } else if (hm == 2 and vm == 2) {
        g.payoff_cell = .bb;
        g.strat_score[hi] = g.strat_score[hi] + g.bb;
        g.strat_score[vi] = g.strat_score[vi] + g.bb;
    }
}

fn round(g: *Game, round_num: f64) void {
    // roundSetup
    g.r_counter = 0;
    pick_strats(g, round_num);
    g.tourney_report = .round;
    g.tourney_report_round = round_num + 1;
    round_loop(g);
}

/// `roundLoop` (also the 50 ms timeout after clearGrid).
pub fn round_loop(g: *Game) void {
    if (g.r_counter < 10) {
        run_round(g);
        g.set_timeout(50, .clear_grid);
    } else {
        g.current_round += 1;
        run_tourney(g);
    }
}

/// `clearGrid` (the 50 ms timeout after runRound).
pub fn clear_grid(g: *Game) void {
    g.payoff_cell = .none;
    g.set_timeout(50, .round_loop);
}

fn run_round(g: *Game) void {
    g.r_counter += 1;
    g.h_move_prev = g.h_move;
    g.v_move_prev = g.v_move;
    g.h_move = pick_move(g, g.h_strat);
    g.v_move = pick_move(g, g.v_strat);
    calc_payoff(g, g.h_move, g.v_move);
}
