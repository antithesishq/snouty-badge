//! Spawner and stage flow (PLAN.md M7 "Stages"): four stages, `UNIT
//! TESTS`, `INTEGRATION`, `STAGING` and `PRODUCTION`, one table each,
//! then the loop again (`loop + 1`, rank +400). Per stage: the `STAGE n`
//! pop (hud.zig) over the first 120 ticks of the table, the table (about
//! 70 s, sorted by tick; a midboss entry pauses the table clock while the
//! herd lives, so it cannot be waited out), `.warning` for 6 s, the boss
//! (`.boss`), its death (`.cleared`, +500 and a fuel refill) or escape (no
//! +500, no refill), a 120-tick breather, the next stage. The difficulty
//! comes from `rank.zig` and from what each table puts on the field.
const enemies = @import("enemies.zig");
const rng = @import("rng.zig");
const world = @import("world.zig");
const formations = @import("formations.zig");

const Kind = enemies.Kind;
const Edge = enemies.Edge;

/// `y` value meaning "draw from the world rng".
const random: i16 = -1;

/// One scripted spawn. `y` is the cell y for the right and left edges and
/// the cell x for the top and bottom edges (spider: its column x; mite and
/// herd: ignored), `random` draws it from the world rng. Gnat entries
/// spawn one string of 5 (count and spacing are ignored); centipede entries
/// one centipede (head and 5 segments). Other kinds spawn `count`, the
/// i-th `i * spacing` ticks later, offset across the edge by `vee(i) * dy`
/// px (0, -dy, +dy, -2 dy, ...: a vee when the spacing is short).
/// `formation`: the members form one formation that drops a crate when
/// all are shot down (1942's POW). `pattern` picks the kind's movement /
/// fire program (enemies.zig). `edge` (wasps and ladybugs): where they
/// come in; fleas always come from the left, behind the ship.
pub const Entry = struct {
    at: u32,
    kind: Kind,
    y: i16 = random,
    count: u8 = 1,
    spacing: u8 = 0,
    dy: i8 = 0,
    pattern: u8 = 0,
    formation: bool = false,
    edge: Edge = .right,
};

fn s(sec: u32) u32 {
    return sec * 60;
}

