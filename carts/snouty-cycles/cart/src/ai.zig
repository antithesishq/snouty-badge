//! The programs (SPEC.md section 5). `decide(brain, world, i)` returns
//! cycle i's input for the coming tick. It reads the World, never writes
//! it, and never sees the player's input, so a link game gets the same AI
//! on both badges.
//!
//! Tiers (after the 2010 Google AI Challenge, a1k0n's winning bot):
//! - T0 WANDER: a 1-3 cell lookahead, random turns, dodges a wall ahead
//!   only most of the time.
//! - T1 AVOID: a capped flood fill per move; most space wins.
//! - T2 TERRITORY: a Voronoi split per move. One BFS from every other head
//!   (the others' distance field), then per move a BFS of the cells this
//!   program reaches strictly first, scored 0.055 per cell + 0.194 per
//!   edge (a1k0n's fit); the 3x3 cut-cell table splits a move into
//!   chambers (only the best counts); the prey's cells it takes count
//!   twice, plus a bonus for claiming the prey's road. Once every move's
//!   territory is complete and touches no one it is alone: a
//!   parity-bounded, wall-hugging fill, braking while a rival's room is
//!   bigger. Sudden death: closing rings are walls, rooms count only the
//!   cells it can ride before their ring closes.
//! - T3 SEARCH: T2 with a longer view, plus iterative-deepening
//!   alpha-beta against the nearest rival (paranoid, others are walls) on
//!   a 32 x 32 bitboard window as a tactical check, and a depth-first
//!   fill search with parity-bounded chamber leaves once alone.
//!
//! Timing (PLAN M1 Track A item 2): a program decides once per cell. T2
//! and T3 think on the first tick in a new cell, or later if this tick's
//! shared work pool is spent (never past the last tick before the cell
//! boundary), and press their plan when the boundary is at most
//! `tuning.press_ticks` away, after re-checking that its cell is still
//! free. T0 and T1 think at press time (they are cheap). Pressing a tick
//! or two early means a speed change between ticks never makes a program
//! miss its boundary.
//!
//! Budgets are work units, never time: one unit per cell a fill or BFS
//! takes off its queue, per search node and per bitboard row step (about
//! 0.5 us each on the badge, calibrated). Each decision gets
//! `tuning.decision_units[tier]`; all programs deciding on one World tick
//! share `tuning.tick_pool`. Passes degrade as units run short (a field
//! or territory BFS stops at its share and counts as truncated; a search
//! keeps the deepest finished iteration); when a tick's pool is spent, T1
//! stands in with a small fill.
//!
//! Determinism: the only randomness is the brain's own xorshift, advanced
//! only by its decisions, and every decision is a function of the Brain
//! and the World on the tick it is made. A decision never spans ticks
//! (a search resumed over several Worlds could not be replayed from an
//! M2 keyframe taken in the middle), so a rewind replay from a keyframe
//! with the same Brains makes the same moves. The shared pool is module
//! state keyed by (World, tick); `reset_pool` forgets it after a restore.
//! The scratch (stamps, queue, cell info, the search grid) is module
//! state too and never carries anything from one decision to the next,
//! so `ai` is not reentrant but is replayable.
//!
//! M2 modifiers: SNAKE and GAPS only change the grid, which the programs
//! read as it is. WRAP (no rim) changes the topology: every neighbour step
//! wraps (`nb`; the BFS loops are specialised at compile time so the rim
//! arena pays nothing), distances between heads are the short way round,
//! and T3's 32 x 32 window wraps too. `wrapping` is set from the World at
//! every entry point.
const std = @import("std");
const sim = @import("sim.zig");
const rng = @import("rng.zig");

pub const Tier = enum(u8) {
    /// T0: short lookahead, random turns, sometimes misses a wall.
    wander,
    /// T1: capped flood fill per move.
    avoid,
    /// T2: Voronoi territory, chambers, endgame fill.
    territory,
    /// T3: alpha-beta against the nearest rival.
    search,
};

/// What a program holds down between decisions (the energy bar: SPEC 4).
pub const Hold = enum(u2) { none, boost, brake };

pub const tuning = struct {
    /// T1's flood fill stops counting here (SPEC 5).
    pub const fill_cap: u32 = 300;
    /// ... and when it stands in for T2/T3 on a tick whose pool is spent.
    pub const stand_in_cap: u32 = 100;
    /// A move into the cell another head is about to enter (a likely RACE
    /// CONDITION) counts its space divided by this (T1).
    pub const race_penalty: u32 = 4;

    /// Press the plan once the cell boundary is this many ticks away or
    /// less (at the current speed). Speed changes by well under 50% a
    /// tick, so 2 never misses a boundary.
    pub const press_ticks: u32 = 2;

    /// Work units all programs on one World tick share (calibrated with
    /// badge-bench: PLAN.md status, M1 Track A).
    pub const tick_pool: i32 = 10000;
    /// `decide_apart` (the autopilot riding for you): a pool of its own
    /// each tick, as big as the programs' (so a T3 thinks early on a
    /// quiet tick), but never more than `apart_cap` less what the
    /// programs spent on that tick: a frame's AI work stays bounded, and
    /// on a busy tick it defers to its last one like a program does.
    /// 12000 keeps the bench's WRAP runs under 10.5 ms (PLAN M2.1 status).
    pub const apart_pool: i32 = tick_pool;
    pub const apart_cap: i32 = 12000;
    /// A decision starts before its last tick only if this many units of
    /// the pool would be left for programs whose last tick it is.
    pub const due_reserve: i32 = 2000;
    /// A territory pass with fewer units left than this gives up (T1
    /// stands in): its answer would be noise.
    pub const min_pass: i32 = 100;
    /// How far a pass may run past its units: the BFS checks its budget
    /// once per layer.
    pub const overrun: u32 = 1200;
    /// Units one decision may use, per tier (T0 and T1 are not budgeted:
    /// a T1 decision is at most 3 x `fill_cap` plus 3 cells).
    pub const decision_units = [4]i32{ 0, 0, 6000, 8000 };

    // T0 WANDER defaults (full strength; presets soften them).
    pub const wander_look: u8 = 3;
    pub const wander_dodge_permille: u16 = 850;
    pub const wander_turn_permille: u16 = 30;

    // T2/T3 Voronoi weights per cell and per edge (a1k0n's fit, x1000).
    pub const w_cells: i32 = 55;
    pub const w_edges: i32 = 194;
    /// Bonus per cell 2..4 ahead of the prey that the program reaches
    /// first, per aggression step (aggression 0..8).
    pub const agg_unit: i32 = 50;
    pub const aggression_max: u8 = 8;
    /// The prey's territory counts against a move by this many eighths.
    pub const prey_share: i32 = 8;
    /// A move into a cut cell whose chambers stay apart (T2).
    pub const cut_penalty: i32 = 200;
    /// A move into the cell another head is about to enter (T2, T3 root).
    pub const race_score: i32 = 1 << 22;
    /// Endgame: a cell of room outweighs this many free neighbours of the
    /// move's cell (fewer: hug the walls).
    pub const hug_weight: i32 = 64;
    /// Separated: per cell of parity-bounded space difference (T3 leaves).
    pub const sep_weight: i32 = 256;

    /// Steps a T2 / T3 territory BFS looks from a move (vision 0). Reach
    /// is most of the strength: T2 at 16 / 24 / 36 against T1 won 9 / 22 /
    /// 32 of 40; T3 at 48, 64 or the whole arena against T2 at 32 won 25
    /// of 40 each (2026-10-05).
    pub const region_reach: u32 = 32;
    pub const region_reach_t3: u32 = 48;
    /// Eighths of the units left after the field that T3's territory
    /// pass may use (the rest is for the search).
    pub const t3_t2_share: i32 = 6;
    /// Layers a T3 leaf's window Voronoi runs (vision 0).
    pub const leaf_reach: u32 = 10;

    // T3 SEARCH (the window is 32 x 32: `bb_rows`).
    /// A rival is searched against when both head offsets are at most this.
    pub const search_range: u8 = 18;
    /// Deepest alpha-beta iteration (move pairs) and endgame fill depth.
    pub const max_depth: u8 = 8;
    pub const max_fill_depth: u8 = 24;

    /// Sudden death: plan as if the rings that start closing within this
    /// many ticks were walls already.
    pub const sd_lookahead: u32 = 180;
    /// ... and value rooms by how long they stay open from this many
    /// ticks before it starts.
    pub const sd_horizon: u32 = 1500;

    // Energy (T2/T3 only).
    /// Boost in a side-by-side race: prey within this many cells sideways
    /// and not more than one cell ahead, with this much clear road.
    pub const race_side: u8 = 6;
    pub const race_road: u32 = 6;
};

/// One program's mind. Small and plain, so M2 keyframes copy it whole.
pub const Brain = struct {
    tier: Tier = .avoid,
    rng: rng.Xorshift = .init(1),
    /// Human-feel knobs (SPEC 5): reaction delay in cells (after a turn
    /// the program goes straight this many cells unless the way ahead is
    /// blocked); the chance of a random move into a free cell per decision
    /// instead of the tier's choice (per mille); vision radius in cells (a
    /// fill or BFS sees this many steps; 0 = the whole arena).
    reaction: u8 = 0,
    mistake_permille: u16 = 0,
    vision: u8 = 0,
    /// T2/T3: how hard it goes for the prey's path (0..8).
    aggression: u8 = tuning.aggression_max,
    /// T3: deepest alpha-beta iteration in move pairs (0 = no cap).
    depth_cap: u8 = 0,
    /// T0: longest lookahead (1..3) and its dodge and random-turn rates.
    look: u8 = tuning.wander_look,
    dodge_permille: u16 = tuning.wander_dodge_permille,
    turn_permille: u16 = tuning.wander_turn_permille,
    /// The cycle it hunts (no_cycle or itself: the nearest rival).
    prey: u8 = sim.no_cycle,
    /// The trail position (log_head) of the cell the plan is for.
    decided: u32 = 0xFFFF_FFFF,
    /// The plan for the next cell boundary and whether it still has to be
    /// made (`pending`) or pressed (`armed`).
    plan: sim.Dir = .up,
    pending: bool = false,
    armed: bool = false,
    /// A or B held until the next decision (T2/T3).
    hold: Hold = .none,
    /// Cells left of the reaction delay.
    cooldown: u8 = 0,
    /// T2/T3: walled off from every other head when it last looked (the
    /// endgame), the biggest rival room then, and the others' trail
    /// count then (what they have filled since comes off that room).
    alone: bool = false,
    rival_room: u16 = 0,
    rival_mark: u32 = 0,

    pub fn init(tier: Tier, seed: u32) Brain {
        return .{ .tier = tier, .rng = .init(seed) };
    }

    /// A Brain from a preset (`preset`) with its own rng stream.
    pub fn from(k: Knobs, seed: u32) Brain {
        return .{
            .tier = k.tier,
            .rng = .init(seed),
            .reaction = k.reaction,
            .mistake_permille = k.mistake_permille,
            .vision = k.vision,
            .aggression = k.aggression,
            .depth_cap = k.depth_cap,
            .look = k.look,
            .dodge_permille = k.dodge_permille,
            .turn_permille = k.turn_permille,
            .prey = k.prey,
        };
    }
};

/// A Brain's configuration without its state (`preset`, `Brain.from`).
pub const Knobs = struct {
    tier: Tier,
    reaction: u8 = 0,
    mistake_permille: u16 = 0,
    vision: u8 = 0,
    aggression: u8 = tuning.aggression_max,
    depth_cap: u8 = 0,
    look: u8 = tuning.wander_look,
    dodge_permille: u16 = tuning.wander_dodge_permille,
    turn_permille: u16 = tuning.wander_turn_permille,
    prey: u8 = 0,
};

/// The ladder's knobs (levels.zig): `level` 0 is the softest program of a
/// tier, 3 (or more) the full-strength one. Presets hunt cycle 0 (the
/// player); a program that is cycle 0 itself hunts the nearest rival.
pub fn preset(tier: Tier, level: u8) Knobs {
    const l = @min(level, 3);
    return switch (tier) {
        // Sloppy: short sight, misses walls now and then, wanders.
        .wander => .{
            .tier = .wander,
            .look = ([4]u8{ 1, 2, 2, 3 })[l],
            .dodge_permille = ([4]u16{ 700, 780, 830, 870 })[l],
            .turn_permille = ([4]u16{ 50, 40, 35, 30 })[l],
        },
        // Never stupid but planless: shorter sight and a slip at the low end.
        .avoid => .{
            .tier = .avoid,
            .vision = ([4]u8{ 10, 16, 0, 0 })[l],
            .mistake_permille = ([4]u16{ 12, 6, 2, 0 })[l],
            .reaction = ([4]u8{ 1, 0, 0, 0 })[l],
        },
        // Hunts: aggression and vision grow with the level.
        .territory => .{
            .tier = .territory,
            .aggression = ([4]u8{ 4, 6, 8, 8 })[l],
            .vision = ([4]u8{ 28, 30, 0, 0 })[l],
            .mistake_permille = ([4]u16{ 6, 3, 1, 0 })[l],
            .reaction = ([4]u8{ 1, 0, 0, 0 })[l],
        },
        // Hard: a longer view and a deeper search with the level.
        .search => .{
            .tier = .search,
            .vision = ([4]u8{ 40, 0, 0, 0 })[l],
            .depth_cap = ([4]u8{ 1, 2, 3, 0 })[l],
            .mistake_permille = ([4]u16{ 3, 1, 0, 0 })[l],
        },
    };
}

