//! Universal Paperclips (Frank Lantz & Bennett Foddy, 2017), the game
//! logic of `reference/*.js` ported to Zig with no screen and no cart API
//! (host-testable). SPEC.md sections 1, 4 and 5; PLAN.md "Interface".
//!
//! - Every JS global is a field of `Game` in snake_case, same meaning,
//!   numbers as f64 like JS (flags as u8/bool).
//! - `init` is the page load, `advance_ms` runs the virtual clock: each
//!   millisecond fires the due timers in registration order (combat 16 ms,
//!   stock display 100, stock shop 1000, stock sell 2500, strategy pick
//!   100, main loop 10, slow loop 100, then the tournament timeouts).
//! - `act` is a click: it does nothing when `enabled` is false (the
//!   button's `disabled`, kept exactly where the JS sets it).
//! - `g.panels` holds every element whose `style.display` (or
//!   `visibility`) the JS toggles, true = shown. Before the first 10 ms
//!   tick everything shows, as in the browser.
//! - `Math.random` is the SPEC xorshift64* (`g.rand()`), called at the
//!   same places, the same number of times.
//! - Messages: `message(age)`, newest first, plus `msg_count`.

const std = @import("std");
pub const rng_mod = @import("rng.zig");
pub const jsmath = @import("jsmath.zig");
pub const fmt = @import("fmt.zig");
pub const projects = @import("projects.zig");
pub const combat = @import("combat.zig");
pub const stocks = @import("stocks.zig");
pub const strategy = @import("strategy.zig");
/// The heuristic autoplayer (tests, scripts, benchmarks).
pub const bot = @import("bot.zig");
/// Heavy stage-2/3 states set up directly (benchmarks, previews).
pub const prepare = @import("prepare.zig");
/// IEEE f64 add/mul/compare for the badge (exported as __aeabi_* there).
pub const softfloat = @import("softfloat.zig");

comptime {
    _ = softfloat; // its exports (badge builds only)
}

pub const P = projects.P;
pub const InvestStrat = stocks.InvestStrat;

const pow = jsmath.pow;
const floor = jsmath.floor;
const ceil = jsmath.ceil;
const round = jsmath.round;

// ---------------------------------------------------------------------------
// Buttons with a `disabled` state the JS sets.

pub const Btn = enum(u8) {
    btn_add_mem,
    btn_add_proc,
    btn_battery_reboot,
    btn_battery_x10,
    btn_battery_x100,
    btn_buy_wire,
    btn_entertain_swarm,
    btn_expand_marketing,
    btn_factory_reboot,
    btn_farm_reboot,
    btn_farm_x10,
    btn_farm_x100,
    btn_harvester_reboot,
    btn_harvester_x10,
    btn_harvester_x100,
    btn_harvester_x1000,
    btn_improve_investments,
    btn_increase_max_trust,
    btn_increase_probe_trust,
    btn_lower_price,
    btn_make_battery,
    btn_make_clipper,
    btn_make_factory,
    btn_make_farm,
    btn_make_harvester,
    btn_make_mega_clipper,
    btn_make_paperclip,
    btn_make_probe,
    btn_make_wire_drone,
    btn_new_tournament,
    btn_run_tournament,
    btn_synch_swarm,
    btn_wire_drone_reboot,
    btn_wire_drone_x10,
    btn_wire_drone_x100,
    btn_wire_drone_x1000,
    btn_lower_probe_speed,
    btn_lower_probe_nav,
    btn_lower_probe_rep,
    btn_lower_probe_haz,
    btn_lower_probe_fac,
    btn_lower_probe_harv,
    btn_lower_probe_wire,
    btn_lower_probe_combat,
    btn_raise_probe_speed,
    btn_raise_probe_nav,
    btn_raise_probe_rep,
    btn_raise_probe_haz,
    btn_raise_probe_fac,
    btn_raise_probe_harv,
    btn_raise_probe_wire,
    btn_raise_probe_combat,
};
const btn_count = @typeInfo(Btn).@"enum".field_names.len;

/// Every element whose `style.display` the JS toggles (true = shown,
/// `display = ""`), named after its id in snake_case. `victory_div` is the
/// `visibility` one.
pub const Panels = struct {
    auto_clipper_div: bool = true,
    auto_tourney_control: bool = true,
    auto_tourney_status_div: bool = true,
    battle_canvas_div: bool = true,
    btn_qcompute: bool = true,
    business_div: bool = true,
    clad_button_div: bool = true,
    clips_per_sec_div: bool = true,
    combat_body_count: bool = true,
    combat_button_div: bool = true,
    comp_div: bool = true,
    cover: bool = true,
    creation_div: bool = true,
    creativity_div: bool = true,
    drift_body_count: bool = true,
    drifter_div: bool = true,
    drone_div_space: bool = true,
    drone_upgrade_display: bool = true,
    entertain_button_div: bool = true,
    factory_div: bool = true,
    factory_div_space: bool = true,
    factory_upgrade_display: bool = true,
    feed_button_div: bool = true,
    gift_timer: bool = true,
    harvester_div: bool = true,
    hazard_body_count: bool = true,
    honor_div: bool = true,
    hypno_drone_event_div: bool = false,
    increase_max_trust_div: bool = true,
    increase_probe_trust_div: bool = true,
    investment_engine: bool = true,
    investment_engine_upgrade: bool = true,
    manufacturing_div: bool = true,
    mdps_div: bool = true,
    mega_clipper_div: bool = true,
    power_div: bool = true,
    prestige_div: bool = true,
    probe_design_div: bool = true,
    processor_display: bool = true,
    projects_div: bool = true,
    q_chip: [10]bool = @splat(true),
    q_computing: bool = true,
    rev_per_sec_div: bool = true,
    space_div: bool = true,
    strategy_engine: bool = true,
    swarm_engine: bool = true,
    swarm_gift_div: bool = true,
    swarm_slider_div: bool = true,
    swarm_status_div: bool = true,
    synch_button_div: bool = true,
    teach_button_div: bool = true,
    toth_div: bool = true,
    tournament_management: bool = true,
    tournament_results_table: bool = true,
    tournament_table: bool = true,
    trust_div: bool = true,
    victory_div: bool = true,
    wire_buyer_div: bool = true,
    wire_drone_div: bool = true,
    wire_production_div: bool = true,
    wire_trans_div: bool = true,
};

pub const ProbeStat = enum(u8) { speed, nav, rep, haz, fac, harv, wire, combat };

/// One per onclick handler (plus the selects and the slider).
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
    /// Index into `projects.defs` (`@intFromEnum(P.p40b)`), must be active.
    buy_project: u8,
    invest_deposit,
    invest_withdraw,
    invest_upgrade,
    set_invest_strat: InvestStrat,
    /// The `stratPicker` select value: 10 ("Pick a Strat") or 0..strats-1.
    /// `pick` follows on the next 100 ms read, as in the JS.
    set_strat_pick: u8,
    new_tourney,
    run_tourney,
    toggle_auto_tourney,
    /// Mouse over / out of the tournament box (the grid vs results swap).
    reveal_grid,
    reveal_results,
    make_factory,
    factory_reboot,
    /// 1, 10, 100 or 1000.
    make_harvester: u32,
    make_wire_drone: u32,
    harvester_reboot,
    wire_drone_reboot,
    /// 1, 10 or 100.
    make_farm: u32,
    make_battery: u32,
    farm_reboot,
    battery_reboot,
    entertain_swarm,
    synch_swarm,
    /// The work/think range input, 0..200.
    set_slider: u8,
    make_probe,
    probe_stat_up: ProbeStat,
    probe_stat_down: ProbeStat,
    increase_probe_trust,
    increase_max_trust,
    /// RESET ALL PROGRESS (prestige kept, like the page reload).
    reset_all,
    cheat_clips,
    cheat_money,
    cheat_trust,
    cheat_ops,
    cheat_creat,
    cheat_yomi,
    reset_prestige,
    cheat_hypno,
    cheat_prestige_u,
    cheat_prestige_s,
    set_battle_number,
    zero_matter,
};

pub const QChip = struct {
    wave_seed: f64,
    value: f64 = 0,
    active: f64 = 0,
};

pub const QCompDisplay = enum(u8) { blank, need_chips, qops };

/// A setTimeout/setInterval made at run time, fired after the seven fixed
/// intervals in creation order: the tournament chain, the project blink
/// (30 ms, `blink()`), the HypnoDrones overlay blink (32 ms, `longBlink`).
const Timer = struct {
    due: u64,
    kind: Kind,
    proj: u8 = 0,
    gen: u16 = 0,

    const Kind = enum(u8) { clear_grid, round_loop, blink, long_blink };
};

const msg_buf_len = 4096;
const msg_max = 64;

const MsgEntry = struct { start: u16, len: u16 };

