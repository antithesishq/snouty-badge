//! The engine's host tests (track L). `zig build test -Dcart=raspberry-trail`.
const std = @import("std");
const G = @import("game.zig");

test {
    _ = @import("rng.zig");
}

test "engine: starts at the instructions question" {
    var g: G.Game = .{};
    G.init(&g, 1);
    G.start(&g);
    try std.testing.expectEqual(G.PromptKind.yes_no, g.prompt.kind);
    try std.testing.expectEqual(@as(u16, 190), g.prompt.line);
}

/// Checks the prompt is well formed (SPEC 3.3, interface comments).
fn check_prompt(g: *const G.Game) !void {
    const p = &g.prompt;
    try std.testing.expect(!g.overflow);
    try std.testing.expect(g.n_lines <= G.max_lines);
    try std.testing.expect(p.question.len <= 52);
    switch (p.kind) {
        .choice => {
            try std.testing.expect(p.n_options >= 2 and p.n_options <= 5);
            for (p.options[0..p.n_options]) |o| try std.testing.expect(o.len > 0 and o.len <= 22);
            try std.testing.expect(p.default_choice >= 1 and p.default_choice <= p.n_options);
            try std.testing.expect(p.question.len > 0);
        },
        .number => {
            try std.testing.expect(p.min <= p.default and p.default <= p.max);
            try std.testing.expect(p.question.len > 0);
        },
        .yes_no, .shoot => try std.testing.expect(p.question.len > 0),
        .game_over => try std.testing.expect(p.outcome != .none),
    }
    if (p.kind != .game_over) try std.testing.expect(p.line != 0);
}

/// A random answer for the current prompt, sometimes out of range. In
/// `slow` games the bot dawdles (cheap oxen, lots of food, always hunts,
/// shoots well) so that some games last into the winter.
fn bot_answer(g: *const G.Game, r: *std.Random.DefaultPrng, slow: bool) G.Answer {
    const rand = r.random();
    const p = &g.prompt;
    if (slow) switch (p.line) {
        860 => return .{ .number = 200 },
        940 => return .{ .number = 300 },
        990 => return .{ .number = 100 },
        1040 => return .{ .number = 60 },
        1090 => return .{ .number = 40 },
        2100 => return .{ .choice = 2 },
        2180 => return .{ .choice = 1 },
        2770 => return .{ .choice = 2 },
        3000 => return .{ .choice = 3 },
        6220 => return .{ .shoot = .{ .correct = true, .seconds = 1 + rand.float(f64) } },
        else => {},
    };
    return switch (p.kind) {
        .yes_no => .{ .yes_no = rand.boolean() },
        .choice => .{ .choice = if (rand.uintLessThan(u8, 10) == 0) rand.uintLessThan(u8, 10) else 1 + rand.uintLessThan(u8, p.n_options) },
        .number => blk: {
            const k = rand.uintLessThan(u8, 20);
            if (k == 0) break :blk .{ .number = rand.intRangeAtMost(i32, -50, 1000) };
            if (k == 1) break :blk .{ .number = p.max };
            const span: i32 = @min(p.max - p.min, 150);
            break :blk .{ .number = p.min + rand.intRangeAtMost(i32, 0, @max(0, span)) };
        },
        .shoot => .{ .shoot = .{ .correct = rand.uintLessThan(u8, 8) != 0, .seconds = @as(f64, @floatFromInt(rand.uintLessThan(u32, 6000))) / 1000.0 } },
        .game_over => .game_over,
    };
}

test "engine: bot plays 10000 seeded games to game over" {
    var g: G.Game = .{};
    var outcomes = std.EnumArray(G.Outcome, u32).initFill(0);
    var seed: u64 = 0;
    while (seed < 10000) : (seed += 1) {
        var r = std.Random.DefaultPrng.init(seed ^ 0xA5A5);
        G.init(&g, seed);
        G.start(&g);
        const slow = seed % 4 == 0;
        var steps: u32 = 0;
        while (g.prompt.kind != .game_over) : (steps += 1) {
            try check_prompt(&g);
            try std.testing.expect(steps < 5000);
            G.answer(&g, bot_answer(&g, &r, slow));
        }
        try check_prompt(&g);
        outcomes.getPtr(g.prompt.outcome).* += 1;
    }
    // Every ending happens somewhere in 10000 random games. Pneumonia is
    // never the outcome: 5120 is reached only from 5080 and 5110 (which
    // name their own cause) and from the wolves at 4400 (K8=1, injuries).
    var it = outcomes.iterator();
    while (it.next()) |e| {
        if (e.key == .none or e.key == .pneumonia) {
            try std.testing.expectEqual(@as(u32, 0), e.value.*);
            continue;
        }
        try std.testing.expect(e.value.* > 0);
    }
}

// ------------------------------------------------------- scenario tests ----
// These set the BASIC variables directly, force the RND(-1) values
// (`rnd_script`) and run the port from a jump target (`run_at`).

const t = std.testing;

