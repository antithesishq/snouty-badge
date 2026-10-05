//! The GRID LADDER (SPEC.md section 6): twelve levels named after
//! programming languages, as TRON '82 did, ending on Zig and then
//! production. After PROD the ladder loops at +10% speed per loop.
//! Data only: `get(n)` turns a ladder position (1-based, growing across
//! loops) into the round's programs and `sim.Config`.
const std = @import("std");
const sim = @import("sim.zig");
const ai = @import("ai.zig");

/// One program on a level: its tier and the `ai.preset` level (0..3) its knobs
/// come from (reaction, mistakes, vision).
pub const Program = struct {
    tier: ai.Tier,
    preset: u8,
};

pub const Level = struct {
    name: []const u8,
    programs: []const Program,
    /// Base speed in percent (RUST's 1.1x).
    speed_pct: u16 = 100,
    /// `layouts.zig` index, 0 = the empty arena (Track S's table).
    layout: u8 = 0,
    sudden_death: bool = true,
};

pub const count = 12;
/// Speed added per loop of the ladder, in percent.
pub const loop_speed_pct: u16 = 10;

fn p(tier: ai.Tier, preset: u8) Program {
    return .{ .tier = tier, .preset = preset };
}

/// SPEC 6's table. Layouts (`layouts.zig`: 1 PILLARS, 2 BARS, 3 CROSS,
/// 4 RING, 5 LANES, 6 CORNERS, 7 CHECKER, 8 COLUMNS) from level 5 on, on
/// every other level; the ASM duel stays open.
pub const table = [count]Level{
    .{ .name = "BASIC", .programs = &.{p(.wander, 1)} },
    .{ .name = "COBOL", .programs = &.{ p(.wander, 2), p(.wander, 2) } },
    .{ .name = "PASCAL", .programs = &.{p(.avoid, 1)} },
    .{ .name = "FORTRAN", .programs = &.{ p(.avoid, 2), p(.avoid, 2) } },
    .{ .name = "LISP", .programs = &.{ p(.avoid, 3), p(.avoid, 3), p(.avoid, 3) }, .layout = 1 },
    .{ .name = "C", .programs = &.{p(.territory, 0)} },
    .{ .name = "C++", .programs = &.{ p(.territory, 0), p(.territory, 0) }, .layout = 2 },
    .{ .name = "JAVA", .programs = &.{ p(.territory, 2), p(.avoid, 3), p(.avoid, 3) } },
    .{ .name = "RUST", .programs = &.{ p(.territory, 2), p(.territory, 1) }, .speed_pct = 110, .layout = 3 },
    .{ .name = "ASM", .programs = &.{p(.search, 1)} },
    .{ .name = "ZIG", .programs = &.{ p(.search, 2), p(.territory, 3) }, .layout = 4 },
    .{ .name = "PROD", .programs = &.{ p(.search, 3), p(.territory, 3), p(.territory, 3) }, .layout = 6 },
};

/// Layouts the ladder cycles through on later loops: 1..8 of
/// `layouts.zig` (`layouts.count` = 9 with 0 OPEN).
pub const layouts_used: u8 = 8;

/// A ladder position resolved for a round.
pub const Round = struct {
    /// Ladder position, 1-based (13 is BASIC on the second loop).
    n: u32,
    /// 0 on the first pass, 1 after PROD once, ...
    loop: u32,
    level: *const Level,
    speed_pct: u16,
    layout: u8,

    pub fn name(r: Round) []const u8 {
        return r.level.name;
    }
    /// The number shown on banners and the HUD: 1..12 on every loop.
    pub fn number(r: Round) u32 {
        return (r.n - 1) % count + 1;
    }
    pub fn programs(r: Round) []const Program {
        return r.level.programs;
    }
    pub fn n_cycles(r: Round) u8 {
        return @intCast(1 + r.level.programs.len);
    }

    /// The round's rules: every M1 mechanic on, sudden death per level.
    pub fn config(r: Round) sim.Config {
        return .{
            .n_cycles = r.n_cycles(),
            .speed_pct = r.speed_pct,
            .grinding = true,
            .energy = true,
            .rubber = sim.tuning.rubber_max,
            .sudden_death = r.level.sudden_death,
            .layout = r.layout,
        };
    }
};

/// Ladder position n (1-based). Loops after PROD at +10% speed per loop;
/// from the second loop the layouts shift by one per loop so a returning
/// player sees new arenas.
pub fn get(n: u32) Round {
    const k = if (n == 0) 1 else n;
    const loop = (k - 1) / count;
    const lv = &table[(k - 1) % count];
    var layout = lv.layout;
    if (layout != 0 and loop != 0) layout = @intCast((layout - 1 + loop) % layouts_used + 1);
    const speed: u32 = @as(u32, lv.speed_pct) * (100 + loop_speed_pct * @min(loop, 20)) / 100;
    return .{
        .n = k,
        .loop = loop,
        .level = lv,
        .speed_pct = @intCast(speed),
        .layout = layout,
    };
}

