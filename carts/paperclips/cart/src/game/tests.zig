//! Host tests for the game logic. Root for `zig build test` (the cart's
//! build wires it) or run directly: `zig test cart/src/game/tests.zig`.

const std = @import("std");
const game = @import("game.zig");
const fmt = game.fmt;
const jsmath = game.jsmath;
const bot_mod = @import("bot.zig");
const Game = game.Game;
const P = game.P;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

fn bits(x: f64) u64 {
    return @bitCast(x);
}

test "rng matches the SPEC xorshift64*" {
    var r = game.rng_mod.Rng.init(1);
    // x = 1: x ^= x>>12 (1); x ^= x<<25 (0x2000001); x ^= x>>27 (same)
    const x: u64 = 0x2000001;
    const want = @as(f64, @floatFromInt((x *% 0x2545F4914F6CDD1D) >> 11)) / 9007199254740992.0;
    try expectEqual(want, r.next());
}

test "JS constants and Math as V8 computes them" {
    // Values printed by Node 22 (bit patterns).
    try expectEqual(@as(u64, 0x45b363156bbee301), bits(jsmath.pow(10, 24) * 6000));
    try expectEqual(@as(u64, 0x4b73936f0f937d31), bits(jsmath.pow(10, 54) * 30));
    try expectEqual(@as(u64, 0x4376345785d8a000), bits(jsmath.pow(10, 17)));
    try expectEqual(@as(u64, 0x40574ca399362f5a), bits(jsmath.pow(1.1, 47) + 5));
    try expectEqual(@as(u64, 0x3fdae4044881c506), bits(jsmath.sin(13)));
    try expectEqual(@as(u64, 0x3ffbf8940234019f), bits(jsmath.log10(56)));
}

test {
    _ = fmt;
}

test "fmt prints like the browser" {
    var b: [128]u8 = undefined;
    try expectEqualStrings("1.001", fmt.loc(&b, 1.0005));
    try expectEqualStrings("1,180,591,620,717,411,300,000", fmt.loc(&b, std.math.pow(f64, 2, 70)));
    try expectEqualStrings("0.13", fmt.loc2(&b, 0.125));
    try expectEqualStrings("-0", fmt.loc(&b, -0.0));
    try expectEqualStrings("1.000", fmt.to_fixed(&b, 1.0005, 3));
    try expectEqualStrings("3", fmt.to_fixed(&b, 2.5, 0));
    try expectEqualStrings("0.51", fmt.num_str(&b, 0.51));
    try expectEqualStrings("0.52", fmt.num_str(&b, 0.5 + 0.01 + 0.01));
    try expectEqualStrings("4.839474365580827e+23", fmt.num_str(&b, 4.839474365580827e+23));
    try expectEqualStrings("578 ", fmt.number_cruncher(&b, 578.36, 2));
    try expectEqualStrings("483.95 sextillion", fmt.number_cruncher(&b, 4.839474365580827e+23, 2));
    try expectEqualStrings("1 hour 1 minute 1 second", fmt.time_cruncher(&b, 366100));
    try expectEqualStrings("9 minutes 38 seconds", fmt.time_cruncher(&b, 57836));
}

test "page load: welcome, combat ships, disabled Run" {
    var g: Game = undefined;
    game.init(&g, 42);
    try expectEqualStrings("Welcome to Universal Paperclips", g.message(0).?);
    try expectEqual(@as(u16, 400), g.num_ships);
    try expect(!game.enabled(&g, .run_tourney));
    try expect(game.enabled(&g, .make_paperclip));
    // Before the first tick every panel shows, like the DOM.
    try expect(g.panels.business_div and g.panels.space_div);
    game.advance_ms(&g, 10);
    try expect(g.panels.business_div and !g.panels.space_div and !g.panels.comp_div);
    try expect(!g.panels.auto_clipper_div);
}

test "making and selling clips" {
    var g: Game = undefined;
    game.init(&g, 7);
    game.advance_ms(&g, 10);
    var i: u32 = 0;
    while (i < 50) : (i += 1) game.act(&g, .make_paperclip);
    try expectEqual(@as(f64, 50), g.clips);
    try expectEqual(@as(f64, 950), g.wire);
    game.advance_ms(&g, 5000);
    try expect(g.funds > 0);
    try expect(g.unsold_clips < 50);
    // Price buttons and the margin's float rounding.
    game.act(&g, .raise_price);
    try expectEqual(@as(f64, 0.26), g.margin);
    game.act(&g, .lower_price);
    game.act(&g, .lower_price);
    try expectEqual(@as(f64, 0.24), g.margin);
}