/// A mid-trail state below South Pass, on a no-fort turn (X1 = -1).
fn fresh(g: *G.Game) void {
    G.init(g, 7);
    g.v.A = 250;
    g.v.B = 1000;
    g.v.C = 50;
    g.v.F = 100;
    g.v.M = 500;
    g.v.M1 = 50;
    g.v.T = 100;
    g.v.E = 2;
    g.v.X1 = -1;
    g.v.D3 = 3;
    g.v.D9 = 3;
}

fn line_with(g: *const G.Game, text: []const u8) ?G.Line {
    for (g.printed()) |l| if (std.mem.eql(u8, l.text, text)) return l;
    return null;
}

fn expect_line(g: *const G.Game, tag: G.Tag, text: []const u8) !void {
    const l = line_with(g, text) orelse {
        std.debug.print("missing line: {s}\n", .{text});
        for (g.printed()) |p| std.debug.print("  [{s}] {s}\n", .{ @tagName(p.tag), p.text });
        return error.TestExpectedLine;
    };
    try t.expectEqual(tag, l.tag);
}

/// Runs the event selection with forced draws; `r` is RND for R1 then the
/// event's own draws. Expects the run to reach the next turn's 2180.
fn run_event(g: *G.Game, r: []const f64) !void {
    g.rnd_script = r;
    G.run_at(g, 3550);
}

fn expect_next_turn(g: *const G.Game, draws: u32) !void {
    try t.expectEqual(@as(u16, 2180), g.prompt.line);
    try t.expectEqual(draws, g.draws);
    try t.expectEqual(@as(usize, 0), g.rnd_script.len);
    try t.expectEqual(@as(f64, 4), g.v.D3);
    try expect_line(g, .date, "MONDAY MAY 24 1847");
    try t.expect(!g.overflow);
}

test "events: wagon, ox, daughter, wanders, son, water, rain" {
    var g: G.Game = .{};
    fresh(&g);
    try run_event(&g, &.{ 0.03, 0.5 });
    try expect_line(&g, .wagon_breaks, "WAGON BREAKS DOWN--LOSE TIME AND SUPPLIES FIXING IT");
    try t.expectEqual(@floor(@as(f64, 500) - 15 - 5 * 0.5), g.v.M);
    try t.expectEqual(@as(f64, 42), g.v.M1);
    try t.expectEqual(@as(f64, 1), g.v.D1);
    try t.expectEqual(@as(f64, 6), g.v.D);
    try t.expectEqual(@as(f64, 3), g.v.R1);
    try expect_next_turn(&g, 2);

    fresh(&g);
    try run_event(&g, &.{0.085});
    try expect_line(&g, .ox_injured, "OX INJURES LEG---SLOWS YOU DOWN REST OF TRIP");
    try t.expectEqual(@as(f64, 475), g.v.M);
    try t.expectEqual(@as(f64, 230), g.v.A);
    try expect_next_turn(&g, 1);

    fresh(&g);
    try run_event(&g, &.{ 0.12, 0.5, 0.5 });
    try expect_line(&g, .daughter_arm, "BAD LUCK---YOUR DAUGHTER BROKE HER ARM");
    try expect_line(&g, .plain, "YOU HAD TO STOP AND USE SUPPLIES TO MAKE A SLING");
    try t.expectEqual(@as(f64, 493), g.v.M);
    try t.expectEqual(@as(f64, 46), g.v.M1);
    try expect_next_turn(&g, 3);

    fresh(&g);
    try run_event(&g, &.{0.14});
    try expect_line(&g, .ox_wanders, "OX WANDERS OFF---SPEND TIME LOOKING FOR IT");
    try t.expectEqual(@as(f64, 483), g.v.M);
    try expect_next_turn(&g, 1);

    fresh(&g);
    try run_event(&g, &.{0.16});
    try expect_line(&g, .son_lost, "YOUR SON GETS LOST---SPEND HALF THE DAY LOOKING FOR HIM");
    try t.expectEqual(@as(f64, 490), g.v.M);
    try expect_next_turn(&g, 1);

    fresh(&g);
    try run_event(&g, &.{ 0.195, 0.5 });
    try expect_line(&g, .bad_water, "UNSAFE WATER--LOSE TIME LOOKING FOR CLEAN SPRING");
    try t.expectEqual(@as(f64, 493), g.v.M);
    try expect_next_turn(&g, 2);

    fresh(&g);
    try run_event(&g, &.{ 0.27, 0.5 });
    try expect_line(&g, .heavy_rain, "HEAVY RAINS---TIME AND SUPPLIES LOST");
    try t.expectEqual(@as(f64, 90), g.v.F);
    try t.expectEqual(@as(f64, 500), g.v.B);
    try t.expectEqual(@as(f64, 35), g.v.M1);
    try t.expectEqual(@as(f64, 490), g.v.M);
    try expect_next_turn(&g, 2);
}