/// Counters for tests and the bench; nothing reads them to decide.
pub const Stats = struct {
    /// Decisions made per tier (the tier's own method, fallbacks aside).
    decisions: [4]u32 = @splat(0),
    units: [4]u64 = @splat(0),
    max_units: [4]u32 = @splat(0),
    /// Decisions that ran out of units with no answer (T1 stood in).
    fallbacks: u32 = 0,
    /// Ticks a T2/T3 decision waited for the pool.
    deferred: u32 = 0,
    /// T3 alpha-beta: deepest finished iteration per decision.
    depth: [tuning.max_depth + 1]u32 = @splat(0),
    /// Most units any World tick used.
    max_tick_units: u32 = 0,
    /// Bitboard rows the T3 leaves processed (calibration).
    leaf_rows: u64 = 0,
    leaves: u64 = 0,
    /// Fallbacks per tier.
    tier_fallbacks: [4]u32 = @splat(0),
    /// Fallbacks by cause: the decision started with less than its units
    /// (pool short), or ran out of its own.
    short_fallbacks: u32 = 0,
};
pub var stats: Stats = .{};

// ---------------------------------------------------------------- decide

/// Cycle i's input for the coming tick: A/B held as planned, and a heading
/// press once per cell a tick or two before the boundary.
pub fn decide(b: *Brain, w: *const sim.World, i: usize) sim.Input {
    const c = &w.cycles[i];
    if (c.state != .alive or w.result != .running) return .idle;
    use_world(w);
    sync_pool(w);
    var press: ?sim.Dir = null;
    if (c.stalled) {
        // Rubber: the way ahead is blocked; a free turn applies at once.
        press = rescue(b, w, i);
    } else {
        if (b.decided != c.log_head) {
            b.decided = c.log_head;
            b.pending = true;
            b.armed = false;
        }
        const due = w.ticks_to_step(i) <= tuning.press_ticks;
        if (b.pending) think(b, w, i, due);
        if (b.armed and due) {
            b.armed = false;
            press = commit(b, w, i);
        }
    }
    // An empty bar gives nothing and holding it blocks the recharge.
    if (c.energy == 0) b.hold = .none;
    var in: sim.Input = .{ .boost = b.hold == .boost, .brake = b.hold == .brake };
    if (press) |d| {
        if (d != w.planned_dir(i)) in.press = .of(d);
    }
    return in;
}

/// Forgets the shared per-tick pool (call after restoring a World from a
/// keyframe, before the first `decide`).
pub fn reset_pool() void {
    pool_world = null;
}

/// `decide` for a cycle that is not one of the programs (the autopilot):
/// call it after every program's `decide` for the tick. It spends a pool
/// of its own (`tuning.apart_pool`, less whatever the programs left
/// short of `tuning.apart_cap`), so the programs play the same whether
/// you or the autopilot ride, and nothing it does reaches them.
pub fn decide_apart(b: *Brain, w: *const sim.World, i: usize) sim.Input {
    const fresh = pool_world != w or pool_tick != w.tick;
    const spent = if (fresh) 0 else tuning.tick_pool - pool_left;
    const saved = .{ pool_world, pool_tick, pool_left };
    defer {
        pool_world = saved[0];
        pool_tick = saved[1];
        pool_left = saved[2];
    }
    pool_world = w;
    pool_tick = w.tick;
    pool_left = @min(tuning.apart_pool, tuning.apart_cap - spent);
    return decide(b, w, i);
}

var pool_world: ?*const sim.World = null;
var pool_tick: u32 = 0;
var pool_left: i32 = 0;
/// Units left in the running decision (fills and BFS count them down).
var units_left: i32 = 0;

fn sync_pool(w: *const sim.World) void {
    if (pool_world == w and pool_tick == w.tick) return;
    if (pool_world != null) {
        const used: u32 = @intCast(@max(0, tuning.tick_pool - pool_left));
        stats.max_tick_units = @max(stats.max_tick_units, used);
    }
    pool_world = w;
    pool_tick = w.tick;
    pool_left = tuning.tick_pool;
}

/// Runs `f` with `budget` units and charges what it used to the pool.
fn charged(budget: i32, tier: Tier, comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    units_left = budget;
    const r = @call(.auto, f, args);
    const used: u32 = @intCast(@max(0, budget - units_left));
    pool_left -= @intCast(used);
    const t = @backingInt(tier);
    stats.units[t] += used;
    stats.max_units[t] = @max(stats.max_units[t], used);
    return r;
}

const unbudgeted: i32 = 1 << 30;

fn think(b: *Brain, w: *const sim.World, i: usize, due: bool) void {
    const c = &w.cycles[i];
    var plan: Plan = .{ .dir = c.dir };
    switch (b.tier) {
        // Cheap: decide at press time, on the freshest World.
        .wander => {
            if (!due) return;
            plan.dir = charged(unbudgeted, .wander, wander, .{ b, w, i });
        },
        .avoid => {
            if (!due) return;
            if (!reacting(b, w, i)) plan.dir = charged(unbudgeted, .avoid, avoid, .{ b, w, i });
        },
        .territory, .search => {
            if (reacting(b, w, i)) {
                plan.dir = c.dir;
            } else {
                const need = tuning.decision_units[@backingInt(b.tier)];
                if (!due and pool_left - need < tuning.due_reserve) {
                    stats.deferred += 1;
                    return;
                }
                const budget = @min(need, @max(pool_left, 0));
                const got = if (b.tier == .territory)
                    charged(budget, .territory, territory, .{ b, w, i })
                else
                    charged(budget, .search, search, .{ b, w, i });
                if (got) |p| {
                    plan = p;
                    stats.decisions[@backingInt(b.tier)] += 1;
                } else |_| {
                    stats.fallbacks += 1;
                    stats.tier_fallbacks[@backingInt(b.tier)] += 1;
                    if (budget < need) stats.short_fallbacks += 1;
                    plan.dir = stand_in(b, w, i);
                }
            }
        },
    }
    if (b.mistake_permille != 0 and b.rng.chance(b.mistake_permille)) {
        // A slip: any move whose next cell is free, the planned one included.
        const cands = [3]sim.Dir{ c.dir, c.dir.ccw(), c.dir.cw() };
        const k = b.rng.below(3);
        for (0..3) |j| {
            const m = cands[(k + j) % 3];
            const t = w.next_cell(c.x, c.y, m);
            if (!sim.is_wall(w.at(t[0], t[1]))) {
                plan.dir = m;
                break;
            }
        }
    }
    b.plan = plan.dir;
    b.hold = plan.hold;
    b.pending = false;
    b.armed = true;
}

/// The reaction delay: after a turn, carry straight on for `cooldown`
/// cells while the way ahead is clear (and nobody is about to cut in).
fn reacting(b: *Brain, w: *const sim.World, i: usize) bool {
    if (b.cooldown == 0) return false;
    b.cooldown -= 1;
    const c = &w.cycles[i];
    const t = w.next_cell(c.x, c.y, c.dir);
    return !sim.is_wall(w.at(t[0], t[1])) and !race_risk(w, i, t);
}

/// Presses the plan, unless its cell has been taken since (T2/T3 think a
/// few ticks ahead): then T1's answer on the World as it is now.
fn commit(b: *Brain, w: *const sim.World, i: usize) sim.Dir {
    const c = &w.cycles[i];
    var d = b.plan;
    if (b.tier == .territory or b.tier == .search) {
        const t = w.next_cell(c.x, c.y, d);
        if (sim.is_wall(w.at(t[0], t[1])) or race_risk(w, i, t)) {
            d = stand_in(b, w, i);
        }
    }
    if (d != c.dir) b.cooldown = b.reaction;
    return d;
}

/// Stalled on rubber: T0 dodges if it notices; the others take T1's move.
fn rescue(b: *Brain, w: *const sim.World, i: usize) ?sim.Dir {
    const c = &w.cycles[i];
    const d = if (b.tier == .wander)
        (if (b.rng.chance(b.dodge_permille)) dodge(b, w, i) else c.dir)
    else
        stand_in(b, w, i);
    const t = w.next_cell(c.x, c.y, d);
    if (sim.is_wall(w.at(t[0], t[1]))) return null;
    return d;
}

const Plan = struct {
    dir: sim.Dir,
    hold: Hold = .none,
};

const Err = error{OutOfBudget};

// ---------------------------------------------------------------- T0, T1

/// T0 WANDER: straight on unless a wall shows within its 1..look cell
/// lookahead (then it dodges, most of the time); now and then a random
/// turn into a free side.
fn wander(b: *Brain, w: *const sim.World, i: usize) sim.Dir {
    const c = &w.cycles[i];
    const look = 1 + b.rng.below(@max(b.look, 1));
    if (w.free_run(c.x, c.y, c.dir, look) < look) {
        return if (b.rng.chance(b.dodge_permille)) dodge(b, w, i) else c.dir;
    }
    if (b.rng.chance(b.turn_permille)) {
        const d = if (b.rng.below(2) == 0) c.dir.ccw() else c.dir.cw();
        if (w.free_run(c.x, c.y, d, 1) == 1) return d;
    }
    return c.dir;
}

/// T0's dodge: the free side with the longer straight run (a coin on ties).
fn dodge(b: *Brain, w: *const sim.World, i: usize) sim.Dir {
    const c = &w.cycles[i];
    const l = w.free_run(c.x, c.y, c.dir.ccw(), 8);
    const r = w.free_run(c.x, c.y, c.dir.cw(), 8);
    if (l == 0 and r == 0) return c.dir;
    if (l > r) return c.dir.ccw();
    if (r > l) return c.dir.cw();
    return if (b.rng.below(2) == 0) c.dir.ccw() else c.dir.cw();
}

/// T1 AVOID: the move with the most reachable space (on the planning
/// view: closing sudden-death rings count as walls, unless every move is
/// into one).
pub fn avoid(b: *Brain, w: *const sim.World, i: usize) sim.Dir {
    use_world(w);
    return avoid_capped(b, w, i, tuning.fill_cap);
}

fn avoid_capped(b: *Brain, w: *const sim.World, i: usize, cap: u32) sim.Dir {
    const g = view(w);
    if (avoid_on(b, w, i, g, cap)) |d| return d;
    return avoid_on(b, w, i, &w.grid, cap) orelse w.cycles[i].dir;
}

/// T1's answer standing in for a T2/T3 plan (out of units, a plan whose
/// cell was taken, a rubber stall): with a smaller fill once this tick's
/// pool is spent, so a crowded tick stays bounded.
fn stand_in(b: *Brain, w: *const sim.World, i: usize) sim.Dir {
    const cap = if (pool_left > 0) tuning.fill_cap else tuning.stand_in_cap;
    return charged(unbudgeted, .avoid, avoid_capped, .{ b, w, i, cap });
}

fn avoid_on(b: *Brain, w: *const sim.World, i: usize, g: *const Grid, cap: u32) ?sim.Dir {
    const c = &w.cycles[i];
    const cands = [3]sim.Dir{ c.dir, c.dir.ccw(), c.dir.cw() };
    const reach: u32 = if (b.vision != 0) b.vision else 0xFFFF;
    var best: ?sim.Dir = null;
    var best_key: u32 = 0;
    for (cands, 0..) |d, k| {
        const t = w.next_cell(c.x, c.y, d);
        if (wall(g, sim.index(t[0], t[1]))) continue;
        var space = fill(g, sim.index(t[0], t[1]), cap, reach);
        if (race_risk(w, i, t)) space /= tuning.race_penalty;
        const open = free4(g, sim.index(t[0], t[1]));
        // Priority: space, then straight, then open neighbours, then a coin.
        const key = 1 + (space << 8) + (@as(u32, @intFromBool(k == 0)) << 7) + (open << 4) + b.rng.below(16);
        if (key > best_key) {
            best_key = key;
            best = d;
        }
    }
    return best;
}

/// True if another live head is about to step into cell t.
fn race_risk(w: *const sim.World, i: usize, t: [2]u8) bool {
    for (w.cycles, 0..) |o, j| {
        if (j == i or o.state != .alive) continue;
        const n = w.next_cell(o.x, o.y, w.planned_dir(j));
        if (n[0] == t[0] and n[1] == t[1]) return true;
    }
    return false;
}