/// Stage 1, UNIT TESTS: the five old bugs. Learn the game, but every kind
/// fires soon after it shows; from 20 s the gnat strings fire too.
const stage1 = [_]Entry{
    .{ .at = s(2), .kind = .gnat, .y = 40, .formation = true },
    .{ .at = s(4), .kind = .gnat, .y = 88 },
    .{ .at = s(7), .kind = .wasp, .y = 56, .count = 3, .spacing = 8, .dy = 18 },
    .{ .at = s(10), .kind = .beetle, .y = 40 },
    .{ .at = s(12), .kind = .gnat, .y = 96 },
    .{ .at = s(14), .kind = .spider },
    .{ .at = s(15), .kind = .wasp, .y = 30, .count = 3, .spacing = 8, .dy = 16 },
    .{ .at = s(17), .kind = .moth, .count = 2, .spacing = 30 },
    .{ .at = s(20), .kind = .gnat, .y = 30, .pattern = 1 },
    .{ .at = s(21), .kind = .gnat, .y = 90, .pattern = 1 },
    .{ .at = s(23), .kind = .beetle, .y = 80 },
    .{ .at = s(24), .kind = .wasp, .y = 40, .count = 3, .spacing = 8, .dy = 18 },
    .{ .at = s(26), .kind = .spider, .count = 2, .spacing = 60 },
    .{ .at = s(29), .kind = .moth, .count = 2, .spacing = 30 },
    .{ .at = s(29), .kind = .gnat, .pattern = 1 },
    .{ .at = s(32), .kind = .wasp, .y = 92, .count = 3, .spacing = 8, .dy = 16 },
    .{ .at = s(33), .kind = .wasp, .y = 28, .count = 3, .spacing = 8, .dy = 16 },
    .{ .at = s(35), .kind = .beetle, .y = 28 },
    .{ .at = s(35), .kind = .beetle, .y = 92 },
    .{ .at = s(38), .kind = .gnat, .y = 50, .pattern = 1, .formation = true },
    .{ .at = s(39), .kind = .gnat, .y = 80, .pattern = 1 },
    .{ .at = s(41), .kind = .spider, .count = 2, .spacing = 40 },
    .{ .at = s(44), .kind = .moth, .count = 3, .spacing = 30 },
    .{ .at = s(45), .kind = .wasp, .y = 64, .count = 3, .spacing = 8, .dy = 18 },
    .{ .at = s(48), .kind = .beetle, .y = 60 },
    .{ .at = s(49), .kind = .gnat, .y = 24, .pattern = 1 },
    .{ .at = s(50), .kind = .gnat, .y = 100, .pattern = 1 },
    .{ .at = s(52), .kind = .wasp, .y = 30, .count = 3, .spacing = 8, .dy = 16 },
    .{ .at = s(53), .kind = .wasp, .y = 92, .count = 3, .spacing = 8, .dy = 16 },
    .{ .at = s(54), .kind = .spider, .count = 2, .spacing = 40 },
    .{ .at = s(56), .kind = .moth, .count = 2, .spacing = 30 },
    .{ .at = s(57), .kind = .beetle, .y = 36 },
    .{ .at = s(57), .kind = .beetle, .y = 84 },
    .{ .at = s(60), .kind = .gnat, .y = 24, .pattern = 1 },
    .{ .at = s(61), .kind = .gnat, .y = 64, .pattern = 1 },
    .{ .at = s(62), .kind = .gnat, .y = 100, .pattern = 1 },
    .{ .at = s(63), .kind = .wasp, .y = 56, .count = 3, .spacing = 8, .dy = 20 },
    .{ .at = s(65), .kind = .spider, .count = 2, .spacing = 40 },
    .{ .at = s(66), .kind = .moth, .count = 2, .spacing = 30 },
    .{ .at = s(68), .kind = .gnat, .y = 40, .pattern = 1 },
    .{ .at = s(68), .kind = .gnat, .y = 88, .pattern = 1 },
    // The last wave flies the spawn line: a crate before the WARNING
    // for a ship that has not moved (the probe's turret).
    .{ .at = s(69), .kind = .gnat, .y = 58, .formation = true },
};