test "events: bandits (both ways), fire, fog, snake, river" {
    var g: G.Game = .{};
    fresh(&g);
    try run_event(&g, &.{ 0.335, 0.3 });
    try expect_line(&g, .bandits, "BANDITS ATTACK");
    try expect_line(&g, .question, "TYPE BLAM");
    try t.expectEqual(G.PromptKind.shoot, g.prompt.kind);
    try t.expectEqual(G.Word.blam, g.prompt.word);
    try t.expectEqual(G.ShotReason.bandits, g.prompt.shot);
    try t.expectEqual(@as(f64, 2), g.v.S6);
    G.answer(&g, .{ .shoot = .{ .correct = true, .seconds = 2.5 } });
    const b1 = (2.5 / @as(f64, 3600) - 0) * 3600 - (3 - 1);
    try t.expectEqual(b1, g.v.B1);
    try expect_line(&g, .plain, "QUICKEST DRAW OUTSIDE OF DODGE CITY!!!");
    try expect_line(&g, .plain, "YOU GOT 'EM!");
    try t.expectEqual(@floor(1000 - 20 * b1), g.v.B);
    try expect_next_turn(&g, 2);

    fresh(&g);
    try run_event(&g, &.{ 0.335, 0.99 });
    try t.expectEqual(G.Word.wham, g.prompt.word);
    G.answer(&g, .{ .shoot = .{ .correct = false, .seconds = 0.5 } });
    try t.expectEqual(@as(f64, 9), g.v.B1);
    try expect_line(&g, .plain, "YOU GOT SHOT IN THE LEG AND THEY TOOK ONE OF YOUR OXEN");
    try t.expectEqual(@as(f64, 820), g.v.B);
    try t.expectEqual(@as(f64, 230), g.v.A);
    // The doctor's bill comes at the next turn (K8 cleared there).
    try t.expectEqual(@as(f64, 0), g.v.K8);
    try t.expectEqual(@as(f64, 45 - 0), g.v.M1);
    try t.expectEqual(@as(f64, 80), g.v.T);
    try expect_line(&g, .warning, "DOCTOR'S BILL IS $20");
    try expect_next_turn(&g, 2);

    // Out of bullets: the cash is cut to a third, then the leg wound.
    fresh(&g);
    g.v.B = 10;
    try run_event(&g, &.{ 0.335, 0.0 });
    try t.expectEqual(G.Word.bang, g.prompt.word);
    G.answer(&g, .{ .shoot = .{ .correct = false, .seconds = 1 } });
    try expect_line(&g, .plain, "YOU RAN OUT OF BULLETS---THEY GET LOTS OF CASH");
    try expect_line(&g, .plain, "YOU GOT SHOT IN THE LEG AND THEY TOOK ONE OF YOUR OXEN");
    try t.expectEqual(@floor(@as(f64, 100) / 3) - 20, g.v.T);

    fresh(&g);
    try run_event(&g, &.{ 0.36, 0.5 });
    try expect_line(&g, .fire, "THERE WAS A FIRE IN YOUR WAGON--FOOD AND SUPPLIES DAMAGE");
    try t.expectEqual(@as(f64, 60), g.v.F);
    try t.expectEqual(@as(f64, 600), g.v.B);
    try t.expectEqual(@as(f64, 43), g.v.M1);
    try t.expectEqual(@as(f64, 485), g.v.M);
    try expect_next_turn(&g, 2);

    fresh(&g);
    try run_event(&g, &.{ 0.395, 0.5 });
    try expect_line(&g, .fog, "LOSE YOUR WAY IN HEAVY FOG---TIME IS LOST");
    try t.expectEqual(@as(f64, 487), g.v.M);
    try expect_next_turn(&g, 2);

    fresh(&g);
    try run_event(&g, &.{0.43});
    try expect_line(&g, .snake, "YOU KILLED A POISONOUS SNAKE AFTER IT BIT YOU");
    try t.expectEqual(@as(f64, 990), g.v.B);
    try t.expectEqual(@as(f64, 45), g.v.M1);
    try expect_next_turn(&g, 1);

    fresh(&g);
    try run_event(&g, &.{ 0.49, 0.5 });
    try expect_line(&g, .river, "WAGON GETS SWAMPED FORDING RIVER--LOSE FOOD AND CLOTHES");
    try t.expectEqual(@as(f64, 70), g.v.F);
    try t.expectEqual(@as(f64, 30), g.v.C);
    try t.expectEqual(@as(f64, 470), g.v.M);
    try expect_next_turn(&g, 2);
}