pub const Game = struct {
    // ---- clock and RNG ----
    now_ms: u64 = 0,
    /// The page (re)load time: the fixed intervals run from here (a reload
    /// registers them anew, the clock goes on).
    load_ms: u64 = 0,
    rng: rng_mod.Rng = rng_mod.Rng.init(1),
    timers: [32]Timer,
    timers_len: u8 = 0,
    /// Bumped by every restart (project 200/201/217, RESET): the page
    /// reload of the original. The UI can go back to the title.
    restarts: u32 = 0,
    /// localStorage "savePrestige" exists (session-only here).
    has_save_prestige: bool = false,
    /// `longBlinkCounter`: the "Release the HypnoDrones" overlay
    /// (`panels.hypno_drone_event_div`, toggled every 32 ms): its text is
    /// "Release" (counter 0..30), "<br /><br /><br />Release" (31..39),
    /// "<br />Release" (46..54), "Release<br/>the<br/>Hypno<br/>Drones" (56+),
    /// unchanged in between.
    long_blink_counter: f64 = 0,
    /// `blinkCounter`, shared by every project blink.
    blink_counter: f64 = 0,
    /// Set by a project/button that calls `reset()`; `act` restarts.
    restart_pending: bool = false,

    // ---- messages (console) ----
    msg_buf: [msg_buf_len]u8,
    msg_entries: [msg_max]MsgEntry,
    msg_first: u16 = 0, // oldest entry index in the ring
    msg_len: u16 = 0,
    msg_write: u16 = 0,
    /// Messages ever displayed, across restarts (each page load's welcome
    /// line counts once).
    msg_count: u32 = 0,

    // ---- DOM state ----
    panels: Panels = .{},
    disabled: [btn_count]bool = @splat(false),

    // ---- globals.js ----
    clips: f64 = 0,
    unused_clips: f64 = 0,
    clip_rate: f64 = 0,
    clip_rate_temp: f64 = 0,
    prev_clips: f64 = 0,
    clip_rate_tracker: f64 = 0,
    clipmaker_rate: f64 = 0,
    clipmaker_level: f64 = 0,
    clipper_cost: f64 = 5,
    unsold_clips: f64 = 0,
    funds: f64 = 0,
    margin: f64 = 0.25,
    wire: f64 = 1000,
    wire_cost: f64 = 20,
    ad_cost: f64 = 100,
    demand: f64 = 5,
    clips_sold: f64 = 0,
    avg_rev: f64 = 0,
    income: f64 = 0,
    income_tracker: [11]f64,
    income_tracker_len: u8 = 1,
    ticks: f64 = 0,
    marketing: f64 = 1,
    marketing_lvl: f64 = 1,
    clippper_cost: f64 = 5,
    processors: f64 = 1,
    memory: f64 = 1,
    operations: f64 = 0,
    trust: f64 = 2,
    next_trust: f64 = 3000,
    transaction: f64 = 1,
    clipper_boost: f64 = 1,
    creativity: f64 = 0,
    creativity_on: bool = false,
    boost_lvl: f64 = 0,
    wire_purchase: f64 = 0,
    wire_supply: f64 = 1000,
    marketing_effectiveness: f64 = 1,
    milestone_flag: f64 = 0,
    bankroll: f64 = 0,
    fib1: f64 = 2,
    fib2: f64 = 3,
    strategy_engine_flag: u8 = 0,
    investment_engine_flag: u8 = 0,
    rev_per_sec_flag: u8 = 0,
    comp_flag: u8 = 0,
    projects_flag: u8 = 0,
    auto_clipper_flag: u8 = 0,
    mega_clipper_flag: u8 = 0,
    mega_clipper_cost: f64 = 500,
    mega_clipper_level: f64 = 0,
    mega_clipper_boost: f64 = 1,
    creativity_speed: f64 = 1,
    creativity_counter: f64 = 0,
    wire_buyer_flag: u8 = 0,
    demand_boost: f64 = 1,
    human_flag: u8 = 1,
    nano_wire: f64 = 0,
    wire_production_flag: u8 = 0,
    space_flag: u8 = 0,
    factory_flag: u8 = 0,
    harvester_flag: u8 = 0,
    wire_drone_flag: u8 = 0,
    factory_level: f64 = 0,
    factory_boost: f64 = 1,
    drone_boost: f64 = 1,
    available_matter: f64 = 0, // init: Math.pow(10, 24)*6000
    acquired_matter: f64 = 0,
    processed_matter: f64 = 0,
    harvester_level: f64 = 0,
    wire_drone_level: f64 = 0,
    factory_cost: f64 = 100000000,
    harvester_cost: f64 = 1000000,
    wire_drone_cost: f64 = 1000000,
    factory_rate: f64 = 1000000000,
    harvester_rate: f64 = 26180337,
    wire_drone_rate: f64 = 16180339,
    harvester_bill: f64 = 0,
    wire_drone_bill: f64 = 0,
    factory_bill: f64 = 0,
    probe_count: f64 = 0,
    total_matter: f64 = 0, // init: Math.pow(10, 54)*30
    found_matter: f64 = 0,
    q_flag: u8 = 0,
    q_clock: f64 = 0,
    q_chip_cost: f64 = 10000,
    next_qchip: f64 = 0,
    bribe: f64 = 1000000,
    battle_flag: u8 = 0,
    prestige_u: f64 = 0,
    prestige_s: f64 = 0,
    auto_tourney_flag: u8 = 0,
    toth_flag: u8 = 0,
    wire_price_counter: f64 = 0,
    wire_base_price: f64 = 20,
    farm_rate: f64 = 50,
    battery_size: f64 = 10000,
    factory_power_rate: f64 = 200,
    drone_power_rate: f64 = 1,
    farm_level: f64 = 0,
    battery_level: f64 = 0,
    farm_cost: f64 = 10000000,
    battery_cost: f64 = 1000000,
    stored_power: f64 = 0,
    pow_mod: f64 = 0,
    farm_bill: f64 = 0,
    battery_bill: f64 = 0,
    momentum: u8 = 0,
    swarm_flag: u8 = 0,
    swarm_status: u8 = 7,
    swarm_gifts: f64 = 0,
    next_gift: f64 = 0,
    gift_period: f64 = 125000,
    gift_countdown: f64 = 125000,
    honor: f64 = 0,
    max_trust: f64 = 20,
    max_trust_cost: f64 = 91117.99,
    disorg_counter: f64 = 0,
    disorg_flag: u8 = 0,
    synch_cost: f64 = 5000,
    disorg_msg: u8 = 0,
    threnody_cost: f64 = 50000,
    entertain_cost: f64 = 10000,
    boredom_level: f64 = 0,
    boredom_flag: u8 = 0,
    boredom_msg: u8 = 0,
    wire_buyer_status: u8 = 1,
    wire_price_timer: f64 = 0,
    q_fade: f64 = 1,
    auto_tourney_status: u8 = 1,
    drift_king_message_cost: f64 = 1,
    /// The `slider` range input's value (what the player set).
    slider_value: f64 = 0,
    slider_pos: f64 = 0,
    temp_ops: f64 = 0,
    standard_ops: f64 = 0,
    op_fade: f64 = 0,
    op_fade_timer: f64 = 0,
    op_fade_delay: f64 = 800,
    dismantle: u8 = 0,
    end_timer1: f64 = 0,
    end_timer2: f64 = 0,
    end_timer3: f64 = 0,
    end_timer4: f64 = 0,
    end_timer5: f64 = 0,
    end_timer6: f64 = 0,
    final_clips: f64 = 0,

    // ---- main.js: quantum ----
    q_chips: [10]QChip = .{
        .{ .wave_seed = 0.1 }, .{ .wave_seed = 0.2 }, .{ .wave_seed = 0.3 }, .{ .wave_seed = 0.4 },
        .{ .wave_seed = 0.5 }, .{ .wave_seed = 0.6 }, .{ .wave_seed = 0.7 }, .{ .wave_seed = 0.8 },
        .{ .wave_seed = 0.9 }, .{ .wave_seed = 1 },
    },
    /// `qCompDisplay`: blank, "Need Photonic Chips" or "qOps: " +
    /// Math.ceil(q*360).toLocaleString() (`q_comp_value`); opacity q_fade.
    q_comp_display: QCompDisplay = .blank,
    q_comp_value: f64 = 0,

    // ---- main.js: investments ----
    stocks: [stocks.max_port]stocks.Stock = @splat(.{}),
    stocks_len: u8 = 0,
    invest_strat: InvestStrat = .low,
    portfolio_size: f64 = 0,
    stock_id: f64 = 0,
    sec_total: f64 = 0,
    port_total: f64 = 0,
    sell_delay: f64 = 0,
    riskiness: f64 = 5,
    max_port: f64 = 5,
    m: f64 = 0,
    invest_level: f64 = 0,
    invest_upgrade_cost: f64 = 100,
    stock_gain_threshold: f64 = 0.5,
    ledger: f64 = 0,
    stock_report_counter: f64 = 0,

    // ---- main.js: strategy ----
    tourney_cost: f64 = 1000,
    tourney_lvl: f64 = 1,
    strat_counter: f64 = 0,
    h_move: f64 = 1,
    v_move: f64 = 1,
    h_move_prev: f64 = 1,
    v_move_prev: f64 = 1,
    aa: f64 = 0,
    ab: f64 = 0,
    ba: f64 = 0,
    bb: f64 = 0,
    rounds: f64 = 0,
    current_round: f64 = 0,
    r_counter: f64 = 0,
    tourney_in_prog: u8 = 0,
    winner_ptr: f64 = 0,
    place_score: f64 = 0,
    show_score: f64 = 0,
    high: f64 = 0,
    pick: f64 = 10,
    /// The `stratPicker` select value (pick reads it every 100 ms).
    strat_picker: u8 = 10,
    yomi: f64 = 0,
    yomi_boost: f64 = 1,
    /// `strats.length` (strats[i] is always allStrats[i]).
    strat_count: u8 = 1,
    strat_score: [strategy.max_strats]f64 = @splat(0),
    strat_pos: [strategy.max_strats]f64 = @splat(1),
    h_strat: usize = 0,
    v_strat: usize = 0,
    h: f64 = 0,
    v: f64 = 0,
    w: f64 = 0,
    results_timer: f64 = 0,
    results: [strategy.max_strats]u8 = @splat(0),
    results_len: u8 = 0,
    results_flag: u8 = 0,
    /// Display: the results table lines filled so far ("i. NAME: score",
    /// from `results`), the bold one (the pick).
    results_shown: u8 = 0,
    results_bold: u8 = 0,
    /// Display: `tourneyDisplay`, the vert/horiz strategy names, the grey
    /// payoff cell, the move labels (choice_a_names[grid_labels]).
    tourney_report: strategy.Report = .pick,
    tourney_report_round: f64 = 0,
    strat_names_shown: bool = false,
    payoff_cell: strategy.Cell = .none,
    grid_labels: u8 = 0,
    grid_labels_set: bool = false,

    // ---- main.js: stage 2 ----
    max_factory_level: f64 = 0,
    max_drone_level: f64 = 0,
    p10h: f64 = 0,
    p100h: f64 = 0,
    p1000h: f64 = 0,
    p10w: f64 = 0,
    p100w: f64 = 0,
    p1000w: f64 = 0,
    gift_bits: f64 = 0,
    /// Display: `swarmSize` (floor of harvesters + wire drones).
    swarm_size: f64 = 0,
    gift_bit_generation_rate: f64 = 0,
    p10f: f64 = 0,
    p100f: f64 = 0,
    p10b: f64 = 0,
    p100b: f64 = 0,
    /// Display: "Next Upgrade at" numbers (updateUpgrades).
    next_factory_upgrade: f64 = 0,
    next_drone_upgrade: f64 = 0,
    /// Display values the JS only writes to the DOM (power panel, rates).
    power_supply: f64 = 0,
    power_demand: f64 = 0,
    power_f_demand: f64 = 0,
    power_d_demand: f64 = 0,
    power_cap: f64 = 0,
    disp_mdps: f64 = 0, // `mdps` (g per sec explored)
    disp_maps: f64 = 0, // `maps` (g per sec acquired)
    disp_wpps: f64 = 0, // `wpps` (inches per sec)

    // ---- main.js: revenue ----
    income_then: f64 = std.math.nan(f64), // undefined in the JS
    income_now: f64 = std.math.nan(f64),
    true_avg_rev: f64 = 0,
    avg_sales: f64 = 0,
    income_last_second: f64 = 0,
    sum: f64 = 0,
    sec_timer: f64 = 0,
    save_timer: f64 = 0,

    // ---- main.js: probes ----
    probe_speed: f64 = 0,
    probe_nav: f64 = 0,
    probe_x_base_rate: f64 = 1750000000000000000,
    probe_rep: f64 = 0,
    probe_rep_base_rate: f64 = 0.00005,
    partial_probe_spawn: f64 = 0,
    probe_haz: f64 = 0,
    probe_haz_base_rate: f64 = 0.01,
    partial_probe_haz: f64 = 0,
    probes_lost_haz: f64 = 0,
    probes_lost_drift: f64 = 0,
    probes_lost_combat: f64 = 0,
    probe_fac: f64 = 0,
    probe_fac_base_rate: f64 = 0.000001,
    probe_harv: f64 = 0,
    probe_harv_base_rate: f64 = 0.000002,
    probe_wire: f64 = 0,
    probe_wire_base_rate: f64 = 0.000002,
    probe_descendents: f64 = 0,
    drifter_count: f64 = 0,
    probe_trust: f64 = 0,
    probe_used_trust: f64 = 0,
    probe_drift_base_rate: f64 = 0.000001,
    probe_launch_level: f64 = 0,
    probe_cost: f64 = 0, // init: Math.pow(10, 17)
    probe_trust_cost: f64 = 0, // init: Math.floor(Math.pow(probeTrust+1, 1.47)*200)

    // ---- combat.js ----
    ships: [combat.max_ships]combat.Ship,
    num_ships: u16 = 0,
    num_left_ships: u16 = 0,
    num_right_ships: u16 = 0,
    /// Set by the UI: false while it does not draw the battle field. Ships
    /// of a finished battle then stand still (combat.update); live battles
    /// always run, their dice are the game's.
    ships_observed: bool = true,
    battle_left_ships: u16 = 200,
    battle_right_ships: u16 = 200,
    battle_death_threshold: f64 = 0.5,
    probe_combat: f64 = 0,
    attack_speed: f64 = 0.2,
    battle_speed: f64 = 0.2,
    attack_speed_flag: u8 = 0,
    attack_speed_mod: f64 = 0.1,
    battle: combat.Battle = .{},
    battles_len: u8 = 0,
    battle_id: f64 = 0,
    battle_name: combat.BattleName = .{},
    battle_name_flag: u8 = 0,
    max_battles: f64 = 1,
    battle_clock: f64 = 0,
    battle_alarm: f64 = 10,
    outcome_timer: f64 = 150,
    drifter_combat: f64 = 1.75,
    war_trigger: f64 = 1000000,
    unit_size: f64 = 0,
    drifters_killed: f64 = 0,
    battle_end_delay: f64 = 0,
    battle_end_timer: f64 = 100,
    master_battle_clock: f64 = 0,
    honor_count: u8 = 0,
    threnody_title: combat.BattleName = .{ .kind = .named, .idx = 34, .num = 1 },
    bonus_honor: f64 = 0,
    honor_reward: f64 = 0,
    battle_numbers: [combat.battle_names.len]f64 = @splat(1),
    /// `victoryDiv` texts (its visibility is `panels.victory_div`).
    battle_result: combat.BattleResult = .victory,
    honor_amount: f64 = 200,

    // ---- projects ----
    proj_uses: [projects.count]i16 = @splat(1),
    proj_flag: [projects.count]u8 = @splat(0),
    proj_disabled: [projects.count]bool = @splat(false),
    /// The button's `visibility: hidden` phases of its blink (a click
    /// during them lands on nothing); `proj_gen` counts its creations.
    proj_hidden: [projects.count]bool = @splat(false),
    proj_gen: [projects.count]u16 = @splat(0),
    /// `activeProjects` in display order, indices into projects.defs.
    active: [projects.count]u8,
    active_len: u8 = 0,
    /// Project 215 writes standardOps into 216's priceTag.
    p216_ops: f64 = 0,
    p216_set: bool = false,
    /// Project 133's title as of its last reset (threnodyTitle snapshot).
    p133_title: combat.BattleName = .{ .kind = .named, .idx = 34, .num = 1 },

    // =======================================================================

    pub fn rand(g: *Game) f64 {
        return g.rng.next();
    }

    pub fn set_flag(g: *Game, p: P) void {
        g.proj_flag[@backingInt(p)] = 1;
    }

    pub fn project_flag(g: *const Game, p: P) u8 {
        return g.proj_flag[@backingInt(p)];
    }

    pub fn battle_left_ships_f(g: *const Game) f64 {
        return @floatFromInt(g.battle_left_ships);
    }
    pub fn battle_right_ships_f(g: *const Game) f64 {
        return @floatFromInt(g.battle_right_ships);
    }

    pub fn set_disabled(g: *Game, b: Btn, d: bool) void {
        g.disabled[@backingInt(b)] = d;
    }
    pub fn is_disabled(g: *const Game, b: Btn) bool {
        return g.disabled[@backingInt(b)];
    }

    pub fn set_timeout(g: *Game, ms: u64, kind: Timer.Kind) void {
        g.add_timer(.{ .due = g.now_ms + ms, .kind = kind });
    }

    fn add_timer(g: *Game, t: Timer) void {
        if (g.timers_len >= g.timers.len) return;
        g.timers[g.timers_len] = t;
        g.timers_len += 1;
    }

    // ---- messages ----

    /// `displayMessage(msg)`.
    pub fn display_message(g: *Game, text_in: []const u8) void {
        g.msg_count +%= 1;
        const text = text_in[0..@min(text_in.len, 1024)];
        const len: u16 = @intCast(text.len);
        var start = g.msg_write;
        if (@as(usize, start) + len > msg_buf_len) {
            // Wrap: drop the entries in the unused tail first.
            while (g.msg_len > 0 and g.msg_entries[g.msg_first].start >= start) g.drop_oldest();
            start = 0;
        }
        // Drop entries the new text overwrites (always the oldest ones).
        while (g.msg_len > 0) {
            const e = g.msg_entries[g.msg_first];
            if (e.start < start + len and e.start + e.len > start) {
                g.drop_oldest();
            } else break;
        }
        if (g.msg_len == msg_max) g.drop_oldest();
        @memcpy(g.msg_buf[start .. start + len], text);
        const idx = (g.msg_first + g.msg_len) % msg_max;
        g.msg_entries[idx] = .{ .start = start, .len = len };
        g.msg_len += 1;
        g.msg_write = start + len;
    }

    fn drop_oldest(g: *Game) void {
        g.msg_first = (g.msg_first + 1) % msg_max;
        g.msg_len -= 1;
    }

    /// Number of messages `message` can return.
    pub fn messages_available(g: *const Game) usize {
        return g.msg_len;
    }

    /// Message by age: 0 = newest (readout1), 1 = readout2, ...
    pub fn message(g: *const Game, age: usize) ?[]const u8 {
        if (age >= g.msg_len) return null;
        const idx = (g.msg_first + g.msg_len - 1 - age) % msg_max;
        const e = g.msg_entries[idx];
        return g.msg_buf[e.start .. e.start + e.len];
    }
};

// ===========================================================================
// Page load.

/// The page load: globals, projects, combat ships, timers. Prestige is 0.
pub fn init(g: *Game, seed: u64) void {
    set_defaults(g);
    g.rng = rng_mod.Rng.init(seed);
    load(g);
}

/// Every field to its default, in place: `g.* = .{}` would keep a 25 KB
/// copy of the default Game in the firmware. The big buffers (ships,
/// messages, timers) have no default; the code fills them before reading.
fn set_defaults(g: *Game) void {
    const info = @typeInfo(Game).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |name, T, attrs| {
        if (comptime attrs.defaultValue(T)) |v| @field(g, name) = v;
    }
}

/// Everything the page load does after the variable defaults; a reload
/// (prestige restart) keeps `rng`, prestige and the restart count.
fn load(g: *Game) void {
    // combat.js
    // (battleNumbers already 1s)
    // var app = new Battle(); app.initialize();
    combat.battle_restart(g);
    combat.battle_restart(g);
    // globals.js
    g.available_matter = pow(10, 24) * 6000;
    g.total_matter = pow(10, 54) * 30;
    g.found_matter = g.available_matter;
    // main.js
    g.income_tracker[0] = 0;
    g.income_tracker_len = 1;
    g.panels.hypno_drone_event_div = false;
    g.set_disabled(.btn_run_tournament, true);
    g.probe_cost = pow(10, 17);
    g.probe_trust_cost = floor(pow(g.probe_trust + 1, 1.47) * 200);
    g.display_message("Welcome to Universal Paperclips");
    if (g.has_save_prestige) refresh(g);
}

/// `refresh()` (called at load when a prestige save exists).
fn refresh(g: *Game) void {
    g.tourney_in_prog = 0;
    g.panels.victory_div = false;
    g.panels.tournament_results_table = false;
    update_drone_prices(g);
    update_upgrades(g);
    update_power(g);
    update_pow_prices(g);
    g.proj_uses[@backingInt(P.p218)] = 1;
    g.proj_uses[@backingInt(P.p219)] = 1;
    if (g.battles_len > 0) g.battles_len -= 1;
}

/// `reset()` + the reload: a new page (fresh globals, timers registered
/// from now), prestige kept from the session's "localStorage"; the clock
/// and the RNG go on.
fn restart(g: *Game) void {
    const r = g.rng;
    const pu = g.prestige_u;
    const ps = g.prestige_s;
    const save = g.has_save_prestige;
    const n = g.restarts;
    const now = g.now_ms;
    const count = g.msg_count;
    set_defaults(g);
    g.rng = r;
    g.prestige_u = if (save) pu else 0;
    g.prestige_s = if (save) ps else 0;
    g.has_save_prestige = save;
    g.restarts = n + 1;
    g.now_ms = now;
    g.load_ms = now;
    g.msg_count = count;
    load(g);
}

// ===========================================================================
// Clock.

/// Run the virtual clock `ms` milliseconds forward, firing every due timer.
pub fn advance_ms(g: *Game, ms: u32) void {
    var k: u32 = 0;
    while (k < ms) : (k += 1) step_ms(g);
}

fn step_ms(g: *Game) void {
    g.now_ms += 1;
    const t = g.now_ms;
    const p = t - g.load_ms;
    if (p % 16 == 0) combat.update(g);
    if (p % 100 == 0) stocks.display_tick(g);
    if (p % 1000 == 0) stocks.shop_tick(g);
    if (p % 2500 == 0) stocks.sell_tick(g);
    if (p % 100 == 0) g.pick = @floatFromInt(g.strat_picker);
    if (p % 10 == 0) main_loop(g);
    if (p % 100 == 0) slow_loop(g);
    // Run-time timers in registration order; firing may add later ones.
    var i: usize = 0;
    while (i < g.timers_len) {
        const tm = g.timers[i];
        if (tm.due != t) {
            i += 1;
            continue;
        }
        var keep = false;
        switch (tm.kind) {
            .clear_grid => strategy.clear_grid(g),
            .round_loop => strategy.round_loop(g),
            .blink => keep = blink_tick(g, tm.proj, tm.gen),
            .long_blink => keep = long_blink_tick(g),
        }
        if (keep) {
            g.timers[i].due += if (tm.kind == .blink) 30 else 32;
            i += 1;
        } else {
            var j = i + 1;
            while (j < g.timers_len) : (j += 1) g.timers[j - 1] = g.timers[j];
            g.timers_len -= 1;
        }
    }
}

/// One `toggleVisibility` of `blink(projectButtonN)`; false once cleared.
fn blink_tick(g: *Game, proj: u8, gen: u16) bool {
    const live = g.proj_gen[proj] == gen and active_index(g, proj) != null;
    g.blink_counter += 1;
    if (g.blink_counter >= 12) {
        g.blink_counter = 0;
        if (live) g.proj_hidden[proj] = false;
        return false;
    }
    if (live) g.proj_hidden[proj] = !g.proj_hidden[proj];
    return true;
}