test "AutoClippers unlock at $5 with the message" {
    var g: Game = undefined;
    game.init(&g, 3);
    game.advance_ms(&g, 10);
    g.funds = 5;
    game.advance_ms(&g, 20);
    try expectEqualStrings("AutoClippers available for purchase", g.message(0).?);
    try expect(g.panels.auto_clipper_div);
    try expect(game.enabled(&g, .make_clipper));
    game.act(&g, .make_clipper);
    try expectEqual(@as(f64, 1), g.clipmaker_level);
    try expectEqual(jsmath.pow(1.1, 1) + 5, g.clipper_cost);
}

test "projects appear, buy, leave" {
    var g: Game = undefined;
    game.init(&g, 5);
    game.advance_ms(&g, 10);
    g.comp_flag = 1;
    g.projects_flag = 1;
    g.clipmaker_level = 1;
    g.standard_ops = 800;
    g.memory = 1;
    game.advance_ms(&g, 10);
    try expect(game.is_active(&g, .p1));
    try expect(game.is_active(&g, .p42));
    const idx1: u8 = @backingInt(P.p1);
    try expect(game.enabled(&g, .{ .buy_project = idx1 }));
    game.act(&g, .{ .buy_project = idx1 });
    try expect(!game.is_active(&g, .p1));
    try expectEqual(@as(f64, 1.25), g.clipper_boost);
    try expectEqualStrings("AutoClippper performance boosted by 25%", g.message(0).?);
    // Dynamic texts.
    var b: [64]u8 = undefined;
    try expectEqualStrings("($1,000,000)", game.project_price_tag(&g, .p40b, &b));
    try expectEqualStrings("(10,000 ops)", game.project_price_tag(&g, .p51, &b));
    try expectEqualStrings("Threnody for the Heroes of Durenstein 1 ", game.project_title(&g, .p133, &b));
    try expectEqualStrings("(50,000 creat, 5,000 yomi)", game.project_price_tag(&g, .p133, &b));
    try expectEqualStrings("null", game.project_price_tag(&g, .p216, &b));
}

test "message ring keeps the newest" {
    var g: Game = undefined;
    game.init(&g, 9);
    var b: [64]u8 = undefined;
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        const s = std.fmt.bufPrint(&b, "message number {d} with some padding text", .{i}) catch unreachable;
        g.display_message(s);
    }
    try expectEqualStrings("message number 499 with some padding text", g.message(0).?);
    try expectEqualStrings("message number 498 with some padding text", g.message(1).?);
    try expect(g.messages_available() > 30);
    var k: usize = 0;
    while (g.message(k)) |m| : (k += 1) try expect(std.mem.startsWith(u8, m, "message number"));
}

test "tournament round chain runs on the 50 ms timeouts" {
    var g: Game = undefined;
    game.init(&g, 11);
    game.advance_ms(&g, 10);
    g.strategy_engine_flag = 1;
    g.comp_flag = 1;
    g.memory = 5;
    g.standard_ops = 5000;
    game.advance_ms(&g, 100);
    game.act(&g, .{ .set_strat_pick = 0 });
    game.advance_ms(&g, 100);
    try expectEqual(@as(f64, 0), g.pick);
    try expect(game.enabled(&g, .new_tourney));
    game.act(&g, .new_tourney);
    try expect(game.enabled(&g, .run_tourney));
    game.act(&g, .run_tourney);
    try expect(!game.enabled(&g, .run_tourney));
    try expectEqual(@as(f64, 1), g.r_counter);
    // One strategy: one round of 10 moves, 100 ms each.
    game.advance_ms(&g, 1100);
    try expectEqual(@as(u8, 0), g.tourney_in_prog);
    try expectEqual(@as(u8, 1), g.results_flag);
    try expect(g.yomi > 0);
    try expect(std.mem.startsWith(u8, g.message(0).?, "RANDOM scored "));
}

test "a new project blinks: hidden phases for 12 ticks of 30 ms" {
    var g: Game = undefined;
    game.init(&g, 21);
    game.advance_ms(&g, 10);
    g.comp_flag = 1;
    g.projects_flag = 1;
    game.advance_ms(&g, 10); // RevTracker (p42) shows at 20 ms
    const i: u8 = @backingInt(P.p42);
    try expect(game.is_active(&g, .p42));
    try expect(!g.proj_hidden[i]);
    game.advance_ms(&g, 30); // first toggle at 50 ms
    try expect(g.proj_hidden[i]);
    g.standard_ops = 600;
    game.advance_ms(&g, 10);
    try expect(game.enabled(&g, .{ .buy_project = i }));
    try expect(!game.available(&g, .{ .buy_project = i }));
    game.advance_ms(&g, 30 * 11);
    try expect(!g.proj_hidden[i]);
    try expectEqual(@as(f64, 0), g.blink_counter);
    try expect(game.available(&g, .{ .buy_project = i }));
}