test "events: wild animals, hail, eating illness, helpful food, cold" {
    var g: G.Game = .{};
    fresh(&g);
    try run_event(&g, &.{ 0.59, 0.6 });
    try expect_line(&g, .wild_animals, "WILD ANIMALS ATTACK!");
    try t.expectEqual(G.Word.pow, g.prompt.word);
    try t.expectEqual(G.ShotReason.animals, g.prompt.shot);
    G.answer(&g, .{ .shoot = .{ .correct = true, .seconds = 6 } });
    const b1 = (6 / @as(f64, 3600) - 0) * 3600 - (3 - 1);
    try expect_line(&g, .plain, "SLOW ON THE DRAW---THEY GOT AT YOUR FOOD AND CLOTHES");
    try t.expectEqual(@floor(1000 - 20 * b1), g.v.B);
    try t.expectEqual(@floor(50 - b1 * 4), g.v.C);
    try t.expectEqual(@floor(100 - b1 * 8), g.v.F);
    try expect_next_turn(&g, 2);

    fresh(&g);
    try run_event(&g, &.{ 0.665, 0.5, 0.5 });
    try expect_line(&g, .hail, "HAIL STORM---SUPPLIES DAMAGED");
    try t.expectEqual(@as(f64, 490), g.v.M);
    try t.expectEqual(@as(f64, 800), g.v.B);
    try t.expectEqual(@as(f64, 44), g.v.M1);
    try expect_next_turn(&g, 3);

    // Event 15 with E=1: always ill (mild here).
    fresh(&g);
    g.v.E = 1;
    try run_event(&g, &.{ 0.82, 0.05 });
    try expect_line(&g, .illness, "MILD ILLNESS---MEDICINE USED");
    try t.expectEqual(@as(f64, 495), g.v.M);
    try t.expectEqual(@as(f64, 48), g.v.M1);
    try expect_next_turn(&g, 2);

    // E=2: ill only if RND > .25.
    fresh(&g);
    try run_event(&g, &.{ 0.82, 0.25 });
    try t.expectEqual(@as(usize, 0), countTag(&g, .illness));
    try expect_next_turn(&g, 2);

    // E=3: ill if RND < .5; serious illness -> the doctor next turn.
    fresh(&g);
    g.v.E = 3;
    try run_event(&g, &.{ 0.82, 0.4, 0.9, 0.98 });
    try expect_line(&g, .illness, "SERIOUS ILLNESS---");
    try expect_line(&g, .plain, "YOU MUST STOP FOR MEDICAL ATTENTION");
    try expect_line(&g, .warning, "DOCTOR'S BILL IS $20");
    try t.expectEqual(@as(f64, 40), g.v.M1);
    try t.expectEqual(@as(f64, 80), g.v.T);
    try t.expectEqual(@as(f64, 0), g.v.S4);
    try expect_next_turn(&g, 4);

    // E=2, bad illness: 100*RND < 100-40/4 = 90.
    fresh(&g);
    try run_event(&g, &.{ 0.82, 0.3, 0.9, 0.89 });
    try expect_line(&g, .illness, "BAD ILLNESS---MEDICINE USED");
    try t.expectEqual(@as(f64, 45), g.v.M1);
    try t.expectEqual(@as(f64, 495), g.v.M);
    try expect_next_turn(&g, 4);

    fresh(&g);
    try run_event(&g, &.{0.99});
    try expect_line(&g, .helpful_food, "HELPFUL INDIANS SHOW YOU WHERE TO FIND MORE FOOD");
    try t.expectEqual(@as(f64, 114), g.v.F);
    try t.expectEqual(@as(f64, 16), g.v.D1);
    try t.expectEqual(@as(f64, 95), g.v.D);
    try expect_next_turn(&g, 1);

    // Event 7 above 950 miles is the cold; F1=1 and a high RND skip the
    // mountains.
    fresh(&g);
    g.v.M = 1000;
    g.v.F1 = 1;
    try run_event(&g, &.{ 0.27, 0.5, 0.99 });
    try expect_line(&g, .cold, "COLD WEATHER---BRRRRRRR!---YOU HAVE ENOUGH CLOTHING TO KEEP YOU WARM");
    try expect_next_turn(&g, 3);
    try t.expectEqual(@as(f64, 0), g.v.C1);

    fresh(&g);
    g.v.M = 1000;
    g.v.F1 = 1;
    g.v.C = 10;
    try run_event(&g, &.{ 0.27, 0.5, 0.1, 0.99 });
    try expect_line(&g, .cold, "COLD WEATHER---BRRRRRRR!---YOU DON'T HAVE ENOUGH CLOTHING TO KEEP YOU WARM");
    try expect_line(&g, .illness, "MILD ILLNESS---MEDICINE USED");
    try t.expectEqual(@as(f64, 1), g.v.C1);
    try t.expectEqual(@as(f64, 995), g.v.M);
    try expect_next_turn(&g, 4);
}

fn countTag(g: *const G.Game, tag: G.Tag) usize {
    var n: usize = 0;
    for (g.printed()) |l| n += @intFromBool(l.tag == tag);
    return n;
}

fn bury(g: *G.Game, kin: bool) !void {
    try t.expectEqual(@as(u16, 5220), g.prompt.line);
    try expect_line(g, .funeral, "DUE TO YOUR UNFORTUNATE SITUATION, THERE ARE A FEW");
    G.answer(g, .{ .yes_no = true });
    try t.expectEqual(@as(u16, 5240), g.prompt.line);
    G.answer(g, .{ .yes_no = false });
    try t.expectEqual(@as(u16, 5260), g.prompt.line);
    G.answer(g, .{ .yes_no = kin });
    try t.expectEqual(G.PromptKind.game_over, g.prompt.kind);
    try expect_line(g, .plain, if (kin) "THAT WILL BE $4.50 FOR THE TELEGRAPH CHARGE." else "BUT YOUR AUNT SADIE IN ST. LOUIS IS REALLY WORRIED ABOUT YOU");
    try expect_line(g, .letter, "BETTER LUCK NEXT TIME");
    try t.expectEqual(@as(u16, 0), g.pc);
}