/// OPTIONS (SPEC 6, PLAN M2 Track R item 4): the session's modifiers,
/// all off by default, for the ladder and SKIRMISH. RAM only.
pub const Options = struct {
    speed: Speed = .normal,
    /// TRAILS: SNAKE (finite walls) instead of FULL.
    snake: bool = false,
    gaps: bool = false,
    wrap: bool = false,
    /// Rubber 4 and no snapshots in the ladder.
    hardcore: bool = false,

    pub const Speed = enum(u8) {
        normal,
        slow,
        fast,

        pub fn pct(s: Speed) u16 {
            return switch (s) {
                .normal => 100,
                .slow => 80,
                .fast => 125,
            };
        }
        pub fn name(s: Speed) []const u8 {
            return switch (s) {
                .normal => "NORMAL",
                .slow => "SLOW",
                .fast => "FAST",
            };
        }
    };

    /// SNAKE's wall length (Armagetron's WALLS_LENGTH, SPEC 6).
    pub const snake_len = sim.tuning.snake_len;
    pub const hardcore_rubber: u8 = 4;

    /// `cfg` with these options on top: speed scaled, the modifiers set.
    pub fn apply(o: Options, cfg: sim.Config) sim.Config {
        var c = cfg;
        c.speed_pct = @intCast(@as(u32, cfg.speed_pct) * o.speed.pct() / 100);
        if (o.snake) c.snake_len = snake_len;
        c.gaps = o.gaps;
        c.wrap = o.wrap;
        if (o.hardcore) c.rubber = hardcore_rubber;
        return c;
    }

    pub fn is_default(o: Options) bool {
        return std.meta.eql(o, Options{});
    }

    /// `debug_options` and the `snouty_cycles_options` poke: bits 0-1
    /// speed (0 normal, 1 slow, 2 fast), 2 SNAKE, 3 GAPS, 4 WRAP,
    /// 5 HARDCORE.
    pub fn from_bits(b: u32) Options {
        return .{
            .speed = @fromBackingInt(@intCast(@min(b & 3, 2))),
            .snake = b & 4 != 0,
            .gaps = b & 8 != 0,
            .wrap = b & 16 != 0,
            .hardcore = b & 32 != 0,
        };
    }
    pub fn bits(o: Options) u32 {
        return @as(u32, @backingInt(o.speed)) | @as(u32, @intFromBool(o.snake)) << 2 |
            @as(u32, @intFromBool(o.gaps)) << 3 | @as(u32, @intFromBool(o.wrap)) << 4 |
            @as(u32, @intFromBool(o.hardcore)) << 5;
    }
};

/// SKIRMISH's program tiers, named like the ladder's levels where they
/// first appear (SPEC 6, PLAN M2 Track R item 3).
pub const tier_names = [4][]const u8{ "BASIC", "PASCAL", "C", "ASM" };
pub const skirmish_tiers = [4]ai.Tier{ .wander, .avoid, .territory, .search };
/// The `ai.preset` level SKIRMISH's programs use.
pub const skirmish_preset: u8 = 2;

/// A SKIRMISH round: `programs` (1..3) of tier `tier` (0..3) in layout
/// `layout`, every M1 rule on, then the options.
pub fn skirmish_config(programs: u8, layout: u8, o: Options) sim.Config {
    return o.apply(.{
        .n_cycles = 1 + programs,
        .grinding = true,
        .energy = true,
        .rubber = sim.tuning.rubber_max,
        .sudden_death = true,
        .layout = layout,
    });
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "the ladder: SPEC 6's twelve levels, then a faster loop" {
    try testing.expectEqualStrings("BASIC", get(1).name());
    try testing.expectEqualStrings("C", get(6).name());
    try testing.expectEqualStrings("ZIG", get(11).name());
    try testing.expectEqualStrings("PROD", get(12).name());
    try testing.expectEqual(@as(u8, 4), get(12).n_cycles());
    try testing.expectEqual(@as(u16, 110), get(9).speed_pct);
    try testing.expectEqual(@as(u16, 100), get(12).speed_pct);
    // Loop 2: BASIC again at 110%, RUST at 121%.
    try testing.expectEqualStrings("BASIC", get(13).name());
    try testing.expectEqual(@as(u32, 1), get(13).number());
    try testing.expectEqual(@as(u16, 110), get(13).speed_pct);
    try testing.expectEqual(@as(u16, 121), get(21).speed_pct);
    for (1..40) |n| {
        const r = get(@intCast(n));
        const cfg = r.config();
        try testing.expect(cfg.n_cycles >= 2 and cfg.n_cycles <= sim.max_cycles);
        try testing.expect(cfg.sudden_death);
        try testing.expect(cfg.layout <= layouts_used);
        // No layouts before LISP on the first pass.
        if (n < 5) try testing.expectEqual(@as(u8, 0), cfg.layout);
        // Names fit the HUD and the intro banner at scale 2.
        try testing.expect(r.name().len <= 8);
    }
}

test "options: defaults change nothing; each one sets its Config field" {
    const base = get(6).config();
    try testing.expect(std.meta.eql(base, (Options{}).apply(base)));
    const all: Options = .{ .speed = .fast, .snake = true, .gaps = true, .wrap = true, .hardcore = true };
    const c = all.apply(base);
    try testing.expectEqual(@as(u16, 125), c.speed_pct);
    try testing.expectEqual(Options.snake_len, c.snake_len);
    try testing.expect(c.gaps and c.wrap);
    try testing.expectEqual(Options.hardcore_rubber, c.rubber);
    try testing.expectEqual(@as(u16, 88), (Options{ .speed = .slow }).apply(get(9).config()).speed_pct);
    for (0..64) |b| {
        const o = Options.from_bits(@intCast(b));
        if (b & 3 != 3) try testing.expectEqual(@as(u32, @intCast(b)), o.bits());
    }
    try testing.expect(!all.is_default() and (Options{}).is_default());
}