test "cheats" {
    var g: Game = undefined;
    game.init(&g, 4);
    game.advance_ms(&g, 10);
    game.act(&g, .cheat_clips);
    try expectEqual(@as(f64, 100000000), g.clips);
    try expectEqualStrings("you just cheated", g.message(0).?);
    game.act(&g, .cheat_money);
    try expectEqual(@as(f64, 10000000), g.funds);
    game.act(&g, .cheat_trust);
    try expectEqual(@as(f64, 3), g.trust);
    game.act(&g, .cheat_ops);
    try expectEqual(@as(f64, 10000), g.standard_ops);
    game.act(&g, .cheat_creat);
    try expect(g.creativity_on);
    game.act(&g, .cheat_yomi);
    try expectEqual(@as(f64, 1000000), g.yomi);
    game.act(&g, .set_battle_number);
    try expectEqual(@as(f64, 7), g.battle_numbers[1]);
    game.act(&g, .zero_matter);
    try expectEqual(@as(f64, 0), g.available_matter);
    game.act(&g, .cheat_hypno);
    game.advance_ms(&g, 32);
    try expect(g.panels.hypno_drone_event_div);
    game.advance_ms(&g, 32 * 119);
    try expect(!g.panels.hypno_drone_event_div);
    game.act(&g, .cheat_prestige_u);
    try expectEqual(@as(f64, 1), g.prestige_u);
    game.act(&g, .reset_prestige);
    try expectEqual(@as(f64, 0), g.prestige_u);
}

test "prestige: The Universe Within restarts the universe, the clock goes on" {
    var g: Game = undefined;
    game.init(&g, 77);
    game.advance_ms(&g, 1005);
    const rng_before = g.rng.x;
    g.comp_flag = 1;
    g.projects_flag = 1;
    g.set_flag(.p147);
    g.creativity = 300000;
    game.advance_ms(&g, 10);
    const idx: u8 = @backingInt(P.p201);
    try expect(game.is_active(&g, .p201));
    try expect(game.enabled(&g, .{ .buy_project = idx }));
    const count = g.msg_count;
    game.act(&g, .{ .buy_project = idx });
    // A new page: prestige kept, everything else fresh, the RNG and the
    // clock go on, the timers run from the reload.
    try expectEqual(@as(u32, 1), g.restarts);
    try expectEqual(@as(f64, 1), g.prestige_s);
    try expectEqual(@as(f64, 0), g.creativity);
    try expectEqual(@as(f64, 0), g.clips);
    try expectEqual(@as(u64, 1015), g.now_ms);
    try expectEqual(@as(u64, 1015), g.load_ms);
    try expect(g.rng.x != rng_before);
    try expectEqualStrings("Welcome to Universal Paperclips", g.message(0).?);
    try expectEqual(count + 2, g.msg_count); // "Entering Simulated Universe." + welcome
    try expectEqual(@as(f64, 1), g.pow_mod); // refresh() ran updatePower
    try expect(!g.panels.tournament_results_table);
    game.advance_ms(&g, 10);
    try expect(g.panels.prestige_div);
    try expectEqual(@as(f64, 1), g.ticks);
    // Creativity runs 10% faster: 400 / (1 + 0.1) ticks per point.
    g.creativity_on = true;
    g.comp_flag = 1;
    g.operations = 1000;
    g.standard_ops = 1000;
    game.advance_ms(&g, 10 * 364);
    try expectEqual(@as(f64, 1), g.creativity);
}