test "deaths: every cause" {
    var g: G.Game = .{};

    fresh(&g);
    g.v.F = 12;
    G.run_at(&g, 2720);
    try expect_line(&g, .death, "YOU RAN OUT OF FOOD AND STARVED TO DEATH");
    try bury(&g, false);
    try t.expectEqual(G.Outcome.starved, g.prompt.outcome);

    fresh(&g);
    g.v.K8 = 1;
    g.v.T = 19;
    G.run_at(&g, 1750);
    try expect_line(&g, .death, "YOU CAN'T AFFORD A DOCTOR");
    try expect_line(&g, .death, "YOU DIED OF INJURIES");
    try t.expectEqual(@as(f64, 0), g.v.T);
    try bury(&g, true);
    try t.expectEqual(G.Outcome.no_doctor_money, g.prompt.outcome);

    fresh(&g);
    g.v.S4 = 1;
    g.v.T = 0;
    G.run_at(&g, 1750);
    try expect_line(&g, .death, "YOU DIED OF PNEUMONIA");
    try bury(&g, false);
    try t.expectEqual(G.Outcome.no_doctor_money, g.prompt.outcome);

    fresh(&g);
    g.v.M1 = 1;
    g.rnd_script = &.{0.05};
    G.run_at(&g, 6300);
    try expect_line(&g, .death, "YOU RAN OUT OF MEDICAL SUPPLIES");
    try expect_line(&g, .death, "YOU DIED OF PNEUMONIA");
    try bury(&g, false);
    try t.expectEqual(G.Outcome.no_medicine, g.prompt.outcome);

    fresh(&g);
    g.v.B = 39;
    try run_event(&g, &.{ 0.59, 0.1 });
    G.answer(&g, .{ .shoot = .{ .correct = true, .seconds = 1 } });
    try expect_line(&g, .plain, "YOU WERE TOO LOW ON BULLETS--");
    try expect_line(&g, .plain, "THE WOLVES OVERPOWERED YOU");
    try expect_line(&g, .death, "YOU DIED OF INJURIES");
    try bury(&g, false);
    try t.expectEqual(G.Outcome.injuries, g.prompt.outcome);

    fresh(&g);
    g.v.D3 = 19;
    g.v.M = 1500;
    G.run_at(&g, 1230);
    try expect_line(&g, .death, "MONDAY YOU HAVE BEEN ON THE TRAIL TOO LONG  ------");
    try expect_line(&g, .death, "YOUR FAMILY DIES IN THE FIRST BLIZZARD OF WINTER");
    try t.expectEqual(@as(f64, 20), g.v.D3);
    try bury(&g, false);
    try t.expectEqual(G.Outcome.winter, g.prompt.outcome);

    fresh(&g);
    g.v.S5 = 0;
    g.v.B = -1;
    G.run_at(&g, 3470);
    try expect_line(&g, .plain, "RIDERS WERE HOSTILE--CHECK FOR LOSSES");
    try expect_line(&g, .death, "YOU RAN OUT OF BULLETS AND GOT MASSACRED BY THE RIDERS");
    try bury(&g, false);
    try t.expectEqual(G.Outcome.massacred, g.prompt.outcome);

    fresh(&g);
    g.v.M1 = 4;
    try run_event(&g, &.{0.43});
    try expect_line(&g, .death, "YOU DIE OF SNAKEBITE SINCE YOU HAVE NO MEDICINE");
    try bury(&g, false);
    try t.expectEqual(G.Outcome.snakebite, g.prompt.outcome);
}