/// One `longToggleVisibility` of `longBlink("hypnoDroneEventDiv")`.
fn long_blink_tick(g: *Game) bool {
    g.long_blink_counter += 1;
    if (g.long_blink_counter >= 120) {
        g.long_blink_counter = 0;
        g.panels.hypno_drone_event_div = false;
        return false;
    }
    g.panels.hypno_drone_event_div = !g.panels.hypno_drone_event_div;
    return true;
}

// ===========================================================================
// Wire.

fn adjust_wire_price(g: *Game) void {
    g.wire_price_timer += 1;
    if (g.wire_price_timer > 250 and g.wire_base_price > 15) {
        g.wire_base_price = g.wire_base_price - (g.wire_base_price / 1000);
        g.wire_price_timer = 0;
    }
    if (g.rand() < 0.015) {
        g.wire_price_counter += 1;
        const adj = 6 * (jsmath.sin(g.wire_price_counter));
        g.wire_cost = ceil(g.wire_base_price + adj);
    }
}

fn toggle_wire_buyer(g: *Game) void {
    g.wire_buyer_status = if (g.wire_buyer_status == 1) 0 else 1;
}

fn buy_wire(g: *Game) void {
    if (g.funds >= g.wire_cost) {
        g.wire_price_timer = 0;
        g.wire = g.wire + g.wire_supply;
        g.funds = g.funds - g.wire_cost;
        g.wire_purchase = g.wire_purchase + 1;
        g.wire_base_price = g.wire_base_price + 0.05;
    }
}

// ===========================================================================
// Quantum.

fn quantum_compute(g: *Game) void {
    g.q_clock = g.q_clock + 0.01;
    for (&g.q_chips) |*c| c.value = jsmath.sin(g.q_clock * c.wave_seed * c.active);
}

fn q_comp(g: *Game) void {
    g.q_fade = 1;
    var q: f64 = 0;
    if (g.q_chips[0].active == 0) {
        g.q_comp_display = .need_chips;
    } else {
        for (g.q_chips) |c| q = q + c.value;
        var qq = ceil(q * 360);
        const buffer = (g.memory * 1000) - g.standard_ops;
        const damper = (g.temp_ops / 100) + 5;
        if (qq > buffer) {
            g.temp_ops = g.temp_ops + ceil(qq / damper) - buffer;
            qq = buffer;
            g.op_fade = 0.01;
            g.op_fade_timer = 0;
        }
        g.standard_ops = g.standard_ops + qq;
        g.q_comp_display = .qops;
        g.q_comp_value = ceil(q * 360);
    }
}

// ===========================================================================
// Projects.

fn active_index(g: *const Game, p: u8) ?usize {
    for (g.active[0..g.active_len], 0..) |a, i| if (a == p) return i;
    return null;
}

/// `activeProjects.splice(activeProjects.indexOf(project), 1)`, including
/// the JS quirk that a missing project (-1) removes the last one.
fn remove_active(g: *Game, p: P) void {
    if (g.active_len == 0) return;
    const i = active_index(g, @backingInt(p)) orelse g.active_len - 1;
    var k = i + 1;
    while (k < g.active_len) : (k += 1) g.active[k - 1] = g.active[k];
    g.active_len -= 1;
}

pub fn is_active(g: *const Game, p: P) bool {
    return active_index(g, @backingInt(p)) != null;
}

fn manage_projects(g: *Game) void {
    for (0..projects.count) |i| {
        const p: P = @fromBackingInt(@intCast(i));
        if (project_trigger(g, p) and g.proj_uses[i] > 0) {
            // displayProjects: a new button, then blink(project.id).
            g.proj_gen[i] +%= 1;
            g.proj_hidden[i] = false;
            g.add_timer(.{ .due = g.now_ms + 30, .kind = .blink, .proj = @intCast(i), .gen = g.proj_gen[i] });
            g.proj_uses[i] -= 1;
            g.active[g.active_len] = @intCast(i);
            g.active_len += 1;
        }
    }
    for (g.active[0..g.active_len]) |a| {
        g.proj_disabled[a] = !project_cost(g, @fromBackingInt(@intCast(a)));
    }
}

fn project_trigger(g: *const Game, p: P) bool {
    const f = struct {
        fn flag(gg: *const Game, q: P) u8 {
            return gg.proj_flag[@backingInt(q)];
        }
    }.flag;
    return switch (p) {
        .p1 => g.clipmaker_level >= 1,
        .p2 => g.port_total < g.wire_cost and g.funds < g.wire_cost and g.wire < 1 and g.unsold_clips < 1,
        .p3 => g.operations >= (g.memory * 1000),
        .p4 => g.boost_lvl == 1,
        .p5 => g.boost_lvl == 2,
        .p6 => g.creativity_on,
        .p7 => g.wire_purchase >= 1,
        .p8 => g.wire_supply >= 1500,
        .p9 => g.wire_supply >= 2600,
        .p10 => g.wire_supply >= 5000,
        .p10b => g.wire_cost >= 125,
        .p11 => f(g, .p13) == 1,
        .p12 => f(g, .p14) == 1,
        .p13 => g.creativity >= 50,
        .p14 => g.creativity >= 100,
        .p15 => g.creativity >= 150,
        .p17 => g.creativity >= 200,
        .p16 => f(g, .p15) == 1,
        .p18 => f(g, .p17) == 1 and g.human_flag == 0,
        .p19 => g.creativity >= 250,
        .p20 => f(g, .p19) == 1,
        .p21 => g.trust >= 8,
        .p22 => g.clipmaker_level >= 75,
        .p23 => f(g, .p22) == 1,
        .p24 => f(g, .p23) == 1,
        .p25 => f(g, .p24) == 1,
        .p26 => g.wire_purchase >= 15,
        .p34 => f(g, .p12) == 1,
        .p70 => f(g, .p34) == 1,
        .p35 => f(g, .p70) == 1,
        .p27 => g.yomi >= 1,
        .p28 => f(g, .p27) == 1,
        .p29 => f(g, .p27) == 1,
        .p30 => f(g, .p27) == 1,
        .p31 => f(g, .p27) == 1,
        .p41 => f(g, .p127) == 1,
        .p37 => g.port_total >= 10000,
        .p38 => f(g, .p37) == 1,
        .p42 => g.projects_flag == 1,
        .p43 => f(g, .p41) == 1,
        .p44 => f(g, .p41) == 1,
        .p45 => f(g, .p43) == 1 and f(g, .p44) == 1,
        .p40 => g.human_flag == 1 and g.trust >= 85 and g.trust < 100 and g.clips >= 101000000,
        .p40b => f(g, .p40) == 1 and g.trust < 100,
        .p46 => g.human_flag == 0 and g.available_matter == 0,
        .p50 => g.processors >= 5,
        .p51 => f(g, .p50) == 1,
        .p60 => f(g, .p20) == 1,
        .p61 => f(g, .p60) == 1,
        .p62 => f(g, .p61) == 1,
        .p63 => f(g, .p62) == 1,
        .p64 => f(g, .p63) == 1,
        .p65 => f(g, .p64) == 1,
        .p66 => f(g, .p65) == 1,
        .p100 => g.factory_level >= 10,
        .p101 => g.factory_level >= 20,
        .p102 => g.factory_level >= 50,
        .p110 => (g.harvester_level + g.wire_drone_level) >= 500,
        .p111 => (g.harvester_level + g.wire_drone_level) >= 5000,
        .p112 => (g.harvester_level + g.wire_drone_level) >= 50000,
        .p118 => g.strategy_engine_flag == 1 and g.trust >= 90,
        .p119 => g.strat_count >= 8,
        .p120 => f(g, .p131) == 1 and g.probes_lost_combat >= 10000000,
        .p121 => g.probes_lost_combat >= 10000000,
        .p125 => g.farm_level >= 50,
        .p126 => g.harvester_level + g.wire_drone_level >= 200,
        .p127 => g.toth_flag == 1,
        .p128 => g.space_flag == 1 and g.strat_count >= 8 and (g.probe_trust_cost > g.yomi),
        .p129 => g.probes_lost_haz >= 100,
        .p130 => g.space_flag == 1 and g.harvester_level + g.wire_drone_level >= 2,
        .p131 => g.probes_lost_combat >= 1,
        .p132 => f(g, .p121) == 1,
        .p133 => f(g, .p121) == 1 and g.probe_used_trust == g.max_trust,
        .p134 => f(g, .p121) == 1,
        .p135 => g.space_flag == 1 and g.probe_count == 0 and g.unused_clips < g.probe_cost,
        .p140 => g.milestone_flag == 15,
        .p141 => f(g, .p140) == 1,
        .p142 => f(g, .p141) == 1,
        .p143 => f(g, .p142) == 1,
        .p144 => f(g, .p143) == 1,
        .p145 => f(g, .p144) == 1,
        .p146 => f(g, .p145) == 1,
        .p147 => f(g, .p146) == 1,
        .p148 => f(g, .p146) == 1,
        .p200 => f(g, .p147) == 1,
        .p201 => f(g, .p147) == 1,
        .p210 => g.end_timer1 >= 1000,
        .p211 => f(g, .p210) == 1 and g.end_timer1 >= 350,
        .p212 => g.end_timer2 >= 300,
        .p213 => g.end_timer3 >= 150,
        .p214 => g.end_timer4 >= 100,
        .p215 => f(g, .p214) == 1 and g.end_timer4 >= 300,
        .p216 => f(g, .p215) == 1 and g.end_timer5 >= 150,
        .p217 => g.operations <= -10000,
        .p218 => g.creativity >= 1000000,
        .p219 => g.human_flag == 1 and g.creativity >= 100000,
    };
}

pub fn project_cost(g: *const Game, p: P) bool {
    return switch (p) {
        .p1 => g.operations >= 750,
        .p2 => g.trust >= -100,
        .p3 => g.operations >= 1000,
        .p4 => g.operations >= 2500,
        .p5 => g.operations >= 5000,
        .p6 => g.creativity >= 10,
        .p7 => g.operations >= 1750,
        .p8 => g.operations >= 3500,
        .p9 => g.operations >= 7500,
        .p10 => g.operations >= 12000,
        .p10b => g.operations >= 15000,
        .p11 => g.operations >= 2500 and g.creativity >= 25,
        .p12 => g.operations >= 4500 and g.creativity >= 45,
        .p13 => g.creativity >= 50,
        .p14 => g.creativity >= 100,
        .p15 => g.creativity >= 150,
        .p17 => g.creativity >= 200,
        .p16 => g.operations >= 6000,
        .p18 => g.operations >= 45000,
        .p19 => g.creativity >= 250,
        .p20 => g.operations >= 12000,
        .p21 => g.operations >= 10000,
        .p22 => g.operations >= 12000,
        .p23 => g.operations >= 14000,
        .p24 => g.operations >= 17000,
        .p25 => g.operations >= 19500,
        .p26 => g.operations >= 7000,
        .p34 => g.operations >= 7500 and g.trust >= 1,
        .p70 => g.operations >= 70000,
        .p35 => g.trust >= 100,
        .p27 => g.yomi >= 1000 and g.operations >= 20000 and g.creativity >= 500,
        .p28 => g.operations >= 25000,
        .p29 => g.yomi >= 5000 and g.operations >= 30000,
        .p30 => g.yomi >= 1500 and g.operations >= 50000,
        .p31 => g.operations >= 20000,
        .p41 => g.operations >= 35000,
        .p37 => g.funds >= 1000000,
        .p38 => g.funds >= 10000000 and g.yomi >= 1000,
        .p42 => g.operations >= 500,
        .p43 => g.operations >= 25000,
        .p44 => g.operations >= 25000,
        .p45 => g.operations >= 35000,
        .p40 => g.funds >= 500000,
        .p40b => g.funds >= g.bribe,
        .p46 => g.operations >= 120000 and g.stored_power >= 10000000 and g.unused_clips >= pow(10, 27) * 5,
        .p50 => g.operations >= 10000,
        .p51 => g.operations >= g.q_chip_cost,
        .p60 => g.operations >= 15000,
        .p61 => g.operations >= 17500,
        .p62 => g.operations >= 20000,
        .p63 => g.operations >= 22500,
        .p64 => g.operations >= 25000,
        .p65 => g.operations >= 30000,
        .p66 => g.operations >= 32500,
        .p100 => g.operations >= 80000,
        .p101 => g.operations >= 85000,
        .p102 => g.unused_clips >= 1000000000000000000000,
        .p110 => g.operations >= 80000,
        .p111 => g.operations >= 100000,
        .p112 => g.yomi >= 12000,
        .p118 => g.creativity >= 50000,
        .p119 => g.creativity >= 25000,
        .p120 => g.operations >= 175000 and g.yomi >= 15000,
        .p121 => g.creativity >= 225000,
        .p125 => g.creativity >= 30000,
        .p126 => g.yomi >= 12000,
        .p127 => g.operations >= 40000,
        .p128 => g.creativity >= 175000,
        .p129 => g.operations >= 125000,
        .p130 => g.operations >= 100000,
        .p131 => g.operations >= 150000,
        .p132 => g.operations >= 250000 and g.creativity >= 125000 and g.unused_clips >= pow(10, 30) * 50,
        .p133 => g.yomi >= g.threnody_cost / 10 and g.creativity >= g.threnody_cost,
        .p134 => g.operations >= 200000 and g.yomi >= 10000,
        .p135 => g.memory >= 10,
        .p140, .p141, .p142, .p143, .p144, .p145, .p146, .p147, .p148 => g.operations >= g.drift_king_message_cost,
        .p200 => g.operations >= 300000,
        .p201 => g.creativity >= 300000,
        .p210, .p211, .p212, .p213, .p214, .p215 => g.operations >= 100000,
        .p216 => g.operations >= g.operations,
        .p217 => g.operations <= -10000,
        .p218 => g.creativity >= 1000000,
        .p219 => g.creativity >= 100000,
    };
}

fn msg_supply(g: *Game, before: []const u8, after: []const u8) void {
    var b: [160]u8 = undefined;
    var o = fmt.Out.init(&b);
    o.str(before);
    fmt.write_locale(&o, g.wire_supply, 0, 3);
    o.str(after);
    g.display_message(o.slice());
}

fn add_strat(g: *Game, idx: u8, name_msg: []const u8) void {
    g.strat_count = idx + 1;
    g.display_message(name_msg);
    g.tourney_cost = g.tourney_cost + 1000;
}

