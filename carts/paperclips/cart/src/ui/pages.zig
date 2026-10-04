//! The pages of SPEC section 3: which pages exist right now, and the rows
//! of each, built fresh from the game state every frame. This file is the
//! one place that reads the game's fields for display; widgets.zig draws
//! the rows and app.zig moves the cursor and presses them.
const std = @import("std");
const G = @import("game");
const numfmt = @import("numfmt.zig");
const text = @import("text.zig");

pub const Page = enum(u8) {
    business,
    manufacturing,
    computing,
    projects,
    investments,
    strategy,
    cheats,

    pub fn title(p: Page) []const u8 {
        return switch (p) {
            .business => "BUSINESS",
            .manufacturing => "MANUFACTURING",
            .computing => "COMPUTING",
            .projects => "PROJECTS",
            .investments => "INVESTMENTS",
            .strategy => "STRATEGY",
            .cheats => "CHEATS",
        };
    }
};

pub const page_count = @typeInfo(Page).@"enum".field_names.len;

/// Does the page exist now (its panels are shown in the original)?
pub fn visible(g: *const G.Game, p: Page, cheats: bool) bool {
    const v = &g.panels;
    return switch (p) {
        .business => g.human_flag == 1,
        .manufacturing => true,
        .computing => v.comp_div,
        .projects => v.projects_div,
        .investments => v.investment_engine,
        .strategy => v.strategy_engine,
        .cheats => cheats,
    };
}

pub const Kind = enum {
    /// A readout: label left, value right.
    text,
    /// A button: A presses it (grey when disabled).
    button,
    /// A value with A raising / B lowering (price, risk, strategy pick).
    value,
    /// A project button: title; the footer shows its price and description.
    project,
    /// A sub-heading inside a page (a panel title of the original).
    heading,
    /// The ten quantum chips (two text rows tall).
    chips,
    /// The strategy payoff grid (three rows tall).
    grid,
    /// The stock table's column heads / one stock line.
    stock_head,
    stock,
    /// One line of free text (wrapped notes, tournament results).
    note,
};

pub const Row = struct {
    kind: Kind,
    /// Stable identity for news marks ("!" when a new one appears) and to
    /// keep the cursor on the same row as rows come and go.
    id: u16,
    left: []const u8 = "",
    right: []const u8 = "",
    /// A (and the held repeat when `repeat`).
    act: ?G.Action = null,
    /// B, on value rows.
    act_b: ?G.Action = null,
    enabled: bool = true,
    enabled_b: bool = true,
    repeat: bool = false,
    /// Shown in the footer while the cursor is on the row.
    detail: []const u8 = "",
    /// Height in text rows (widgets).
    lines: u8 = 1,
    /// Emphasis (bold in the original): drawn with a light face.
    strong: bool = false,

    pub fn selectable(r: Row) bool {
        return r.act != null or r.act_b != null;
    }
};

pub const max_rows = 48;

/// Characters per line of a wrapped note (the row less its margins).
pub const note_cols = 25;

pub const RowList = struct {
    rows: [max_rows]Row = undefined,
    n: usize = 0,

    pub fn add(l: *RowList, r: Row) void {
        if (l.n < max_rows) {
            l.rows[l.n] = r;
            l.n += 1;
        }
    }

    pub fn slice(l: *const RowList) []const Row {
        return l.rows[0..l.n];
    }
};

/// Row ids: fixed rows are page * 64 + n; projects are project_id_base + index.
pub const project_id_base: u16 = 1024;
pub const max_ids = 2048;

fn rid(p: Page, n: u16) u16 {
    return @as(u16, @intFromEnum(p)) * 64 + n;
}

/// Builds the rows of page `p` into `out`, formatting numbers into `a`.
pub fn build(g: *const G.Game, p: Page, out: *RowList, a: *text.Arena) void {
    out.n = 0;
    var b = Builder{ .g = g, .out = out, .a = a, .page = p };
    switch (p) {
        .business => b.business(),
        .manufacturing => b.manufacturing(),
        .computing => b.computing(),
        .projects => b.projects(),
        .investments => b.investments(),
        .strategy => b.strategy(),
        .cheats => b.cheats(),
    }
}

