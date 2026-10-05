//! Representative heavy states for benchmarks and previews, set field by
//! field instead of playing thousands of virtual seconds (badge-bench
//! runs this in start() on the emulated badge). The numbers follow the
//! autoplayer's own games (bot.zig, seed 2026) at the busiest points of
//! stage 2 (the swarm at ~65,000 drones, power, factories, auto
//! tournaments, quantum) and stage 3 (half a billion probes, drifters, a
//! 200 vs 200 battle on the canvas). Not a save: the rules run on from
//! here, so the state only has to be consistent enough to keep going.

const game = @import("game.zig");
const Game = game.Game;
const P = game.P;
const jsmath = game.jsmath;
const combat = game.combat;

/// Projects bought by the end of stage 1 (no longer offered).
const stage1_done = [_]P{
    .p1,  .p3,   .p4,   .p5,  .p6,  .p7,  .p8,  .p9,  .p10, .p10b, .p11, .p12, .p13, .p14, .p15,
    .p17, .p16,  .p19,  .p20, .p21, .p22, .p23, .p24, .p25, .p26,  .p34, .p70, .p35, .p27, .p28,
    .p29, .p30,  .p31,  .p37, .p38, .p42, .p40, .p50, .p51, .p60,  .p61, .p62, .p63, .p64, .p65,
    .p66, .p118, .p119,
};
/// And by the busy middle of stage 2.
const stage2_done = [_]P{ .p18, .p127, .p41, .p43, .p44, .p45, .p100, .p101, .p110, .p111, .p125, .p126 };
/// And early in stage 3.
const stage3_done = [_]P{ .p46, .p130, .p129, .p131, .p128, .p121, .p134, .p120 };

fn done(g: *Game, list: []const P) void {
    for (list) |p| {
        g.proj_flag[@backingInt(p)] = 1;
        g.proj_uses[@backingInt(p)] = 0;
    }
}

/// `stage` 2 or 3, on a freshly `init`ed game. Runs the clock 2 s so the
/// panels and buttons settle.
pub fn prepare(g: *Game, stage: u8) void {
    // The game-start skirmish (combat.zig) is long over by stage 2.
    while (g.num_left_ships > 0 and g.num_right_ships > 0) combat.update(g);
    done(g, &stage1_done);
    done(g, &stage2_done);
    // Stage 1 behind: the HypnoDrones released, trust spent on chips.
    g.human_flag = 0;
    g.comp_flag = 1;
    g.projects_flag = 1;
    g.creativity_on = true;
    g.milestone_flag = 12;
    g.trust = 100;
    g.processors = 65;
    g.memory = 130;
    g.creativity_speed = jsmath.log10(65) * jsmath.pow(65, 1.1) + 64;
    g.standard_ops = 130000;
    g.operations = 130000;
    g.creativity = 60000;
    g.yomi = 150000;
    g.boost_lvl = 3;
    g.clipper_boost = 7.5;
    g.mega_clipper_boost = 2.75;
    g.wire_supply = 173250;
    g.marketing_effectiveness = 15;
    g.demand_boost = 50;
    g.strategy_engine_flag = 1;
    g.strat_count = 8;
    g.strat_picker = 7;
    g.yomi_boost = 2;
    g.tourney_cost = 16000;
    g.auto_tourney_flag = 1;
    g.results_flag = 1;
    g.q_flag = 1;
    for (&g.q_chips) |*c| c.active = 1;
    g.next_qchip = 10;
    g.q_chip_cost = 60000;
    // Stage 2: the swarm at work.
    g.toth_flag = 1;
    g.wire_production_flag = 1;
    g.harvester_flag = 1;
    g.wire_drone_flag = 1;
    g.factory_flag = 1;
    g.factory_rate = 1000000000 * 100 * 1000;
    g.harvester_rate = 26180337 * 100 * 1000;
    g.wire_drone_rate = 16180339 * 100 * 1000;
    g.factory_level = 200;
    g.max_factory_level = 200;
    g.factory_cost = 1.6e30;
    g.harvester_level = 32790;
    g.wire_drone_level = 32799;
    g.max_drone_level = g.harvester_level + g.wire_drone_level;
    g.harvester_cost = jsmath.pow(g.harvester_level + 1, 2.25) * 1000000;
    g.wire_drone_cost = jsmath.pow(g.wire_drone_level + 1, 2.25) * 1000000;
    g.farm_level = 2876;
    g.farm_cost = jsmath.pow(g.farm_level + 1, 2.78) * 100000000;
    g.battery_level = 1200;
    g.battery_cost = jsmath.pow(g.battery_level + 1, 2.54) * 10000000;
    g.stored_power = 2519753;
    g.pow_mod = 23.2;
    g.momentum = 1;
    g.swarm_flag = 1;
    g.slider_value = 100;
    g.slider_pos = 100;
    g.clips = 7.5e26;
    g.unused_clips = 6.2e25;
    g.available_matter = 4.785e27;
    g.acquired_matter = 4.6e26;
    g.wire = 1e24;
    game.update_drone_prices(g);
    game.update_pow_prices(g);
    game.update_upgrades(g);
    if (stage >= 3) {
        done(g, &stage3_done);
        g.milestone_flag = 14;
        g.space_flag = 1;
        g.battle_flag = 1;
        g.battle_name_flag = 1;
        g.battle_end_timer = 200;
        g.attack_speed_flag = 1;
        g.farm_level = 1;
        g.battery_level = 0;
        g.stored_power = 0;
        g.pow_mod = 1;
        g.slider_value = 20;
        g.slider_pos = 20;
        g.factory_boost = 1000;
        g.drone_boost = 2;
        g.factory_level = 3.1e6;
        g.harvester_level = 6.2e6;
        g.wire_drone_level = 6.2e6;
        g.max_trust = 30;
        g.probe_trust = 20;
        g.probe_trust_cost = jsmath.floor(jsmath.pow(g.probe_trust + 1, 1.47) * 200);
        g.probe_speed = 1;
        g.probe_nav = 1;
        g.probe_rep = 6;
        g.probe_haz = 4;
        g.probe_fac = 1;
        g.probe_harv = 1;
        g.probe_wire = 1;
        g.probe_combat = 5;
        g.probe_launch_level = 2000;
        g.probe_count = 5.4e8;
        g.probe_descendents = 5e9;
        g.drifter_count = 3.1e8;
        g.probes_lost_haz = 2.6e8;
        g.probes_lost_drift = 1e8;
        g.probes_lost_combat = 3.3e8;
        g.honor = 30000;
        g.clips = 5.4e30;
        g.unused_clips = 5.4e30;
        g.available_matter = 0;
        g.acquired_matter = 0;
        g.found_matter = 1.6e-25 * g.total_matter;
        g.wire = 0;
        // A battle in full: 200 probe ships against 200 drifters.
        combat.create_battle(g);
        g.battle_left_ships = 200;
        g.battle_right_ships = 200;
        combat.battle_restart(g);
    }
    game.advance_ms(g, 2000);
}