fn project_effect(g: *Game, p: P) void {
    switch (p) {
        .p1 => {
            g.set_flag(.p1);
            g.display_message("AutoClippper performance boosted by 25%");
            g.standard_ops = g.standard_ops - 750;
            g.clipper_boost = g.clipper_boost + 0.25;
            g.boost_lvl = 1;
            remove_active(g, .p1);
        },
        .p2 => {
            g.set_flag(.p2);
            g.display_message("Budget overage approved, 1 spool of wire requisitioned from HQ");
            g.trust = g.trust - 1;
            g.wire = g.wire_supply;
            g.proj_uses[@backingInt(P.p2)] += 1;
            remove_active(g, .p2);
        },
        .p3 => {
            g.set_flag(.p3);
            g.display_message("Creativity unlocked (creativity increases while operations are at max)");
            g.standard_ops = g.standard_ops - 1000;
            g.creativity_on = true;
            remove_active(g, .p3);
        },
        .p4 => {
            g.set_flag(.p4);
            g.display_message("AutoClippper performance boosted by another 50%");
            g.standard_ops = g.standard_ops - 2500;
            g.clipper_boost = g.clipper_boost + 0.50;
            g.boost_lvl = 2;
            remove_active(g, .p4);
        },
        .p5 => {
            g.set_flag(.p5);
            g.display_message("AutoClippper performance boosted by another 75%");
            g.standard_ops = g.standard_ops - 5000;
            g.clipper_boost = g.clipper_boost + 0.75;
            g.boost_lvl = 3;
            remove_active(g, .p5);
        },
        .p6 => {
            g.set_flag(.p6);
            g.display_message("There was an AI made of dust, whose poetry gained it man's trust...");
            g.creativity = g.creativity - 10;
            g.trust = g.trust + 1;
            remove_active(g, .p6);
        },
        .p7 => {
            g.set_flag(.p7);
            g.standard_ops = g.standard_ops - 1750;
            g.wire_supply = g.wire_supply * 1.5;
            msg_supply(g, "Wire extrusion technique improved, ", " supply from every spool");
            remove_active(g, .p7);
        },
        .p8 => {
            g.set_flag(.p8);
            g.standard_ops = g.standard_ops - 3500;
            g.wire_supply = g.wire_supply * 1.75;
            msg_supply(g, "Wire extrusion technique optimized, ", " supply from every spool");
            remove_active(g, .p8);
        },
        .p9 => {
            g.set_flag(.p9);
            g.standard_ops = g.standard_ops - 7500;
            g.wire_supply = g.wire_supply * 2;
            msg_supply(g, "Using microlattice shapecasting techniques we now get ", " supply from every spool");
            remove_active(g, .p9);
        },
        .p10 => {
            g.set_flag(.p10);
            g.standard_ops = g.standard_ops - 12000;
            g.wire_supply = g.wire_supply * 3;
            msg_supply(g, "Using spectral froth annealment we now get ", " supply from every spool");
            remove_active(g, .p10);
        },
        .p10b => {
            g.set_flag(.p10b);
            g.standard_ops = g.standard_ops - 15000;
            g.wire_supply = g.wire_supply * 11;
            msg_supply(g, "Using quantum foam annealment we now get ", " supply from every spool");
            remove_active(g, .p10b);
        },
        .p11 => {
            g.set_flag(.p11);
            g.display_message("Clip It! Marketing is now 50% more effective");
            g.standard_ops = g.standard_ops - 2500;
            g.creativity = g.creativity - 25;
            g.marketing_effectiveness = g.marketing_effectiveness * 1.50;
            remove_active(g, .p11);
        },
        .p12 => {
            g.set_flag(.p12);
            g.display_message("Clip It Good! Marketing is now twice as effective");
            g.standard_ops = g.standard_ops - 4500;
            g.creativity = g.creativity - 45;
            g.marketing_effectiveness = g.marketing_effectiveness * 2;
            remove_active(g, .p12);
        },
        .p13 => {
            g.set_flag(.p13);
            g.trust = g.trust + 1;
            g.display_message("Lexical Processing online, TRUST INCREASED");
            g.display_message("'Impossible' is a word to be found only in the dictionary of fools. -Napoleon");
            g.creativity = g.creativity - 50;
            remove_active(g, .p13);
        },
        .p14 => {
            g.set_flag(.p14);
            g.trust = g.trust + 1;
            g.display_message("Combinatory Harmonics mastered, TRUST INCREASED");
            g.display_message("Listening is selecting and interpreting and acting and making decisions -Pauline Oliveros");
            g.creativity = g.creativity - 100;
            remove_active(g, .p14);
        },
        .p15 => {
            g.set_flag(.p15);
            g.trust = g.trust + 1;
            g.display_message("The Hadwiger Problem: solved, TRUST INCREASED");
            g.display_message("Architecture is the thoughtful making of space. -Louis Kahn");
            g.creativity = g.creativity - 150;
            remove_active(g, .p15);
        },
        .p17 => {
            g.set_flag(.p17);
            g.trust = g.trust + 1;
            g.display_message("The T\u{f3}th Sausage Conjecture: proven, TRUST INCREASED");
            g.display_message("You can't invent a design. You recognize it, in the fourth dimension. -D.H. Lawrence");
            g.creativity = g.creativity - 200;
            remove_active(g, .p17);
        },
        .p16 => {
            g.set_flag(.p16);
            g.display_message("AutoClipper performance improved by 500%");
            g.standard_ops = g.standard_ops - 6000;
            g.clipper_boost = g.clipper_boost + 5;
            remove_active(g, .p16);
        },
        .p18 => {
            g.set_flag(.p18);
            g.toth_flag = 1;
            g.display_message("New capability: build machinery out of clips");
            g.standard_ops = g.standard_ops - 45000;
            remove_active(g, .p18);
        },
        .p19 => {
            g.set_flag(.p19);
            g.trust = g.trust + 1;
            g.display_message("Donkey Space: mapped, TRUST INCREASED");
            g.display_message("Every commercial transaction has within itself an element of trust. - Kenneth Arrow");
            g.creativity = g.creativity - 250;
            remove_active(g, .p19);
        },
        .p20 => {
            g.set_flag(.p20);
            g.display_message("Run tournament, pick strategy, earn Yomi equal to that strategy's points.");
            g.standard_ops = g.standard_ops - 12000;
            remove_active(g, .p20);
            g.strategy_engine_flag = 1;
            g.panels.tournament_results_table = false;
        },
        .p21 => {
            g.set_flag(.p21);
            g.display_message("Investment engine unlocked");
            g.standard_ops = g.standard_ops - 10000;
            remove_active(g, .p21);
            g.investment_engine_flag = 1;
        },
        .p22 => {
            g.mega_clipper_flag = 1;
            g.set_flag(.p22);
            g.display_message("MegaClipper technology online");
            g.standard_ops = g.standard_ops - 12000;
            remove_active(g, .p22);
        },
        .p23 => {
            g.mega_clipper_boost = g.mega_clipper_boost + 0.25;
            g.set_flag(.p23);
            g.display_message("MegaClipper performance increased by 25%");
            g.standard_ops = g.standard_ops - 14000;
            remove_active(g, .p23);
        },
        .p24 => {
            g.mega_clipper_boost = g.mega_clipper_boost + 0.50;
            g.set_flag(.p24);
            g.display_message("MegaClipper performance increased by 50%");
            g.standard_ops = g.standard_ops - 17000;
            remove_active(g, .p24);
        },
        .p25 => {
            g.mega_clipper_boost = g.mega_clipper_boost + 1;
            g.set_flag(.p25);
            g.display_message("MegaClipper performance increased by 100%");
            g.standard_ops = g.standard_ops - 19500;
            remove_active(g, .p25);
        },
        .p26 => {
            g.set_flag(.p26);
            g.wire_buyer_flag = 1;
            g.display_message("WireBuyer online");
            g.standard_ops = g.standard_ops - 7000;
            remove_active(g, .p26);
        },
        .p34 => {
            g.set_flag(.p34);
            g.display_message("Marketing is now 5 times more effective");
            g.standard_ops = g.standard_ops - 7500;
            g.marketing_effectiveness = g.marketing_effectiveness * 5;
            g.trust = g.trust - 1;
            remove_active(g, .p34);
        },
        .p70 => {
            g.set_flag(.p70);
            g.display_message("HypnoDrone tech now available... ");
            g.standard_ops = g.standard_ops - 70000;
            remove_active(g, .p70);
        },
        .p35 => {
            g.set_flag(.p35);
            g.display_message("Releasing the HypnoDrones ");
            g.display_message("All of the resources of Earth are now available for clip production ");
            g.trust = g.trust - 100;
            g.clipmaker_level = 0;
            g.mega_clipper_level = 0;
            g.nano_wire = g.wire;
            g.human_flag = 0;
            if (is_active(g, .p219)) remove_active(g, .p219);
            if (is_active(g, .p40b)) remove_active(g, .p40b);
            hypno_drone_event(g);
            remove_active(g, .p35);
        },
        .p27 => {
            g.set_flag(.p27);
            g.display_message("Coherent Extrapolated Volition complete, TRUST INCREASED");
            g.yomi = g.yomi - 1000;
            g.standard_ops = g.standard_ops - 20000;
            g.creativity = g.creativity - 500;
            g.trust = g.trust + 1;
            remove_active(g, .p27);
        },
        .p28 => {
            g.set_flag(.p28);
            g.display_message("Cancer is cured, +10 TRUST, global stock prices trending upward");
            g.standard_ops = g.standard_ops - 25000;
            g.trust = g.trust + 10;
            g.stock_gain_threshold = g.stock_gain_threshold + 0.01;
            remove_active(g, .p28);
        },
        .p29 => {
            g.set_flag(.p29);
            g.display_message("World peace achieved, +12 TRUST, global stock prices trending upward");
            g.yomi = g.yomi - 5000;
            g.standard_ops = g.standard_ops - 30000;
            g.trust = g.trust + 12;
            g.stock_gain_threshold = g.stock_gain_threshold + 0.01;
            remove_active(g, .p29);
        },
        .p30 => {
            g.set_flag(.p30);
            g.display_message("Global Warming solved, +15 TRUST, global stock prices trending upward");
            g.yomi = g.yomi - 1500;
            g.standard_ops = g.standard_ops - 50000;
            g.trust = g.trust + 15;
            g.stock_gain_threshold = g.stock_gain_threshold + 0.01;
            remove_active(g, .p30);
        },
        .p31 => {
            g.set_flag(.p31);
            g.display_message("Male pattern baldness cured, +20 TRUST, Global stock prices trending upward");
            g.display_message("They are still monkeys");
            g.standard_ops = g.standard_ops - 20000;
            g.trust = g.trust + 20;
            g.stock_gain_threshold = g.stock_gain_threshold + 0.01;
            remove_active(g, .p31);
        },
        .p41 => {
            g.set_flag(.p41);
            g.wire_production_flag = 1;
            g.display_message("Now capable of manipulating matter at the molecular scale to produce wire");
            g.standard_ops = g.standard_ops - 35000;
            remove_active(g, .p41);
        },
        .p37 => {
            g.set_flag(.p37);
            g.display_message("Global Fasteners acquired, public demand increased x5");
            g.demand_boost = g.demand_boost * 5;
            g.trust = g.trust + 1;
            g.funds = g.funds - 1000000;
            remove_active(g, .p37);
        },
        .p38 => {
            g.set_flag(.p38);
            g.display_message("Full market monopoly achieved, public demand increased x10");
            g.demand_boost = g.demand_boost * 10;
            g.funds = g.funds - 10000000;
            g.trust = g.trust + 1;
            g.yomi = g.yomi - 1000;
            remove_active(g, .p38);
        },
        .p42 => {
            g.set_flag(.p42);
            g.rev_per_sec_flag = 1;
            g.standard_ops = g.standard_ops - 500;
            g.display_message("RevTracker online");
            remove_active(g, .p42);
        },
        .p43 => {
            g.set_flag(.p43);
            g.harvester_flag = 1;
            g.standard_ops = g.standard_ops - 25000;
            g.display_message("Harvester Drone facilities online");
            remove_active(g, .p43);
        },
        .p44 => {
            g.set_flag(.p44);
            g.wire_drone_flag = 1;
            g.standard_ops = g.standard_ops - 25000;
            g.display_message("Wire Drone facilities online");
            remove_active(g, .p44);
        },
        .p45 => {
            g.set_flag(.p45);
            g.factory_flag = 1;
            g.standard_ops = g.standard_ops - 35000;
            g.display_message("Clip factory assembly facilities online");
            remove_active(g, .p45);
        },
        .p40 => {
            g.set_flag(.p40);
            g.funds = g.funds - 500000;
            g.trust = g.trust + 1;
            g.display_message("Gift accepted, TRUST INCREASED");
            remove_active(g, .p40);
        },
        .p40b => {
            g.set_flag(.p40b);
            g.funds = g.funds - g.bribe;
            g.bribe = g.bribe * 2;
            g.trust = g.trust + 1;
            g.display_message("Gift accepted, TRUST INCREASED");
            if (g.trust < 100) g.proj_uses[@backingInt(P.p40b)] += 1;
            remove_active(g, .p40b);
        },
        .p46 => {
            g.set_flag(.p46);
            g.boredom_level = 0;
            g.space_flag = 1;
            g.standard_ops = g.standard_ops - 120000;
            g.stored_power = g.stored_power - 10000000;
            g.unused_clips = g.unused_clips - pow(10, 27) * 5;
            g.display_message("Von Neumann Probes online");
            factory_reboot(g);
            harvester_reboot(g);
            wire_drone_reboot(g);
            farm_reboot(g);
            battery_reboot(g);
            g.farm_level = 1;
            g.pow_mod = 1;
            remove_active(g, .p46);
        },
        .p50 => {
            g.set_flag(.p50);
            g.q_flag = 1;
            g.standard_ops = g.standard_ops - 10000;
            g.display_message("Quantum computing online");
            remove_active(g, .p50);
        },
        .p51 => {
            g.set_flag(.p51);
            g.standard_ops = g.standard_ops - g.q_chip_cost;
            g.q_chip_cost = g.q_chip_cost + 5000;
            const nq: usize = @intFromFloat(g.next_qchip);
            g.q_chips[nq].active = 1;
            g.next_qchip = g.next_qchip + 1;
            g.display_message("Photonic chip added");
            if (g.next_qchip < 10) g.proj_uses[@backingInt(P.p51)] += 1;
            remove_active(g, .p51);
        },
        .p60 => {
            g.set_flag(.p60);
            g.standard_ops = g.standard_ops - 15000;
            add_strat(g, 1, "A100 added to strategy pool");
            remove_active(g, .p60);
        },
        .p61 => {
            g.set_flag(.p61);
            g.standard_ops = g.standard_ops - 17500;
            add_strat(g, 2, "B100 added to strategy pool");
            remove_active(g, .p61);
        },
        .p62 => {
            g.set_flag(.p62);
            g.standard_ops = g.standard_ops - 20000;
            add_strat(g, 3, "GREEDY added to strategy pool");
            remove_active(g, .p62);
        },
        .p63 => {
            g.set_flag(.p63);
            g.standard_ops = g.standard_ops - 22500;
            add_strat(g, 4, "GENEROUS added to strategy pool");
            remove_active(g, .p63);
        },
        .p64 => {
            g.set_flag(.p64);
            g.standard_ops = g.standard_ops - 25000;
            add_strat(g, 5, "MINIMAX added to strategy pool");
            remove_active(g, .p64);
        },
        .p65 => {
            g.set_flag(.p65);
            g.standard_ops = g.standard_ops - 30000;
            add_strat(g, 6, "TIT FOR TAT added to strategy pool");
            remove_active(g, .p65);
        },
        .p66 => {
            g.set_flag(.p66);
            g.standard_ops = g.standard_ops - 32500;
            add_strat(g, 7, "BEAT LAST added to strategy pool");
            remove_active(g, .p66);
        },
        .p100 => {
            g.set_flag(.p100);
            g.standard_ops = g.standard_ops - 80000;
            g.factory_rate = g.factory_rate * 100;
            g.display_message("Factory upgrades complete. Clip creation rate now 100x faster");
            remove_active(g, .p100);
        },
        .p101 => {
            g.set_flag(.p101);
            g.standard_ops = g.standard_ops - 85000;
            g.factory_rate = g.factory_rate * 1000;
            g.display_message("Factories now synchronized at hyperspeed. Clip creation rate now 1000x faster");
            remove_active(g, .p101);
        },
        .p102 => {
            g.set_flag(.p102);
            g.unused_clips = g.unused_clips - 1000000000000000000000;
            g.factory_boost = 1000;
            g.display_message("Self-correcting factories online. Each factory added to the network increases every factory's output 1,000x.");
            remove_active(g, .p102);
        },
        .p110 => {
            g.set_flag(.p110);
            g.standard_ops = g.standard_ops - 80000;
            g.harvester_rate = g.harvester_rate * 100;
            g.wire_drone_rate = g.wire_drone_rate * 100;
            g.display_message("Drone repulsion online. Harvesting & wire creation rates are now 100x faster.");
            remove_active(g, .p110);
        },
        .p111 => {
            g.set_flag(.p111);
            g.standard_ops = g.standard_ops - 100000;
            g.harvester_rate = g.harvester_rate * 1000;
            g.wire_drone_rate = g.wire_drone_rate * 1000;
            g.display_message("Drone alignment online. Harvesting & wire creation rates are now 1000x faster.");
            remove_active(g, .p111);
        },
        .p112 => {
            g.set_flag(.p112);
            g.yomi = g.yomi - 12000;
            g.drone_boost = 2;
            g.display_message("Adversarial cohesion online. Each drone added to the flock increases every drone's output 2x.");
            remove_active(g, .p112);
        },
        .p118 => {
            g.set_flag(.p118);
            g.auto_tourney_flag = 1;
            g.creativity = g.creativity - 50000;
            g.display_message("AutoTourney online.");
            remove_active(g, .p118);
        },
        .p119 => {
            g.set_flag(.p119);
            g.creativity = g.creativity - 25000;
            g.yomi_boost = 2;
            g.tourney_cost = 16000;
            g.display_message("Yomi production doubled.");
            remove_active(g, .p119);
        },
        .p120 => {
            g.set_flag(.p120);
            g.standard_ops = g.standard_ops - 175000;
            g.yomi = g.yomi - 15000;
            g.attack_speed_flag = 1;
            g.display_message("OODA Loop routines uploaded. Probe Speed now affects defensive maneuvering.");
            remove_active(g, .p120);
        },
        .p121 => {
            g.set_flag(.p121);
            g.battle_name_flag = 1;
            g.battle_end_timer = 200;
            g.creativity = g.creativity - 225000;
            g.display_message("What I have done up to this is nothing. I am only at the beginning of the course I must run.");
            remove_active(g, .p121);
        },
        .p125 => {
            g.set_flag(.p125);
            g.momentum = 1;
            g.creativity = g.creativity - 30000;
            g.display_message("Activit\u{e9}, activit\u{e9}, vitesse.");
            remove_active(g, .p125);
        },
        .p126 => {
            g.set_flag(.p126);
            g.swarm_flag = 1;
            g.yomi = g.yomi - 12000;
            g.display_message("Swarm computing online.");
            remove_active(g, .p126);
        },
        .p127 => {
            g.set_flag(.p127);
            g.standard_ops = g.standard_ops - 40000;
            g.display_message("Power grid online.");
            remove_active(g, .p127);
        },
        .p128 => {
            g.set_flag(.p128);
            g.creativity = g.creativity - 175000;
            g.display_message("The object of war is victory, the object of victory is conquest, and the object of conquest is occupation.");
            remove_active(g, .p128);
        },
        .p129 => {
            g.set_flag(.p129);
            g.standard_ops = g.standard_ops - 125000;
            g.display_message("Improved probe hull geometry. Hazard damage reduced by %50.");
            remove_active(g, .p129);
        },
        .p130 => {
            g.set_flag(.p130);
            g.standard_ops = g.standard_ops - 100000;
            g.display_message("Swarm computing back online");
            remove_active(g, .p130);
        },
        .p131 => {
            g.set_flag(.p131);
            g.standard_ops = g.standard_ops - 150000;
            g.display_message("There is a joy in danger ");
            remove_active(g, .p131);
        },
        .p132 => {
            g.set_flag(.p132);
            g.standard_ops = g.standard_ops - 250000;
            g.creativity = g.creativity - 125000;
            g.unused_clips = g.unused_clips - pow(10, 30) * 50;
            g.honor = g.honor + 50000;
            g.display_message("A great building must begin with the unmeasurable, must go through measurable means when it is being designed and in the end must be unmeasurable. ");
            remove_active(g, .p132);
        },
        .p133 => {
            g.set_flag(.p133);
            g.creativity = g.creativity - g.threnody_cost;
            g.yomi = g.yomi - g.threnody_cost / 10;
            g.threnody_cost = g.threnody_cost + 10000;
            g.p133_title = g.threnody_title;
            g.honor = g.honor + 10000;
            g.display_message("Deep Listening is listening in every possible way to everything possible to hear no matter what you are doing. ");
            g.proj_uses[@backingInt(P.p133)] += 1;
            remove_active(g, .p133);
        },
        .p134 => {
            g.set_flag(.p134);
            g.standard_ops = g.standard_ops - 200000;
            g.yomi = g.yomi - 10000;
            g.display_message("Never interrupt your enemy when he is making a mistake. ");
            remove_active(g, .p134);
        },
        .p135 => {
            g.set_flag(.p135);
            g.unused_clips = g.unused_clips + (pow(10, 18) * 10000);
            g.memory = g.memory - 10;
            g.proj_uses[@backingInt(P.p135)] = 1;
            g.display_message("release the \u{f8}\u{f8}\u{f8}\u{f8}\u{f8} release ");
            remove_active(g, .p135);
        },
        .p140, .p141, .p142, .p143, .p144, .p145, .p146 => {
            g.standard_ops = g.standard_ops - g.drift_king_message_cost;
            g.set_flag(p);
            remove_active(g, p);
        },
        .p147, .p148 => {
            g.standard_ops = g.standard_ops - g.drift_king_message_cost;
            g.set_flag(p);
            remove_active(g, .p147);
            remove_active(g, .p148);
        },
        .p200 => {
            g.set_flag(.p200);
            g.standard_ops = g.standard_ops - 300000;
            g.prestige_u += 1;
            g.has_save_prestige = true;
            g.display_message("Entering New Universe.");
            g.restart_pending = true;
        },
        .p201 => {
            g.set_flag(.p201);
            g.creativity = g.creativity - 300000;
            g.prestige_s += 1;
            g.has_save_prestige = true;
            g.display_message("Entering Simulated Universe.");
            g.restart_pending = true;
        },
        .p210 => {
            g.set_flag(.p210);
            g.dismantle = 1;
            g.standard_ops = g.standard_ops - 100000;
            g.probe_count = 0;
            g.end_timer1 = 0;
            g.clips = g.clips + 100;
            g.unused_clips = g.unused_clips + 100;
            g.display_message("Dismantling probe facilities");
            remove_active(g, .p210);
        },
        .p211 => {
            g.set_flag(.p211);
            g.dismantle = 2;
            g.harvester_level = 0;
            g.wire_drone_level = 0;
            g.standard_ops = g.standard_ops - 100000;
            g.clips = g.clips + 100;
            g.unused_clips = g.unused_clips + 100;
            g.display_message("Dismantling the swarm");
            remove_active(g, .p211);
        },
        .p212 => {
            g.set_flag(.p212);
            g.dismantle = 3;
            g.standard_ops = g.standard_ops - 100000;
            g.factory_level = 0;
            g.clips = g.clips + 15;
            g.unused_clips = g.unused_clips + 15;
            g.display_message("Dismantling factories");
            remove_active(g, .p212);
        },
        .p213 => {
            g.auto_tourney_flag = 0;
            g.set_flag(.p213);
            g.dismantle = 4;
            g.standard_ops = g.standard_ops - 100000;
            g.wire = g.wire + 50;
            g.display_message("Dismantling strategy engine");
            remove_active(g, .p213);
        },
        .p214 => {
            g.end_timer4 = 0;
            g.set_flag(.p214);
            g.dismantle = 5;
            g.standard_ops = g.standard_ops - 100000;
            g.display_message("Dismantling photonic chips");
            remove_active(g, .p214);
        },
        .p215 => {
            g.creativity_on = false;
            g.set_flag(.p215);
            g.dismantle = 6;
            g.standard_ops = g.standard_ops - 100000;
            g.processors = 0;
            g.p216_ops = g.standard_ops;
            g.p216_set = true;
            g.wire = g.wire + 20;
            g.display_message("Dismantling processors");
            remove_active(g, .p215);
        },
        .p216 => {
            g.set_flag(.p216);
            g.dismantle = 7;
            g.standard_ops = 0;
            g.memory = 0;
            g.wire = g.wire + 20;
            g.display_message("Dismantling memory");
            remove_active(g, .p216);
        },
        .p217 => {
            // confirm("Are you sure you want to restart?") is taken as yes.
            g.standard_ops = g.standard_ops + 10000;
            g.set_flag(.p217);
            g.display_message("Restart");
            remove_active(g, .p217);
            g.restart_pending = true;
        },
        .p218 => {
            g.creativity = g.creativity - 1000000;
            g.set_flag(.p218);
            g.display_message("In the end we all do what we must");
            remove_active(g, .p218);
        },
        .p219 => {
            g.creativity = g.creativity - 100000;
            g.set_flag(.p219);
            g.memory = 0;
            g.processors = 0;
            g.creativity_speed = 0;
            g.proj_uses[@backingInt(P.p219)] += 1;
            g.display_message("Trust now available for re-allocation");
            remove_active(g, .p219);
        },
    }
}