test "arrival: final-turn fraction, date and weekday" {
    var g: G.Game = .{};
    fresh(&g);
    g.v.D3 = 12;
    g.v.M2 = 1900;
    g.v.M = 2100;
    G.run_at(&g, 1230);
    try t.expectEqual(G.PromptKind.game_over, g.prompt.kind);
    try t.expectEqual(G.Outcome.arrived, g.prompt.outcome);
    // F9 = 140/200 = .7; INT(.7*14) = 9; D3 = 12*14+9 = 177; weekday 10-7.
    const f9 = (2040 - @as(f64, 1900)) / (2100 - 1900);
    try t.expectEqual(100 + (1 - f9) * (8 + 5 * @as(f64, 2)), g.v.F);
    try t.expectEqual(@as(f64, 3), g.v.F9);
    try t.expectEqual(@as(f64, 22), g.v.D3);
    try expect_line(&g, .bell, "YOU FINALLY ARRIVED AT OREGON CITY");
    try expect_line(&g, .bell, "AFTER 2040 LONG MILES---HOORAY!!!!!");
    try expect_line(&g, .arrival, "A REAL PIONEER!");
    try expect_line(&g, .date, "WEDNESDAY SEPTEMBER 22 1847");
    try t.expectEqualStrings("SEPTEMBER 22 1847", g.hud.date_text);
    try t.expectEqual(@as(i32, 2040), g.hud.mileage_shown);
    try t.expectEqual(@as(i32, 2100), g.hud.mileage_true);
    try t.expectEqual(@as(i32, 100), g.hud.cash);
    try expect_line(&g, .letter, "                      AT YOUR NEW HOME");

    // M = 2040 exactly: F9 = 1, INT(14) = 14, 15-7 = 8 is out of ON's
    // range and falls through to MONDAY; D3 = 10*14+14 = 154 = AUGUST 30.
    fresh(&g);
    g.v.D3 = 10;
    g.v.M2 = 1900;
    g.v.M = 2040;
    G.run_at(&g, 1230);
    try t.expectEqual(@as(f64, 8), g.v.F9);
    try expect_line(&g, .date, "MONDAY AUGUST 30 1847");

    // Each month of lines 5700-5910 (F9 = 99.5/100, INT(13.93) = 13),
    // including the listing's DECEMBER 33 on the last possible turn.
    const cases = [_]struct { d3: f64, text: []const u8 }{
        .{ .d3 = 8, .text = "AUGUST 1 1847" },
        .{ .d3 = 11, .text = "SEPTEMBER 12 1847" },
        .{ .d3 = 14, .text = "OCTOBER 24 1847" },
        .{ .d3 = 16, .text = "NOVEMBER 21 1847" },
        .{ .d3 = 19, .text = "DECEMBER 33 1847" },
    };
    for (cases) |c| {
        fresh(&g);
        g.v.D3 = c.d3;
        g.v.M2 = 1940.5;
        g.v.M = 2040.5;
        G.run_at(&g, 1230);
        try t.expectEqual(G.Outcome.arrived, g.prompt.outcome);
        try t.expectEqualStrings(c.text, g.hud.date_text);
    }
}

test "mountains: the 950 display after South Pass" {
    var g: G.Game = .{};
    fresh(&g);
    g.v.M = 960;
    // 4720 rugged (1 <= 6.54), lost (RND <= .1), South Pass no snow (>= .8).
    g.rnd_script = &.{ 0.1, 0.05, 0.9 };
    G.run_at(&g, 4710);
    try expect_line(&g, .mountains, "RUGGED MOUNTAINS");
    try expect_line(&g, .plain, "YOU GOT LOST---LOSE VALUABLE TIME TRYING TO FIND TRAIL!");
    try expect_line(&g, .south_pass, "YOU MADE IT SAFELY THROUGH SOUTH PASS--NO SNOW");
    try expect_line(&g, .mileage, "TOTAL MILEAGE IS 950");
    try t.expectEqual(@as(i32, 950), g.hud.mileage_shown);
    try t.expectEqual(@as(i32, 900), g.hud.mileage_true);
    try t.expectEqual(@as(f64, 900), g.v.M);
    try t.expectEqual(@as(f64, 0), g.v.M9);
    try t.expectEqual(@as(f64, 1), g.v.F1);
    try expect_next_turn(&g, 3);

    // A blizzard in South Pass, clothes enough: back to 4940.
    fresh(&g);
    g.v.M = 1200;
    g.rnd_script = &.{ 0.99, 0.5, 0.5, 0.5 };
    G.run_at(&g, 4710);
    try expect_line(&g, .blizzard, "BLIZZARD IN MOUNTAIN PASS--TIME AND SUPPLIES LOST");
    try t.expectEqual(@as(f64, 1), g.v.L1);
    try t.expectEqual(@as(f64, 1200 - 50), g.v.M);
    try t.expectEqual(@as(f64, 75), g.v.F);
    try t.expectEqual(@as(f64, 700), g.v.B);
    try t.expectEqual(@as(f64, 40), g.v.M1);
    try expect_line(&g, .mileage, "TOTAL MILEAGE IS 1150");
    try expect_next_turn(&g, 4);
}