/// Stage 2, INTEGRATION: the centipede, ladybug loops from the top and the
/// bottom, fleas from behind; the Thundering Herd at 35 s.
const stage2 = [_]Entry{
    .{ .at = s(2), .kind = .centipede, .y = 40, .formation = true },
    .{ .at = s(5), .kind = .gnat, .y = 96, .pattern = 1 },
    .{ .at = s(7), .kind = .ladybug, .y = 120, .count = 4, .spacing = 16, .edge = .top },
    .{ .at = s(10), .kind = .flea, .y = 80 },
    .{ .at = s(11), .kind = .wasp, .y = 60, .count = 3, .spacing = 8, .dy = 18, .pattern = 1 },
    .{ .at = s(13), .kind = .ladybug, .y = 100, .count = 4, .spacing = 16, .edge = .bottom },
    .{ .at = s(16), .kind = .beetle, .y = 40, .pattern = 1 },
    .{ .at = s(17), .kind = .centipede, .y = 88 },
    .{ .at = s(20), .kind = .flea, .y = 70, .count = 2, .spacing = 50 },
    .{ .at = s(21), .kind = .moth, .count = 2, .spacing = 30 },
    .{ .at = s(24), .kind = .ladybug, .y = 130, .count = 4, .spacing = 16, .edge = .top, .formation = true },
    .{ .at = s(25), .kind = .ladybug, .y = 90, .count = 4, .spacing = 16, .edge = .bottom },
    .{ .at = s(27), .kind = .gnat, .y = 30, .pattern = 1 },
    .{ .at = s(28), .kind = .gnat, .y = 96, .pattern = 1 },
    .{ .at = s(29), .kind = .spider, .count = 2, .spacing = 50 },
    .{ .at = s(32), .kind = .wasp, .y = 80, .count = 3, .spacing = 8, .dy = 20, .pattern = 1, .edge = .top },
    .{ .at = s(35), .kind = .herd },
    .{ .at = s(38), .kind = .centipede, .y = 64, .pattern = 1 },
    .{ .at = s(40), .kind = .flea, .y = 60 },
    .{ .at = s(40), .kind = .flea, .y = 90, .pattern = 1 },
    .{ .at = s(42), .kind = .ladybug, .y = 110, .count = 4, .spacing = 16, .edge = .top },
    .{ .at = s(44), .kind = .beetle, .y = 88, .pattern = 1 },
    .{ .at = s(44), .kind = .moth, .count = 2, .spacing = 30 },
    .{ .at = s(47), .kind = .ladybug, .y = 120, .count = 4, .spacing = 16, .edge = .bottom },
    .{ .at = s(48), .kind = .gnat, .y = 50, .pattern = 1 },
    .{ .at = s(50), .kind = .wasp, .y = 30, .count = 3, .spacing = 8, .dy = 16, .pattern = 1 },
    .{ .at = s(51), .kind = .wasp, .y = 92, .count = 3, .spacing = 8, .dy = 16, .pattern = 1 },
    .{ .at = s(53), .kind = .centipede, .y = 40 },
    .{ .at = s(54), .kind = .flea, .y = 80, .pattern = 1 },
    .{ .at = s(56), .kind = .spider, .count = 2, .spacing = 40 },
    .{ .at = s(57), .kind = .ladybug, .y = 130, .count = 4, .spacing = 16, .edge = .top },
    .{ .at = s(59), .kind = .beetle, .y = 40, .pattern = 1 },
    .{ .at = s(59), .kind = .beetle, .y = 88 },
    .{ .at = s(62), .kind = .flea, .y = 70, .count = 3, .spacing = 40 },
    .{ .at = s(64), .kind = .ladybug, .y = 120, .count = 4, .spacing = 16, .edge = .top },
    .{ .at = s(65), .kind = .ladybug, .y = 90, .count = 4, .spacing = 16, .edge = .bottom },
    .{ .at = s(67), .kind = .gnat, .y = 40, .pattern = 2 },
    .{ .at = s(68), .kind = .gnat, .y = 88, .pattern = 2 },
    // The last wave flies the spawn line: a crate before the WARNING
    // for a ship that has not moved (the probe's turret).
    .{ .at = s(69), .kind = .gnat, .y = 58, .formation = true },
};