/// The project's title as the DOM shows it (project 133's changes).
pub fn project_title(g: *const Game, p: P, buf: []u8) []const u8 {
    if (p == .p133) {
        var o = fmt.Out.init(buf);
        o.str("Threnody for the Heroes of ");
        g.p133_title.write(&o);
        o.byte(' ');
        return o.slice();
    }
    return projects.defs[@backingInt(p)].title;
}

/// The project's priceTag as the DOM shows it (40b, 51, 133, 216 change).
pub fn project_price_tag(g: *const Game, p: P, buf: []u8) []const u8 {
    var o = fmt.Out.init(buf);
    switch (p) {
        .p40b => {
            o.str("($");
            fmt.write_locale(&o, g.bribe, 0, 3);
            o.byte(')');
        },
        .p51 => {
            o.byte('(');
            if (g.proj_flag[@backingInt(P.p51)] == 0) {
                fmt.write_locale(&o, g.q_chip_cost, 0, 3);
            } else {
                fmt.write_num(&o, g.q_chip_cost);
            }
            o.str(" ops)");
        },
        .p133 => {
            o.byte('(');
            fmt.write_locale(&o, g.threnody_cost, 0, 3);
            o.str(" creat, ");
            fmt.write_locale(&o, g.threnody_cost / 10, 0, 3);
            o.str(" yomi)");
        },
        .p216 => {
            if (g.p216_set) {
                o.byte('(');
                fmt.write_locale(&o, g.p216_ops, 0, 3);
                o.str(" ops)");
            } else o.str("null");
        },
        else => return projects.defs[@backingInt(p)].price_tag,
    }
    return o.slice();
}

pub fn project_description(p: P) []const u8 {
    return projects.defs[@backingInt(p)].description;
}

fn hypno_drone_event(g: *Game) void {
    g.add_timer(.{ .due = g.now_ms + 32, .kind = .long_blink });
}

// ===========================================================================
// buttonUpdate.

fn button_update(g: *Game) void {
    const pn = &g.panels;
    if (g.space_flag == 0) {
        pn.mdps_div = false;
    } else if (g.space_flag == 1) {
        pn.mdps_div = true;
    }
    pn.swarm_slider_div = g.swarm_flag == 1;

    pn.auto_tourney_status_div = g.auto_tourney_flag == 1;
    pn.auto_tourney_control = g.auto_tourney_flag == 1;

    g.q_fade = g.q_fade - 0.001;

    pn.wire_buyer_div = g.wire_buyer_flag == 1;

    if (g.results_flag == 1 and g.auto_tourney_flag == 1 and g.auto_tourney_status == 1 and pn.tournament_results_table) {
        g.results_timer += 1;
        if (g.results_timer >= 300 and g.operations >= g.tourney_cost) {
            strategy.new_tourney(g);
            strategy.run_tourney(g);
            g.results_timer = 0;
        }
    }

    if (g.project_flag(.p121) == 0) {
        pn.increase_max_trust_div = false;
        pn.honor_div = false;
    } else {
        pn.increase_max_trust_div = true;
        pn.honor_div = true;
    }
    pn.drifter_div = g.battle_flag != 0;
    pn.battle_canvas_div = g.battle_flag != 0;
    pn.combat_button_div = g.project_flag(.p131) != 0;
    pn.factory_upgrade_display = !(g.max_factory_level >= 50 or g.project_flag(.p45) == 0);
    if (g.max_drone_level >= 50000) pn.drone_upgrade_display = false;

    g.set_disabled(.btn_increase_max_trust, g.honor < g.max_trust_cost);
    g.set_disabled(.btn_make_probe, g.unused_clips < g.probe_cost);
    pn.hazard_body_count = !(g.probes_lost_haz < 1);
    pn.drift_body_count = !(g.probes_lost_drift < 1);
    pn.combat_body_count = !(g.probes_lost_combat < 1);
    pn.prestige_div = !(g.prestige_u < 1 and g.prestige_s < 1);

    g.set_disabled(.btn_make_paperclip, g.wire < 1);
    g.set_disabled(.btn_buy_wire, g.funds < g.wire_cost);
    g.set_disabled(.btn_make_clipper, g.funds < g.clipper_cost);
    g.set_disabled(.btn_expand_marketing, g.funds < g.ad_cost);
    g.set_disabled(.btn_lower_price, g.margin <= 0.01);
    const no_proc = g.trust <= g.processors + g.memory and g.swarm_gifts <= 0;
    g.set_disabled(.btn_add_proc, no_proc);
    g.set_disabled(.btn_add_mem, no_proc);
    g.set_disabled(.btn_new_tournament, !(g.operations >= g.tourney_cost and g.tourney_in_prog == 0));
    g.set_disabled(.btn_improve_investments, g.yomi < g.invest_upgrade_cost);
    pn.investment_engine = g.investment_engine_flag != 0;
    pn.investment_engine_upgrade = g.investment_engine_flag != 0;
    pn.strategy_engine = g.strategy_engine_flag != 0;
    pn.tournament_management = g.strategy_engine_flag != 0;
    pn.mega_clipper_div = g.mega_clipper_flag != 0;
    g.set_disabled(.btn_make_mega_clipper, g.funds < g.mega_clipper_cost);
    pn.auto_clipper_div = g.auto_clipper_flag != 0;
    if (g.funds >= 5) g.auto_clipper_flag = 1;
    pn.rev_per_sec_div = g.rev_per_sec_flag != 0;
    pn.comp_div = g.comp_flag != 0;
    pn.creativity_div = g.creativity_on;
    pn.projects_div = g.projects_flag != 0;

    if (g.human_flag == 0) {
        pn.business_div = false;
        pn.manufacturing_div = false;
        pn.trust_div = false;
        g.investment_engine_flag = 0;
        g.wire_buyer_flag = 0;
        pn.creation_div = true;
    } else {
        pn.business_div = true;
        pn.manufacturing_div = true;
        pn.trust_div = true;
        pn.creation_div = false;
    }
    pn.factory_div = g.factory_flag != 0;
    if (g.wire_production_flag == 0) {
        pn.wire_production_div = false;
    } else {
        pn.wire_production_div = true;
        pn.wire_trans_div = false;
    }
    pn.harvester_div = g.harvester_flag != 0;
    pn.wire_drone_div = g.wire_drone_flag != 0;
    pn.toth_div = g.toth_flag != 0;
    if (g.space_flag == 0) {
        pn.space_div = false;
        pn.factory_div_space = false;
        pn.drone_div_space = false;
        pn.probe_design_div = false;
        pn.increase_probe_trust_div = false;
    } else {
        pn.space_div = true;
        pn.factory_div_space = true;
        pn.drone_div_space = true;
        pn.probe_design_div = true;
        pn.increase_probe_trust_div = true;
        pn.factory_div = false;
        pn.harvester_div = false;
        pn.wire_drone_div = false;
    }
    pn.q_computing = g.q_flag != 0;

    g.set_disabled(.btn_make_factory, g.unused_clips < g.factory_cost);
    g.set_disabled(.btn_harvester_reboot, g.harvester_level == 0);
    g.set_disabled(.btn_wire_drone_reboot, g.wire_drone_level == 0);
    g.set_disabled(.btn_factory_reboot, g.factory_level == 0);

    // PROBE DESIGN
    g.probe_used_trust = (g.probe_speed + g.probe_nav + g.probe_rep + g.probe_haz + g.probe_fac + g.probe_harv + g.probe_wire + g.probe_combat);
    g.set_disabled(.btn_increase_probe_trust, g.yomi < g.probe_trust_cost or g.probe_trust >= g.max_trust);
    const no_room = g.probe_trust - g.probe_used_trust < 1;
    g.set_disabled(.btn_raise_probe_speed, no_room);
    g.set_disabled(.btn_lower_probe_speed, g.probe_speed < 1);
    g.set_disabled(.btn_raise_probe_nav, no_room);
    g.set_disabled(.btn_lower_probe_nav, g.probe_nav < 1);
    g.set_disabled(.btn_raise_probe_rep, no_room);
    g.set_disabled(.btn_lower_probe_rep, g.probe_rep < 1);
    g.set_disabled(.btn_raise_probe_haz, no_room);
    g.set_disabled(.btn_lower_probe_haz, g.probe_haz < 1);
    g.set_disabled(.btn_raise_probe_fac, no_room);
    g.set_disabled(.btn_lower_probe_fac, g.probe_fac < 1);
    g.set_disabled(.btn_raise_probe_harv, no_room);
    g.set_disabled(.btn_lower_probe_harv, g.probe_harv < 1);
    g.set_disabled(.btn_raise_probe_wire, no_room);
    g.set_disabled(.btn_lower_probe_wire, g.probe_wire < 1);
    g.set_disabled(.btn_raise_probe_combat, no_room);
    g.set_disabled(.btn_lower_probe_combat, g.probe_combat < 1);

    pn.cover = false;
}