pub fn open_neighbours(w: *const sim.World, x: u8, y: u8) u32 {
    use_world(w);
    return free4(&w.grid, sim.index(x, y));
}

// ---------------------------------------------------------------- scratch

const Grid = [sim.cells]u8;

/// Neighbour offsets in `Dir` order (up, right, down, left), as wrapping
/// u16 adds. With a rim a non-wall cell is never on it, so its four
/// neighbours are inside the grid.
const off = [4]u16{ 0 -% @as(u16, sim.grid_w), 1, sim.grid_w, 0 -% @as(u16, 1) };

/// The World's topology for this decision: WRAP (no rim, edges wrap).
var wrapping: bool = false;

fn use_world(w: *const sim.World) void {
    wrapping = w.cfg.wrap;
}

/// Neighbour k (`Dir` order) of cell `at`: the plain offset with a rim,
/// round the edges in WRAP (`wr`, comptime so the hot loops specialise).
inline fn nb(comptime wr: bool, at: u16, comptime k: usize) u16 {
    if (!wr) return at +% off[k];
    const W = sim.grid_w;
    return switch (k) {
        0 => if (at < W) at + (sim.cells - W) else at - W,
        1 => if (at % W == W - 1) at + 1 - W else at + 1,
        2 => if (at >= sim.cells - W) at - (sim.cells - W) else at + W,
        3 => if (at % W == 0) at + W - 1 else at - 1,
        else => unreachable,
    };
}

/// `nb` with k known at run time.
inline fn nbk(comptime wr: bool, at: u16, k: usize) u16 {
    if (!wr) return at +% off[k];
    return switch (k) {
        inline 0...3 => |kk| nb(true, at, kk),
        else => unreachable,
    };
}

/// `nb` for the current World, k known at run time (cold paths).
fn nbr(at: u16, k: usize) u16 {
    return if (wrapping) nbk(true, at, k) else nbk(false, at, k);
}

/// Signed offset from a to b along an axis of `size` cells: the short way
/// round in WRAP.
fn delta(a: u8, b: u8, size: u8) i32 {
    var d: i32 = @as(i32, b) - a;
    if (wrapping) {
        const half: i32 = size / 2;
        if (d > half) d -= size else if (d < -half) d += size;
    }
    return d;
}

// Scratch, 33.6 KB: the BFS queue (9.6), the others' distance field
// (stamp, distance, owner: 14.4), the deciding program's own stamps (4.8)
// and the search's copy of the grid (4.8). Stamps are generations, so
// nothing is cleared per search.
var queue: [sim.cells]u16 = undefined;
var o_stamp: [sim.cells]u8 = @splat(0);
var o_dist: [sim.cells]u8 = undefined;
var o_own: [sim.cells]u8 = undefined;
var m_stamp: [sim.cells]u8 = @splat(0);
var work: Grid = undefined;
var o_gen: u8 = 0;
var m_gen: u8 = 0;

/// Own stamps use generations 1..127; `gen | touched` is a cell seen but
/// not claimed (someone else gets there first or as early).
const touched: u8 = 0x80;

fn next_ogen() u8 {
    o_gen +%= 1;
    if (o_gen == 0) {
        @memset(&o_stamp, 0);
        o_gen = 1;
    }
    return o_gen;
}

fn next_mgen() u8 {
    m_gen += 1;
    if (m_gen == touched) {
        @memset(&m_stamp, 0);
        m_gen = 1;
    }
    return m_gen;
}

/// The sudden-death stage that starts closing within `sd_lookahead` ticks
/// (0: none). Stage k closes ring k, or k - 1 in WRAP.
fn danger_ring(w: *const sim.World) u8 {
    if (!w.cfg.sudden_death) return 0;
    const t = w.tick + tuning.sd_lookahead;
    if (t < sim.tuning.sudden_death_ticks) return 0;
    const k = (t - sim.tuning.sudden_death_ticks) / sim.tuning.sudden_death_period + 1;
    return @intCast(@min(k, w.sd_stages()));
}

/// The grid programs plan on: the World's, or while sudden death closes
/// in, a copy in `work` with the closing rings walled.
fn view(w: *const sim.World) *const Grid {
    if (danger_ring(w) == 0) return &w.grid;
    copy_view(w);
    return &work;
}

/// `work` = the planning view (always a copy).
fn copy_view(w: *const sim.World) void {
    @memcpy(&work, &w.grid);
    units_left -= sim.cells / 64;
    const k = danger_ring(w);
    if (k == 0) return;
    // Stages further out are laid already.
    var st: u32 = if (k > 2) k - 2 else 1;
    while (st <= k) : (st += 1) {
        const r = st - 1 + w.sd_first_ring();
        const x1 = sim.grid_w - 1 - r;
        const y1 = sim.grid_h - 1 - r;
        for (r..x1 + 1) |x| {
            put_wall(sim.index(x, r));
            put_wall(sim.index(x, y1));
        }
        for (r..y1 + 1) |y| {
            put_wall(sim.index(r, y));
            put_wall(sim.index(x1, y));
        }
    }
}

/// A planning wall in `work` (never written over a real one).
const plan_wall: u8 = 0x42;

fn put_wall(at: u16) void {
    if (!sim.is_wall(work[at])) work[at] = plan_wall;
}

inline fn wall(g: *const Grid, n: u16) bool {
    return sim.is_wall(g[n]);
}

fn free4(g: *const Grid, at: u16) u32 {
    return if (wrapping) free4_t(true, g, at) else free4_t(false, g, at);
}

fn free4_t(comptime wr: bool, g: *const Grid, at: u16) u32 {
    var n: u32 = 0;
    inline for (0..4) |k| n += @intFromBool(!wall(g, nb(wr, at, k)));
    return n;
}

/// Empty cells reachable from empty cell (x, y), itself included, counted
/// up to `cap`.
pub fn flood(w: *const sim.World, x: u8, y: u8, cap: u32) u32 {
    use_world(w);
    const saved = units_left;
    units_left = unbudgeted;
    defer units_left = saved;
    return fill(&w.grid, sim.index(x, y), cap, 0xFFFF);
}

/// The flood behind `flood` and T1: cells reachable from empty cell
/// `start` within `reach` steps, up to `cap`. Charges its cells.
fn fill(g: *const Grid, start: u16, cap: u32, reach: u32) u32 {
    return if (wrapping) fill_t(true, g, start, cap, reach) else fill_t(false, g, start, cap, reach);
}

fn fill_t(comptime wr: bool, g: *const Grid, start: u16, cap: u32, reach: u32) u32 {
    const gn = next_mgen();
    m_stamp[start] = gn;
    queue[0] = start;
    var head: u32 = 0;
    var tail: u32 = 1;
    var seg: u32 = 1;
    var layer: u32 = 0;
    while (head < tail and tail < cap) : (head += 1) {
        if (head == seg) {
            layer += 1;
            seg = tail;
            if (layer >= reach) break;
        }
        const at = queue[head];
        inline for (0..4) |k| {
            const n = nb(wr, at, k);
            if (m_stamp[n] != gn and !wall(g, n)) {
                m_stamp[n] = gn;
                queue[tail] = n;
                tail += 1;
            }
        }
    }
    units_left -= @intCast(head);
    return @min(tail, cap);
}

// ---------------------------------------------------------------- cut cells

/// 3x3 neighbourhood table (a1k0n): bit m is set when a cell whose eight
/// neighbours have free mask m (bit 0 N, 1 NE, 2 E, 3 SE, 4 S, 5 SW, 6 W,
/// 7 NW) has two or more groups of free side neighbours that the ring of
/// neighbours does not join: walling it may split the space (a potential
/// articulation point). Generated by a script (the test below recomputes
/// it); data, so no comptime work.
const cut_table = [8]u32{ 0x2AFA2020, 0x2AFA2020, 0xFFFFFAFA, 0x2AFAFAFA, 0x2AFA2020, 0x2AFA2020, 0x7FFF7070, 0x00707070 };

const ring8 = [8]u16{
    0 -% @as(u16, sim.grid_w), 0 -% @as(u16, sim.grid_w - 1), 1,                sim.grid_w + 1,
    sim.grid_w,                sim.grid_w - 1,                0 -% @as(u16, 1), 0 -% @as(u16, sim.grid_w + 1),
};
/// The same ring as (dx, dy), for WRAP.
const ring8_xy = [8][2]i8{ .{ 0, -1 }, .{ 1, -1 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ -1, 1 }, .{ -1, 0 }, .{ -1, -1 } };

fn ring_mask(g: *const Grid, at: u16) u8 {
    var m: u8 = 0;
    if (wrapping) {
        const x: i32 = at % sim.grid_w;
        const y: i32 = at / sim.grid_w;
        for (ring8_xy, 0..) |d, k| {
            const nx: u32 = @intCast(@mod(x + d[0], sim.grid_w));
            const ny: u32 = @intCast(@mod(y + d[1], sim.grid_h));
            if (!wall(g, sim.index(nx, ny))) m |= @as(u8, 1) << @intCast(k);
        }
        return m;
    }
    for (ring8, 0..) |o, k| {
        if (!wall(g, at +% o)) m |= @as(u8, 1) << @intCast(k);
    }
    return m;
}

/// True if walling free cell `at` may cut its free neighbours apart.
fn is_cut(g: *const Grid, at: u16) bool {
    const m = ring_mask(g, at);
    return (cut_table[m >> 5] >> @intCast(m & 31)) & 1 != 0;
}

// ---------------------------------------------------------------- Voronoi

/// Owner value of a cell two or more other heads reach at once.
const tie: u8 = 0xFF;

/// The others' distance field: a BFS from every other live head at once,
/// leaving per cell (stamped `field.gen`) the distance in steps
/// (saturating at 255) and who gets there first (`tie` for a draw), and
/// per cycle how many cells it gets first. Charges a unit per cell.
var field: struct {
    gen: u8 = 0,
    cells: [sim.max_cycles]u32 = @splat(0),
    truncated: bool = false,
} = .{};

fn others_field(g: *const Grid, w: *const sim.World, i: usize, reach: u32) Err!void {
    return if (wrapping) others_field_t(true, g, w, i, reach) else others_field_t(false, g, w, i, reach);
}

fn others_field_t(comptime wr: bool, g: *const Grid, w: *const sim.World, i: usize, reach: u32) Err!void {
    const gn = next_ogen();
    field = .{ .gen = gn };
    var tail: u32 = 0;
    for (w.cycles[0..w.cfg.n_cycles], 0..) |o, j| {
        if (j == i or o.state != .alive) continue;
        const at = sim.index(o.x, o.y);
        o_stamp[at] = gn;
        o_dist[at] = 0;
        o_own[at] = @intCast(j);
        queue[tail] = at;
        tail += 1;
    }
    const n0 = tail;
    const lim: u32 = @intCast(@max(units_left, 0));
    var head: u32 = 0;
    var seg = tail;
    var layer: u32 = 0;
    while (head < tail) : (head += 1) {
        if (head == seg) {
            layer += 1;
            seg = tail;
            // Out of reach, or past half the units left: the rest is far.
            if (layer > reach or head > lim / 2) {
                field.truncated = true;
                break;
            }
        }
        const at = queue[head];
        const own = o_own[at];
        const nd: u8 = @intCast(@min(layer + 1, 255));
        inline for (0..4) |k| {
            const n = nb(wr, at, k);
            if (!wall(g, n)) {
                if (o_stamp[n] != gn) {
                    o_stamp[n] = gn;
                    o_dist[n] = nd;
                    o_own[n] = own;
                    queue[tail] = n;
                    tail += 1;
                } else if (o_own[n] != own and o_dist[n] == nd) {
                    o_own[n] = tie;
                }
            }
        }
    }
    // Count after the pass: a cell's owner can still turn into a tie
    // while its own layer is being expanded.
    for (queue[n0..head]) |at| {
        const own = o_own[at];
        if (own != tie) field.cells[own] += 1;
    }
    units_left -= @intCast(head);
}

/// Steps from the others' heads to cell n (0xFFFF: none of them reach it).
inline fn other_dist(n: u16) u32 {
    if (o_stamp[n] != field.gen) return 0xFFFF;
    const d = o_dist[n];
    return if (d == 255) 0xFFFF else d;
}

/// The deciding program's territory from a move: cells it reaches
/// strictly before every other head.
const Mine = struct {
    cells: u32 = 0,
    edges: u32 = 0,
    /// Cells an odd number of steps from the start (checkerboard).
    odd: u32 = 0,
    /// Of those, the prey's cells (in the others' field) it takes, with
    /// their edges, and the prey's cells it draws level on.
    stolen: u32 = 0,
    stolen_edges: u32 = 0,
    tied: u32 = 0,
    /// Next to someone else's cells or a tie.
    contact: bool = false,
    truncated: bool = false,
    /// Innermost sudden-death ring among the cells (when it matters).
    deep: u32 = 0,
};