/// Stage 3, STAGING: ground mites and zombies, walls with gaps (beetle
/// pattern 2), stop-and-go moths, two kinds at once; Herd v2 at 35 s.
const stage3 = [_]Entry{
    .{ .at = s(2), .kind = .mite },
    .{ .at = s(3), .kind = .gnat, .y = 40, .pattern = 1 },
    .{ .at = s(6), .kind = .zombie, .y = 48, .count = 2, .spacing = 40, .dy = 20 },
    .{ .at = s(9), .kind = .beetle, .y = 56, .pattern = 2 },
    .{ .at = s(10), .kind = .mite },
    .{ .at = s(13), .kind = .ladybug, .y = 120, .count = 4, .spacing = 16, .edge = .top, .pattern = 1, .formation = true },
    .{ .at = s(15), .kind = .flea, .y = 70, .pattern = 1 },
    .{ .at = s(17), .kind = .zombie, .y = 70, .count = 2, .spacing = 40, .dy = 24 },
    .{ .at = s(17), .kind = .moth, .pattern = 1 },
    .{ .at = s(20), .kind = .centipede, .y = 40, .pattern = 1 },
    .{ .at = s(20), .kind = .mite },
    .{ .at = s(23), .kind = .beetle, .y = 30, .pattern = 2 },
    .{ .at = s(23), .kind = .gnat, .y = 96, .pattern = 2 },
    .{ .at = s(26), .kind = .ladybug, .y = 100, .count = 4, .spacing = 16, .edge = .bottom, .pattern = 1 },
    .{ .at = s(26), .kind = .flea, .y = 80, .count = 2, .spacing = 40 },
    .{ .at = s(29), .kind = .wasp, .y = 60, .count = 3, .spacing = 8, .dy = 18, .pattern = 1 },
    .{ .at = s(29), .kind = .mite, .pattern = 1 },
    .{ .at = s(32), .kind = .zombie, .y = 40, .count = 2, .spacing = 30, .dy = 30, .pattern = 1 },
    .{ .at = s(32), .kind = .spider, .count = 2, .spacing = 40, .pattern = 1 },
    .{ .at = s(35), .kind = .herd, .pattern = 1 },
    .{ .at = s(37), .kind = .mite, .count = 2, .spacing = 90 },
    .{ .at = s(38), .kind = .beetle, .y = 80, .pattern = 2 },
    .{ .at = s(38), .kind = .moth, .pattern = 1 },
    .{ .at = s(41), .kind = .centipede, .y = 70, .pattern = 1, .formation = true },
    .{ .at = s(41), .kind = .flea, .y = 60, .pattern = 1 },
    .{ .at = s(44), .kind = .ladybug, .y = 130, .count = 4, .spacing = 16, .edge = .top, .pattern = 1 },
    .{ .at = s(45), .kind = .ladybug, .y = 90, .count = 4, .spacing = 16, .edge = .bottom, .pattern = 1 },
    .{ .at = s(47), .kind = .zombie, .y = 56, .count = 3, .spacing = 40, .dy = 24, .pattern = 1 },
    .{ .at = s(48), .kind = .gnat, .y = 30, .pattern = 2 },
    .{ .at = s(50), .kind = .beetle, .y = 40, .pattern = 2 },
    .{ .at = s(50), .kind = .mite, .pattern = 1 },
    .{ .at = s(53), .kind = .flea, .y = 80, .count = 2, .spacing = 30, .pattern = 1 },
    .{ .at = s(53), .kind = .wasp, .y = 70, .count = 3, .spacing = 8, .dy = 20, .pattern = 1, .edge = .top },
    .{ .at = s(56), .kind = .centipede, .y = 40, .pattern = 2 },
    .{ .at = s(56), .kind = .ladybug, .y = 110, .count = 4, .spacing = 16, .edge = .bottom, .pattern = 2 },
    .{ .at = s(59), .kind = .moth, .count = 2, .spacing = 30, .pattern = 1 },
    .{ .at = s(59), .kind = .spider, .count = 2, .spacing = 40, .pattern = 1 },
    .{ .at = s(60), .kind = .mite },
    .{ .at = s(62), .kind = .beetle, .y = 88, .pattern = 1 },
    .{ .at = s(62), .kind = .zombie, .y = 40, .count = 2, .spacing = 30, .dy = 30, .pattern = 1 },
    .{ .at = s(65), .kind = .flea, .y = 70, .count = 2, .spacing = 40, .pattern = 2 },
    .{ .at = s(65), .kind = .ladybug, .y = 120, .count = 4, .spacing = 16, .edge = .top, .pattern = 2 },
    .{ .at = s(68), .kind = .gnat, .y = 40, .pattern = 2 },
    .{ .at = s(68), .kind = .gnat, .y = 88, .pattern = 2 },
    // The last wave flies the spawn line: a crate before the WARNING
    // for a ship that has not moved (the probe's turret).
    .{ .at = s(69), .kind = .gnat, .y = 58, .formation = true },
};

