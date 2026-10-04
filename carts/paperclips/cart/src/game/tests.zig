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

fn hypno_done(g: *const Game) bool {
    return g.project_flag(.p35) == 1;
}

test "autoplayer reaches the HypnoDrones" {
    var g: Game = undefined;
    game.init(&g, 2026);
    var bot = bot_mod.Bot{ .stage1_only = true };
    const t = bot_mod.play(&g, &bot, 4 * 3600 * 1000, hypno_done);
    std.debug.print("\nautoplayer: HypnoDrones released at {d} virtual s (clips {d}, trust {d})\n", .{ t / 1000, g.clips, g.trust });
    try expect(hypno_done(&g));
    try expect(g.human_flag == 0);
}