/// BFS from `start`, `layer0` steps from the head (1 for the move's cell,
/// 2 for a neighbour of it), claiming cells this program reaches first
/// (stamped `gn`); stops at cells the others reach as early. Charges a
/// unit per cell.
fn region(g: *const Grid, start: u16, layer0: u32, prey: u8, reach: u32, cap: u32, gn: u8, m: *Mine) Err!void {
    return if (wrapping) region_t(true, g, start, layer0, prey, reach, cap, gn, m) else region_t(false, g, start, layer0, prey, reach, cap, gn, m);
}

fn region_t(comptime wr: bool, g: *const Grid, start: u16, layer0: u32, prey: u8, reach: u32, cap: u32, gn: u8, m: *Mine) Err!void {
    if (units_left < tuning.min_pass) return error.OutOfBudget;
    m_stamp[start] = gn;
    queue[0] = start;
    const og = field.gen;
    const lim: u32 = @intCast(@max(units_left, 0));
    var head: u32 = 0;
    var tail: u32 = 1;
    var seg: u32 = 1;
    var layer: u32 = layer0;
    var edges: u32 = 0;
    var odd: u32 = 0;
    var stolen: u32 = 0;
    var stolen_edges: u32 = 0;
    while (head < tail) : (head += 1) {
        if (head == seg) {
            layer += 1;
            seg = tail;
            if (layer - layer0 > reach or head >= @min(cap, lim)) {
                m.truncated = true;
                break;
            }
        }
        const at = queue[head];
        const nd = layer + 1;
        var free: u32 = 0;
        inline for (0..4) |k| {
            const n = nb(wr, at, k);
            if (!wall(g, n)) {
                free += 1;
                const s = m_stamp[n] & ~touched;
                if (s != gn) {
                    const od = other_dist(n);
                    if (nd < od) {
                        m_stamp[n] = gn;
                        queue[tail] = n;
                        tail += 1;
                    } else {
                        m_stamp[n] = gn | touched;
                        m.contact = true;
                        if (nd == od and o_own[n] == prey) m.tied += 1;
                    }
                }
            }
        }
        edges += free;
        odd += (layer - layer0) & 1;
        if (o_stamp[at] == og and o_own[at] == prey) {
            stolen += 1;
            stolen_edges += free;
        }
    }
    if (sd.on) {
        m.deep = @max(m.deep, deepest(queue[0..head]));
        units_left -= @intCast(head / 4);
    }
    m.cells += head;
    m.edges += edges;
    m.odd += odd;
    m.stolen += stolen;
    m.stolen_edges += stolen_edges;
    units_left -= @intCast(head);
}

/// Sudden death, per decision (`sd_clock`): whether it is near enough to
/// matter, the tick, the round's base speed and the first ring it closes
/// (1, or 0 in WRAP).
var sd: struct { on: bool = false, now: u32 = 0, speed: u32 = 0, first: u8 = 1 } = .{};

fn sd_clock(w: *const sim.World) void {
    sd = .{
        .on = w.cfg.sudden_death and w.tick + tuning.sd_horizon >= sim.tuning.sudden_death_ticks,
        .now = w.tick,
        .speed = w.base_speed(),
        .first = w.sd_first_ring(),
    };
}

/// The sudden-death stage at which cell `at` closes (0: the rim, never).
fn ring_idx(at: u16) u32 {
    const y = at / sim.grid_w;
    return sim.ring_of(at - y * sim.grid_w, y) + 1 - sd.first;
}

/// The innermost sudden-death stage among `cells`.
fn deepest(cells: []const u16) u32 {
    var d: u32 = 0;
    for (cells) |at| d = @max(d, ring_idx(at));
    return d;
}

/// Cells a cycle at base speed rides through before stage `d` is swept
/// (half-way through its second): how much of a room near the rim is
/// any use.
fn cells_until_close(d: u32) u32 {
    const p = sim.tuning.sudden_death_period;
    const close = sim.tuning.sudden_death_ticks + (d -| 1) * p + p / 2;
    if (close <= sd.now) return 0;
    return @intCast(@as(u64, close - sd.now) * sd.speed / sim.tuning.one);
}

/// Longest path bound by the checkerboard: a path alternates colours,
/// starting with colour A, so it uses at most 2B + 1 cells when A > B,
/// else 2A.
fn parity_bound(a: u32, b: u32) u32 {
    return if (a > b) 2 * b + 1 else 2 * a;
}

fn score_of(cells: u32, edges: u32) i32 {
    return tuning.w_cells * @as(i32, @intCast(cells)) + tuning.w_edges * @as(i32, @intCast(edges));
}

/// From wall cell `at` (a head, or the cell a move enters), the most
/// cells a path can still fill: the best chamber among its free
/// neighbours' regions, each bounded by the checkerboard. Unbounded by
/// vision (once separated a program knows its room). Charges its cells.
fn chamber_space(g: *const Grid, at: u16, cap: u32) Err!u32 {
    return if (wrapping) chamber_space_t(true, g, at, cap) else chamber_space_t(false, g, at, cap);
}

fn chamber_space_t(comptime wr: bool, g: *const Grid, at: u16, cap: u32) Err!u32 {
    const gn = next_mgen();
    m_stamp[at] = gn;
    const lim: u32 = @intCast(@max(units_left, 0));
    var used: u32 = 0;
    var best: u32 = 0;
    inline for (0..4) |k0| {
        const s = nb(wr, at, k0);
        if (!wall(g, s) and m_stamp[s] != gn) {
            m_stamp[s] = gn;
            queue[0] = s;
            var head: u32 = 0;
            var tail: u32 = 1;
            var seg: u32 = 1;
            var layer: u32 = 0;
            var odd: u32 = 0;
            while (head < tail) : (head += 1) {
                if (head == seg) {
                    layer += 1;
                    seg = tail;
                    // A room bigger than `cap` is big enough: count it so far.
                    if (head >= cap) break;
                    if (used + head > lim) {
                        units_left -= @intCast(used + head);
                        return error.OutOfBudget;
                    }
                }
                odd += layer & 1;
                const q = queue[head];
                inline for (0..4) |k| {
                    const n = nb(wr, q, k);
                    if (m_stamp[n] != gn and !wall(g, n)) {
                        m_stamp[n] = gn;
                        queue[tail] = n;
                        tail += 1;
                    }
                }
            }
            used += head;
            var v = parity_bound(head - odd, odd);
            if (sd.on) {
                v = @min(v, cells_until_close(deepest(queue[0..head])));
                used += head / 4;
            }
            best = @max(best, v);
        }
    }
    units_left -= @intCast(used);
    return best;
}

// ---------------------------------------------------------------- T2

/// The cycle a program hunts: its prey if alive, else the nearest live
/// rival (Manhattan, lowest index on ties), or null.
fn pick_prey(b: *const Brain, w: *const sim.World, i: usize) ?usize {
    if (b.prey < sim.max_cycles and b.prey != i and w.cycles[b.prey].state == .alive) return b.prey;
    return nearest(w, i, 0xFF);
}

fn nearest(w: *const sim.World, i: usize, range: u8) ?usize {
    const c = &w.cycles[i];
    var best: ?usize = null;
    var best_d: u32 = 0xFFFF;
    for (w.cycles[0..w.cfg.n_cycles], 0..) |o, j| {
        if (j == i or o.state != .alive) continue;
        const dx = @abs(delta(c.x, o.x, sim.grid_w));
        const dy = @abs(delta(c.y, o.y, sim.grid_h));
        if (dx > range or dy > range) continue;
        if (dx + dy < best_d) {
            best_d = dx + dy;
            best = j;
        }
    }
    return best;
}

/// How far a program's own territory BFS looks (steps from the move).
fn reach_of(b: *const Brain) u32 {
    if (b.vision != 0) return b.vision;
    return if (b.tier == .search) tuning.region_reach_t3 else tuning.region_reach;
}

/// How far the others' field looks: just past the program's own reach
/// (a cell further out is nobody's concern this decision).
fn field_reach(b: *const Brain) u32 {
    return reach_of(b) +| 2;
}

/// T2 TERRITORY: the move with the best Voronoi score.
fn territory(b: *Brain, w: *const sim.World, i: usize) Err!Plan {
    sd_clock(w);
    const g = view(w);
    if (b.alone) {
        if (try endgame(b, w, i, g, false)) |p| return p;
    }
    try others_field(g, w, i, field_reach(b));
    const r = try t2_move(b, w, i, g);
    if (r.alone) {
        note_alone(b, w, i);
        return .{ .dir = r.dir, .hold = endgame_hold(b, w, i, r.space) };
    }
    return .{ .dir = r.dir, .hold = race_hold(b, w, i) };
}

const T2 = struct {
    dir: sim.Dir,
    /// Every move's territory was complete and touched no one: alone, and
    /// `dir` is the endgame's choice (most parity-bounded space, hugging
    /// walls on ties), `space` its room.
    alone: bool = false,
    space: u32 = 0,
};

/// Per move: the program's best chamber of territory, plus the prey's
/// cells it takes (counted again: they are the prey's loss), a bonus for
/// claiming the prey's road, less the cut and race penalties.
fn t2_move(b: *Brain, w: *const sim.World, i: usize, g: *const Grid) Err!T2 {
    const c = &w.cycles[i];
    const prey: u8 = if (pick_prey(b, w, i)) |p| @intCast(p) else sim.no_cycle;
    const reach = reach_of(b);
    // Each move's territory gets the same share of the units (T3 keeps
    // some for its search): past it, a territory counts as truncated.
    const share: i32 = if (b.tier == .search) tuning.t3_t2_share else 8;
    const cap: u32 = @intCast(@max(@divTrunc(units_left * share, 8 * 3), 0));
    const cands = [3]sim.Dir{ c.dir, c.dir.ccw(), c.dir.cw() };
    var best = c.dir;
    var best_s: i32 = std.math.minInt(i32);
    var alone = true;
    var eg: T2 = .{ .dir = c.dir };
    var best_e: i32 = std.math.minInt(i32);
    for (cands) |d| {
        const t2 = w.next_cell(c.x, c.y, d);
        const t = sim.index(t2[0], t2[1]);
        if (wall(g, t)) continue;
        const gn = next_mgen();
        var space: u32 = 0;
        var m: Mine = .{};
        const cut = is_cut(g, t);
        var groups: u32 = 0;
        if (!cut) {
            try region(g, t, 1, prey, reach, cap, gn, &m);
            groups = 1;
            space = parity_bound(m.cells - m.odd, m.odd);
        } else {
            // A cut cell: each side is a chamber; only one can be used.
            m_stamp[t] = gn;
            var best_m: Mine = .{};
            var best_ms: i32 = -1;
            for (0..4) |k| {
                const s = nbr(t, k);
                if (!wall(g, s) and m_stamp[s] & ~touched != gn) {
                    if (2 < other_dist(s)) {
                        var cm: Mine = .{};
                        try region(g, s, 2, prey, reach, cap, gn, &cm);
                        groups += 1;
                        const cs = score_of(cm.cells, cm.edges);
                        if (cs > best_ms) {
                            best_ms = cs;
                            best_m = cm;
                        }
                    } else {
                        m_stamp[s] = gn | touched;
                        best_m.contact = true;
                    }
                }
            }
            m = best_m;
            space = parity_bound(m.cells - m.odd, m.odd) + 1;
            m.cells += 1;
        }
        if (sd.on) {
            // Cells the ring takes before the program gets to them.
            const left = cells_until_close(m.deep);
            if (m.cells > left) {
                m.edges = m.edges * left / m.cells;
                m.cells = left;
            }
            space = @min(space, left);
        }
        if (m.contact or m.truncated) alone = false;
        const e = hug_score(space, free4(g, t));
        if (e > best_e) {
            best_e = e;
            eg = .{ .dir = d, .alone = true, .space = space };
        }
        var s = score_of(m.cells, m.edges);
        s += @divTrunc(score_of(m.stolen, m.stolen_edges) * tuning.prey_share, 8);
        s += @divTrunc(tuning.w_cells * @as(i32, @intCast(m.tied)) * tuning.prey_share, 16);
        if (prey != sim.no_cycle) s += claim_bonus(b, w, prey, gn);
        if (cut and groups > 1) s -= tuning.cut_penalty;
        if (race_risk(w, i, t2)) s -= tuning.race_score;
        if (s > best_s) {
            best_s = s;
            best = d;
        }
    }
    // Every move is a wall in the plan (a closing ring): the least bad.
    if (best_s == std.math.minInt(i32)) return .{ .dir = avoid(b, w, i) };
    if (alone) return eg;
    return .{ .dir = best };
}