/// Stage 4, PRODUCTION: everything, overlapping formations, curtains from
/// two sides (walls from the right while fleas come from behind, ladybugs
/// from the top and the bottom at once), the splitting orb beetle; Herd v3
/// at 35 s.
const stage4 = [_]Entry{
    .{ .at = s(2), .kind = .centipede, .y = 40, .pattern = 2 },
    .{ .at = s(2), .kind = .mite, .pattern = 1 },
    .{ .at = s(5), .kind = .ladybug, .y = 120, .count = 4, .spacing = 16, .edge = .top, .pattern = 2, .formation = true },
    .{ .at = s(5), .kind = .ladybug, .y = 80, .count = 4, .spacing = 16, .edge = .bottom, .pattern = 2 },
    .{ .at = s(8), .kind = .beetle, .y = 64, .pattern = 2 },
    .{ .at = s(9), .kind = .flea, .y = 80, .count = 2, .spacing = 40, .pattern = 1 },
    .{ .at = s(11), .kind = .zombie, .y = 40, .count = 2, .spacing = 30, .dy = 30, .pattern = 1 },
    .{ .at = s(12), .kind = .moth, .pattern = 1 },
    .{ .at = s(14), .kind = .beetle, .y = 30, .pattern = 3 },
    .{ .at = s(14), .kind = .mite, .pattern = 1 },
    .{ .at = s(17), .kind = .ladybug, .y = 110, .count = 4, .spacing = 16, .edge = .top, .pattern = 1 },
    .{ .at = s(17), .kind = .gnat, .y = 96, .pattern = 2 },
    .{ .at = s(20), .kind = .flea, .y = 70, .count = 2, .spacing = 40, .pattern = 2 },
    .{ .at = s(20), .kind = .wasp, .y = 70, .count = 3, .spacing = 8, .dy = 20, .pattern = 1, .edge = .top },
    .{ .at = s(21), .kind = .wasp, .y = 110, .count = 3, .spacing = 8, .dy = 20, .pattern = 1, .edge = .bottom },
    .{ .at = s(23), .kind = .centipede, .y = 88, .pattern = 1 },
    .{ .at = s(23), .kind = .spider, .count = 2, .spacing = 40, .pattern = 1 },
    .{ .at = s(26), .kind = .beetle, .y = 40, .pattern = 2 },
    .{ .at = s(26), .kind = .flea, .y = 80, .count = 2, .spacing = 30, .pattern = 1 },
    .{ .at = s(29), .kind = .zombie, .y = 56, .count = 3, .spacing = 40, .dy = 24, .pattern = 1 },
    .{ .at = s(29), .kind = .mite, .pattern = 1 },
    .{ .at = s(32), .kind = .ladybug, .y = 130, .count = 4, .spacing = 16, .edge = .top, .pattern = 2 },
    .{ .at = s(32), .kind = .ladybug, .y = 90, .count = 4, .spacing = 16, .edge = .bottom, .pattern = 2 },
    .{ .at = s(34), .kind = .moth, .count = 2, .spacing = 30, .pattern = 1 },
    .{ .at = s(35), .kind = .herd, .pattern = 2 },
    .{ .at = s(37), .kind = .mite, .count = 2, .spacing = 90, .pattern = 1 },
    .{ .at = s(39), .kind = .beetle, .y = 88, .pattern = 3 },
    .{ .at = s(39), .kind = .flea, .y = 70, .count = 2, .spacing = 40, .pattern = 1 },
    .{ .at = s(42), .kind = .centipede, .y = 60, .pattern = 2, .formation = true },
    .{ .at = s(42), .kind = .ladybug, .y = 120, .count = 4, .spacing = 16, .edge = .top, .pattern = 1 },
    .{ .at = s(45), .kind = .beetle, .y = 50, .pattern = 2 },
    .{ .at = s(45), .kind = .flea, .y = 80, .count = 3, .spacing = 30, .pattern = 2 },
    .{ .at = s(48), .kind = .zombie, .y = 50, .count = 3, .spacing = 30, .dy = 26, .pattern = 1 },
    .{ .at = s(48), .kind = .spider, .count = 3, .spacing = 40, .pattern = 1 },
    .{ .at = s(51), .kind = .ladybug, .y = 100, .count = 4, .spacing = 16, .edge = .bottom, .pattern = 2 },
    .{ .at = s(51), .kind = .wasp, .y = 30, .count = 3, .spacing = 8, .dy = 16, .pattern = 1 },
    .{ .at = s(52), .kind = .wasp, .y = 92, .count = 3, .spacing = 8, .dy = 16, .pattern = 1 },
    .{ .at = s(54), .kind = .centipede, .y = 40, .pattern = 1 },
    .{ .at = s(54), .kind = .mite, .count = 2, .spacing = 60, .pattern = 1 },
    .{ .at = s(57), .kind = .beetle, .y = 30, .pattern = 3 },
    .{ .at = s(57), .kind = .beetle, .y = 84, .pattern = 2 },
    .{ .at = s(60), .kind = .flea, .y = 70, .count = 3, .spacing = 30, .pattern = 1 },
    .{ .at = s(60), .kind = .moth, .count = 2, .spacing = 30, .pattern = 1 },
    .{ .at = s(63), .kind = .ladybug, .y = 120, .count = 4, .spacing = 16, .edge = .top, .pattern = 2 },
    .{ .at = s(63), .kind = .ladybug, .y = 80, .count = 4, .spacing = 16, .edge = .bottom, .pattern = 2 },
    .{ .at = s(66), .kind = .zombie, .y = 40, .count = 2, .spacing = 30, .dy = 40, .pattern = 1 },
    .{ .at = s(66), .kind = .gnat, .y = 64, .pattern = 2 },
    .{ .at = s(68), .kind = .beetle, .y = 64, .pattern = 2 },
    // The last wave flies the spawn line: a crate before the WARNING
    // for a ship that has not moved (the probe's turret).
    .{ .at = s(69), .kind = .gnat, .y = 58, .formation = true },
};