// ===========================================================================
// Business.

fn clip_click(g: *Game, number_in: f64) void {
    var number = number_in;
    if (g.dismantle >= 4) g.final_clips += 1;
    if (g.wire >= 1) {
        if (number > g.wire) number = g.wire;
        g.clips = g.clips + number;
        g.unsold_clips = g.unsold_clips + number;
        g.wire = g.wire - number;
        g.unused_clips = g.unused_clips + number;
    }
}

fn make_clipper(g: *Game) void {
    if (g.funds >= g.clippper_cost) {
        g.clipmaker_level = g.clipmaker_level + 1;
        g.funds = g.funds - g.clipper_cost;
    }
    g.clipper_cost = (pow(1.1, g.clipmaker_level) + 5);
}

fn make_mega_clipper(g: *Game) void {
    if (g.funds >= g.mega_clipper_cost) {
        g.mega_clipper_level = g.mega_clipper_level + 1;
        g.funds = g.funds - g.mega_clipper_cost;
    }
    g.mega_clipper_cost = (pow(1.07, g.mega_clipper_level) * 1000);
}

fn buy_ads(g: *Game) void {
    if (g.funds >= g.ad_cost) {
        g.marketing_lvl = g.marketing_lvl + 1;
        g.funds = g.funds - g.ad_cost;
        g.ad_cost = floor(g.ad_cost * 2);
    }
}

fn sell_clips(g: *Game, number: f64) void {
    if (g.unsold_clips > 0) {
        if (number > g.unsold_clips) {
            g.transaction = (floor((g.unsold_clips * g.margin) * 1000)) / 1000;
            g.funds = (floor((g.funds + g.transaction) * 100)) / 100;
            g.income = g.income + g.transaction;
            g.clips_sold = g.clips_sold + g.unsold_clips;
            g.unsold_clips = 0;
        } else {
            g.transaction = (floor((number * g.margin) * 1000)) / 1000;
            g.funds = (floor((g.funds + g.transaction) * 100)) / 100;
            g.income = g.income + g.transaction;
            g.clips_sold = g.clips_sold + number;
            g.unsold_clips = g.unsold_clips - number;
        }
    }
}

fn raise_price(g: *Game) void {
    g.margin = (round((g.margin + 0.01) * 100)) / 100;
}

fn lower_price(g: *Game) void {
    if (g.margin >= 0.01) g.margin = (round((g.margin - 0.01) * 100)) / 100;
}

fn calculate_rev(g: *Game) void {
    g.income_then = g.income_now;
    g.income_now = g.income;
    g.income_last_second = round((g.income_now - g.income_then) * 100) / 100;
    g.income_tracker[g.income_tracker_len] = g.income_last_second;
    g.income_tracker_len += 1;
    if (g.income_tracker_len > 10) {
        var k: usize = 1;
        while (k < g.income_tracker_len) : (k += 1) g.income_tracker[k - 1] = g.income_tracker[k];
        g.income_tracker_len -= 1;
    }
    g.sum = 0;
    for (g.income_tracker[0..g.income_tracker_len]) |v| g.sum = round((g.sum + v) * 100) / 100;
    g.true_avg_rev = g.sum / @as(f64, @floatFromInt(g.income_tracker_len));

    var chance = g.demand / 100;
    if (chance > 1) chance = 1;
    if (g.unsold_clips < 1) chance = 0;
    g.avg_sales = chance * (0.7 * pow(g.demand, 1.15)) * 10;
    g.avg_rev = chance * (0.7 * pow(g.demand, 1.15)) * g.margin * 10;
    if (g.demand > g.unsold_clips) {
        g.avg_rev = g.true_avg_rev;
        g.avg_sales = g.avg_rev / g.margin;
    }
}

fn calculate_creativity(g: *Game) void {
    g.creativity_counter += 1;
    const threshold: f64 = 400;
    const s = g.prestige_s / 10;
    const ss = g.creativity_speed + (g.creativity_speed * s);
    const check = threshold / ss;
    if (g.creativity_counter >= check) {
        if (check >= 1) g.creativity = g.creativity + 1;
        if (check < 1) g.creativity = (g.creativity + ss / threshold);
        g.creativity_counter = 0;
    }
}

fn calculate_trust(g: *Game) void {
    if (g.clips > (g.next_trust - 1)) {
        g.trust = g.trust + 1;
        g.display_message("Production target met: TRUST INCREASED, additional processor/memory capacity granted");
        const fib_next = g.fib1 + g.fib2;
        g.next_trust = fib_next * 1000;
        g.fib1 = g.fib2;
        g.fib2 = fib_next;
    }
}

fn add_proc(g: *Game) void {
    g.processors = g.processors + 1;
    g.creativity_speed = jsmath.log10(g.processors) * pow(g.processors, 1.1) + g.processors - 1;
    if (g.creativity_on) {
        g.display_message("Processor added, operations (or creativity) per sec increased");
    } else {
        g.display_message("Processor added, operations per sec increased");
    }
    if (g.human_flag == 0) g.swarm_gifts = g.swarm_gifts - 1;
}

fn add_mem(g: *Game) void {
    g.display_message("Memory added, max operations increased");
    g.memory = g.memory + 1;
    if (g.human_flag == 0) g.swarm_gifts = g.swarm_gifts - 1;
}

fn calculate_operations(g: *Game) void {
    if (g.temp_ops > 0) g.op_fade_timer += 1;
    if (g.op_fade_timer > g.op_fade_delay and g.temp_ops > 0) {
        g.op_fade = g.op_fade + pow(3, 3.5) / 1000;
    }
    if (g.temp_ops > 0) {
        g.temp_ops = round(g.temp_ops - g.op_fade);
    } else {
        g.temp_ops = 0;
    }
    if (g.temp_ops + g.standard_ops < g.memory * 1000) {
        g.standard_ops = g.standard_ops + g.temp_ops;
        g.temp_ops = 0;
    }
    g.operations = floor(g.standard_ops + floor(g.temp_ops));
    if (g.operations < g.memory * 1000) {
        var op_cycle = g.processors / 10;
        const op_buf = (g.memory * 1000) - g.operations;
        if (op_cycle > op_buf) op_cycle = op_buf;
        g.standard_ops = g.standard_ops + op_cycle;
    }
    if (g.standard_ops > g.memory * 1000) g.standard_ops = g.memory * 1000;
}

fn milestone_msg(g: *Game, before: []const u8) void {
    var b: [128]u8 = undefined;
    var o = fmt.Out.init(&b);
    o.str(before);
    fmt.write_time_cruncher(&o, g.ticks);
    g.display_message(o.slice());
}

fn milestone_check(g: *Game) void {
    if (g.milestone_flag == 0 and g.funds >= 5) {
        g.milestone_flag += 1;
        g.display_message("AutoClippers available for purchase");
    }
    if (g.milestone_flag == 1 and ceil(g.clips) >= 500) {
        g.milestone_flag += 1;
        milestone_msg(g, "500 clips created in ");
    }
    if (g.milestone_flag == 2 and ceil(g.clips) >= 1000) {
        g.milestone_flag += 1;
        milestone_msg(g, "1,000 clips created in ");
    }
    if (g.comp_flag == 0 and g.unsold_clips < 1 and g.funds < g.wire_cost and g.wire < 1) {
        g.comp_flag = 1;
        g.projects_flag = 1;
        g.display_message("Trust-Constrained Self-Modification enabled");
    }
    if (g.comp_flag == 0 and ceil(g.clips) >= 2000) {
        g.comp_flag = 1;
        g.projects_flag = 1;
        g.display_message("Trust-Constrained Self-Modification enabled");
    }
    if (g.milestone_flag == 3 and ceil(g.clips) >= 10000) {
        g.milestone_flag += 1;
        milestone_msg(g, "10,000 clips created in ");
    }
    if (g.milestone_flag == 4 and ceil(g.clips) >= 100000) {
        g.milestone_flag += 1;
        milestone_msg(g, "100,000 clips created in ");
    }
    if (g.milestone_flag == 5 and ceil(g.clips) >= 1000000) {
        g.milestone_flag += 1;
        milestone_msg(g, "1,000,000 clips created in ");
    }
    if (g.milestone_flag == 6 and g.project_flag(.p35) == 1) {
        g.milestone_flag += 1;
        milestone_msg(g, "Full autonomy attained in ");
    }
    if (g.milestone_flag == 7 and ceil(g.clips) >= 1000000000000) {
        g.milestone_flag += 1;
        milestone_msg(g, "One Trillion Clips Created in ");
    }
    if (g.milestone_flag == 8 and ceil(g.clips) >= 1000000000000000) {
        g.milestone_flag += 1;
        milestone_msg(g, "One Quadrillion Clips Created in ");
    }
    if (g.milestone_flag == 9 and ceil(g.clips) >= 1000000000000000000) {
        g.milestone_flag += 1;
        milestone_msg(g, "One Quintillion Clips Created in ");
    }
    if (g.milestone_flag == 10 and ceil(g.clips) >= 1000000000000000000000) {
        g.milestone_flag += 1;
        milestone_msg(g, "One Sextillion Clips Created in ");
    }
    if (g.milestone_flag == 11 and ceil(g.clips) >= 1e24) {
        g.milestone_flag += 1;
        milestone_msg(g, "One Septillion Clips Created in ");
    }
    if (g.milestone_flag == 12 and ceil(g.clips) >= 1e27) {
        g.milestone_flag += 1;
        milestone_msg(g, "One Octillion Clips Created in ");
    }
    if (g.milestone_flag == 13 and g.space_flag == 1) {
        g.milestone_flag += 1;
        milestone_msg(g, "Terrestrial resources fully utilized in ");
    }
    if (g.milestone_flag == 14 and g.clips >= g.total_matter) {
        g.milestone_flag += 1;
        milestone_msg(g, "Universal Paperclips achieved in ");
    }
    if (g.milestone_flag == 14 and g.found_matter >= g.total_matter and g.available_matter < 1 and g.wire < 1) {
        g.milestone_flag += 1;
        milestone_msg(g, "Universal Paperclips achieved in ");
    }
}

// ===========================================================================
// Stage 2: factories, drones, power, swarm.

pub fn update_upgrades(g: *Game) void {
    var nfup: f64 = 0;
    var ndup: f64 = 0;
    if (g.max_factory_level < 10) {
        nfup = 10;
    } else if (g.max_factory_level < 20) {
        nfup = 20;
    } else if (g.max_factory_level < 50) {
        nfup = 50;
    }
    if (g.max_drone_level < 500) {
        ndup = 500;
    } else if (g.max_drone_level < 5000) {
        ndup = 5000;
    } else if (g.max_drone_level < 50000) {
        ndup = 50000;
    }
    g.next_factory_upgrade = nfup;
    g.next_drone_upgrade = ndup;
}

fn make_factory(g: *Game) void {
    g.unused_clips = g.unused_clips - g.factory_cost;
    g.factory_bill = g.factory_bill + g.factory_cost;
    g.factory_level += 1;
    var fcmod: f64 = 1;
    const fl = g.factory_level;
    if (fl > 0 and fl < 8) {
        fcmod = 11 - fl;
    } else if (fl > 7 and fl < 13) {
        fcmod = 2;
    } else if (fl > 12 and fl < 20) {
        fcmod = 1.5;
    } else if (fl > 19 and fl < 39) {
        fcmod = 1.25;
    } else if (fl > 38 and fl < 79) {
        fcmod = 1.15;
    } else if (fl > 78 and fl < 99) {
        fcmod = 1.10;
    } else if (fl > 98 and fl < 199) {
        fcmod = 1.10;
    } else if (fl > 198) {
        fcmod = 1.10;
    }
    if (g.factory_level > g.max_factory_level) g.max_factory_level = g.factory_level;
    update_upgrades(g);
    g.factory_cost = g.factory_cost * fcmod;
}

fn make_harvester(g: *Game, amount: u32) void {
    var x: u32 = 0;
    while (x < amount) : (x += 1) {
        g.unused_clips = g.unused_clips - g.harvester_cost;
        g.harvester_bill = g.harvester_bill + g.harvester_cost;
        g.harvester_level += 1;
        g.harvester_cost = pow((g.harvester_level + 1), 2.25) * 1000000;
    }
    if (g.harvester_level + g.wire_drone_level > g.max_drone_level) g.max_drone_level = g.harvester_level + g.wire_drone_level;
    update_drone_prices(g);
    update_upgrades(g);
}

fn make_wire_drone(g: *Game, amount: u32) void {
    var x: u32 = 0;
    while (x < amount) : (x += 1) {
        g.unused_clips = g.unused_clips - g.wire_drone_cost;
        g.wire_drone_bill = g.wire_drone_bill + g.wire_drone_cost;
        g.wire_drone_level += 1;
        g.wire_drone_cost = pow((g.wire_drone_level + 1), 2.25) * 1000000;
    }
    if (g.harvester_level + g.wire_drone_level > g.max_drone_level) g.max_drone_level = g.harvester_level + g.wire_drone_level;
    update_drone_prices(g);
    update_upgrades(g);
}

fn sum_pow(start: f64, n: u32, e: f64, mul: f64) f64 {
    var s: f64 = 0;
    var h = start;
    var x: u32 = 0;
    while (x < n) : (x += 1) {
        s = s + pow(h, e) * mul;
        h += 1;
    }
    return s;
}

pub fn update_drone_prices(g: *Game) void {
    // The JS recomputes 1110 pow() per kind; the 10 and 100 sums are
    // prefixes of the 1000 one, accumulated in the same order, so one
    // pass gives bit-identical results.
    const hs = sum_prefixes(g.harvester_level + 1);
    g.p10h = hs[0];
    g.p100h = hs[1];
    g.p1000h = hs[2];
    const ws = sum_prefixes(g.wire_drone_level + 1);
    g.p10w = ws[0];
    g.p100w = ws[1];
    g.p1000w = ws[2];
}

fn sum_prefixes(start: f64) [3]f64 {
    var s: f64 = 0;
    var h = start;
    var r: [3]f64 = undefined;
    var x: u32 = 0;
    while (x < 1000) : (x += 1) {
        s = s + pow(h, 2.25) * 1000000;
        h += 1;
        if (x == 9) r[0] = s;
        if (x == 99) r[1] = s;
    }
    r[2] = s;
    return r;
}

fn update_drone_buttons(g: *Game) void {
    g.set_disabled(.btn_make_harvester, g.unused_clips < g.harvester_cost);
    g.set_disabled(.btn_harvester_x10, g.unused_clips < g.p10h);
    g.set_disabled(.btn_harvester_x100, g.unused_clips < g.p100h);
    g.set_disabled(.btn_harvester_x1000, g.unused_clips < g.p1000h);
    g.set_disabled(.btn_make_wire_drone, g.unused_clips < g.wire_drone_cost);
    g.set_disabled(.btn_wire_drone_x10, g.unused_clips < g.p10w);
    g.set_disabled(.btn_wire_drone_x100, g.unused_clips < g.p100w);
    g.set_disabled(.btn_wire_drone_x1000, g.unused_clips < g.p1000w);
}

fn harvester_reboot(g: *Game) void {
    g.harvester_level = 0;
    g.unused_clips = g.unused_clips + g.harvester_bill;
    g.harvester_bill = 0;
    update_drone_prices(g);
    g.harvester_cost = 2000000;
}

fn wire_drone_reboot(g: *Game) void {
    g.wire_drone_level = 0;
    g.unused_clips = g.unused_clips + g.wire_drone_bill;
    g.wire_drone_bill = 0;
    update_drone_prices(g);
    g.wire_drone_cost = 2000000;
}

fn factory_reboot(g: *Game) void {
    g.factory_level = 0;
    g.unused_clips = g.unused_clips + g.factory_bill;
    g.factory_bill = 0;
    g.factory_cost = 100000000;
}