const Builder = struct {
    g: *const G.Game,
    out: *RowList,
    a: *text.Arena,
    page: Page,

    fn id(b: *Builder, n: u16) u16 {
        return rid(b.page, n);
    }

    // Formatting helpers: each returns a slice kept in the arena.
    fn int(b: *Builder, v: f64) []const u8 {
        return b.a.keep(numfmt.int(b.a.scratch(), v));
    }
    fn money(b: *Builder, v: f64) []const u8 {
        return b.a.keep(numfmt.money(b.a.scratch(), v));
    }
    fn compact(b: *Builder, v: f64) []const u8 {
        return b.a.keep(numfmt.compact(b.a.scratch(), v));
    }
    fn fixed(b: *Builder, v: f64, d: u3) []const u8 {
        return b.a.keep(numfmt.fixed(b.a.scratch(), v, d));
    }
    fn join(b: *Builder, parts: []const []const u8) []const u8 {
        return b.a.join(parts);
    }

    fn readout(b: *Builder, n: u16, left: []const u8, right: []const u8) void {
        b.out.add(.{ .kind = .text, .id = b.id(n), .left = left, .right = right });
    }

    fn button(b: *Builder, n: u16, left: []const u8, right: []const u8, act: G.Action, repeat: bool) void {
        b.out.add(.{
            .kind = .button,
            .id = b.id(n),
            .left = left,
            .right = right,
            .act = act,
            .enabled = G.enabled(b.g, act),
            .repeat = repeat,
        });
    }

    /// Free text, wrapped over as many lines as it needs (at most 4).
    fn note(b: *Builder, n: u16, s: []const u8, strong: bool) void {
        var spans: [4]text.Span = undefined;
        const lines = @min(text.wrap(s, note_cols, &spans), spans.len);
        b.out.add(.{ .kind = .note, .id = b.id(n), .left = s, .lines = @intCast(@max(1, lines)), .strong = strong });
    }

    fn heading(b: *Builder, n: u16, s: []const u8) void {
        b.out.add(.{ .kind = .heading, .id = b.id(n), .left = s });
    }

    // BUSINESS: Make Paperclip and the Business panel.
    fn business(b: *Builder) void {
        const g = b.g;
        b.button(0, "Make Paperclip", "", .make_paperclip, false);
        b.readout(1, "Available Funds", b.money(g.funds));
        if (g.panels.rev_per_sec_div) {
            b.readout(2, "Avg. Rev. per sec", b.money(g.avg_rev));
            b.readout(3, "Avg. Clips Sold/sec", b.int(g.avg_sales));
        }
        b.readout(4, "Unsold Inventory", b.int(g.unsold_clips));
        b.out.add(.{
            .kind = .value,
            .id = b.id(5),
            .left = "Price per Clip",
            .right = b.money(g.margin),
            .act = .raise_price,
            .act_b = .lower_price,
            .enabled = G.enabled(g, .raise_price),
            .enabled_b = G.enabled(g, .lower_price),
            .repeat = true,
        });
        b.readout(6, "Public Demand", b.join(&.{ b.int(g.demand * 10), "%" }));
        b.button(7, "Marketing", b.join(&.{ "Level ", b.int(g.marketing_lvl) }), .buy_ads, true);
        b.readout(8, "  Cost", b.money(g.ad_cost));
    }

    // MANUFACTURING (stage 1): clips per second, wire, the clippers.
    fn manufacturing(b: *Builder) void {
        const g = b.g;
        b.readout(0, "Clips per Second", b.int(g.clip_rate));
        if (g.panels.wire_buyer_div)
            b.button(1, "WireBuyer", if (g.wire_buyer_status == 1) "ON" else "OFF", .toggle_wire_buyer, false);
        b.button(2, "Wire", b.join(&.{ b.int(g.wire), if (g.wire == 1) " inch" else " inches" }), .buy_wire, true);
        b.readout(3, "  Cost", b.money(g.wire_cost));
        if (g.panels.auto_clipper_div) {
            b.button(4, "AutoClippers", b.int(g.clipmaker_level), .make_clipper, true);
            b.readout(5, "  Cost", b.money(g.clipper_cost));
        }
        if (g.panels.mega_clipper_div) {
            b.button(6, "MegaClippers", b.int(g.mega_clipper_level), .make_mega_clipper, true);
            b.readout(7, "  Cost", b.money(g.mega_clipper_cost));
        }
    }

    // COMPUTING: trust, processors, memory, operations, creativity, quantum.
    fn computing(b: *Builder) void {
        const g = b.g;
        if (g.panels.trust_div) {
            b.readout(0, "Trust", b.int(g.trust));
            b.readout(1, "+1 Trust at", b.join(&.{ b.int(g.next_trust), " clips" }));
        }
        b.button(2, "Processors", b.int(g.processors), .add_proc, true);
        b.button(3, "Memory", b.int(g.memory), .add_mem, true);
        b.readout(4, "Operations", b.join(&.{ b.int(g.operations), " / ", b.int(g.memory * 1000) }));
        if (g.panels.creativity_div) b.readout(5, "Creativity", b.int(@round(g.creativity)));
        if (g.panels.q_computing) {
            b.heading(6, "Quantum Computing");
            b.out.add(.{ .kind = .chips, .id = b.id(7), .lines = 2 });
            b.button(8, "Compute", g.q_comp_display[0..g.q_comp_display_len], .q_compute, false);
        }
    }

    // PROJECTS: the active projects in display order.
    fn projects(b: *Builder) void {
        const g = b.g;
        for (g.active_projects[0..g.active_projects_len]) |i| {
            const d = &G.projects.defs[i];
            b.out.add(.{
                .kind = .project,
                .id = project_id_base + i,
                .left = std.mem.trimEnd(u8, d.title, " "),
                .act = .{ .buy_project = i },
                .enabled = G.enabled(g, .{ .buy_project = i }),
                .detail = b.join(&.{ d.price_tag, " ", d.description }),
            });
        }
        if (g.active_projects_len == 0) b.note(0, "(no projects yet)", false);
    }

    // INVESTMENTS: risk, deposit, withdraw, cash/stocks/total, the stocks,
    // the engine upgrade.
    fn investments(b: *Builder) void {
        const g = b.g;
        const risk: []const u8 = switch (g.invest_strat) {
            .low => "Low Risk",
            .med => "Med Risk",
            .hi => "High Risk",
        };
        b.out.add(.{
            .kind = .value,
            .id = b.id(0),
            .left = "Strategy",
            .right = risk,
            .act = .{ .set_invest_strat = switch (g.invest_strat) {
                .low => .med,
                .med => .hi,
                .hi => .hi,
            } },
            .act_b = .{ .set_invest_strat = switch (g.invest_strat) {
                .low => .low,
                .med => .low,
                .hi => .med,
            } },
            .enabled = g.invest_strat != .hi,
            .enabled_b = g.invest_strat != .low,
        });
        b.button(1, "Deposit", "", .invest_deposit, false);
        b.button(2, "Withdraw", "", .invest_withdraw, false);
        b.readout(3, "Cash", b.join(&.{ "$", b.int(g.bankroll) }));
        b.readout(4, "Stocks", b.join(&.{ "$", b.int(g.sec_total) }));
        b.out.add(.{ .kind = .text, .id = b.id(5), .left = "Total", .right = b.join(&.{ "$", b.int(g.port_total) }), .strong = true });
        b.out.add(.{ .kind = .stock_head, .id = b.id(6) });
        for (g.stocks[0..g.portfolio_size], 0..) |*s, i| {
            b.out.add(.{
                .kind = .stock,
                .id = b.id(7 + @as(u16, @intCast(i))),
                .left = s.symbol[0..s.symbol_len],
                .right = b.join(&.{ b.compact(@ceil(s.amount)), "|", b.compact(@ceil(s.price)), "|", b.compact(@ceil(s.total)), "|", b.compact(@ceil(s.profit)) }),
            });
        }
        if (g.panels.investment_engine_upgrade) {
            b.button(12, "Upgrade Engine", b.join(&.{ "Level ", b.int(g.invest_level) }), .invest_upgrade, true);
            b.readout(13, "  Cost", b.join(&.{ b.int(g.invest_upgrade_cost), " Yomi" }));
        }
    }

    // STRATEGY: pick, run, new tournament, auto, the grid, results, yomi.
    fn strategy(b: *Builder) void {
        const g = b.g;
        const n = g.strats_len;
        const pick_name: []const u8 = if (g.pick < n) g.strats[g.pick].name else "Pick a Strat";
        // Value row: steps through "Pick a Strat" (10) and the strategies.
        const next: u8 = if (g.pick >= n) 0 else if (g.pick + 1 < n) g.pick + 1 else g.pick;
        const prev: u8 = if (g.pick >= n) 10 else if (g.pick == 0) 10 else g.pick - 1;
        b.out.add(.{
            .kind = .value,
            .id = b.id(0),
            .left = "Strat",
            .right = pick_name,
            .act = .{ .set_strat_pick = next },
            .act_b = .{ .set_strat_pick = prev },
            .enabled = !(g.pick < n and g.pick + 1 >= n),
            .enabled_b = g.pick < n,
        });
        b.button(1, "Run", "", .run_tourney, false);
        if (g.panels.tournament_management) {
            b.button(2, "New Tournament", b.join(&.{ b.int(g.tourney_cost), " ops" }), .new_tourney, false);
            if (g.panels.auto_tourney_control)
                b.button(3, "AutoTourney", if (g.auto_tourney_status == 1) "ON" else "OFF", .toggle_auto_tourney, false);
        }
        b.readout(4, "Yomi", b.int(g.yomi));
        b.note(5, g.tourney_display, false);
        if (g.panels.tournament_table) {
            b.out.add(.{ .kind = .grid, .id = b.id(6), .lines = 4 });
        }
        if (g.panels.tournament_results_table) {
            for (g.results[0..g.results_len], 0..) |si, k| {
                const s = &g.strats[si];
                var nb: [4]u8 = undefined;
                const place = numfmt.plain_u(&nb, k + 1);
                b.out.add(.{
                    .kind = .note,
                    .id = b.id(16 + @as(u16, @intCast(k))),
                    .left = b.join(&.{ place, ". ", s.name, ": ", b.int(s.current_score) }),
                    .strong = si == g.pick,
                });
            }
        }
    }

    // CHEATS: the mirror's cheat buttons (after the title's code).
    fn cheats(b: *Builder) void {
        b.button(0, "Free Clips", "", .cheat_clips, true);
        b.button(1, "Free Money", "", .cheat_money, true);
        b.button(2, "Free Trust", "", .cheat_trust, true);
        b.button(3, "Free Ops", "", .cheat_ops, true);
        b.button(4, "Free Creativity", "", .cheat_creat, true);
        b.button(5, "Free Yomi", "", .cheat_yomi, true);
        b.button(6, "Destroy all Humans", "", .cheat_hypno, false);
    }
};