/// Stage 1 from the second loop on also runs this: the bugs of the later
/// stages come back to UNIT TESTS, from behind, above and below, where a
/// fully powered ship cannot shoot them as they enter.
const stage1_loop = [_]Entry{
    .{ .at = s(6), .kind = .flea, .y = 80, .count = 2, .spacing = 40, .pattern = 1 },
    .{ .at = s(12), .kind = .mite, .pattern = 1 },
    .{ .at = s(18), .kind = .ladybug, .y = 120, .count = 4, .spacing = 16, .edge = .top, .pattern = 1 },
    .{ .at = s(24), .kind = .zombie, .y = 40, .count = 2, .spacing = 30, .dy = 40, .pattern = 1 },
    .{ .at = s(30), .kind = .flea, .y = 70, .count = 3, .spacing = 30, .pattern = 2 },
    .{ .at = s(36), .kind = .ladybug, .y = 90, .count = 4, .spacing = 16, .edge = .bottom, .pattern = 2 },
    .{ .at = s(42), .kind = .mite, .count = 2, .spacing = 60, .pattern = 1 },
    .{ .at = s(48), .kind = .flea, .y = 60, .count = 2, .spacing = 40, .pattern = 1 },
    .{ .at = s(54), .kind = .ladybug, .y = 120, .count = 4, .spacing = 16, .edge = .top, .pattern = 2 },
    .{ .at = s(54), .kind = .ladybug, .y = 80, .count = 4, .spacing = 16, .edge = .bottom, .pattern = 2 },
    .{ .at = s(60), .kind = .zombie, .y = 50, .count = 3, .spacing = 30, .dy = 26, .pattern = 1 },
    .{ .at = s(64), .kind = .flea, .y = 80, .count = 3, .spacing = 30, .pattern = 1 },
};

/// Extra waves by stage from the second loop on (run beside the table).
const loop_tables = [_][]const Entry{ &stage1_loop, &.{}, &.{}, &.{} };

/// The stage tables, `stage_count` of them.
const tables = [_][]const Entry{ &stage1, &stage2, &stage3, &stage4 };
pub const stage_count: u8 = tables.len;

/// Stage names (the `STAGE n` pop, PLAN.md M7).
pub const stage_names = [stage_count][]const u8{ "UNIT TESTS", "INTEGRATION", "STAGING", "PRODUCTION" };

/// 72 s: the table is done; "WARNING" until the boss enters (the table
/// clock, which waits while the midboss lives).
pub const warning_at: u32 = s(72);
/// 78 s: the boss enters.
pub const boss_at: u32 = s(78);
/// Ticks of the `STAGE n` pop at the start of a stage's table.
pub const stage_pop: u32 = 120;
/// Ticks of `.cleared` between the boss death and the table restarting.
pub const breather: u32 = 120;
/// Boss spawn point (cell top-left).
const boss_x: f32 = 168;
const boss_y: f32 = 40;
/// Midboss spawn point (cell top-left of the 32x32 herd).
const herd_x: f32 = 168;
const herd_y: f32 = 36;

const min_y = 16;
const max_y = 104;
const min_x = 40;
const max_x = 140;
const spider_min_x = 64;
const spider_max_x = 136;
/// Fleas come in on lines between these cell y.
const flea_min_y = 40;
const flea_max_y = 96;
const string_len = 5;
const centipede_len = 6;