test "turns: fort alternation and the hunt re-ask" {
    var g: G.Game = .{};
    G.init(&g, 3);
    G.start(&g);
    const opening = [_]G.Answer{ .{ .yes_no = false }, .{ .choice = 3 }, .{ .number = 250 }, .{ .number = 200 }, .{ .number = 50 }, .{ .number = 50 }, .{ .number = 50 } };
    for (opening) |a| G.answer(&g, a);
    var menus: [32]u16 = undefined;
    var n: usize = 0;
    while (g.prompt.kind != .game_over) {
        const a: G.Answer = switch (g.prompt.line) {
            2100, 2180 => blk: {
                menus[n] = g.prompt.line;
                n += 1;
                break :blk .{ .choice = if (g.prompt.line == 2100) 3 else 2 };
            },
            2770 => .{ .choice = 2 },
            3000 => .{ .choice = 3 },
            6220 => .{ .shoot = .{ .correct = true, .seconds = 1 } },
            else => .{ .yes_no = false },
        };
        G.answer(&g, a);
    }
    try t.expect(n >= 4);
    for (menus[0..n], 0..) |m, i| try t.expectEqual(@as(u16, if (i % 2 == 0) 2180 else 2100), m);

    // On a fort turn (X1 = 1), HUNT without bullets re-asks the fort
    // question (2560 GOTO 2080) and X1 flips only once.
    fresh(&g);
    g.v.X1 = 1;
    g.v.B = 39;
    G.run_at(&g, 1750);
    try t.expectEqual(@as(u16, 2100), g.prompt.line);
    try t.expectEqual(@as(f64, -1), g.v.X1);
    G.answer(&g, .{ .choice = 2 });
    try expect_line(&g, .warning, "TOUGH---YOU NEED MORE BULLETS TO GO HUNTING");
    try t.expectEqual(@as(u16, 2100), g.prompt.line);
    try t.expectEqual(@as(f64, -1), g.v.X1);
    // Out of range: 9 and 0 both mean CONTINUE.
    G.answer(&g, .{ .choice = 9 });
    try t.expectEqual(@as(f64, 3), g.v.X);
    try t.expectEqual(@as(u16, 2770), g.prompt.line);

    // The no-fort menu: HUNT without bullets asks again, X1 unflipped.
    fresh(&g);
    g.v.B = 20;
    G.run_at(&g, 1750);
    G.answer(&g, .{ .choice = 1 });
    try expect_line(&g, .warning, "TOUGH---YOU NEED MORE BULLETS TO GO HUNTING");
    try t.expectEqual(@as(u16, 2180), g.prompt.line);
    try t.expectEqual(@as(f64, -1), g.v.X1);
    G.answer(&g, .{ .choice = 0 }); // anything but 1 is CONTINUE
    try t.expectEqual(@as(f64, 3), g.v.X);
    try t.expectEqual(@as(f64, 1), g.v.X1);
}

test "turns: fort purchases (2/3 value, overspend)" {
    var g: G.Game = .{};
    fresh(&g);
    g.v.X1 = 1;
    G.run_at(&g, 1750);
    G.answer(&g, .{ .choice = 1 });
    try expect_line(&g, .fort, "ENTER WHAT YOU WISH TO SPEND ON THE FOLLOWING");
    try expect_line(&g, .question, "FOOD");
    try t.expectEqual(@as(u16, 2330), g.prompt.line);
    try t.expectEqual(@as(i32, 100), g.prompt.max);
    G.answer(&g, .{ .number = 30 });
    try t.expectEqual(@as(f64, 100) + 2.0 / 3.0 * @as(f64, 30), g.v.F);
    try t.expectEqual(@as(i32, 70), g.prompt.max);
    G.answer(&g, .{ .number = 71 }); // too much: missed
    try expect_line(&g, .plain, "YOU MISS YOUR CHANCE TO SPEND ON THAT ITEM");
    try t.expectEqual(@as(f64, 0), g.v.P);
    try t.expectEqual(@as(f64, 1000), g.v.B);
    G.answer(&g, .{ .number = -3 }); // negative: T unchanged, C reduced
    try t.expectEqual(@as(f64, 50) + 2.0 / 3.0 * @as(f64, -3), g.v.C);
    try t.expectEqual(@as(f64, 70), g.v.T);
    G.answer(&g, .{ .number = 9 });
    try t.expectEqual(@as(f64, 50) + 2.0 / 3.0 * @as(f64, 9), g.v.M1);
    try t.expectEqual(@as(f64, 61), g.v.T);
    try t.expectEqual(@as(f64, 455), g.v.M);
    try t.expectEqual(@as(u16, 2770), g.prompt.line);
}

test "turns: RND draw counts" {
    var g: G.Game = .{};
    // Eat, no riders, event 4 (no draws of its own), below the mountains:
    // 2860, 2890, 3570.
    fresh(&g);
    G.run_at(&g, 2720);
    try t.expectEqual(@as(u16, 2770), g.prompt.line);
    g.rnd_script = &.{ 0.5, 0.99, 0.14 };
    G.answer(&g, .{ .choice = 2 });
    try expect_next_turn(&g, 3);
    try t.expectEqual(@floor(500 + 200 + (@as(f64, 250) - 220) / 5 + 10 * 0.5 - 17), g.v.M);
    try t.expectEqual(@as(f64, 100 - 8 - 5 * 2), g.v.F);

    // Riders: 2920 and 2980 draw; an invalid tactic redraws 2980.
    fresh(&g);
    G.run_at(&g, 2720);
    g.rnd_script = &.{ 0.5, 0.01, 0.5, 0.5, 0.1, 0.14 };
    G.answer(&g, .{ .choice = 2 });
    try expect_line(&g, .riders, "RIDERS AHEAD.  THEY LOOK HOSTILE");
    try t.expectEqual(@as(u16, 3000), g.prompt.line);
    try t.expectEqual(@as(u32, 4), g.draws);
    try t.expectEqual(@as(f64, 0), g.v.S5);
    G.answer(&g, .{ .choice = 5 });
    try t.expectEqual(@as(u32, 5), g.draws);
    try t.expectEqual(@as(f64, 1), g.v.S5); // RND .1 <= .2 flips
    G.answer(&g, .{ .choice = 1 }); // friendly run: M+15, A-10
    try expect_line(&g, .plain, "RIDERS WERE FRIENDLY, BUT CHECK FOR POSSIBLE LOSSES");
    try t.expectEqual(@as(f64, 240), g.v.A);
    try expect_next_turn(&g, 6);

    // The live generator: a whole game's draws are deterministic per seed.
    var a: G.Game = .{};
    var b: G.Game = .{};
    for ([_]*G.Game{ &a, &b }) |p| {
        G.init(p, 99);
        G.start(p);
        var r = std.Random.DefaultPrng.init(5);
        while (p.prompt.kind != .game_over) G.answer(p, bot_answer(p, &r, false));
    }
    try t.expectEqual(a.draws, b.draws);
    try t.expectEqual(a.v, b.v);
}