/// Endgame move score: room first, then the fewest free neighbours (hug
/// the walls, the classic fill).
fn hug_score(space: u32, free: u32) i32 {
    return @as(i32, @intCast(space)) * tuning.hug_weight - @as(i32, @intCast(free));
}

/// Aggression: cells 2..4 ahead of the prey's head that the move claims.
fn claim_bonus(b: *const Brain, w: *const sim.World, p: usize, gn: u8) i32 {
    if (b.aggression == 0) return 0;
    const o = &w.cycles[p];
    const d = w.planned_dir(p);
    var x = o.x;
    var y = o.y;
    var bonus: i32 = 0;
    const unit = tuning.agg_unit * @as(i32, b.aggression);
    for (1..5) |k| {
        const n = w.next_cell(x, y, d);
        x = n[0];
        y = n[1];
        const at = sim.index(x, y);
        if (wall(&w.grid, at)) break;
        if (k >= 2 and m_stamp[at] == gn) bonus += unit;
    }
    return bonus;
}

/// The endgame's per-move greedy answer, or null when another head turns
/// out to share the room (a faded wall reopened it).
const Greedy = struct { dir: sim.Dir, space: u32 };

/// Alone in its room: the move with the most parity-bounded space in its
/// best chamber, hugging walls on ties.
fn endgame_greedy(w: *const sim.World, i: usize, g: *const Grid) Err!?Greedy {
    const c = &w.cycles[i];
    const cands = [3]sim.Dir{ c.dir, c.dir.ccw(), c.dir.cw() };
    var best: Greedy = .{ .dir = c.dir, .space = 0 };
    var best_s: i32 = std.math.minInt(i32);
    var gens: [3]u8 = @splat(0);
    var any = false;
    for (cands, 0..) |d, k| {
        const t2 = w.next_cell(c.x, c.y, d);
        const t = sim.index(t2[0], t2[1]);
        if (wall(g, t)) continue;
        const space = try chamber_space(g, t, @intCast(@max(@divTrunc(units_left, 4), 0)));
        gens[k] = m_gen;
        any = true;
        const s = hug_score(space, free4(g, t));
        if (s > best_s) {
            best_s = s;
            best = .{ .dir = d, .space = space };
        }
    }
    // Still alone: no other head next to any cell the floods reached.
    for (w.cycles[0..w.cfg.n_cycles], 0..) |o, j| {
        if (j == i or o.state != .alive) continue;
        const h = sim.index(o.x, o.y);
        for (0..4) |k| {
            const n = nbr(h, k);
            const st = m_stamp[n];
            if (!wall(g, n) and st != 0 and (st == gens[0] or st == gens[1] or st == gens[2])) return null;
        }
    }
    if (!any) return null;
    return best;
}

fn others_filled(w: *const sim.World, i: usize) u32 {
    var n: u32 = 0;
    for (w.cycles, 0..) |o, j| {
        if (j != i) n +%= o.log_head;
    }
    return n;
}

/// Just walled off (every move's territory complete and touching no
/// one): remember the biggest rival room for the brake.
fn note_alone(b: *Brain, w: *const sim.World, i: usize) void {
    var rival: u32 = 0;
    for (field.cells) |n| rival = @max(rival, n);
    b.alone = true;
    b.rival_room = @intCast(@min(rival, 0xFFFF));
    b.rival_mark = others_filled(w, i);
}

/// Brake while a rival's room is bigger: slower is longer alive.
fn endgame_hold(b: *const Brain, w: *const sim.World, i: usize, space: u32) Hold {
    const filled = others_filled(w, i) -% b.rival_mark;
    const rival = @as(u32, b.rival_room) -| filled;
    return if (space + 1 < rival) .brake else .none;
}

/// The endgame for T2 (greedy) and T3 (`deep`: the fill search too), or
/// null when no longer alone. Charges its floods.
fn endgame(b: *Brain, w: *const sim.World, i: usize, g: *const Grid, deep: bool) Err!?Plan {
    const e = (try endgame_greedy(w, i, g)) orelse {
        b.alone = false;
        return null;
    };
    var p: Plan = .{ .dir = e.dir, .hold = endgame_hold(b, w, i, e.space) };
    if (deep) p.dir = fill_search(w, i, e.dir);
    return p;
}

/// Boost in a side-by-side race with the prey: same heading, close
/// sideways, not behind, and clear road ahead.
fn race_hold(b: *const Brain, w: *const sim.World, i: usize) Hold {
    if (b.aggression < 4) return .none;
    const p = pick_prey(b, w, i) orelse return .none;
    const c = &w.cycles[i];
    const o = &w.cycles[p];
    if (o.dir != c.dir) return .none;
    const ax: i32 = delta(o.x, c.x, sim.grid_w);
    const ay: i32 = delta(o.y, c.y, sim.grid_h);
    // Along and across the shared heading.
    const along: i32 = ax * c.dir.dx() + ay * c.dir.dy();
    const side: u32 = @abs(ax * c.dir.dy() - ay * c.dir.dx());
    if (side == 0 or side > tuning.race_side or along < -1 or along > 4) return .none;
    if (w.free_run(c.x, c.y, c.dir, tuning.race_road) < tuning.race_road) return .none;
    return .boost;
}

// ---------------------------------------------------------------- T3

/// T3 SEARCH: T2's move with a longer view, checked by alpha-beta against
/// a rival in range on a 32 x 32 bitboard window (a forced win is taken;
/// a move that loses or draws by force is swapped for the search's best);
/// alone, the fill search.
fn search(b: *Brain, w: *const sim.World, i: usize) Err!Plan {
    sd_clock(w);
    const g = view(w);
    if (b.alone) {
        if (try endgame(b, w, i, g, true)) |p| return p;
    }
    try others_field(g, w, i, field_reach(b));
    // T2's move: the answer if the search finds none, and searched first.
    const t2 = try t2_move(b, w, i, g);
    if (t2.alone) {
        note_alone(b, w, i);
        const d = fill_search(w, i, t2.dir);
        return .{ .dir = d, .hold = endgame_hold(b, w, i, t2.space) };
    }
    const t2d = t2.dir;
    const hold = race_hold(b, w, i);
    const r = pick_rival(b, w, i) orelse return .{ .dir = t2d, .hold = hold };
    bb_setup(g, w, i, r);
    bb.reach = if (b.vision != 0) @min(b.vision, tuning.leaf_reach) else tuning.leaf_reach;
    const c = &w.cycles[i];
    var order: [4]sim.Dir = .{ c.dir, c.dir.ccw(), c.dir.cw(), c.dir.opposite() };
    for (order[1..], 1..) |d, k| {
        if (d == t2d) {
            order[k] = order[0];
            order[0] = d;
        }
    }
    // The search is a tactical check on T2's move, which it always
    // searches first (so its score is exact): take a forced win; leave a
    // move that loses or draws by force for the best one that does not.
    // (Its windowed leaves judge the open board worse than T2 does.)
    var res: ?Root = null;
    var done: u8 = 0;
    const cap: u8 = if (b.depth_cap != 0) @min(b.depth_cap, tuning.max_depth) else tuning.max_depth;
    var depth: u8 = 1;
    while (depth <= cap) : (depth += 1) {
        const r2 = ab_root(depth, order) catch break;
        res = r2;
        done = depth;
        if (@abs(r2.score) >= win - 1000) break;
    }
    stats.depth[done] += 1;
    var d = t2d;
    if (res) |rr| {
        if (rr.score >= win / 2 or (rr.first <= draw and rr.score > rr.first)) d = rr.dir;
    }
    return .{ .dir = d, .hold = hold };
}

fn pick_rival(b: *const Brain, w: *const sim.World, i: usize) ?usize {
    const c = &w.cycles[i];
    if (b.prey < sim.max_cycles and b.prey != i) {
        const o = &w.cycles[b.prey];
        if (o.state == .alive and @abs(delta(c.x, o.x, sim.grid_w)) <= tuning.search_range and @abs(delta(c.y, o.y, sim.grid_h)) <= tuning.search_range) return b.prey;
    }
    return nearest(w, i, tuning.search_range);
}

/// The search window: `bb_rows` rows of 32 cells (bit x = column x0 + x),
/// with an empty row above and below so y +- 1 needs no bounds check.
const bb_rows = 32;
const Rows = [bb_rows + 2]u32;

var bb: struct {
    x0: u32 = 0,
    y0: u32 = 0,
    /// Free cells (the moves made so far in the search cleared).
    free: Rows = @splat(0),
    /// Heads: column and padded row.
    mx: u8 = 0,
    my: u8 = 0,
    rx: u8 = 0,
    ry: u8 = 0,
    reach: u32 = 0xFFFF,
    /// Checkerboard: bit x of row y is colour (x0 + x + y0 + y - 1) & 1.
    even_row: u32 = 0,
} = .{};

const checker: u32 = 0x5555_5555;

/// Builds the window centred between the two heads, clamped to the
/// arena (in WRAP it wraps round the edges instead: window column x is
/// arena column (x0 + x) mod 80), from the planning grid, with the other
/// heads' next cells walled (paranoid: they go straight). The window's
/// own edge is a wall to the search.
fn bb_setup(g: *const Grid, w: *const sim.World, i: usize, r: usize) void {
    const c = &w.cycles[i];
    const o = &w.cycles[r];
    const half = bb_rows / 2;
    var x0: u32 = undefined;
    var y0: u32 = undefined;
    if (wrapping) {
        // Centred between the heads the short way round.
        const mx: i32 = @as(i32, c.x) + @divTrunc(delta(c.x, o.x, sim.grid_w), 2);
        const my: i32 = @as(i32, c.y) + @divTrunc(delta(c.y, o.y, sim.grid_h), 2);
        x0 = @intCast(@mod(mx - half, sim.grid_w));
        y0 = @intCast(@mod(my - half, sim.grid_h));
    } else {
        const mx = (@as(u32, c.x) + o.x) / 2;
        const my = (@as(u32, c.y) + o.y) / 2;
        x0 = @min(mx -| half, sim.grid_w - 32);
        y0 = @min(my -| half, sim.grid_h - bb_rows);
    }
    bb.x0 = x0;
    bb.y0 = y0;
    bb.free = @splat(0);
    for (0..bb_rows) |y| {
        var row: u32 = 0;
        if (wrapping) {
            const gy = (y0 + y) % sim.grid_h;
            var gx = x0;
            for (0..32) |x| {
                if (!wall(g, sim.index(gx, gy))) row |= @as(u32, 1) << @intCast(x);
                gx += 1;
                if (gx == sim.grid_w) gx = 0;
            }
        } else {
            const base = sim.index(x0, y0 + y);
            for (0..32) |x| {
                if (!wall(g, @intCast(base + x))) row |= @as(u32, 1) << @intCast(x);
            }
        }
        bb.free[y + 1] = row;
    }
    units_left -= bb_rows;
    for (w.cycles[0..w.cfg.n_cycles], 0..) |oc, j| {
        if (j == i or j == r or oc.state != .alive) continue;
        const n = w.next_cell(oc.x, oc.y, w.planned_dir(j));
        bb_clear_abs(n[0], n[1]);
    }
    bb.mx = @intCast(win_x(c.x));
    bb.my = @intCast(win_y(c.y) + 1);
    bb.rx = @intCast(win_x(o.x));
    bb.ry = @intCast(win_y(o.y) + 1);
    // Row 1 is y0: colour of (x0, y0) decides which bits are colour 0 (the
    // arena's sides are even, so the colours agree across a WRAP edge).
    bb.even_row = if ((x0 + y0) & 1 == 0) checker else ~checker;
}

/// Arena column x as a window column (32 or more: outside the window).
fn win_x(x: u8) u32 {
    return (@as(u32, x) + sim.grid_w - bb.x0) % sim.grid_w;
}
/// Arena row y as an unpadded window row (`bb_rows` or more: outside).
fn win_y(y: u8) u32 {
    return (@as(u32, y) + sim.grid_h - bb.y0) % sim.grid_h;
}

fn bb_clear_abs(x: u8, y: u8) void {
    const wx = win_x(x);
    const wy = win_y(y);
    if (wx >= 32 or wy >= bb_rows) return;
    bb.free[wy + 1] &= ~(@as(u32, 1) << @intCast(wx));
}

inline fn bb_free(x: u8, y: u8) bool {
    if (x >= 32 or y < 1 or y > bb_rows) return false;
    return bb.free[y] >> @intCast(x) & 1 != 0;
}

inline fn bb_set(x: u8, y: u8, on: bool) void {
    const bit = @as(u32, 1) << @intCast(x);
    if (on) bb.free[y] |= bit else bb.free[y] &= ~bit;
}