pub const StagePhase = enum(u8) { waves, warning, boss, cleared };

/// Spawner state, stored in `world.w.waves`.
pub const State = struct {
    /// Ticks since the start of the current stage (paused while the
    /// midboss is on the field).
    t: u32 = 0,
    /// Index of the next entry of the stage's table to run.
    next: u8 = 0,
    /// Index of the next entry of the stage's loop table (second loop on).
    next_loop: u8 = 0,
    /// Completed loops through all `stage_count` stages (rank +400 each).
    loop: u8 = 0,
    /// Current stage index, 0..stage_count-1 (0 = UNIT TESTS).
    stage: u8 = 0,
    phase: StagePhase = .waves,
    /// Monotonic count of boss kills; `main` refills the rewind fuel when
    /// it passes its high water.
    stage_clears: u8 = 0,
    /// `game_tick` when the last boss died (0 = never).
    clear_tick: u32 = 0,
    /// The last stage ended with the boss escaping (its final phase timed
    /// out): no +500, no fuel refill (`stage_clears` untouched).
    escaped: bool = false,
};

fn table() []const Entry {
    return tables[@min(world.w.waves.stage, stage_count - 1)];
}

pub fn update() void {
    const st = &world.w.waves;
    if (st.phase == .cleared and world.w.game_tick -% st.clear_tick >= breather) {
        // The stage index already moved on at the clear (`advance`).
        st.t = 0;
        st.next = 0;
        st.next_loop = 0;
        st.phase = .waves;
    }
    if (st.phase == .waves and st.t >= warning_at) st.phase = .warning;
    if (st.phase == .warning and st.t >= boss_at) {
        // A full pool delays the boss by a tick rather than losing it.
        if (enemies.spawn(.boss, boss_x, boss_y, 0) != null) st.phase = .boss;
    }
    if (st.phase == .waves) {
        // The midboss holds the table: its stage cannot be waited out.
        if (enemies.herd_alive()) return;
        const tb = table();
        while (st.next < tb.len and tb[st.next].at <= st.t) {
            run(tb[st.next]);
            st.next += 1;
        }
        if (st.loop > 0) {
            const lt = loop_tables[@min(st.stage, stage_count - 1)];
            while (st.next_loop < lt.len and lt[st.next_loop].at <= st.t) {
                run(lt[st.next_loop]);
                st.next_loop += 1;
            }
        }
    }
    st.t += 1;
}

/// Moves the stage index on: the next stage, or stage 0 of the next loop
/// after the last one; the stage clock restarts (rank's stage_seconds).
fn advance() void {
    const st = &world.w.waves;
    st.stage += 1;
    if (st.stage >= stage_count) {
        st.stage = 0;
        st.loop +|= 1;
    }
    st.t = 0;
}

/// Called by the boss on the last tick of its death sequence: the clear
/// (+fuel via `stage_clears`), then a breather before the next stage,
/// whose index (and rank) applies from now.
pub fn boss_cleared() void {
    const st = &world.w.waves;
    st.escaped = false;
    st.stage_clears +%= 1;
    st.clear_tick = world.w.game_tick;
    advance();
    st.phase = .cleared;
}

/// Called by a boss whose final phase timed out once it has left the
/// screen (PLAN.md M7 "Decisions": nobody is stuck on a boss). The stage
/// advances as after a clear, without the +500 or the fuel refill.
pub fn boss_escaped() void {
    const st = &world.w.waves;
    st.escaped = true;
    st.clear_tick = world.w.game_tick;
    advance();
    st.phase = .cleared;
}

/// Debug hook (`debug_next_stage`): jumps to the start of the next stage at
/// once. Clears the enemies (the boss too), enemy bullets, crates and
/// formations, moves the stage index on as a clear does (not again during
/// the breather after a clear, which already did), and starts the table
/// from its first entry: no breather, +500, fuel refill or `stage_clears`
/// count. The caller checkpoints the history.
pub fn next_stage() void {
    const w = &world.w;
    w.enemies = @splat(.{});
    w.enemy_bullets = @splat(.{});
    w.pickups = @splat(.{});
    formations.clear();
    if (w.waves.phase == .cleared) w.waves.t = 0 else advance();
    w.waves.next = 0;
    w.waves.next_loop = 0;
    w.waves.phase = .waves;
}

