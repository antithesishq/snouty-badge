//! main.js INVESTMENTS: the stock portfolio, its three timers and the
//! deposit/withdraw/upgrade buttons.

const std = @import("std");
const game = @import("game.zig");
const Game = game.Game;
const jsmath = @import("jsmath.zig");
const fmt = @import("fmt.zig");

pub const max_port = 5;

pub const Stock = struct {
    id: f64 = 0,
    symbol: [4]u8 = .{ 0, 0, 0, 0 },
    symbol_len: u8 = 0,
    price: f64 = 0,
    amount: f64 = 0,
    total: f64 = 0,
    profit: f64 = 0,
    age: f64 = 0,

    pub fn sym(s: *const Stock) []const u8 {
        return s.symbol[0..s.symbol_len];
    }
};

/// The `investStrat` select.
pub const InvestStrat = enum(u8) { low, med, hi };

pub fn invest_upgrade(g: *Game) void {
    g.yomi = g.yomi - g.invest_upgrade_cost;
    g.invest_level += 1;
    g.stock_gain_threshold = g.stock_gain_threshold + 0.01;
    g.invest_upgrade_cost = @floor(jsmath.pow(g.invest_level + 1, std.math.e) * 100);
    var b: [128]u8 = undefined;
    var o = fmt.Out.init(&b);
    o.str("Investment engine upgraded, expected profit/loss ratio now ");
    fmt.write_num(&o, g.stock_gain_threshold);
    g.display_message(o.slice());
}

pub fn invest_deposit(g: *Game) void {
    g.ledger = g.ledger - @floor(g.funds);
    g.bankroll = @floor(g.bankroll + g.funds);
    g.funds = 0;
}

pub fn invest_withdraw(g: *Game) void {
    g.ledger = g.ledger + g.bankroll;
    g.funds = g.funds + g.bankroll;
    g.bankroll = 0;
}

fn stock_shop(g: *Game) void {
    var budget = @ceil(g.port_total / g.riskiness);
    const r = 11 - g.riskiness;
    var reserves = @ceil(g.port_total / r);
    if (g.riskiness == 1) reserves = 0;

    if ((g.bankroll - budget) < reserves and g.riskiness == 1 and g.bankroll > (g.port_total / 10)) {
        budget = g.bankroll;
    } else if ((g.bankroll - budget) < reserves and g.riskiness == 1) {
        budget = 0;
    } else if ((g.bankroll - budget) < reserves) {
        budget = g.bankroll - reserves;
    }

    if (@as(f64, @floatFromInt(g.stocks_len)) < g.max_port and g.bankroll >= 5 and budget >= 1 and g.bankroll - budget >= reserves) {
        if (g.rand() < 0.25) create_stock(g, budget);
    }
}

fn create_stock(g: *Game, dollars: f64) void {
    g.stock_id += 1;
    var s = Stock{};
    generate_symbol(g, &s);
    const roll = g.rand();
    var pri: f64 = undefined;
    if (roll > 0.99) {
        pri = @ceil(g.rand() * 3000);
    } else if (roll > 0.85) {
        pri = @ceil(g.rand() * 500);
    } else if (roll > 0.60) {
        pri = @ceil(g.rand() * 150);
    } else if (roll > 0.20) {
        pri = @ceil(g.rand() * 50);
    } else {
        pri = @ceil(g.rand() * 15);
    }
    if (pri > dollars) pri = @ceil(dollars * roll);
    var amt = @floor(dollars / pri);
    if (amt > 1000000) amt = 1000000;
    s.id = g.stock_id;
    s.price = pri;
    s.amount = amt;
    s.total = pri * amt;
    g.stocks[g.stocks_len] = s;
    g.stocks_len += 1;
    g.portfolio_size = @floatFromInt(g.stocks_len);
    g.bankroll = g.bankroll - (pri * amt);
}

fn sell_stock(g: *Game) void {
    g.bankroll = g.bankroll + g.stocks[0].total;
    var i: usize = 1;
    while (i < g.stocks_len) : (i += 1) g.stocks[i - 1] = g.stocks[i];
    g.stocks_len -= 1;
    g.portfolio_size = @floatFromInt(g.stocks_len);
}

fn generate_symbol(g: *Game, s: *Stock) void {
    var ltr: u8 = 0;
    const x = g.rand();
    if (x <= 0.01) {
        ltr = 1;
    } else if (x <= 0.1) {
        ltr = 2;
    } else if (x <= 0.4) {
        ltr = 3;
    } else {
        ltr = 4;
    }
    const y: u8 = @intFromFloat(@floor(g.rand() * 26));
    s.symbol[0] = 'A' + y;
    var i: u8 = 1;
    while (i < ltr) : (i += 1) {
        const z: u8 = @intFromFloat(@floor(g.rand() * 26));
        s.symbol[i] = 'A' + z;
    }
    s.symbol_len = ltr;
}

fn update_stocks(g: *Game) void {
    const n: usize = @intFromFloat(g.portfolio_size);
    for (g.stocks[0..n]) |*s| {
        s.age = s.age + 1;
        if (g.rand() < 0.6) {
            var gain = true;
            if (g.rand() > g.stock_gain_threshold) gain = false;
            const current = s.price;
            const delta = @ceil((g.rand() * current) / (4 * g.riskiness));
            if (gain) {
                s.price = s.price + delta;
            } else {
                s.price = s.price - delta;
            }
            if (s.price == 0 and g.rand() > 0.24) s.price = 1;
            s.total = s.price * s.amount;
            if (gain) {
                s.profit = s.profit + (delta * s.amount);
            } else {
                s.profit = s.profit - (delta * s.amount);
            }
        }
    }
}

/// The 100 ms "Stock List Display Routine" interval.
pub fn display_tick(g: *Game) void {
    g.riskiness = switch (g.invest_strat) {
        .low => 7,
        .med => 5,
        .hi => 1,
    };
    g.m = 0;
    const n: usize = @intFromFloat(g.portfolio_size);
    for (g.stocks[0..n]) |*s| g.m = g.m + s.total;
    g.sec_total = g.m;
    g.port_total = g.bankroll + g.sec_total;
    g.portfolio_size = @floatFromInt(g.stocks_len);
}

/// The 1000 ms interval.
pub fn shop_tick(g: *Game) void {
    if (g.human_flag == 1) stock_shop(g);
}

/// The 2500 ms interval.
pub fn sell_tick(g: *Game) void {
    g.sell_delay = g.sell_delay + 1;
    if (g.portfolio_size > 0 and g.sell_delay >= 5 and g.rand() <= 0.3 and g.human_flag == 1) {
        sell_stock(g);
        g.sell_delay = 0;
    }
    if (g.portfolio_size > 0 and g.human_flag == 1) update_stocks(g);
}