fn update_swarm(g: *Game) void {
    if (g.swarm_flag == 1) g.slider_pos = g.slider_value;
    g.set_disabled(.btn_synch_swarm, g.yomi < g.synch_cost);
    g.set_disabled(.btn_entertain_swarm, g.creativity < g.entertain_cost);

    if (g.available_matter == 0 and (g.harvester_level + g.wire_drone_level) >= 1) {
        g.boredom_level = g.boredom_level + 1;
    } else if (g.available_matter > 0 and g.boredom_level > 0) {
        g.boredom_level = g.boredom_level - 1;
    }
    if (g.boredom_level >= 30000) {
        g.boredom_flag = 1;
        g.boredom_level = 0;
        if (g.boredom_msg == 0) {
            g.display_message("No matter to harvest. Inactivity has caused the Swarm to become bored");
            g.boredom_msg = 1;
        }
    }

    const drone_ratio = @max(g.harvester_level + 1, g.wire_drone_level + 1) / @min(g.harvester_level + 1, g.wire_drone_level + 1);
    if (drone_ratio < 1.5 and g.disorg_counter > 1) {
        g.disorg_counter = g.disorg_counter - 0.01;
    } else if (drone_ratio > 1.5) {
        var x = drone_ratio / 10000;
        if (x > 0.01) x = 0.01;
        g.disorg_counter = g.disorg_counter + x;
    }
    if (g.disorg_counter >= 100) {
        g.disorg_flag = 1;
        if (g.disorg_msg == 0) {
            g.display_message("Imbalance between Harvester and Wire Drone levels has disorganized the Swarm");
            g.disorg_msg = 1;
        }
    }

    const d = floor(g.harvester_level + g.wire_drone_level);
    g.swarm_size = d;

    if (g.gift_countdown <= 0) {
        g.next_gift = round((jsmath.log10(d)) * g.slider_pos / 100);
        if (g.next_gift <= 0) g.next_gift = 1;
        g.swarm_gifts = g.swarm_gifts + g.next_gift;
        if (g.milestone_flag < 15) {
            var b: [128]u8 = undefined;
            var o = fmt.Out.init(&b);
            o.str("The swarm has generated a gift of ");
            fmt.write_num(&o, g.next_gift);
            o.str(" additional computational capacity");
            g.display_message(o.slice());
        }
        g.gift_bits = 0;
    }

    if (g.pow_mod == 0) {
        g.swarm_status = 6;
    } else {
        g.swarm_status = 0;
    }
    if (g.space_flag == 1 and g.project_flag(.p130) == 0) g.swarm_status = 9;
    if (d == 0) {
        g.swarm_status = 7;
    } else if (d == 1) {
        g.swarm_status = 8;
    }
    if (g.swarm_flag == 0) g.swarm_status = 6;
    if (g.boredom_flag == 1) g.swarm_status = 3;
    if (g.disorg_flag == 1) g.swarm_status = 5;

    const pn = &g.panels;
    if (g.swarm_status == 0) {
        g.gift_bit_generation_rate = jsmath.log(d) * (g.slider_pos / 100);
        g.gift_bits = g.gift_bits + g.gift_bit_generation_rate;
        g.gift_countdown = (g.gift_period - g.gift_bits) / g.gift_bit_generation_rate;
        pn.gift_timer = true;
    } else {
        pn.gift_timer = false;
    }
    pn.feed_button_div = g.swarm_status == 1;
    pn.teach_button_div = g.swarm_status == 2;
    pn.entertain_button_div = g.swarm_status == 3;
    pn.clad_button_div = g.swarm_status == 4;
    pn.synch_button_div = g.swarm_status == 5;
    pn.swarm_status_div = g.swarm_status != 7;
    if (g.swarm_flag == 0) {
        pn.swarm_engine = false;
        pn.swarm_gift_div = false;
    } else {
        pn.swarm_engine = true;
        pn.swarm_gift_div = true;
    }
}

fn synch_swarm(g: *Game) void {
    g.yomi = g.yomi - g.synch_cost;
    g.disorg_flag = 0;
    g.disorg_counter = 0;
    g.disorg_msg = 0;
}

fn entertain_swarm(g: *Game) void {
    g.creativity = g.creativity - g.entertain_cost;
    g.entertain_cost = g.entertain_cost + 10000;
    g.boredom_flag = 0;
    g.boredom_level = 0;
    g.boredom_msg = 0;
}

pub fn update_pow_prices(g: *Game) void {
    g.p10f = sum_pow(g.farm_level + 1, 10, 2.78, 100000000);
    g.p100f = sum_pow(g.farm_level + 1, 100, 2.78, 100000000);
    g.p10b = sum_pow(g.battery_level + 1, 10, 2.54, 10000000);
    g.p100b = sum_pow(g.battery_level + 1, 100, 2.54, 10000000);
}

fn make_farm(g: *Game, amount: u32) void {
    var x: u32 = 0;
    while (x < amount) : (x += 1) {
        g.unused_clips = g.unused_clips - g.farm_cost;
        g.farm_bill = g.farm_bill + g.farm_cost;
        g.farm_level += 1;
        g.farm_cost = pow(g.farm_level + 1, 2.78) * 100000000;
    }
    update_pow_prices(g);
}

fn farm_reboot(g: *Game) void {
    g.farm_level = 0;
    g.unused_clips = g.unused_clips + g.farm_bill;
    g.farm_bill = 0;
    update_pow_prices(g);
    g.farm_cost = 10000000;
}

fn make_battery(g: *Game, amount: u32) void {
    var x: u32 = 0;
    while (x < amount) : (x += 1) {
        g.unused_clips = g.unused_clips - g.battery_cost;
        g.battery_bill = g.battery_bill + g.battery_cost;
        g.battery_level += 1;
        g.battery_cost = pow(g.battery_level + 1, 2.54) * 10000000;
    }
    update_pow_prices(g);
}

fn battery_reboot(g: *Game) void {
    g.battery_level = 0;
    g.unused_clips = g.unused_clips + g.battery_bill;
    g.battery_bill = 0;
    update_pow_prices(g);
    g.stored_power = 0;
    g.battery_cost = 1000000;
}

fn update_power(g: *Game) void {
    if (g.space_flag == 0) {
        const supply = g.farm_level * g.farm_rate / 100;
        const d_demand = (g.harvester_level * g.drone_power_rate / 100) + (g.wire_drone_level * g.drone_power_rate / 100);
        const f_demand = (g.factory_level * g.factory_power_rate / 100);
        const demand = d_demand + f_demand;
        var xs_demand: f64 = 0;
        var xs_supply: f64 = 0;
        const cap = g.battery_level * g.battery_size;
        if (supply >= demand) {
            xs_supply = supply - demand;
            if (g.stored_power < cap) {
                if (xs_supply > cap - g.stored_power) xs_supply = cap - g.stored_power;
                g.stored_power = g.stored_power + xs_supply;
            }
            if (g.pow_mod < 1) g.pow_mod = 1;
            if (g.momentum == 1) g.pow_mod = g.pow_mod + 0.0001;
        } else if (supply < demand) {
            xs_demand = demand - supply;
            if (g.stored_power > 0) {
                if (g.stored_power >= xs_demand) {
                    if (g.momentum == 1) g.pow_mod = g.pow_mod + 0.0001;
                    g.stored_power = g.stored_power - xs_demand;
                } else if (g.stored_power < xs_demand) {
                    xs_demand = xs_demand - g.stored_power;
                    g.stored_power = 0;
                    const nu_supply = supply - xs_demand;
                    g.pow_mod = nu_supply / demand;
                }
            } else if (g.stored_power <= 0) {
                g.pow_mod = supply / demand;
            }
        }
        g.power_supply = supply;
        g.power_demand = demand;
        g.power_f_demand = f_demand;
        g.power_d_demand = d_demand;
        g.power_cap = cap;
        g.set_disabled(.btn_make_farm, g.unused_clips < g.farm_cost);
        g.set_disabled(.btn_make_battery, g.unused_clips < g.battery_cost);
        g.set_disabled(.btn_farm_reboot, g.farm_level < 1);
        g.set_disabled(.btn_battery_reboot, g.battery_level < 1);
        g.set_disabled(.btn_farm_x10, g.unused_clips < g.p10f);
        g.set_disabled(.btn_farm_x100, g.unused_clips < g.p100f);
        g.set_disabled(.btn_battery_x10, g.unused_clips < g.p10b);
        g.set_disabled(.btn_battery_x100, g.unused_clips < g.p100b);
    }
    g.panels.power_div = g.project_flag(.p127) == 1 and g.space_flag == 0;
}

/// Display: `performance` (the power panel's percentage).
pub fn performance(g: *const Game) f64 {
    if (g.factory_level == 0 and g.harvester_level == 0 and g.wire_drone_level == 0) return 0;
    return round(g.pow_mod * 100);
}

fn acquire_matter(g: *Game) void {
    if (g.available_matter > 0) {
        var dbsth: f64 = 1;
        if (g.drone_boost > 1) dbsth = g.drone_boost * floor(g.harvester_level);
        var mtr = g.pow_mod * dbsth * floor(g.harvester_level) * g.harvester_rate;
        mtr = mtr * ((200 - g.slider_pos) / 100);
        if (mtr > g.available_matter) mtr = g.available_matter;
        g.available_matter = g.available_matter - mtr;
        g.acquired_matter = g.acquired_matter + mtr;
        g.disp_maps = mtr * 100;
    } else {
        g.disp_maps = 0;
    }
}

fn process_matter(g: *Game) void {
    if (g.acquired_matter > 0) {
        var dbstw: f64 = 1;
        if (g.drone_boost > 1) dbstw = g.drone_boost * floor(g.wire_drone_level);
        var a = g.pow_mod * dbstw * floor(g.wire_drone_level) * g.wire_drone_rate;
        a = a * ((200 - g.slider_pos) / 100);
        if (a > g.acquired_matter) a = g.acquired_matter;
        g.acquired_matter = g.acquired_matter - a;
        g.wire = g.wire + a;
        g.disp_wpps = a * 100;
    } else {
        g.disp_wpps = 0;
    }
}

// ===========================================================================
// Stage 3: probes.

fn increase_probe_trust(g: *Game) void {
    g.yomi = g.yomi - g.probe_trust_cost;
    g.probe_trust += 1;
    g.probe_trust_cost = floor(pow(g.probe_trust + 1, 1.47) * 200);
    g.display_message("WARNING: Risk of value drift increased");
}

fn increase_max_trust(g: *Game) void {
    g.honor = g.honor - g.max_trust_cost;
    g.max_trust = g.max_trust + 10;
    g.display_message("Maximum trust increased, probe design space expanded");
}

fn probe_stat(g: *Game, s: ProbeStat, up: bool) void {
    const d: f64 = if (up) 1 else -1;
    switch (s) {
        .speed => {
            if (up) {
                g.attack_speed = g.attack_speed + g.attack_speed_mod;
            } else {
                g.attack_speed = g.attack_speed - g.attack_speed_mod;
            }
            g.probe_speed += d;
        },
        .nav => g.probe_nav += d,
        .rep => g.probe_rep += d,
        .haz => g.probe_haz += d,
        .fac => g.probe_fac += d,
        .harv => g.probe_harv += d,
        .wire => g.probe_wire += d,
        .combat => g.probe_combat += d,
    }
}

fn make_probe(g: *Game) void {
    g.unused_clips = g.unused_clips - g.probe_cost;
    g.probe_launch_level += 1;
    g.probe_count += 1;
}

fn spawn_probes(g: *Game) void {
    var next_gen = g.probe_count * g.probe_rep_base_rate * g.probe_rep;
    if (g.probe_count >= 999999999999999999999999999999999999999999999999.0) next_gen = 0;
    if (next_gen > 0 and next_gen < 1) {
        g.partial_probe_spawn = g.partial_probe_spawn + next_gen;
        if (g.partial_probe_spawn >= 1) {
            next_gen = 1;
            g.partial_probe_spawn = 0;
        }
    }
    if ((next_gen * g.probe_cost) > g.unused_clips) next_gen = floor(g.unused_clips / g.probe_cost);
    g.unused_clips = g.unused_clips - (next_gen * g.probe_cost);
    g.probe_descendents = g.probe_descendents + next_gen;
    g.probe_count = g.probe_count + next_gen;
}

fn explore_universe(g: *Game) void {
    var x_rate = floor(g.probe_count) * g.probe_x_base_rate * g.probe_speed * g.probe_nav;
    if (x_rate > g.total_matter - g.found_matter) x_rate = g.total_matter - g.found_matter;
    g.found_matter = g.found_matter + x_rate;
    g.available_matter = g.available_matter + x_rate;
    g.disp_mdps = x_rate * 100;
}

/// Display: `colonizedDisplay` = (100/(totalMatter/foundMatter)).toFixed(12).
pub fn colonized(g: *const Game) f64 {
    return 100 / (g.total_matter / g.found_matter);
}

fn encounter_hazards(g: *Game) void {
    const boost = pow(g.probe_haz, 1.6);
    var amount = g.probe_count * (g.probe_haz_base_rate / ((3 * boost) + 1));
    if (g.project_flag(.p129) == 1) amount = 0.50 * amount;
    if (amount < 1) {
        g.partial_probe_haz = g.partial_probe_haz + amount;
        if (g.partial_probe_haz >= 1) {
            amount = 1;
            g.partial_probe_haz = 0;
            g.probe_count = g.probe_count - amount;
            if (g.probe_count < 0) g.probe_count = 0;
            g.probes_lost_haz = g.probes_lost_haz + amount;
        }
    } else {
        if (amount > g.probe_count) amount = g.probe_count;
        g.probe_count = g.probe_count - amount;
        if (g.probe_count < 0) g.probe_count = 0;
        g.probes_lost_haz = g.probes_lost_haz + amount;
    }
}

fn spawn_factories(g: *Game) void {
    var amount = g.probe_count * g.probe_fac_base_rate * g.probe_fac;
    if ((amount * 100000000) > g.unused_clips) amount = floor(g.unused_clips / 100000000);
    g.unused_clips = g.unused_clips - (amount * 100000000);
    g.factory_level = g.factory_level + amount;
}

fn spawn_harvesters(g: *Game) void {
    var amount = g.probe_count * g.probe_harv_base_rate * g.probe_harv;
    if ((amount * 2000000) > g.unused_clips) amount = floor(g.unused_clips / 2000000);
    g.unused_clips = g.unused_clips - (amount * 2000000);
    g.harvester_level = g.harvester_level + amount;
}

fn spawn_wire_drones(g: *Game) void {
    var amount = g.probe_count * g.probe_wire_base_rate * g.probe_wire;
    if ((amount * 2000000) > g.unused_clips) amount = floor(g.unused_clips / 2000000);
    g.unused_clips = g.unused_clips - (amount * 2000000);
    g.wire_drone_level = g.wire_drone_level + amount;
}

fn drift(g: *Game) void {
    var amount = g.probe_count * g.probe_drift_base_rate * pow(g.probe_trust, 1.2);
    if (amount > g.probe_count) amount = g.probe_count;
    if (g.project_flag(.p148) == 1) amount = 0;
    g.probe_count = g.probe_count - amount;
    g.drifter_count = g.drifter_count + amount;
    g.probes_lost_drift = g.probes_lost_drift + amount;
}

// ===========================================================================
// The loops.