test "opening: marksman, purchases, re-asks and number bounds" {
    var g: G.Game = .{};
    G.init(&g, 1);
    G.start(&g);
    G.answer(&g, .{ .yes_no = true });
    try t.expectEqual(@as(usize, 2 + 45 + 7), g.n_lines);
    try expect_line(&g, .instructions, "\"RETURN\" KEY, THE BETTER LUCK YOU'LL HAVE WITH YOUR GUN.");
    try t.expectEqual(@as(u8, 3), g.prompt.default_choice);
    G.answer(&g, .{ .choice = 9 });
    try t.expectEqual(@as(f64, 0), g.v.D9);
    try t.expectEqual(@as(f64, -1), g.v.X1);
    try t.expectEqual(@as(i32, 200), g.prompt.min);
    try t.expectEqual(@as(i32, 300), g.prompt.max);
    G.answer(&g, .{ .number = 199 });
    try expect_line(&g, .plain, "NOT ENOUGH");
    try t.expectEqual(@as(u16, 860), g.prompt.line);
    G.answer(&g, .{ .number = 301 });
    try expect_line(&g, .plain, "TOO MUCH");
    G.answer(&g, .{ .number = 220 });
    try t.expectEqual(@as(i32, 480), g.prompt.max);
    G.answer(&g, .{ .number = -1 });
    try expect_line(&g, .plain, "IMPOSSIBLE");
    G.answer(&g, .{ .number = 200 });
    try t.expectEqual(@as(i32, 280), g.prompt.max);
    G.answer(&g, .{ .number = 100 });
    try t.expectEqual(@as(i32, 180), g.prompt.max);
    G.answer(&g, .{ .number = 100 });
    try t.expectEqual(@as(i32, 80), g.prompt.max);
    G.answer(&g, .{ .number = 81 });
    try expect_line(&g, .plain, "YOU OVERSPENT--YOU ONLY HAD $700 TO SPEND.  BUY AGAIN");
    try t.expectEqual(@as(u16, 860), g.prompt.line);
    for ([_]i32{ 220, 200, 100, 100, 80 }) |x| G.answer(&g, .{ .number = x });
    try expect_line(&g, .plain, "AFTER ALL YOUR PURCHASES, YOU NOW HAVE 0 DOLLARS LEFT");
    try expect_line(&g, .date, "MONDAY MARCH 29 1847");
    try expect_line(&g, .mileage, "TOTAL MILEAGE IS 0");
    try t.expectEqual(@as(f64, 5000), g.v.B);
    try t.expect(g.hud.valid);
    try t.expectEqual(@as(i32, 5000), g.hud.bullets);
    try t.expectEqual(@as(u16, 2180), g.prompt.line);
}

test "shooting: B1 arithmetic" {
    var g: G.Game = .{};
    fresh(&g);
    g.v.X1 = -1;
    G.run_at(&g, 1750);
    g.rnd_script = &.{ 0.0, 0.0 };
    G.answer(&g, .{ .choice = 1 }); // hunt
    try t.expectEqual(G.ShotReason.hunt, g.prompt.shot);
    try t.expectEqual(@as(f64, 0), g.v.B3);
    G.answer(&g, .{ .shoot = .{ .correct = true, .seconds = 1.5 } });
    // ((1.5/3600 - 0)*3600) - 2 < 0 -> 0 -> the big one (2660).
    try t.expectEqual(@as(f64, 0), g.v.B1);
    try expect_line(&g, .bell, "RIGHT BETWEEN THE EYES---YOU GOT A BIG ONE!!!!");
    try t.expectEqual(@as(f64, 100 + 52 + 0 * 6), g.v.F);
    try t.expectEqual(@as(f64, 455), g.v.M);

    fresh(&g);
    g.v.D9 = 0; // claimed > 5
    G.run_at(&g, 1750);
    g.rnd_script = &.{ 0.0, 0.99 };
    G.answer(&g, .{ .choice = 1 });
    G.answer(&g, .{ .shoot = .{ .correct = true, .seconds = 1.25 } });
    const b1 = (1.25 / @as(f64, 3600) - 0) * 3600 - (0 - 1);
    try t.expectEqual(b1, g.v.B1);
    try expect_line(&g, .hunt_result, "NICE SHOT--RIGHT ON TARGET--GOOD EATIN' TONIGHT!!");
    try t.expectEqual(100 + 48 - 2 * b1, g.v.F);
    try t.expectEqual(1000 - 10 - 3 * b1, g.v.B);
}
