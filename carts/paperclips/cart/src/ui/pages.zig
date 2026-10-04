//! The pages of SPEC section 3: which pages exist right now, and the rows
//! of each, built fresh from the game state every frame. This file is the
//! one place that reads the game's fields for display; render.zig draws
//! the rows and app.zig moves the cursor and presses them.
//!
//! Texts and number formats follow the original's DOM writes (`game.fmt`
//! prints numbers exactly as the browser did); where a row has no room
//! for the original's text, `numfmt` gives a compact form.
const std = @import("std");
const G = @import("game");
const numfmt = @import("numfmt.zig");
const text = @import("text.zig");

const fmt = G.fmt;

pub const Page = enum(u8) {
    business,
    manufacturing,
    factories,
    wire,
    space,
    computing,
    projects,
    investments,
    strategy,
    combat,
    power,
    swarm,
    probe,
    /// Only when no other page holds Make Paperclip (the very end).
    make,
    cheats,

    pub fn title(p: Page) []const u8 {
        return switch (p) {
            .business => "BUSINESS",
            .manufacturing => "MANUFACTURING",
            .factories => "FACTORIES",
            .wire => "WIRE",
            .space => "SPACE",
            .computing => "COMPUTING",
            .projects => "PROJECTS",
            .investments => "INVESTMENTS",
            .strategy => "STRATEGY",
            .combat => "COMBAT",
            .power => "POWER",
            .swarm => "SWARM",
            .probe => "PROBE DESIGN",
            .make => "PAPERCLIPS",
            .cheats => "CHEATS",
        };
    }
};

pub const page_count = @typeInfo(Page).@"enum".field_names.len;

/// Does the page exist now (its panels are shown in the original)?
pub fn visible(g: *const G.Game, p: Page, cheats: bool) bool {
    const v = &g.panels;
    return switch (p) {
        .business => v.business_div,
        .manufacturing => v.manufacturing_div,
        .factories => v.creation_div,
        .wire => v.wire_production_div,
        .space => v.space_div,
        .computing => v.comp_div,
        .projects => v.projects_div,
        .investments => v.investment_engine,
        .strategy => v.strategy_engine or v.tournament_management,
        .combat => v.battle_canvas_div,
        .power => v.power_div,
        .swarm => v.swarm_engine or v.swarm_slider_div,
        .probe => v.probe_design_div or v.increase_probe_trust_div or v.increase_max_trust_div or v.honor_div,
        .make => !v.business_div and !v.creation_div,
        .cheats => cheats,
    };
}

pub const Kind = enum {
    /// A readout: label left, value right.
    text,
    /// A button: A presses it (grey when disabled).
    button,
    /// A value with A raising / B lowering (price, risk, strategy, probe
    /// trust).
    value,
    /// A project button: title; the footer shows its price and description.
    project,
    /// A sub-heading inside a page (a panel title of the original).
    heading,
    /// The ten quantum chips (two text rows tall).
    chips,
    /// The strategy payoff grid (four rows tall).
    grid,
    /// The stock table's column heads / one stock line.
    stock_head,
    stock,
    /// Free text, wrapped over `lines` lines.
    note,
    /// The battle field (combat_view.zig).
    battle,
    /// The work/think slider bar.
    slider,
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
    /// Height in text rows (widgets, wrapped notes).
    lines: u8 = 1,
    /// Emphasis (bold in the original): drawn on a light face.
    strong: bool = false,
    /// The right-hand text's opacity (the quantum display fades), 0..255.
    fade: u8 = 255,
    /// A widget's value (the slider position).
    value: u8 = 0,

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
        .factories => b.factories(),
        .wire => b.wire(),
        .space => b.space(),
        .computing => b.computing(),
        .projects => b.projects(),
        .investments => b.investments(),
        .strategy => b.strategy(),
        .combat => b.combat(),
        .power => b.power(),
        .swarm => b.swarm(),
        .probe => b.probe(),
        .make => b.button(0, "Make Paperclip", "", .make_paperclip, false),
        .cheats => b.cheats(),
    }
}