/// A head's neighbour in direction k (wrapping out of range = not free).
inline fn step_x(x: u8, k: usize) u8 {
    return switch (k) {
        1 => x +% 1,
        3 => x -% 1,
        else => x,
    };
}
inline fn step_y(y: u8, k: usize) u8 {
    return switch (k) {
        0 => y -% 1,
        2 => y +% 1,
        else => y,
    };
}

const win: i32 = 1 << 24;
/// Both into one cell (RACE CONDITION): bad, but not a loss.
const draw: i32 = -(win >> 2);

/// The best root move and its score, and the exact score of the first
/// move searched.
const Root = struct { dir: sim.Dir, score: i32, first: i32 = 0 };

fn ab_root(depth: u8, order: [4]sim.Dir) Err!Root {
    var alpha: i32 = -2 * win;
    var best: ?Root = null;
    var first: ?i32 = null;
    for (order) |d| {
        const k: usize = @backingInt(d);
        const nx = step_x(bb.mx, k);
        const ny = step_y(bb.my, k);
        if (!bb_free(nx, ny)) continue;
        const v = try ab_try_me(nx, ny, depth, 0, alpha, 2 * win);
        if (first == null) first = v;
        if (best == null or v > best.?.score) best = .{ .dir = d, .score = v };
        alpha = @max(alpha, v);
    }
    if (best) |*bb2| bb2.first = first.?;
    // No legal move: anything (T1 has nothing better).
    return best orelse .{ .dir = order[0], .score = -win };
}

fn ab_try_me(nx: u8, ny: u8, depth: u8, ply: i32, alpha: i32, beta: i32) Err!i32 {
    const sx = bb.mx;
    const sy = bb.my;
    bb_set(nx, ny, false);
    bb.mx = nx;
    bb.my = ny;
    defer {
        bb.mx = sx;
        bb.my = sy;
        bb_set(nx, ny, true);
    }
    return ab_riv(depth, ply, alpha, beta, nx, ny);
}

fn riv_stuck() bool {
    for (0..4) |k| {
        if (bb_free(step_x(bb.rx, k), step_y(bb.ry, k))) return false;
    }
    return true;
}

/// The program's move (maximising).
fn ab_me(depth: u8, ply: i32, alpha_in: i32, beta: i32) Err!i32 {
    units_left -= 1;
    if (units_left < 0) return error.OutOfBudget;
    var alpha = alpha_in;
    var best: i32 = -2 * win;
    var any = false;
    for (0..4) |k| {
        const nx = step_x(bb.mx, k);
        const ny = step_y(bb.my, k);
        if (!bb_free(nx, ny)) continue;
        any = true;
        const v = try ab_try_me(nx, ny, depth, ply, alpha, beta);
        best = @max(best, v);
        alpha = @max(alpha, v);
        if (alpha >= beta) break;
    }
    if (!any) {
        // It crashes; if the rival is stuck too, both do.
        return if (riv_stuck()) draw else -win + ply;
    }
    return best;
}

/// The rival's reply (minimising), after the program moved to (mx, my).
fn ab_riv(depth: u8, ply: i32, alpha: i32, beta_in: i32, mx: u8, my: u8) Err!i32 {
    units_left -= 1;
    if (units_left < 0) return error.OutOfBudget;
    var beta = beta_in;
    var best: i32 = 2 * win;
    var any = false;
    for (0..4) |k| {
        const nx = step_x(bb.rx, k);
        const ny = step_y(bb.ry, k);
        var v: i32 = undefined;
        if (nx == mx and ny == my) {
            any = true;
            v = draw;
        } else {
            if (!bb_free(nx, ny)) continue;
            any = true;
            const sx = bb.rx;
            const sy = bb.ry;
            bb_set(nx, ny, false);
            bb.rx = nx;
            bb.ry = ny;
            defer {
                bb.rx = sx;
                bb.ry = sy;
                bb_set(nx, ny, true);
            }
            v = if (depth <= 1) try bb_leaf() else try ab_me(depth - 1, ply + 1, alpha, beta);
        }
        best = @min(best, v);
        beta = @min(beta, v);
        if (beta <= alpha) break;
    }
    if (!any) return win - ply;
    return best;
}

// Leaf scratch: frontiers (two buffers per side), the cells still open,
// and each side's territory.
var lf: struct {
    fm: [2]Rows = undefined,
    fr: [2]Rows = undefined,
    open: Rows = undefined,
    tm: Rows = undefined,
    tr: Rows = undefined,
} = .{};

/// Units per row a leaf processes (a row step of the BFS, or a row of the
/// count); calibrated so a unit costs about what a BFS cell does.
pub const row_units: i32 = 1;

/// Bitboard Voronoi between the two heads inside the window: both
/// frontiers grow a layer at a time; cells both reach in the same layer
/// are nobody's and stop there. Score = cells and edges difference;
/// apart, the difference in parity-bounded space.
fn bb_leaf() Err!i32 {
    lf.open = bb.free;
    lf.tm = @splat(0);
    lf.tr = @splat(0);
    lf.fm[0] = @splat(0);
    lf.fr[0] = @splat(0);
    lf.fm[1] = @splat(0);
    lf.fr[1] = @splat(0);
    lf.fm[0][bb.my] = @as(u32, 1) << @intCast(bb.mx);
    lf.fr[0][bb.ry] = @as(u32, 1) << @intCast(bb.rx);
    var lo: u32 = @max(@min(bb.my, bb.ry), 1);
    var hi: u32 = @min(@max(bb.my, bb.ry), bb_rows);
    var cur: usize = 0;
    var ties = false;
    var rows: i32 = 0;
    var layer: u32 = 0;
    while (layer < bb.reach) : (layer += 1) {
        lo = @max(lo - 1, 1);
        hi = @min(hi + 1, bb_rows);
        const fm = &lf.fm[cur];
        const fr = &lf.fr[cur];
        const gm = &lf.fm[cur ^ 1];
        const gr = &lf.fr[cur ^ 1];
        var any: u32 = 0;
        var y = lo;
        while (y <= hi) : (y += 1) {
            const em = (fm[y] << 1) | (fm[y] >> 1) | fm[y - 1] | fm[y + 1];
            const er = (fr[y] << 1) | (fr[y] >> 1) | fr[y - 1] | fr[y + 1];
            const a = lf.open[y];
            var nm = em & a;
            var nr = er & a;
            const t = nm & nr;
            ties = ties or t != 0;
            nm &= ~t;
            nr &= ~t;
            lf.open[y] = a & ~(nm | nr | t);
            gm[y] = nm;
            gr[y] = nr;
            lf.tm[y] |= nm;
            lf.tr[y] |= nr;
            any |= nm | nr;
        }
        rows += @intCast(hi - lo + 1);
        cur ^= 1;
        if (any == 0) break;
    }
    // Count: cells, edges (free neighbours), colours; and contact.
    var mc: u32 = 0;
    var me: u32 = 0;
    var m0: u32 = 0;
    var rc: u32 = 0;
    var re: u32 = 0;
    var r0: u32 = 0;
    var touch = ties;
    var y = lo;
    const f = &bb.free;
    while (y <= hi) : (y += 1) {
        const col0 = if ((y - 1) & 1 == 0) bb.even_row else ~bb.even_row;
        const tm = lf.tm[y];
        const tr = lf.tr[y];
        const fx = f[y];
        const nb_l = fx << 1;
        const nb_r = fx >> 1;
        if (tm != 0) {
            mc += pc(tm);
            me += pc(tm & nb_l) + pc(tm & nb_r) + pc(tm & f[y - 1]) + pc(tm & f[y + 1]);
            m0 += pc(tm & col0);
            const dil = (tm << 1) | (tm >> 1) | lf.tm[y - 1] | lf.tm[y + 1];
            if (dil & tr != 0) touch = true;
        }
        if (tr != 0) {
            rc += pc(tr);
            re += pc(tr & nb_l) + pc(tr & nb_r) + pc(tr & f[y - 1]) + pc(tr & f[y + 1]);
            r0 += pc(tr & col0);
        }
    }
    rows += 2 * @as(i32, @intCast(hi - lo + 1));
    stats.leaf_rows += @intCast(rows);
    stats.leaves += 1;
    units_left -= rows * row_units;
    if (units_left < 0) return error.OutOfBudget;
    if (!touch and layer < bb.reach) {
        // Apart (in the window): the parity-bounded room each has left.
        // A path from a head starts on the colour opposite the head's.
        const mh = colour_at(bb.mx, bb.my);
        const rh = colour_at(bb.rx, bb.ry);
        const ma = if (mh == 0) mc - m0 else m0;
        const ra = if (rh == 0) rc - r0 else r0;
        const mine = parity_bound(ma, mc - ma);
        const theirs = parity_bound(ra, rc - ra);
        return tuning.sep_weight * (@as(i32, @intCast(mine)) - @as(i32, @intCast(theirs)));
    }
    return score_of(mc, me) - score_of(rc, re);
}

inline fn pc(x: u32) u32 {
    return @popCount(x);
}

/// Colour (0 or 1) of window cell (x, padded y): 0 where `even_row`'s
/// pattern (shifted per row) has the bit.
fn colour_at(x: u8, y: u8) u1 {
    const col0 = if ((y - 1) & 1 == 0) bb.even_row else ~bb.even_row;
    return @intFromBool(col0 >> @intCast(x) & 1 == 0);
}

// ---------------------------------------------------------------- endgame

/// T3 alone: the longest path, by iterative-deepening depth-first search
/// from depth 2 (depth 1 is the greedy answer `first`) with
/// parity-bounded chamber leaves; moves tried hugging walls first, so
/// ties go to the wall. Out of units: the deepest finished answer.
fn fill_search(w: *const sim.World, i: usize, first: sim.Dir) sim.Dir {
    return if (wrapping) fill_search_t(true, w, i, first) else fill_search_t(false, w, i, first);
}

fn fill_search_t(comptime wr: bool, w: *const sim.World, i: usize, first: sim.Dir) sim.Dir {
    const c = &w.cycles[i];
    copy_view(w);
    const at = sim.index(c.x, c.y);
    var order: [4]u8 = undefined;
    const n = hug_order(wr, at, &order);
    var best = first;
    var depth: u8 = 2;
    while (depth <= tuning.max_fill_depth) : (depth += 1) {
        var bv: i32 = -1;
        var bd: ?u8 = null;
        for (order[0..n]) |k| {
            const m = nbk(wr, at, k);
            work[m] = mark_me;
            const v = fill_dfs(wr, m, depth - 1) catch {
                work[m] = sim.empty;
                return best;
            };
            work[m] = sim.empty;
            if (v > bv) {
                bv = v;
                bd = k;
            }
        }
        const k = bd orelse break;
        best = @fromBackingInt(@intCast(k));
        // The leaves were exact: the room fits inside the depth.
        if (bv < depth) break;
    }
    return best;
}

/// The cells a move fills during the endgame search.
const mark_me: u8 = 0x44;

/// Free neighbours of `at`, fewest free neighbours of their own first.
fn hug_order(comptime wr: bool, at: u16, out: *[4]u8) usize {
    var n: usize = 0;
    var key: [4]u32 = undefined;
    inline for (0..4) |k| {
        const m = nb(wr, at, k);
        if (!wall(&work, m)) {
            out[n] = @intCast(k);
            key[n] = free4_t(wr, &work, m);
            n += 1;
        }
    }
    // Insertion sort, stable.
    var a: usize = 1;
    while (a < n) : (a += 1) {
        var j = a;
        while (j > 0 and key[j - 1] > key[j]) : (j -= 1) {
            std.mem.swap(u32, &key[j - 1], &key[j]);
            std.mem.swap(u8, &out[j - 1], &out[j]);
        }
    }
    return n;
}

