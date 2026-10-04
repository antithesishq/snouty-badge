//! The programs (SPEC.md section 5). `decide(brain, world, i)` returns
//! cycle i's input for the coming tick. It reads the World, never writes
//! it, and never sees the player's input, so a link game gets the same AI
//! on both badges.
//!
//! M0 has T1 AVOID: for each of the three legal moves, a flood fill capped
//! at `tuning.fill_cap` cells; most space wins, ties go straight, then to
//! more open neighbours, then to the brain's own rng. M1 adds T0 WANDER,
//! T2 TERRITORY, T3 SEARCH and the per-frame budget; until then every tier
//! plays T1 (the fallback SPEC 5 names for a blown budget too).
//!
//! Determinism: the only randomness is the brain's own xorshift, advanced
//! only by its decisions, so a replay from the same World and Brain makes
//! the same moves (M2's rewind). The flood fill's scratch (stamps, queue)
//! is module state but never changes a result.
const std = @import("std");
const sim = @import("sim.zig");
const rng = @import("rng.zig");

pub const Tier = enum(u8) {
    /// T0: short lookahead, random turns, sometimes misses a wall (M1).
    wander,
    /// T1: capped flood fill per move.
    avoid,
    /// T2: Voronoi territory, chambers, endgame fill (M1).
    territory,
    /// T3: alpha-beta against the nearest rival (M1).
    search,
};

pub const tuning = struct {
    /// T1's flood fill stops counting here (SPEC 5).
    pub const fill_cap: u32 = 300;
    /// A move into the cell another head is about to enter (a likely RACE
    /// CONDITION) counts its space divided by this.
    pub const race_penalty: u32 = 4;
    /// M1: per-frame AI work cap; the rest defers to the next tick.
    pub const ai_budget_us: u32 = 4000;
};

/// One program's mind. Small and plain, so M2 keyframes copy it whole.
pub const Brain = struct {
    tier: Tier = .avoid,
    rng: rng.Xorshift = .init(1),
    /// Human-feel knobs (SPEC 5), all off in M0: reaction delay in cells
    /// (M1), the chance of a random move into a free cell per decision
    /// instead of the tier's choice (per mille),
    /// vision radius in cells (M1; 0 = the whole arena).
    reaction: u8 = 0,
    mistake_permille: u16 = 0,
    vision: u8 = 0,
    /// The trail position (log_head) of the last decision: one per cell.
    decided: u32 = 0xFFFF_FFFF,

    pub fn init(tier: Tier, seed: u32) Brain {
        return .{ .tier = tier, .rng = .init(seed) };
    }
};

/// Cycle i's input for the coming tick: a heading press on the tick it
/// is about to cross into its next cell, else nothing.
pub fn decide(b: *Brain, w: *const sim.World, i: usize) sim.Input {
    if (!w.will_step(i)) return .idle;
    const c = &w.cycles[i];
    if (b.decided == c.log_head) return .idle;
    b.decided = c.log_head;
    var d = switch (b.tier) {
        // M1 fills in wander, territory and search; T1 stands in.
        .wander, .avoid, .territory, .search => avoid(b, w, i),
    };
    if (b.mistake_permille != 0 and b.rng.chance(b.mistake_permille)) {
        // A slip: any move whose next cell is free, the planned one included.
        const cands = [3]sim.Dir{ c.dir, c.dir.ccw(), c.dir.cw() };
        const k = b.rng.below(3);
        for (0..3) |j| {
            const m = cands[(k + j) % 3];
            const t = w.next_cell(c.x, c.y, m);
            if (!sim.is_wall(w.at(t[0], t[1]))) {
                d = m;
                break;
            }
        }
    }
    if (d == w.planned_dir(i)) return .idle;
    return .{ .press = sim.Press.of(d) };
}

/// T1 AVOID: the move with the most reachable space.
pub fn avoid(b: *Brain, w: *const sim.World, i: usize) sim.Dir {
    const c = &w.cycles[i];
    const cands = [3]sim.Dir{ c.dir, c.dir.ccw(), c.dir.cw() };
    var best = c.dir;
    var best_key: u32 = 0;
    for (cands, 0..) |d, k| {
        const t = w.next_cell(c.x, c.y, d);
        if (sim.is_wall(w.at(t[0], t[1]))) continue;
        var space = flood(w, t[0], t[1], tuning.fill_cap);
        if (race_risk(w, i, t)) space /= tuning.race_penalty;
        const open = open_neighbours(w, t[0], t[1]);
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
    var n: u32 = 0;
    for ([_]sim.Dir{ .up, .right, .down, .left }) |d| {
        const c = w.next_cell(x, y, d);
        if (!sim.is_wall(w.at(c[0], c[1]))) n += 1;
    }
    return n;
}

// Flood-fill scratch: a generation stamp per cell (nothing is cleared per
// fill) and the BFS queue.
var stamp: [sim.cells]u16 = @splat(0);
var gen: u16 = 0;
var queue: [sim.cells]u16 = undefined;

fn next_gen() u16 {
    gen +%= 1;
    if (gen == 0) {
        @memset(&stamp, 0);
        gen = 1;
    }
    return gen;
}

/// Empty cells reachable from empty cell (x, y), itself included, counted
/// up to `cap`.
pub fn flood(w: *const sim.World, x: u8, y: u8, cap: u32) u32 {
    const g = next_gen();
    const start = sim.index(x, y);
    stamp[start] = g;
    queue[0] = start;
    var head: u32 = 0;
    var tail: u32 = 1;
    while (head < tail and tail < cap) : (head += 1) {
        const at = queue[head];
        // Cells next to an empty interior cell are inside the grid (the
        // rim or a wall stops the fill first), so plain offsets are safe.
        const ns = [4]u16{ at - sim.grid_w, at + 1, at + sim.grid_w, at - 1 };
        for (ns) |n| {
            if (stamp[n] == g or sim.is_wall(w.grid[n])) continue;
            stamp[n] = g;
            queue[tail] = n;
            tail += 1;
        }
    }
    return @min(tail, cap);
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
    var bb: [4]Brain = undefined;
    for (0..4) |i| {
        ba[i] = .init(.avoid, rng.mix(99, @intCast(i)));
        bb[i] = ba[i];
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
            in_b[i] = decide(&bb[i], b, i);
        }
        a.step(in_a);
        b.step(in_b);
        try testing.expect(sim.World.same_state(a, b));
        try testing.expectEqual(a.hash(), b.hash());
    }
    try testing.expect(rounds >= 1);
}