test "a battle: drifters attack, ships restart, the canvas shows" {
    var g: Game = undefined;
    game.init(&g, 99);
    game.advance_ms(&g, 10);
    g.human_flag = 0;
    g.space_flag = 1;
    g.probe_count = 5e8;
    g.drifter_count = 2e8;
    g.unused_clips = 1e30;
    var tries: u32 = 0;
    while (g.battles_len == 0 and tries < 100) : (tries += 1) game.advance_ms(&g, 10);
    try expectEqual(@as(u8, 1), g.battles_len);
    try expectEqual(@as(u8, 1), g.battle_flag);
    try expectEqual(combat_kind.drifter_attack, g.battle_name.kind);
    try expect(g.num_left_ships > 0 and g.num_right_ships > 0);
    game.advance_ms(&g, 20);
    try expect(g.panels.battle_canvas_div and g.panels.drifter_div);
    // Fight it out.
    game.advance_ms(&g, 60_000);
    try expect(g.probes_lost_combat > 0 or g.drifters_killed > 0);
    var b: [64]u8 = undefined;
    var o = fmt.Out.init(&b);
    g.battle_name.write(&o);
    try expect(std.mem.startsWith(u8, o.slice(), "Drifter Attack "));
}

const combat_kind = game.combat.BattleNameKind;

fn credits(g: *const Game) bool {
    return game.credits_done(g);
}

test "autoplayer plays the whole game to the credits" {
    var g: Game = undefined;
    game.init(&g, 2026);
    var bot = bot_mod.Bot{};
    var hypno: u64 = 0;
    var space: u64 = 0;
    var achieved: u64 = 0;
    while (g.now_ms < 9 * 3600 * 1000 and !game.credits_done(&g)) {
        game.advance_ms(&g, 100);
        bot.step(&g);
        if (hypno == 0 and g.project_flag(.p35) == 1) hypno = g.now_ms;
        if (space == 0 and g.space_flag == 1) space = g.now_ms;
        if (achieved == 0 and g.milestone_flag >= 15) achieved = g.now_ms;
    }
    std.debug.print("\nautoplayer (seed 2026): HypnoDrones {d} s, space {d} s, Universal Paperclips {d} s, credits {d} s (virtual)\n", .{ hypno / 1000, space / 1000, achieved / 1000, g.now_ms / 1000 });
    try expect(hypno > 0 and hypno < 4 * 3600 * 1000);
    try expect(space > 0);
    try expect(game.credits_done(&g));
    try expectEqualStrings("&#169; 2017 Everybody House Games", g.message(0).?);
    var b: [128]u8 = undefined;
    try expectEqualStrings("30,000,000,000,000,000,000,000,000,000,000,000,000,000,000,000,000,000,000", game.clips_text(&g, &b));
    try expect(!g.panels.comp_div and !g.panels.projects_div and !g.panels.creation_div);
}

test "soft-float f64 routines are bit-exact (host FPU as reference)" {
    const sf = game.softfloat;
    var st: u64 = 0x1234567;
    var i: u32 = 0;
    while (i < 2_000_000) : (i += 1) {
        st ^= st << 13;
        st ^= st >> 7;
        st ^= st << 17;
        const r = st;
        // Normals near each other (cancellation), anything, subnormals.
        const a: u64 = switch (r % 4) {
            0 => r,
            1 => r & 0x800fffffffffffff,
            else => (r & 0x800fffffffffffff) | ((1023 + (r >> 52) % 64 - 32) << 52),
        };
        const b: u64 = switch ((r >> 3) % 3) {
            0 => a ^ (1 << 63) +% ((r >> 20) % 16),
            1 => a +% ((r >> 30) % 4096),
            else => (r *% 0x9E3779B97F4A7C15) & 0x83ffffffffffffff | (@as(u64, 0x3f) << 56),
        };
        const fa: f64 = @bitCast(a);
        const fb: f64 = @bitCast(b);
        inline for (.{ .{ fa + fb, sf.add(a, b) }, .{ fa - fb, sf.sub(a, b) }, .{ fa * fb, sf.mul(a, b) }, .{ @floor(fa), sf.floor(a) }, .{ @ceil(fa), sf.ceil(a) } }) |c| {
            const want: u64 = @bitCast(c[0]);
            if (std.math.isNan(c[0])) {
                try expect((c[1] & 0x7fffffffffffffff) > 0x7ff0000000000000);
            } else try expectEqual(want, c[1]);
        }
        try expectEqual(fa < fb, sf.lt(a, b));
        try expectEqual(fa <= fb, sf.le(a, b));
        try expectEqual(fa == fb, sf.eq(a, b));
    }
}

test "prepared bench states keep running" {
    for ([_]u8{ 2, 3 }) |stage| {
        var g: Game = undefined;
        game.init(&g, 7);
        game.prepare.prepare(&g, stage);
        game.advance_ms(&g, 5000);
        try expect(g.human_flag == 0);
        if (stage == 3) try expect(g.space_flag == 1 and g.battle_flag == 1);
    }
}