fn fill_dfs(comptime wr: bool, at: u16, depth: u8) Err!i32 {
    units_left -= 1;
    if (units_left < 0) return error.OutOfBudget;
    if (depth == 0) return 1 + @as(i32, @intCast(try chamber_space_t(wr, &work, at, 0xFFFF_FFFF)));
    var order: [4]u8 = undefined;
    const n = hug_order(wr, at, &order);
    var best: i32 = 1;
    for (order[0..n]) |k| {
        const m = nbk(wr, at, k);
        work[m] = mark_me;
        defer work[m] = sim.empty;
        best = @max(best, 1 + try fill_dfs(wr, m, depth - 1));
    }
    return best;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
var tw: [2]sim.World = undefined;

test "flood counts a closed room exactly and stops at the cap" {
    const w = &tw[0];
    w.init(.{ .n_cycles = 1 }, 1);
    // A 5 x 4 room walled with blocks at x 50..56, y 10..15.
    for (50..57) |x| {
        w.grid[sim.index(x, 10)] = sim.block;
        w.grid[sim.index(x, 15)] = sim.block;
    }
    for (10..16) |y| {
        w.grid[sim.index(50, y)] = sim.block;
        w.grid[sim.index(56, y)] = sim.block;
    }
    try testing.expectEqual(@as(u32, 20), flood(w, 52, 12, 300));
    try testing.expectEqual(@as(u32, 300), flood(w, 20, 40, 300));
    try testing.expectEqual(@as(u32, 7), flood(w, 20, 40, 7));
}

test "T1 turns away from a wall ahead, toward the bigger side" {
    const w = &tw[0];
    w.init(.{ .n_cycles = 1 }, 1);
    const c = &w.cycles[0];
    // A wall right in front; above it a small pocket, below open arena.
    for (1..59) |y| w.grid[sim.index(c.x + 1, y)] = sim.block;
    for (1..c.x + 2) |x| w.grid[sim.index(x, c.y - 3)] = sim.block;
    for (c.y - 3..c.y) |y| w.grid[sim.index(c.x - 1, y)] = sim.block;
    var b = Brain.init(.avoid, 3);
    var t: u32 = 0;
    while (t < 20 and c.dir == .right) : (t += 1) {
        var in: [sim.max_cycles]sim.Input = @splat(.idle);
        in[0] = decide(&b, w, 0);
        w.step(in);
    }
    try testing.expectEqual(sim.Dir.down, c.dir);
    try testing.expectEqual(sim.State.alive, c.state);
}

fn run_round(w: *sim.World, brains: []Brain, cfg: sim.Config, seed: u32) void {
    w.init(cfg, seed);
    for (brains, 0..) |*b, i| b.* = .init(.avoid, rng.mix(seed, @intCast(i)));
    while (w.result == .running) {
        var in: [sim.max_cycles]sim.Input = @splat(.idle);
        for (0..cfg.n_cycles) |i| in[i] = decide(&brains[i], w, i);
        w.step(in);
    }
}

test "T1 vs T1 rounds always end, mostly by a crash" {
    const w = &tw[0];
    var brains: [4]Brain = undefined;
    var crashes: u32 = 0;
    var total_ticks: u32 = 0;
    for (1..21) |seed| {
        const n: u8 = @intCast(2 + seed % 3);
        run_round(w, brains[0..n], .{ .n_cycles = n }, @intCast(seed));
        try testing.expect(w.result != .running);
        try testing.expect(w.tick <= sim.tuning.round_cap_ticks);
        if (!w.timed_out) crashes += 1;
        total_ticks += w.tick;
    }
    // 2026-10-04: 15 of 20 end by a crash, mean 4282 ticks (71 s); M1's
    // sudden death ends the rest.
    try testing.expect(crashes >= 10);
    try testing.expect(total_ticks / 20 > 600);
}

test "same seed and inputs: two Worlds stay byte-identical for 5000 ticks" {
    const a = &tw[0];
    const b = &tw[1];
    const cfg: sim.Config = .{ .n_cycles = 4, .round_cap = 100_000 };
    a.init(cfg, 99);
    b.init(cfg, 99);
    var ba: [4]Brain = undefined;
    var bk: [4]Brain = undefined;
    for (0..4) |i| {
        ba[i] = .init(.avoid, rng.mix(99, @intCast(i)));
        bk[i] = ba[i];
    }
    // Cycle 0 gets random presses (a stand-in for the player); the rest are T1.
    var pr = rng.Xorshift.init(5);
    var rounds: u32 = 0;
    for (0..5000) |_| {
        var fading = false;
        for (a.cycles) |c| fading = fading or c.state == .dying;
        if (a.result != .running and !fading) {
            // Next round from the same seed stream on both sides.
            const s = pr.next();
            a.init(cfg, s);
            b.init(cfg, s);
            rounds += 1;
        }
        var in_a: [sim.max_cycles]sim.Input = @splat(.idle);
        var in_b: [sim.max_cycles]sim.Input = @splat(.idle);
        if (pr.chance(60)) {
            const p: sim.Input = .{ .press = sim.Press.of(@fromBackingInt(@intCast(pr.below(4)))) };
            in_a[0] = p;
            in_b[0] = p;
        }
        for (1..4) |i| {
            in_a[i] = decide(&ba[i], a, i);
            in_b[i] = decide(&bk[i], b, i);
        }
        a.step(in_a);
        b.step(in_b);
        try testing.expect(sim.World.same_state(a, b));
        try testing.expectEqual(a.hash(), b.hash());
    }
    try testing.expect(rounds >= 1);
}

const Score = struct { wins: u32 = 0, losses: u32 = 0, draws: u32 = 0, ticks: u64 = 0 };

/// The ladder's rules (CLAUDE.md, M1 rules) with a layout.
fn ladder_cfg(n: u8, layout: u8) sim.Config {
    return .{ .n_cycles = n, .grinding = true, .rubber = sim.tuning.rubber_max, .energy = true, .sudden_death = true, .layout = layout };
}

/// The opening's drivers: T1 slipping a quarter of the time, the same
/// for both sides of a seed.
fn opening_brains(seed: u32) [2]Brain {
    var o: [2]Brain = undefined;
    for (&o, 0..) |*b, i| {
        b.* = .init(.avoid, rng.mix(seed, @intCast(10 + i)));
        b.mistake_permille = 250;
    }
    return o;
}

/// `rounds` 1v1 rounds of a against b on the ladder's rules: each seed
/// twice with the sides swapped (equal programs score evenly), layouts
/// from `layouts_used` in turn, and a random opening (1 to 3 s of a
/// slipping T1, the same for both sides of a seed) so rounds between
/// deterministic programs differ.
fn duel(ka: Knobs, kb: Knobs, rounds: u32, layouts_used: []const u8, seed0: u32) Score {
    const w = &tw[0];
    var s: Score = .{};
    for (0..rounds) |r| {
        const seed = rng.mix(seed0, @intCast(r / 2));
        const a_slot = r & 1;
        w.init(ladder_cfg(2, layouts_used[(r / 2) % layouts_used.len]), seed);
        var br: [2]Brain = undefined;
        br[a_slot] = .from(ka, rng.mix(seed, 0));
        br[1 - a_slot] = .from(kb, rng.mix(seed, 1));
        reset_pool();
        var dice = rng.Xorshift.init(rng.mix(seed, 7));
        const opening = 60 + dice.below(120);
        var opener = opening_brains(seed);
        while (w.result == .running) {
            var in: [sim.max_cycles]sim.Input = @splat(.idle);
            for (0..2) |i| in[i] = if (w.tick < opening) decide(&opener[i], w, i) else decide(&br[i], w, i);
            w.step(in);
        }
        s.ticks += w.tick;
        if (w.result == .won) {
            if (w.winner == a_slot) s.wins += 1 else s.losses += 1;
        } else s.draws += 1;
    }
    return s;
}

/// Wins with draws as halves, doubled (so it stays an integer).
fn points2(s: Score) u32 {
    return 2 * s.wins + s.draws;
}

fn show(name: []const u8, s: Score) void {
    std.debug.print("  {s}: {d}-{d}-{d} (mean {d} ticks)\n", .{ name, s.wins, s.losses, s.draws, s.ticks / @max(1, s.wins + s.losses + s.draws) });
}

// 40 rounds (20 seeds, both sides) per pairing in the empty arena, with
// rubber, grinding, energy and sudden death on; draws count half. Release
// builds also print the scores and play a few more pairings (`zig test
// -O ReleaseSafe ai.zig --test-filter tournament`). The 2026-10-05
// numbers are in PLAN.md's status (M1 Track A).
test "tournament: T1 > T0, T2 > T1, T3 >= T2, one on one" {
    const full = @import("builtin").mode != .debug;
    const n: u32 = 40;
    const open = [_]u8{0};
    stats = .{};
    const t10 = duel(preset(.avoid, 3), preset(.wander, 3), n, &open, 1);
    const t21 = duel(preset(.territory, 3), preset(.avoid, 3), n, &open, 2);
    const t32 = duel(preset(.search, 3), preset(.territory, 3), n, &open, 3);
    if (full) {
        std.debug.print("\n", .{});
        show("T1 v T0", t10);
        show("T2 v T1", t21);
        show("T3 v T2", t32);
        show("T3 v T1", duel(preset(.search, 3), preset(.avoid, 3), n, &open, 4));
        const mix = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
        show("T3 v T2, layouts 0-8", duel(preset(.search, 3), preset(.territory, 3), n, &mix, 5));
        show("T2 v T1, layouts 0-8", duel(preset(.territory, 3), preset(.avoid, 3), n, &mix, 6));
        std.debug.print("  {any}\n", .{stats});
    }
    try testing.expect(points2(t10) > n);
    try testing.expect(points2(t21) > n);
    try testing.expect(points2(t32) >= n);
}

/// A mixed field of programs: T3, T2, T1 and T0 presets.
fn mixed_brains(seed: u32, out: *[4]Brain) void {
    const ks = [4]Knobs{ preset(.search, 3), preset(.territory, 3), preset(.avoid, 3), preset(.wander, 3) };
    for (out, 0..) |*b, i| b.* = .from(ks[i], rng.mix(seed, @intCast(i)));
}

test "decisions are a function of the World and the Brain (interleaved Worlds agree)" {
    const a = &tw[0];
    const b = &tw[1];
    var ba: [4]Brain = undefined;
    var bb2: [4]Brain = undefined;
    var rounds: u32 = 0;
    var seed: u32 = 11;
    while (rounds < 3) : (rounds += 1) {
        seed = rng.mix(seed, 1);
        a.init(ladder_cfg(4, @intCast(rounds * 3 % 9)), seed);
        b.init(ladder_cfg(4, @intCast(rounds * 3 % 9)), seed);
        mixed_brains(seed, &ba);
        bb2 = ba;
        while (a.result == .running) {
            // Interleaved: each World's calls see a fresh pool all the same.
            var ia: [sim.max_cycles]sim.Input = @splat(.idle);
            var ib: [sim.max_cycles]sim.Input = @splat(.idle);
            for (0..4) |i| {
                ia[i] = decide(&ba[i], a, i);
                ib[i] = decide(&bb2[i], b, i);
            }
            try testing.expectEqual(ia, ib);
            a.step(ia);
            b.step(ib);
            try testing.expect(sim.World.same_state(a, b));
            try testing.expect(std.meta.eql(ba, bb2));
        }
    }
}

test "a replay from a mid-round copy of the World and Brains is exact (M2 keyframes)" {
    const w = &tw[0];
    const k = &tw[1];
    var br: [4]Brain = undefined;
    w.init(ladder_cfg(4, 1), 77);
    mixed_brains(77, &br);
    var kb: [4]Brain = undefined;
    var log: [400]u32 = undefined;
    const key_tick: u32 = 600;
    var t: u32 = 0;
    while (w.result == .running and t < key_tick + log.len) : (t += 1) {
        if (t == key_tick) {
            k.* = w.*;
            kb = br;
        }
        var in: [sim.max_cycles]sim.Input = @splat(.idle);
        for (0..4) |i| in[i] = decide(&br[i], w, i);
        w.step(in);
        if (t >= key_tick) log[t - key_tick] = w.hash();
    }
    try testing.expect(t > key_tick);
    // Something else runs in between (another World's decisions).
    var other: [4]Brain = undefined;
    mixed_brains(5, &other);
    w.init(ladder_cfg(4, 0), 5);
    for (0..50) |_| {
        var in: [sim.max_cycles]sim.Input = @splat(.idle);
        for (0..4) |i| in[i] = decide(&other[i], w, i);
        w.step(in);
    }
    // Restore and replay.
    w.* = k.*;
    br = kb;
    reset_pool();
    var u: u32 = key_tick;
    while (u < t) : (u += 1) {
        var in: [sim.max_cycles]sim.Input = @splat(.idle);
        for (0..4) |i| in[i] = decide(&br[i], w, i);
        w.step(in);
        try testing.expectEqual(log[u - key_tick], w.hash());
    }
}

test "budgets: per decision and per World tick (work units)" {
    const w = &tw[0];
    var br: [4]Brain = undefined;
    stats = .{};
    for (0..4) |r| {
        const seed = rng.mix(31, @intCast(r));
        w.init(ladder_cfg(4, @intCast(r * 2)), seed);
        // Three T3s and a T2: the heaviest field the ladder can bring.
        for (&br, 0..) |*b, i| b.* = .from(preset(if (i == 3) .territory else .search, 3), rng.mix(seed, @intCast(i)));
        reset_pool();
        while (w.result == .running) {
            var in: [sim.max_cycles]sim.Input = @splat(.idle);
            for (0..4) |i| in[i] = decide(&br[i], w, i);
            w.step(in);
        }
    }
    // A pass overruns its units by at most one BFS layer; T1 answers
    // (fallbacks, the press-time re-check) are not budgeted but small.
    try testing.expect(stats.max_units[2] <= tuning.decision_units[2] + tuning.overrun);
    try testing.expect(stats.max_units[3] <= tuning.decision_units[3] + tuning.overrun);
    try testing.expect(stats.max_tick_units <= tuning.tick_pool + tuning.overrun);
    try testing.expect(stats.decisions[3] > 1000);
    // Almost every decision is the tier's own.
    try testing.expect(stats.fallbacks * 50 < stats.decisions[2] + stats.decisions[3]);
}

test "the cut-cell table matches its definition" {
    for (0..256) |mm| {
        const m: u8 = @intCast(mm);
        // Free side neighbours (bits 0, 2, 4, 6) joined through a free corner.
        var parent: [8]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
        const S = struct {
            fn find(p: *[8]u8, a: u8) u8 {
                var x = a;
                while (p[x] != x) x = p[x];
                return x;
            }
        };
        for (0..4) |k| {
            const a: u8 = @intCast(2 * k);
            const b2: u8 = @intCast((2 * k + 2) % 8);
            const corner: u3 = @intCast(2 * k + 1);
            if (m >> @intCast(a) & 1 != 0 and m >> @intCast(b2) & 1 != 0 and m >> corner & 1 != 0) {
                parent[S.find(&parent, a)] = S.find(&parent, b2);
            }
        }
        var roots: u8 = 0;
        var groups: u32 = 0;
        for (0..4) |k| {
            const a: u8 = @intCast(2 * k);
            if (m >> @intCast(a) & 1 == 0) continue;
            const r = S.find(&parent, a);
            if (roots >> @intCast(r) & 1 == 0) {
                roots |= @as(u8, 1) << @intCast(r);
                groups += 1;
            }
        }
        const want = groups > 1;
        const got = (cut_table[m >> 5] >> @intCast(m & 31)) & 1 != 0;
        try testing.expectEqual(want, got);
    }
}

test "rubber: a program stalled at a wall that appears turns out of it" {
    const w = &tw[0];
    var cfg = ladder_cfg(1, 0);
    cfg.sudden_death = false;
    for ([_]Tier{ .avoid, .territory, .search }) |tier| {
        w.init(cfg, 3);
        var b = Brain.from(preset(tier, 3), 9);
        const c = &w.cycles[0];
        // Run until a plan for straight on is pressed, then wall the cell
        // ahead as the boundary comes (another cycle cutting in).
        var t: u32 = 0;
        var walled = false;
        while (t < 200 and c.state == .alive) : (t += 1) {
            var in: [sim.max_cycles]sim.Input = @splat(.idle);
            in[0] = decide(&b, w, 0);
            if (!walled and t > 20 and w.will_step(0) and c.queued == 0 and in[0].press == .none) {
                const n = w.next_cell(c.x, c.y, c.dir);
                w.grid[sim.index(n[0], n[1])] = sim.block;
                walled = true;
            }
            w.step(in);
        }
        try testing.expect(walled);
        try testing.expectEqual(sim.State.alive, c.state);
    }
}

test "T0 crashes on its own; T1 and up do not, alone in the arena" {
    const w = &tw[0];
    var cfg = ladder_cfg(1, 0);
    cfg.sudden_death = false;
    cfg.round_cap = 60 * 60;
    var t0_crashes: u32 = 0;
    for (0..8) |r| {
        for ([_]Tier{ .wander, .avoid, .territory, .search }) |tier| {
            w.init(cfg, @intCast(r + 1));
            var b = Brain.from(preset(tier, if (tier == .wander) 0 else 3), @intCast(r + 5));
            // 20 s, about 320 cells.
            for (0..1200) |_| {
                var in: [sim.max_cycles]sim.Input = @splat(.idle);
                in[0] = decide(&b, w, 0);
                w.step(in);
            }
            if (tier == .wander) {
                if (w.cycles[0].state != .alive) t0_crashes += 1;
            } else {
                try testing.expectEqual(sim.State.alive, w.cycles[0].state);
            }
        }
    }
    try testing.expect(t0_crashes >= 2);
}

// ------------------------------------------------------------- M2 tests

/// The ladder's rules with the M2 modifiers `mods` (bit 0 WRAP, bit 1
/// GAPS, bit 2 SNAKE).
fn mods_cfg(n: u8, layout: u8, mods: u32) sim.Config {
    var cfg = ladder_cfg(n, layout);
    cfg.wrap = mods & 1 != 0;
    cfg.gaps = mods & 2 != 0;
    cfg.snake_len = if (mods & 4 != 0) sim.tuning.snake_len else 0;
    return cfg;
}

test "M2: T1 and up do not crash alone with any modifier mix" {
    const w = &tw[0];
    for (1..8) |mods| {
        for (0..3) |r| {
            for ([_]Tier{ .avoid, .territory, .search }) |tier| {
                var cfg = mods_cfg(1, @intCast(r * 3), @intCast(mods));
                cfg.sudden_death = false;
                cfg.round_cap = 60 * 60;
                w.init(cfg, @intCast(r + 1));
                var b = Brain.from(preset(tier, 3), @intCast(r + 5));
                for (0..1200) |_| {
                    var in: [sim.max_cycles]sim.Input = @splat(.idle);
                    in[0] = decide(&b, w, 0);
                    w.step(in);
                }
                if (w.cycles[0].state != .alive) std.debug.print("mods {d} layout {d} {s}: {s} at {d},{d} tick {d}\n", .{ mods, r * 3, @tagName(tier), w.cycles[0].crash.name(), w.cycles[0].x, w.cycles[0].y, w.cycles[0].died_tick });
                try testing.expectEqual(sim.State.alive, w.cycles[0].state);
            }
        }
    }
}

test "M2: flood and the T3 window wrap round the edges in WRAP" {
    const w = &tw[0];
    w.init(.{ .n_cycles = 1, .wrap = true }, 1);
    // A 4 x 3 room straddling the top-left corner: x 78..1, y 58..0,
    // walled by blocks at x 77 and 2, y 57 and 1.
    const xs = [_]u8{ 77, 78, 79, 0, 1, 2 };
    const ys = [_]u8{ 57, 58, 59, 0, 1 };
    for (xs) |x| {
        w.grid[sim.index(x, 57)] = sim.block;
        w.grid[sim.index(x, 1)] = sim.block;
    }
    for (ys) |y| {
        w.grid[sim.index(77, y)] = sim.block;
        w.grid[sim.index(2, y)] = sim.block;
    }
    try testing.expectEqual(@as(u32, 12), flood(w, 0, 0, 300));
    try testing.expectEqual(@as(u32, 12), flood(w, 78, 58, 300));
    // T3's window between heads on either side of the left edge: both
    // inside it, at their short-way-round distance.
    w.init(.{ .n_cycles = 2, .wrap = true }, 1);
    w.cycles[0].x = 2;
    w.cycles[0].y = 30;
    w.cycles[1].x = 76;
    w.cycles[1].y = 33;
    use_world(w);
    bb_setup(&w.grid, w, 0, 1);
    try testing.expectEqual(@as(i32, 6), @as(i32, bb.mx) - bb.rx);
    try testing.expectEqual(@as(i32, -3), @as(i32, bb.my) - bb.ry);
    try testing.expect(bb.mx < 32 and bb.rx < 32);
    try testing.expectEqual(@as(?usize, 1), nearest(w, 0, tuning.search_range));
    use_world(&tw[1]);
}

test "M2: decisions stay a function of the World and Brain, and a mid-round replay is exact, with modifiers" {
    const a = &tw[0];
    const b = &tw[1];
    var ba: [4]Brain = undefined;
    var bb2: [4]Brain = undefined;
    for (1..8) |mods| {
        const seed = rng.mix(17, @intCast(mods));
        a.init(mods_cfg(4, @intCast(mods % 9), @intCast(mods)), seed);
        b.* = a.*;
        mixed_brains(seed, &ba);
        bb2 = ba;
        reset_pool();
        // Run a while, copy World and Brains (a keyframe), run on logging
        // hashes, then restore the copy and replay.
        var log: [300]u32 = undefined;
        var t: u32 = 0;
        var kb: [4]Brain = undefined;
        const key: u32 = 400;
        while (a.result == .running and t < key + log.len) : (t += 1) {
            if (t == key) {
                b.* = a.*;
                kb = ba;
            }
            var in: [sim.max_cycles]sim.Input = @splat(.idle);
            for (0..4) |i| in[i] = decide(&ba[i], a, i);
            a.step(in);
            if (t >= key) log[t - key] = a.hash();
        }
        if (t <= key) continue;
        reset_pool();
        var u: u32 = key;
        while (u < t) : (u += 1) {
            var in: [sim.max_cycles]sim.Input = @splat(.idle);
            for (0..4) |i| in[i] = decide(&kb[i], b, i);
            b.step(in);
            try testing.expectEqual(log[u - key], b.hash());
        }
        try testing.expect(sim.World.same_state(a, b));
        try testing.expect(std.meta.eql(ba, kb));
    }
}

test "M2: budgets hold in WRAP (work units)" {
    const w = &tw[0];
    var br: [4]Brain = undefined;
    stats = .{};
    for (0..3) |r| {
        const seed = rng.mix(41, @intCast(r));
        w.init(mods_cfg(4, @intCast(r * 3), 1 | @as(u32, @intCast(r)) << 1), seed);
        for (&br, 0..) |*b, i| b.* = .from(preset(if (i == 3) .territory else .search, 3), rng.mix(seed, @intCast(i)));
        reset_pool();
        while (w.result == .running) {
            var in: [sim.max_cycles]sim.Input = @splat(.idle);
            for (0..4) |i| in[i] = decide(&br[i], w, i);
            w.step(in);
        }
    }
    try testing.expect(stats.max_units[2] <= tuning.decision_units[2] + tuning.overrun);
    try testing.expect(stats.max_units[3] <= tuning.decision_units[3] + tuning.overrun);
    try testing.expect(stats.max_tick_units <= tuning.tick_pool + tuning.overrun);
    try testing.expect(stats.fallbacks * 50 < stats.decisions[2] + stats.decisions[3]);
}

// 40 rounds (20 seeds, both sides) of T2 against T1 with WRAP, GAPS and
// SNAKE in turn (every mix but none); draws count half. Release builds
// print the scores and play T3 against T2 too.
test "M2 tournament: T2 > T1 with the modifiers on" {
    const full = @import("builtin").mode != .debug;
    const n: u32 = if (full) 42 else 28;
    const open = [_]u8{0};
    var sum: Score = .{};
    var mods: u32 = 1;
    while (mods < 8) : (mods += 1) {
        const s = duel_mods(preset(.territory, 3), preset(.avoid, 3), n / 7, &open, 20 + mods, mods);
        sum.wins += s.wins;
        sum.losses += s.losses;
        sum.draws += s.draws;
        sum.ticks += s.ticks;
        if (full) {
            var name: [32]u8 = undefined;
            show(std.fmt.bufPrint(&name, "T2 v T1, mods {d}", .{mods}) catch "?", s);
        }
    }
    if (full) {
        show("T2 v T1, all mixes", sum);
        var t32: Score = .{};
        mods = 1;
        while (mods < 8) : (mods += 1) {
            const s = duel_mods(preset(.search, 3), preset(.territory, 3), 6, &open, 40 + mods, mods);
            t32.wins += s.wins;
            t32.losses += s.losses;
            t32.draws += s.draws;
            t32.ticks += s.ticks;
        }
        show("T3 v T2, all mixes", t32);
    }
    try testing.expect(points2(sum) > n);
}

/// `duel` with the modifiers `mods` on.
fn duel_mods(ka: Knobs, kb: Knobs, rounds: u32, layouts_used: []const u8, seed0: u32, mods: u32) Score {
    const w = &tw[0];
    var s: Score = .{};
    for (0..rounds) |r| {
        const seed = rng.mix(seed0, @intCast(r / 2));
        const a_slot = r & 1;
        w.init(mods_cfg(2, layouts_used[(r / 2) % layouts_used.len], mods), seed);
        var br: [2]Brain = undefined;
        br[a_slot] = .from(ka, rng.mix(seed, 0));
        br[1 - a_slot] = .from(kb, rng.mix(seed, 1));
        reset_pool();
        var dice = rng.Xorshift.init(rng.mix(seed, 7));
        const opening = 60 + dice.below(120);
        var opener = opening_brains(seed);
        while (w.result == .running) {
            var in: [sim.max_cycles]sim.Input = @splat(.idle);
            for (0..2) |i| in[i] = if (w.tick < opening) decide(&opener[i], w, i) else decide(&br[i], w, i);
            w.step(in);
        }
        s.ticks += w.tick;
        if (w.result == .won) {
            if (w.winner == a_slot) s.wins += 1 else s.losses += 1;
        } else s.draws += 1;
    }
    return s;
}