/// The stage across loops, stage + 4 x loop (PLAN.md M7's numbering for
/// four stages per loop).
pub fn stage_index() u32 {
    const st = &world.w.waves;
    return @as(u32, st.stage) + 4 * @as(u32, st.loop);
}

/// Debug hook: jump to the warning (the rest of the table is skipped).
/// Only acts while the table is running, so it can never spawn a second
/// boss.
pub fn warp_to_warning() void {
    const st = &world.w.waves;
    if (st.phase != .waves) return;
    st.t = warning_at;
    st.next = @intCast(table().len);
    st.next_loop = @intCast(loop_tables[@min(st.stage, stage_count - 1)].len);
    st.phase = .warning;
}

fn pick(lo: i32, hi: i32, y: i16) f32 {
    return @floatFromInt(if (y == random) rng.range(lo, hi) else y);
}

/// Member offsets across the edge: 0, -1, +1, -2, +2, ... (a vee).
fn vee(i: usize) f32 {
    const k: f32 = @floatFromInt((i + 1) / 2);
    return if (i % 2 == 1) -k else k;
}

/// From the second loop on, every gnat string fires and the herd comes
/// one version harder, on top of the rank's +400 and the faster pace
/// (`enemies.loop_pace`).
fn remix(kind: Kind, pattern: u8) u8 {
    if (world.w.waves.loop == 0) return pattern;
    return switch (kind) {
        .herd => @min(pattern + 1, 2),
        .gnat => @max(pattern, 1),
        else => pattern,
    };
}

fn run(entry: Entry) void {
    var e = entry;
    e.pattern = remix(e.kind, e.pattern);
    switch (e.kind) {
        .gnat => {
            const id = if (e.formation) formations.open(string_len, true) else 0;
            enemies.spawn_gnat_string_ex(enemies.gnat_spawn_x, pick(min_y, max_y, e.y), id, e.pattern);
        },
        .centipede => {
            const id = if (e.formation) formations.open(centipede_len, true) else 0;
            enemies.spawn_centipede(pick(min_y + 8, max_y - 8, e.y), id, e.pattern);
        },
        .herd => _ = enemies.spawn_ex(.herd, herd_x, herd_y, 0, e.pattern, .right, 0),
        else => {
            const id = if (e.formation) formations.open(e.count, true) else 0;
            // One position per entry (a random one drawn once), then the
            // vee offsets.
            const across = switch (e.kind) {
                .spider => 0,
                .flea => pick(flea_min_y, flea_max_y, e.y),
                else => switch (e.edge) {
                    .top, .bottom => pick(min_x, max_x, e.y),
                    else => pick(min_y, max_y, e.y),
                },
            };
            for (0..e.count) |i| {
                const off = across + vee(i) * @as(f32, @floatFromInt(e.dy));
                const delay: u32 = @intCast(i * e.spacing);
                const m = switch (e.kind) {
                    // Spiders draw their own column each when random.
                    .spider => enemies.spawn_ex(.spider, pick(spider_min_x, spider_max_x, e.y), 0, delay, e.pattern, .top, 0),
                    .flea => enemies.spawn_ex(.flea, 0, off, delay, e.pattern, .left, 0),
                    .mite => enemies.spawn_ex(.mite, enemies.spawn_x, 0, delay, e.pattern, .right, 0),
                    else => switch (e.edge) {
                        .top => enemies.spawn_ex(e.kind, off, -16, delay, e.pattern, .top, 0),
                        .bottom => enemies.spawn_ex(e.kind, off, 128, delay, e.pattern, .bottom, 0),
                        // Only fleas come from the left (their programs
                        // move right); any other kind takes the right edge.
                        .left, .right => enemies.spawn_ex(e.kind, enemies.spawn_x, off, delay, e.pattern, .right, 0),
                    },
                };
                if (m) |en| en.formation = id else formations.lost(id);
            }
        },
    }
}