/// The status line: the few numbers that matter now, most important
/// first, as many as fit in `cols` characters.
pub fn status(g: *const G.Game, a: *text.Arena, cols: usize) []const u8 {
    var parts: [6][]const u8 = undefined;
    var n: usize = 0;
    if (g.human_flag == 1) {
        parts[n] = a.keep(numfmt.money_short(a.scratch(), g.funds));
        n += 1;
        parts[n] = a.join(&.{ "Wire ", a.keep(numfmt.compact(a.scratch(), g.wire)) });
        n += 1;
    }
    if (g.panels.comp_div) {
        parts[n] = a.join(&.{ "Ops ", a.keep(numfmt.compact(a.scratch(), g.operations)) });
        n += 1;
    }
    if (g.panels.creativity_div) {
        parts[n] = a.join(&.{ "Cr ", a.keep(numfmt.compact(a.scratch(), g.creativity)) });
        n += 1;
    }
    if (g.panels.strategy_engine) {
        parts[n] = a.join(&.{ "Yomi ", a.keep(numfmt.compact(a.scratch(), g.yomi)) });
        n += 1;
    }
    // Drop from the end until it fits with two spaces between items.
    while (n > 1) {
        var len: usize = 0;
        for (parts[0..n]) |p| len += p.len;
        len += 2 * (n - 1);
        if (len <= cols) break;
        n -= 1;
    }
    var out: [12][]const u8 = undefined;
    var k: usize = 0;
    for (parts[0..n], 0..) |p, i| {
        if (i > 0) {
            out[k] = "  ";
            k += 1;
        }
        out[k] = p;
        k += 1;
        if (k >= out.len) break;
    }
    return a.join(out[0..k]);
}