/// Swarm status texts (updateSwarm); 7 hides the line.
fn swarm_status_text(s: u8) []const u8 {
    return switch (s) {
        0 => "Active",
        1 => "Hungry",
        2 => "Confused",
        3 => "Bored",
        4 => "Cold",
        5 => "Disorganized",
        6 => "Sleeping",
        8 => "Lonely",
        9 => "NO RESPONSE...",
        else => "",
    };
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
    /// toLocaleString() of the value (the caller floors/rounds as the JS
    /// does); compact when it would not fit a row beside a label.
    fn loc(b: *Builder, v: f64) []const u8 {
        const s = fmt.loc(b.a.scratch(), v);
        if (s.len > 16) return b.compact(v);
        return b.a.keep(s);
    }
    /// toLocaleString with exactly two decimals (money).
    fn loc2(b: *Builder, v: f64) []const u8 {
        const s = fmt.loc2(b.a.scratch(), v);
        if (s.len > 16) return b.compact(v);
        return b.a.keep(s);
    }
    /// numberCruncher(v, d): "1.23 million".
    fn crunch(b: *Builder, v: f64, d: u5) []const u8 {
        return b.a.keep(std.mem.trimEnd(u8, fmt.number_cruncher(b.a.scratch(), v, d), " "));
    }
    /// The number as JS prints it (String(v)).
    fn num(b: *Builder, v: f64) []const u8 {
        return b.a.keep(fmt.num_str(b.a.scratch(), v));
    }
    fn compact(b: *Builder, v: f64) []const u8 {
        return b.a.keep(numfmt.compact(b.a.scratch(), v));
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

    /// A button with a hint in the footer (the original's tooltips).
    fn button_tip(b: *Builder, n: u16, left: []const u8, right: []const u8, act: G.Action, repeat: bool, tip: []const u8) void {
        b.button(n, left, right, act, repeat);
        b.out.rows[b.out.n - 1].detail = tip;
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

    // -- stage 1 ---------------------------------------------------------

    // BUSINESS: Make Paperclip and the Business panel.
    fn business(b: *Builder) void {
        const g = b.g;
        b.button(0, "Make Paperclip", "", .make_paperclip, false);
        b.readout(1, "Available Funds", b.join(&.{ "$", b.loc2(g.funds) }));
        if (g.panels.rev_per_sec_div) {
            b.readout(2, "Avg. Rev. per sec", b.join(&.{ "$", b.loc2(g.avg_rev) }));
            b.readout(3, "Avg. Clips Sold/sec", b.loc(@round(g.avg_sales)));
        }
        b.readout(4, "Unsold Inventory", b.loc(@floor(g.unsold_clips)));
        const margin = b.a.keep(fmt.to_fixed(b.a.scratch(), g.margin, 2));
        b.out.add(.{
            .kind = .value,
            .id = b.id(5),
            .left = "Price per Clip",
            .right = b.join(&.{ "$", margin }),
            .act = .raise_price,
            .act_b = .lower_price,
            .enabled = G.enabled(g, .raise_price),
            .enabled_b = G.enabled(g, .lower_price),
            .repeat = true,
        });
        b.readout(6, "Public Demand", b.join(&.{ b.a.keep(fmt.locale(b.a.scratch(), g.demand * 10, 0, 0)), "%" }));
        b.button(7, "Marketing", b.join(&.{ "Level ", b.num(g.marketing_lvl) }), .buy_ads, true);
        b.readout(8, "  Cost", b.join(&.{ "$", b.loc2(g.ad_cost) }));
    }

    // MANUFACTURING (stage 1): clips per second, wire, the clippers.
    fn manufacturing(b: *Builder) void {
        const g = b.g;
        b.readout(1, "Clips per Second", b.loc(g.clip_rate));
        if (g.panels.wire_buyer_div)
            b.button(2, "WireBuyer", if (g.wire_buyer_status == 1) "ON" else "OFF", .toggle_wire_buyer, false);
        b.button(3, "Wire", b.join(&.{ b.loc(@floor(g.wire)), if (g.wire == 1) " inch" else " inches" }), .buy_wire, true);
        b.readout(4, "  Cost", b.join(&.{ "$", b.num(g.wire_cost) }));
        if (g.panels.auto_clipper_div) {
            b.button(5, "AutoClippers", b.num(g.clipmaker_level), .make_clipper, true);
            b.readout(6, "  Cost", b.join(&.{ "$", b.loc2(g.clipper_cost) }));
        }
        if (g.panels.mega_clipper_div) {
            b.button(7, "MegaClippers", b.num(g.mega_clipper_level), .make_mega_clipper, true);
            b.readout(8, "  Cost", b.join(&.{ "$", b.loc2(g.mega_clipper_cost) }));
        }
    }

    // COMPUTING: trust, processors, memory, operations, creativity, quantum.
    fn computing(b: *Builder) void {
        const g = b.g;
        if (g.panels.trust_div) {
            b.readout(0, "Trust", b.loc(@floor(g.trust)));
            b.readout(1, "+1 Trust at", b.join(&.{ b.loc(@floor(g.next_trust)), " clips" }));
        }
        if (g.panels.swarm_gift_div and g.swarm_flag == 1) b.readout(2, "Swarm Gifts", b.crunch(g.swarm_gifts, 2));
        if (g.panels.processor_display) b.button(3, "Processors", b.num(g.processors), .add_proc, true);
        b.button(4, "Memory", b.num(g.memory), .add_mem, true);
        b.readout(5, "Operations", b.join(&.{ b.loc(@floor(g.operations)), " / ", b.loc(g.memory * 1000) }));
        if (g.panels.creativity_div and g.creativity_on) b.readout(6, "Creativity", b.loc(@round(g.creativity)));
        if (g.panels.q_computing) {
            b.heading(7, "Quantum Computing");
            b.out.add(.{ .kind = .chips, .id = b.id(8), .lines = 2 });
            if (g.panels.btn_qcompute) {
                const shown: []const u8 = switch (g.q_comp_display) {
                    .blank => "",
                    .need_chips => "Need Photonic Chips",
                    .qops => b.join(&.{ "qOps: ", b.loc(g.q_comp_value) }),
                };
                b.button(9, "Compute", shown, .q_compute, false);
                const f = std.math.clamp(g.q_fade, 0, 1);
                b.out.rows[b.out.n - 1].fade = @intFromFloat(@round(f * 255));
            }
        }
    }

    // PROJECTS: the active projects in display order.
    fn projects(b: *Builder) void {
        const g = b.g;
        for (g.active[0..g.active_len]) |i| {
            const p: G.P = @enumFromInt(i);
            const title = b.a.keep(G.project_title(g, p, b.a.scratch()));
            const tag = b.a.keep(G.project_price_tag(g, p, b.a.scratch()));
            b.out.add(.{
                .kind = .project,
                .id = project_id_base + i,
                .left = std.mem.trimEnd(u8, title, " "),
                .act = .{ .buy_project = i },
                .enabled = G.enabled(g, .{ .buy_project = i }),
                .detail = b.join(&.{ tag, " ", G.project_description(p) }),
            });
        }
        if (g.active_len == 0) b.note(0, "(no projects yet)", false);
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
            .left = "Risk",
            .right = risk,
            .act = .{ .set_invest_strat = switch (g.invest_strat) {
                .low => .med,
                .med, .hi => .hi,
            } },
            .act_b = .{ .set_invest_strat = switch (g.invest_strat) {
                .low, .med => .low,
                .hi => .med,
            } },
            .enabled = g.invest_strat != .hi,
            .enabled_b = g.invest_strat != .low,
        });
        b.button(1, "Deposit", "", .invest_deposit, false);
        b.button(2, "Withdraw", "", .invest_withdraw, false);
        b.readout(3, "Cash", b.join(&.{ "$", b.loc(g.bankroll) }));
        b.readout(4, "Stocks", b.join(&.{ "$", b.loc(g.sec_total) }));
        b.out.add(.{ .kind = .text, .id = b.id(5), .left = "Total", .right = b.join(&.{ "$", b.loc(g.port_total) }), .strong = true });
        b.out.add(.{ .kind = .stock_head, .id = b.id(6) });
        for (g.stocks[0..g.stocks_len], 0..) |*s, i| {
            b.out.add(.{
                .kind = .stock,
                .id = b.id(7 + @as(u16, @intCast(i))),
                .left = s.sym(),
                .right = b.join(&.{ b.compact(@ceil(s.amount)), "|", b.compact(@ceil(s.price)), "|", b.compact(@ceil(s.total)), "|", b.compact(@ceil(s.profit)) }),
            });
        }
        if (g.panels.investment_engine_upgrade) {
            b.button(12, "Upgrade Engine", b.join(&.{ "Level ", b.num(g.invest_level) }), .invest_upgrade, true);
            b.readout(13, "  Cost", b.join(&.{ b.loc(g.invest_upgrade_cost), " Yomi" }));
        }
    }

    // STRATEGY: pick, run, new tournament, auto, the grid, results, yomi.
    fn strategy(b: *Builder) void {
        const g = b.g;
        if (g.panels.strategy_engine) {
            const n = g.strat_count;
            const v = g.strat_picker;
            const pick_name: []const u8 = if (v < n) G.strategy.names[v] else "Pick a Strat";
            // The select: "Pick a Strat" (10), then the strategies in order.
            const next: u8 = if (v >= n) 0 else if (v + 1 < n) v + 1 else v;
            const prev: u8 = if (v >= n or v == 0) 10 else v - 1;
            b.out.add(.{
                .kind = .value,
                .id = b.id(0),
                .left = "Strat",
                .right = pick_name,
                .act = .{ .set_strat_pick = next },
                .act_b = .{ .set_strat_pick = prev },
                .enabled = next != v,
                .enabled_b = v < n,
            });
            b.button(1, "Run", "", .run_tourney, false);
        }
        if (g.panels.tournament_management) {
            b.button(2, "New Tournament", b.join(&.{ b.loc(g.tourney_cost), " ops" }), .new_tourney, false);
            if (g.panels.auto_tourney_control)
                b.button(3, "AutoTourney", if (g.auto_tourney_status == 1) "ON" else "OFF", .toggle_auto_tourney, false);
        }
        if (!g.panels.strategy_engine) return;
        b.readout(4, "Yomi", b.loc(g.yomi));
        const report = switch (g.tourney_report) {
            .round => b.join(&.{ "Round ", b.num(g.tourney_report_round) }),
            // "roll over for the grid": on the badge, A on the results.
            .results_payoff, .results_grid => "TOURNAMENT RESULTS (A: payoff grid)",
            else => g.tourney_report.text(),
        };
        b.note(5, report, false);
        if (g.panels.tournament_table) {
            // After a tournament the grid is the "roll over" view: A goes
            // back to the results (the original's mouse out).
            b.out.add(.{ .kind = .grid, .id = b.id(6), .lines = 4, .act = if (g.results_flag == 1) .reveal_results else null });
        }
        if (g.panels.tournament_results_table) {
            var k: usize = 0;
            while (k < g.results_shown) : (k += 1) {
                const si = g.results[k];
                var nb: [4]u8 = undefined;
                const place = numfmt.plain_u(&nb, k + 1);
                b.out.add(.{
                    .kind = .note,
                    .id = b.id(16 + @as(u16, @intCast(k))),
                    .left = b.join(&.{ place, ". ", G.strategy.names[si], ": ", b.num(g.strat_score[si]) }),
                    .strong = si == g.results_bold,
                    // A on a result line: the original's roll over (grid).
                    .act = .reveal_grid,
                });
            }
        }
    }

    // -- stage 2 ---------------------------------------------------------

    // FACTORIES: the stage-2 Manufacturing panel (creationDiv).
    fn factories(b: *Builder) void {
        const g = b.g;
        const pn = &g.panels;
        if (!pn.business_div) b.button(0, "Make Paperclip", "", .make_paperclip, false);
        if (pn.factory_upgrade_display) b.readout(1, "Next Upgrade at", b.join(&.{ b.loc(g.next_factory_upgrade), " Fact." }));
        if (pn.clips_per_sec_div) b.readout(2, "Clips per Second", b.crunch(g.clip_rate, 2));
        if (pn.toth_div) b.readout(3, "Unused Clips", b.crunch(g.unused_clips, 2));
        if (pn.factory_div) {
            b.button(4, "Clip Factory", b.num(g.factory_level), .make_factory, true);
            b.button_tip(5, "  Disassemble All", "", .factory_reboot, false, b.join(&.{ "+", b.crunch(g.factory_bill, 2), " clips" }));
            b.readout(6, "  Cost", b.join(&.{ b.crunch(g.factory_cost, 2), " clips" }));
        }
        if (pn.wire_trans_div) b.readout(7, "Wire", b.join(&.{ b.crunch(g.wire, 2), if (g.wire == 1) " inch" else " inches" }));
        if (pn.factory_div_space) b.readout(8, "Factories", b.crunch(@floor(g.factory_level), 2));
    }

    // WIRE: the Wire Production panel.
    fn wire(b: *Builder) void {
        const g = b.g;
        const pn = &g.panels;
        if (pn.drone_upgrade_display) b.readout(0, "Next Upgrade at", b.join(&.{ b.loc(g.next_drone_upgrade), " Drones" }));
        b.readout(1, "Avail. Matter", b.join(&.{ b.crunch(g.available_matter, 2), " g" }));
        if (pn.mdps_div) b.readout(2, "", b.join(&.{ "(", b.crunch(g.disp_mdps, 2), " g per sec)" }));
        b.readout(3, "Acq. Matter", b.join(&.{ b.crunch(g.acquired_matter, 2), " g" }));
        b.readout(4, "", b.join(&.{ "(", b.crunch(g.disp_maps, 2), " g per sec)" }));
        b.readout(5, "Wire", b.join(&.{ b.crunch(g.wire, 2), " in" }));
        b.readout(6, "", b.join(&.{ "(", b.crunch(g.disp_wpps, 2), " in per sec)" }));
        if (pn.harvester_div) {
            b.button(7, "Harvester Drone", b.loc(g.harvester_level), .{ .make_harvester = 1 }, true);
            b.button(8, "  Harvesters +10", "", .{ .make_harvester = 10 }, true);
            b.button(9, "  Harvesters +100", "", .{ .make_harvester = 100 }, true);
            b.button(10, "  Harvesters +1k", "", .{ .make_harvester = 1000 }, true);
            b.button_tip(11, "  Disassemble All", "", .harvester_reboot, false, b.join(&.{ "+", b.crunch(g.harvester_bill, 2), " clips" }));
            b.readout(12, "  Cost", b.join(&.{ b.crunch(g.harvester_cost, 2), " clips" }));
        }
        if (pn.wire_drone_div) {
            b.button(13, "Wire Drone", b.loc(g.wire_drone_level), .{ .make_wire_drone = 1 }, true);
            b.button(14, "  Wire Drones +10", "", .{ .make_wire_drone = 10 }, true);
            b.button(15, "  Wire Drones +100", "", .{ .make_wire_drone = 100 }, true);
            b.button(16, "  Wire Drones +1k", "", .{ .make_wire_drone = 1000 }, true);
            b.button_tip(17, "  Disassemble All", "", .wire_drone_reboot, false, b.join(&.{ "+", b.crunch(g.wire_drone_bill, 2), " clips" }));
            b.readout(18, "  Cost", b.join(&.{ b.crunch(g.wire_drone_cost, 2), " clips" }));
        }
        if (pn.drone_div_space) {
            b.readout(19, "Harvester Drones", b.crunch(@floor(g.harvester_level), 2));
            b.readout(20, "Wire Drones", b.crunch(@floor(g.wire_drone_level), 2));
        }
    }

    // POWER: performance, consumption, production, farms, batteries.
    fn power(b: *Builder) void {
        const g = b.g;
        b.readout(0, "Performance", b.join(&.{ b.loc(G.performance(g)), "%" }));
        b.readout(1, "Consumption", b.join(&.{ b.loc(@round(g.power_demand * 100)), " MW" }));
        b.readout(2, "  Factories", b.join(&.{ b.loc(@round(g.power_f_demand * 100)), " MW" }));
        b.readout(3, "  Drones", b.join(&.{ b.loc(@round(g.power_d_demand * 100)), " MW" }));
        b.readout(4, "Production", b.join(&.{ b.loc(@round(g.power_supply * 100)), " MW" }));
        b.button(5, "Solar Farm", b.loc(g.farm_level), .{ .make_farm = 1 }, true);
        b.button(6, "  Solar Farms +10", "", .{ .make_farm = 10 }, true);
        b.button(7, "  Solar Farms +100", "", .{ .make_farm = 100 }, true);
        b.button_tip(8, "  Disassemble All", "", .farm_reboot, false, b.join(&.{ "+", b.crunch(g.farm_bill, 2), " clips" }));
        b.readout(9, "  Cost", b.join(&.{ b.crunch(g.farm_cost, 2), " clips" }));
        b.readout(10, "Storage", b.join(&.{ b.compact(@round(g.stored_power)), " / ", b.compact(@round(g.power_cap)) }));
        b.button(11, "Battery Tower", b.loc(g.battery_level), .{ .make_battery = 1 }, true);
        b.button(12, "  Batteries +10", "", .{ .make_battery = 10 }, true);
        b.button(13, "  Batteries +100", "", .{ .make_battery = 100 }, true);
        b.button_tip(14, "  Disassemble All", "", .battery_reboot, false, b.join(&.{ "+", b.crunch(g.battery_bill, 2), " clips" }));
        b.readout(15, "  Cost", b.join(&.{ b.crunch(g.battery_cost, 2), " clips" }));
    }

    // SWARM: Swarm Computing and the work/think slider.
    fn swarm(b: *Builder) void {
        const g = b.g;
        const pn = &g.panels;
        if (pn.swarm_engine) {
            b.readout(0, "Drones", b.crunch(g.swarm_size, 2));
            if (pn.swarm_status_div) b.readout(1, "Status", swarm_status_text(g.swarm_status));
            if (pn.gift_timer) b.note(2, b.join(&.{ "Next gift in ", b.a.keep(fmt.time_cruncher(b.a.scratch(), g.gift_countdown)) }), false);
            // Feed, Teach and Clad have no handler in the original (the
            // JS functions do not exist): shown, pressing does nothing.
            if (pn.feed_button_div) b.out.add(.{ .kind = .button, .id = b.id(3), .left = "Feed the Swarm", .right = "0 MWs" });
            if (pn.teach_button_div) b.out.add(.{ .kind = .button, .id = b.id(4), .left = "Teach the Swarm", .right = "0 MWs" });
            if (pn.entertain_button_div) b.button(5, "Entertain Swarm", b.join(&.{ b.loc(g.entertain_cost), " creat" }), .entertain_swarm, false);
            if (pn.clad_button_div) b.out.add(.{ .kind = .button, .id = b.id(6), .left = "Clad the Swarm", .right = "0 MWs" });
            if (pn.synch_button_div) b.button(7, "Synchronize Swarm", "5,000 yomi", .synch_swarm, false);
        }
        if (pn.swarm_slider_div) {
            const v: u8 = @intFromFloat(std.math.clamp(g.slider_value, 0, 200));
            b.out.add(.{
                .kind = .slider,
                .id = b.id(8),
                .left = "Work",
                .right = "Think",
                .act = .{ .set_slider = @min(200, v + 5) },
                .act_b = .{ .set_slider = if (v >= 5) v - 5 else 0 },
                .enabled = v < 200,
                .enabled_b = v > 0,
                .repeat = true,
                .value = v,
            });
        }
    }

    // -- stage 3 ---------------------------------------------------------

    // SPACE: Space Exploration.
    fn space(b: *Builder) void {
        const g = b.g;
        const pn = &g.panels;
        b.note(0, b.join(&.{ b.a.keep(fmt.to_fixed(b.a.scratch(), G.colonized(g), 12)), "% of universe explored" }), true);
        b.button(1, "Launch Probe", "", .make_probe, true);
        b.readout(2, "  Cost", b.join(&.{ b.crunch(g.probe_cost, 2), " clips" }));
        b.readout(3, "Launched", b.crunch(g.probe_launch_level, 2));
        b.readout(4, "Descendents", b.crunch(g.probe_descendents, 2));
        if (pn.hazard_body_count) b.readout(5, "Lost to hazards", b.join(&.{ "(", b.crunch(g.probes_lost_haz, 2), ")" }));
        if (pn.drift_body_count) b.readout(6, "Lost to drift", b.join(&.{ "(", b.crunch(g.probes_lost_drift, 2), ")" }));
        if (pn.combat_body_count) b.readout(7, "Lost in combat", b.join(&.{ "(", b.crunch(g.probes_lost_combat, 2), ")" }));
        b.readout(8, "Total", b.crunch(g.probe_count, 2));
        if (pn.drifter_div) {
            b.readout(9, "Drifters Killed", b.crunch(g.drifters_killed, 2));
            b.readout(10, "Drifters", b.crunch(g.drifter_count, 2));
        }
    }

    // PROBE DESIGN: trust allocation, increase trust, max trust, honor.
    fn probe(b: *Builder) void {
        const g = b.g;
        const pn = &g.panels;
        if (pn.probe_design_div) {
            b.readout(0, "Trust", b.join(&.{ b.num(g.probe_used_trust), " / ", b.num(g.probe_trust), " (", b.loc(g.max_trust), " Max)" }));
            const Stat = struct { s: G.ProbeStat, name: []const u8, tip: []const u8 };
            const stats = [_]Stat{
                .{ .s = .speed, .name = "Speed", .tip = "Modifies rate of exploration" },
                .{ .s = .nav, .name = "Exploration", .tip = "Rate at which probes gain access to new matter" },
                .{ .s = .rep, .name = "Self-Replication", .tip = "Rate at which probes generate more probes (each new probe costs 100 quadrillion clips)" },
                .{ .s = .haz, .name = "Hazard Remediation", .tip = "Reduces damage from dust, junk, radiation, and general entropic decay" },
                .{ .s = .fac, .name = "Factory Production", .tip = "Rate at which probes build factories (each new factory costs 100 million clips)" },
                .{ .s = .harv, .name = "Harvester Drone Prod", .tip = "Rate at which probes spawn Harvester Drones (each new drone costs 2 million clips)" },
                .{ .s = .wire, .name = "Wire Drone Prod", .tip = "Rate at which probes spawn Wire Drones (each new drone costs 2 million clips)" },
                .{ .s = .combat, .name = "Combat", .tip = "Determines offensive and defensive effectiveness in battle" },
            };
            for (stats, 0..) |st, i| {
                if (st.s == .combat and !pn.combat_button_div) continue;
                const v: f64 = switch (st.s) {
                    .speed => g.probe_speed,
                    .nav => g.probe_nav,
                    .rep => g.probe_rep,
                    .haz => g.probe_haz,
                    .fac => g.probe_fac,
                    .harv => g.probe_harv,
                    .wire => g.probe_wire,
                    .combat => g.probe_combat,
                };
                b.out.add(.{
                    .kind = .value,
                    .id = b.id(1 + @as(u16, @intCast(i))),
                    .left = st.name,
                    .right = b.num(v),
                    .act = .{ .probe_stat_up = st.s },
                    .act_b = .{ .probe_stat_down = st.s },
                    .enabled = G.enabled(g, .{ .probe_stat_up = st.s }),
                    .enabled_b = G.enabled(g, .{ .probe_stat_down = st.s }),
                    .detail = st.tip,
                });
            }
        }
        if (pn.increase_probe_trust_div) {
            b.button(10, "Increase Probe Trust", "", .increase_probe_trust, true);
            b.readout(11, "  Cost", b.join(&.{ b.loc(@floor(g.probe_trust_cost)), " yomi" }));
        }
        if (pn.increase_max_trust_div) {
            b.button(12, "Increase Max Trust", "", .increase_max_trust, true);
            b.readout(13, "  Cost", b.join(&.{ b.loc(g.max_trust_cost), " honor" }));
        }
        if (pn.honor_div) b.readout(14, "Honor", b.loc(@round(g.honor)));
    }

    // COMBAT: the battle drawn from the game's ships.
    fn combat(b: *Builder) void {
        const g = b.g;
        b.out.add(.{ .kind = .battle, .id = b.id(0), .lines = 7 });
        var o = fmt.Out.init(b.a.scratch());
        g.battle_name.write(&o);
        const name = b.a.keep(o.slice());
        b.readout(1, name, b.join(&.{ "Scale ", b.crunch(g.unit_size, 0), ":1" }));
        if (g.panels.victory_div and g.victory_visible) {
            const res: []const u8 = if (g.battle_result == .victory) "VICTORY" else "DEFEAT";
            b.readout(2, res, b.join(&.{ if (g.battle_result == .victory) "+" else "", b.loc(g.honor_amount), " honor" }));
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
        b.button(6, "Reset Prestige", "", .reset_prestige, false);
        b.button(7, "Destroy all Humans", "", .cheat_hypno, false);
        b.button(8, "Free Prestige U", "", .cheat_prestige_u, false);
        b.button(9, "Free Prestige S", "", .cheat_prestige_s, false);
        b.button(10, "Battle Number 1 to 7", "", .set_battle_number, false);
        b.button(11, "Avail Matter to 0", "", .zero_matter, false);
    }
};

/// The status line: the few numbers that matter now, most important
/// first, as many as fit in `cols` characters.
pub fn status(g: *const G.Game, a: *text.Arena, cols: usize) []const u8 {
    var parts: [6][]const u8 = undefined;
    var n: usize = 0;
    const S = struct {
        fn c(ar: *text.Arena, v: f64) []const u8 {
            return ar.keep(numfmt.compact(ar.scratch(), v));
        }
    };
    if (g.human_flag == 1) {
        parts[n] = a.keep(numfmt.money_short(a.scratch(), g.funds));
        n += 1;
        parts[n] = a.join(&.{ "Wire ", S.c(a, g.wire) });
        n += 1;
    } else {
        parts[n] = a.join(&.{ "Clips ", S.c(a, g.unused_clips) });
        n += 1;
        if (g.space_flag == 1) {
            parts[n] = a.join(&.{ "Probes ", S.c(a, g.probe_count) });
            n += 1;
        } else {
            parts[n] = a.join(&.{ "Wire ", S.c(a, g.wire) });
            n += 1;
        }
    }
    if (g.panels.comp_div) {
        parts[n] = a.join(&.{ "Ops ", S.c(a, @floor(g.operations)) });
        n += 1;
    }
    if (g.panels.creativity_div and g.creativity_on) {
        parts[n] = a.join(&.{ "Cr ", S.c(a, @round(g.creativity)) });
        n += 1;
    }
    if (g.panels.strategy_engine) {
        parts[n] = a.join(&.{ "Yomi ", S.c(a, g.yomi) });
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
    }
    return a.join(out[0..k]);
}