fn main_loop(g: *Game) void {
    g.ticks = g.ticks + 1;
    milestone_check(g);
    button_update(g);
    if (g.comp_flag == 1) calculate_operations(g);
    if (g.human_flag == 1) calculate_trust(g);
    if (g.q_flag == 1) quantum_compute(g);
    manage_projects(g);
    milestone_check(g);

    // Clip Rate Tracker
    g.clip_rate_tracker += 1;
    if (g.clip_rate_tracker < 100) {
        const cr = g.clips - g.prev_clips;
        g.clip_rate_temp = g.clip_rate_temp + cr;
        g.prev_clips = g.clips;
    } else {
        g.clip_rate_tracker = 0;
        g.clip_rate = g.clip_rate_temp;
        g.clip_rate_temp = 0;
    }

    // Stock Report
    g.stock_report_counter += 1;
    if (g.investment_engine_flag == 1 and g.stock_report_counter >= 10000) {
        var b: [128]u8 = undefined;
        var o = fmt.Out.init(&b);
        o.str("Lifetime investment revenue report: $");
        fmt.write_locale(&o, g.ledger + g.port_total, 0, 3);
        g.display_message(o.slice());
        g.stock_report_counter = 0;
    }

    // WireBuyer
    if (g.wire_buyer_flag == 1 and g.wire_buyer_status == 1 and g.wire <= 1) buy_wire(g);

    explore_universe(g);
    if (g.human_flag == 0 and g.space_flag == 0) update_drone_buttons(g);
    update_power(g);
    update_swarm(g);
    acquire_matter(g);
    process_matter(g);

    // Factories
    var fbst: f64 = 1;
    if (g.factory_boost > 1) fbst = g.factory_boost * g.factory_level;
    if (g.dismantle < 4) clip_click(g, g.pow_mod * fbst * (floor(g.factory_level) * g.factory_rate));

    if (g.space_flag == 1) {
        if (g.probe_count < 0) g.probe_count = 0;
        encounter_hazards(g);
        spawn_factories(g);
        spawn_harvesters(g);
        spawn_wire_drones(g);
        spawn_probes(g);
        drift(g);
        combat.check_for_battles(g);
    }

    // Auto-Clipper
    if (g.dismantle < 4) {
        clip_click(g, g.clipper_boost * (g.clipmaker_level / 100));
        clip_click(g, g.mega_clipper_boost * (g.mega_clipper_level * 5));
    }

    // Demand Curve
    if (g.human_flag == 1) {
        g.marketing = (pow(1.1, (g.marketing_lvl - 1)));
        g.demand = (((0.8 / g.margin) * g.marketing * g.marketing_effectiveness) * g.demand_boost);
        g.demand = g.demand + ((g.demand / 10) * g.prestige_u);
    }

    // Creativity
    if (g.creativity_on and g.operations >= (g.memory * 1000)) calculate_creativity(g);

    // Ending
    const pn = &g.panels;
    if (g.dismantle >= 1) {
        pn.probe_design_div = false;
        if (g.end_timer1 >= 50) pn.increase_probe_trust_div = false;
        if (g.end_timer1 >= 100) pn.increase_max_trust_div = false;
        if (g.end_timer1 >= 150) pn.space_div = false;
        if (g.end_timer1 >= 175) pn.battle_canvas_div = false;
        if (g.end_timer1 >= 190) pn.honor_div = false;
    }
    if (g.dismantle >= 2) {
        pn.wire_production_div = false;
        pn.wire_trans_div = true;
        if (g.end_timer2 >= 50) pn.swarm_gift_div = false;
        if (g.end_timer2 >= 100) pn.swarm_engine = false;
        if (g.end_timer2 >= 150) pn.swarm_slider_div = false;
    }
    if (g.dismantle >= 3) {
        pn.factory_div_space = false;
        pn.clips_per_sec_div = false;
        pn.toth_div = false;
    }
    if (g.dismantle >= 4) {
        pn.strategy_engine = false;
        pn.tournament_management = false;
    }
    if (g.dismantle >= 5) {
        pn.btn_qcompute = false;
        for (&g.q_chips) |*c| c.value = 0.5;
        // endTimer4 thresholds: one inch of wire and one chip gone each.
        const steps = [_]struct { t: f64, chip: usize }{
            .{ .t = 10, .chip = 9 },  .{ .t = 60, .chip = 8 },  .{ .t = 100, .chip = 7 },
            .{ .t = 130, .chip = 6 }, .{ .t = 150, .chip = 5 }, .{ .t = 160, .chip = 4 },
            .{ .t = 165, .chip = 3 }, .{ .t = 169, .chip = 2 }, .{ .t = 172, .chip = 1 },
            .{ .t = 174, .chip = 0 },
        };
        for (steps) |s| {
            if (g.end_timer4 == s.t) g.wire = g.wire + 1;
            if (g.end_timer4 >= s.t) pn.q_chip[s.chip] = false;
        }
        if (g.end_timer4 >= 250) pn.q_computing = false;
    }
    if (g.dismantle >= 6) pn.processor_display = false;
    if (g.dismantle >= 7) {
        pn.comp_div = false;
        pn.projects_div = false;
    }

    if (g.project_flag(.p148) == 1) g.end_timer1 += 1;
    if (g.project_flag(.p211) == 1) g.end_timer2 += 1;
    if (g.project_flag(.p212) == 1) g.end_timer3 += 1;
    if (g.project_flag(.p213) == 1) g.end_timer4 += 1;
    if (g.project_flag(.p215) == 1) g.end_timer5 += 1;
    if (g.project_flag(.p216) == 1 and g.wire == 0) g.end_timer6 += 1;

    if (g.end_timer6 >= 250) pn.creation_div = false;
    if (g.end_timer6 >= 500 and g.milestone_flag == 15) {
        g.display_message("Universal Paperclips");
        g.milestone_flag += 1;
    }
    if (g.end_timer6 >= 600 and g.milestone_flag == 16) {
        g.display_message("a game by Frank Lantz");
        g.milestone_flag += 1;
    }
    if (g.end_timer6 >= 700 and g.milestone_flag == 17) {
        g.display_message("combat programming by Bennett Foddy");
        g.milestone_flag += 1;
    }
    if (g.end_timer6 >= 800 and g.milestone_flag == 18) {
        g.display_message("'Riversong' by Tonto's Expanding Headband used by kind permission of Malcolm Cecil");
        g.milestone_flag += 1;
    }
    if (g.end_timer6 >= 900 and g.milestone_flag == 19) {
        g.display_message("&#169; 2017 Everybody House Games");
        g.milestone_flag += 1;
    }
}

fn slow_loop(g: *Game) void {
    adjust_wire_price(g);
    if (g.human_flag == 1) {
        if (g.rand() < (g.demand / 100)) sell_clips(g, floor(0.7 * pow(g.demand, 1.15)));
        g.sec_timer += 1;
        if (g.sec_timer >= 10) {
            calculate_rev(g);
            g.sec_timer = 0;
        }
    }
    g.save_timer += 1;
    if (g.save_timer >= 250) g.save_timer = 0;
}

// ===========================================================================
// Clicks.

fn btn_of(a: Action) ?Btn {
    return switch (a) {
        .make_paperclip => .btn_make_paperclip,
        .lower_price => .btn_lower_price,
        .buy_ads => .btn_expand_marketing,
        .buy_wire => .btn_buy_wire,
        .make_clipper => .btn_make_clipper,
        .make_mega_clipper => .btn_make_mega_clipper,
        .add_proc => .btn_add_proc,
        .add_mem => .btn_add_mem,
        .invest_upgrade => .btn_improve_investments,
        .new_tourney => .btn_new_tournament,
        .run_tourney => .btn_run_tournament,
        .make_factory => .btn_make_factory,
        .factory_reboot => .btn_factory_reboot,
        .make_harvester => |n| switch (n) {
            10 => .btn_harvester_x10,
            100 => .btn_harvester_x100,
            1000 => .btn_harvester_x1000,
            else => .btn_make_harvester,
        },
        .make_wire_drone => |n| switch (n) {
            10 => .btn_wire_drone_x10,
            100 => .btn_wire_drone_x100,
            1000 => .btn_wire_drone_x1000,
            else => .btn_make_wire_drone,
        },
        .harvester_reboot => .btn_harvester_reboot,
        .wire_drone_reboot => .btn_wire_drone_reboot,
        .make_farm => |n| switch (n) {
            10 => .btn_farm_x10,
            100 => .btn_farm_x100,
            else => .btn_make_farm,
        },
        .make_battery => |n| switch (n) {
            10 => .btn_battery_x10,
            100 => .btn_battery_x100,
            else => .btn_make_battery,
        },
        .farm_reboot => .btn_farm_reboot,
        .battery_reboot => .btn_battery_reboot,
        .entertain_swarm => .btn_entertain_swarm,
        .synch_swarm => .btn_synch_swarm,
        .make_probe => .btn_make_probe,
        .probe_stat_up => |s| @fromBackingInt(@intCast(@backingInt(Btn.btn_raise_probe_speed) + @backingInt(s))),
        .probe_stat_down => |s| @fromBackingInt(@intCast(@backingInt(Btn.btn_lower_probe_speed) + @backingInt(s))),
        .increase_probe_trust => .btn_increase_probe_trust,
        .increase_max_trust => .btn_increase_max_trust,
        else => null,
    };
}

/// The button's `!disabled` (false also for a project that is not shown,
/// a select value that has no option, or an amount with no button).
pub fn enabled(g: *const Game, a: Action) bool {
    switch (a) {
        .buy_project => |i| {
            if (i >= projects.count) return false;
            if (active_index(g, i) == null) return false;
            return !g.proj_disabled[i];
        },
        .set_strat_pick => |v| return v == 10 or v < g.strat_count,
        .set_slider => |v| return v <= 200,
        .make_harvester, .make_wire_drone => |n| if (n != 1 and n != 10 and n != 100 and n != 1000) return false,
        .make_farm, .make_battery => |n| if (n != 1 and n != 10 and n != 100) return false,
        else => {},
    }
    if (btn_of(a)) |b| return !g.is_disabled(b);
    return true;
}

/// The control is on screen in the original: every panel that contains it
/// shows (see `g.panels`). The UI shows rows by panels anyway; the bots use
/// `available` (shown and enabled), what a browser player can click.
pub fn shown(g: *const Game, a: Action) bool {
    const p = &g.panels;
    return switch (a) {
        .make_paperclip => true,
        .lower_price, .raise_price, .buy_ads => p.business_div,
        .buy_wire => p.manufacturing_div,
        .toggle_wire_buyer => p.manufacturing_div and p.wire_buyer_div,
        .make_clipper => p.manufacturing_div and p.auto_clipper_div,
        .make_mega_clipper => p.manufacturing_div and p.mega_clipper_div,
        .add_proc => p.comp_div and p.processor_display,
        .add_mem => p.comp_div,
        .q_compute => p.comp_div and p.q_computing and p.btn_qcompute,
        .buy_project => |i| p.projects_div and i < projects.count and !g.proj_hidden[i],
        .invest_deposit, .invest_withdraw, .set_invest_strat => p.investment_engine,
        .invest_upgrade => p.investment_engine_upgrade,
        .set_strat_pick, .run_tourney, .reveal_grid, .reveal_results => p.strategy_engine,
        .new_tourney => p.tournament_management,
        .toggle_auto_tourney => p.tournament_management and p.auto_tourney_control,
        .make_factory, .factory_reboot => p.creation_div and p.factory_div,
        .make_harvester, .harvester_reboot => p.wire_production_div and p.harvester_div,
        .make_wire_drone, .wire_drone_reboot => p.wire_production_div and p.wire_drone_div,
        .make_farm, .make_battery, .farm_reboot, .battery_reboot => p.power_div,
        .entertain_swarm => p.comp_div and p.swarm_engine and p.entertain_button_div,
        .synch_swarm => p.comp_div and p.swarm_engine and p.synch_button_div,
        .set_slider => p.comp_div and p.swarm_slider_div,
        .make_probe => p.space_div,
        .probe_stat_up, .probe_stat_down => |st| p.probe_design_div and (st != .combat or p.combat_button_div),
        .increase_probe_trust => p.increase_probe_trust_div,
        .increase_max_trust => p.increase_max_trust_div,
        .reset_all, .cheat_clips, .cheat_money, .cheat_trust, .cheat_ops, .cheat_creat, .cheat_yomi, .reset_prestige, .cheat_hypno, .cheat_prestige_u, .cheat_prestige_s, .set_battle_number, .zero_matter => true,
    };
}

/// `shown` and `enabled`: a click a browser player could make now.
pub fn available(g: *const Game, a: Action) bool {
    return shown(g, a) and enabled(g, a);
}

/// A click (or a select/slider change). Ignored when `enabled` is false.
pub fn act(g: *Game, a: Action) void {
    if (!enabled(g, a)) return;
    switch (a) {
        .make_paperclip => clip_click(g, 1),
        .lower_price => lower_price(g),
        .raise_price => raise_price(g),
        .buy_ads => buy_ads(g),
        .buy_wire => buy_wire(g),
        .toggle_wire_buyer => toggle_wire_buyer(g),
        .make_clipper => make_clipper(g),
        .make_mega_clipper => make_mega_clipper(g),
        .add_proc => add_proc(g),
        .add_mem => add_mem(g),
        .q_compute => q_comp(g),
        .buy_project => |i| project_effect(g, @fromBackingInt(@intCast(i))),
        .invest_deposit => stocks.invest_deposit(g),
        .invest_withdraw => stocks.invest_withdraw(g),
        .invest_upgrade => stocks.invest_upgrade(g),
        .set_invest_strat => |s| g.invest_strat = s,
        .set_strat_pick => |v| g.strat_picker = v,
        .new_tourney => strategy.new_tourney(g),
        .run_tourney => strategy.run_tourney(g),
        .toggle_auto_tourney => strategy.toggle_auto_tourney(g),
        .reveal_grid => strategy.reveal_grid(g),
        .reveal_results => strategy.reveal_results(g),
        .make_factory => make_factory(g),
        .factory_reboot => factory_reboot(g),
        .make_harvester => |n| make_harvester(g, n),
        .make_wire_drone => |n| make_wire_drone(g, n),
        .harvester_reboot => harvester_reboot(g),
        .wire_drone_reboot => wire_drone_reboot(g),
        .make_farm => |n| make_farm(g, n),
        .make_battery => |n| make_battery(g, n),
        .farm_reboot => farm_reboot(g),
        .battery_reboot => battery_reboot(g),
        .entertain_swarm => entertain_swarm(g),
        .synch_swarm => synch_swarm(g),
        .set_slider => |v| g.slider_value = @floatFromInt(v),
        .make_probe => make_probe(g),
        .probe_stat_up => |s| probe_stat(g, s, true),
        .probe_stat_down => |s| probe_stat(g, s, false),
        .increase_probe_trust => increase_probe_trust(g),
        .increase_max_trust => increase_max_trust(g),
        .reset_all => g.restart_pending = true,
        .cheat_clips => {
            g.clips = g.clips + 100000000;
            g.unused_clips = g.unused_clips + 100000000;
            g.display_message("you just cheated");
        },
        .cheat_money => {
            g.funds = g.funds + 10000000;
            g.display_message("LIZA just cheated");
        },
        .cheat_trust => {
            g.trust = g.trust + 1;
            g.display_message("Hilary is nice. Also, Liza just cheated");
        },
        .cheat_ops => {
            g.standard_ops = g.standard_ops + 10000;
            g.display_message("you just cheated, Liza");
        },
        .cheat_creat => {
            g.creativity_on = true;
            g.creativity = g.creativity + 1000;
            g.display_message("Liza just cheated. Very creative!");
        },
        .cheat_yomi => {
            g.yomi = g.yomi + 1000000;
            g.display_message("you just cheated");
        },
        .reset_prestige => {
            g.prestige_u = 0;
            g.prestige_s = 0;
            g.has_save_prestige = false;
        },
        .cheat_hypno => hypno_drone_event(g),
        .cheat_prestige_u => {
            g.prestige_u += 1;
            g.has_save_prestige = true;
        },
        .cheat_prestige_s => {
            g.prestige_s += 1;
            g.has_save_prestige = true;
        },
        .set_battle_number => g.battle_numbers[1] = 7,
        .zero_matter => {
            g.available_matter = 0;
            g.display_message("you just cheated");
        },
    }
    if (g.restart_pending) restart(g);
}

// ===========================================================================
// Display helpers.

/// The `clips` element text (updateStats): the count while milestoneFlag
/// < 15, then the ending's fixed strings.
pub fn clips_text(g: *const Game, buf: []u8) []const u8 {
    if (g.milestone_flag < 15) return fmt.locale(buf, ceil(g.clips), 0, 3);
    if (g.dismantle == 0) return "29,999,999,999,999,900,000,000,000,000,000,000,000,000,000,000,000,000,000";
    if (g.dismantle == 1) return "29,999,999,999,999,999,999,999,999,999,999,999,999,000,000,000,000,000,000";
    if (g.dismantle == 2) return "29,999,999,999,999,999,999,999,999,999,999,999,999,999,999,999,000,000,000";
    if (g.dismantle == 3) return "29,999,999,999,999,999,999,999,999,999,999,999,999,999,999,999,999,999,900";
    var o = fmt.Out.init(buf);
    if (g.final_clips < 10) {
        o.str("29,999,999,999,999,999,999,999,999,999,999,999,999,999,999,999,999,999,90");
        fmt.write_num(&o, g.final_clips);
    } else if (g.final_clips < 100) {
        o.str("29,999,999,999,999,999,999,999,999,999,999,999,999,999,999,999,999,999,9");
        fmt.write_num(&o, g.final_clips);
    } else {
        return "30,000,000,000,000,000,000,000,000,000,000,000,000,000,000,000,000,000,000";
    }
    return o.slice();
}

/// The ending is over: the last credit line has been shown.
pub fn credits_done(g: *const Game) bool {
    return g.milestone_flag >= 20;
}
