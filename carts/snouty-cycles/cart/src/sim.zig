//! The light-cycle simulation (SPEC.md sections 3 and 4): the 80 x 60 cell
//! grid, up to four cycles, movement, turns, collisions, derez and fade,
//! the round clock and result. Pure and integer only: no cart API, no
//! floats, no allocation, so the host tests drive it directly and two
//! Worlds given the same seed and inputs stay byte-identical (the basis of
//! M2's rewind and M3's lockstep link).
//!
//! The renderer and the AI read a World and never write it. `step` is the
//! only thing that advances it; it leaves a list of events (cells painted
//! and cleared, crashes, turns) for the renderer.
//!
//! M0 has movement, turns, the safe U-turn, the turn tax, collisions, crash
//! kinds and kill credit, derez with the fade, trail logs and the round
//! clock. M1 adds grinding, rubber, the energy bar, sudden death and the
//! block layouts (`layouts.zig`), each behind its `Config` flag (all off by
//! default, so a bare `Config` plays M0's rules).
const std = @import("std");
const layouts = @import("layouts.zig");

pub const grid_w = 80;
pub const grid_h = 60;
pub const cells = grid_w * grid_h;
pub const max_cycles = 4;

/// Cell values (SPEC 3). 1..4 is a trail of cycle 0..3 (value = index + 1).
pub const empty: u8 = 0;
pub const rim: u8 = 0x40;
pub const block: u8 = 0x41;
/// Reserved for effects the renderer reads; the rules mask it off.
pub const fx_bit: u8 = 0x80;
/// Index of no cycle (no killer, no winner).
pub const no_cycle: u8 = 0xFF;

/// Every rule constant in one place. Speeds and progress are in 1/65536
/// cell (SPEC 4 writes them in 1/256 cell; the extra 8 bits let the slow
/// 1/512 decay and the 0.95 turn tax work in integers). Ticks are 1/60 s.
pub const tuning = struct {
    /// Progress units per cell.
    pub const one: u32 = 1 << 16;
    /// 68/256 cell per tick = 16 cells/s at 60 ticks/s.
    pub const base_speed: u32 = 68 << 8;
    /// Speed cap, in tenths of base (2.2x: well under a cell per tick).
    pub const max_speed_tenths: u32 = 22;
    /// Turn tax: speed * 19/20 per applied turn, only while above base.
    pub const turn_tax_num: u32 = 19;
    pub const turn_tax_den: u32 = 20;
    /// Decay toward the target speed: 1/128 of the excess per tick from
    /// above (a grind or boost lingers: 1.65x is still 1.4x a second later
    /// and 1.25x after two), 1/8 of the shortfall from below. Braking
    /// (energy, B) eases down at the fast rate too.
    pub const decay_above_shift: u5 = 7;
    pub const decay_below_shift: u5 = 3;
    /// Turn queue depth (a fast double tap still lands).
    pub const queue_len = 2;
    /// U-turn: free cells counted to each side to pick the side.
    pub const uturn_lookahead = 3;
    /// Derez: a dead cycle's trail stays `wall_stay` ticks, then fades
    /// from tail to head, `fade_rate` cells per tick.
    pub const wall_stay: u32 = 45;
    pub const fade_rate: u32 = 6;
    /// M0 rounds end in a draw after 90 s (M1's sudden death ends them).
    pub const round_cap_ticks: u32 = 90 * 60;

    // M1: grinding (SPEC 4). Acceleration per tick, in 1/1024 of base
    // speed, with a trail cell (any cycle's, never rim or block) beside
    // the cycle at lateral distance 1 or 2. With the 1/128 decay, hugging
    // a trail at distance 1 gives 1.3x after 0.5 s, 1.5x after 1 s, 1.8x
    // after 2 s (the 2.2x cap after ~3.5 s); distance 2 gives 1.2x after 1 s.
    pub const grind1: u32 = 11;
    pub const grind2: u32 = 4;
    pub const grind_unit: u32 = 1024;
    // M1: the energy bar. A boosts toward 3/2 base, B brakes toward 1/2.
    pub const energy_max: u16 = 1000;
    pub const boost_drain: u16 = 10;
    pub const brake_drain: u16 = 6;
    pub const energy_recharge: u16 = 2;
    pub const boost_num: u32 = 3;
    pub const boost_den: u32 = 2;
    pub const brake_num: u32 = 1;
    pub const brake_den: u32 = 2;
    // M1: rubber. A blocked step stalls at p = one - 1 and drains one per
    // tick; 0 left is a crash. Recharges one per `rubber_recharge` ticks.
    pub const rubber_max: u8 = 12;
    pub const rubber_recharge: u8 = 8;
    // M1: sudden death. From 30 s a ring of block cells closes in every
    // second: ring k (1 = next to the rim) is laid by two sweeps over the
    // `sudden_death_period` ticks starting at
    // `sudden_death_ticks + (k - 1) * sudden_death_period`. Ring 29 is the
    // last (the 22 x 2 middle), so every round ends by tick 3540.
    pub const sudden_death_ticks: u32 = 30 * 60;
    pub const sudden_death_period: u32 = 60;
    pub const sudden_death_rings: u8 = @min(grid_w, grid_h) / 2 - 1;
    // M1 layouts: the start cell and this many cells ahead stay free.
    pub const start_clear: u8 = 5;
};

/// Trail log ring per cycle (cell indices). A round's live trail is far
/// shorter (90 s at 2.2x base is 3200 cells), so the ring never wraps in
/// play; if it ever did, the oldest cells would simply stay walls.
pub const log_cap = 4096;
const log_mask = log_cap - 1;

/// Events per step; more set `events_lost` and the renderer repaints all.
pub const max_events = 48;

pub const Dir = enum(u2) {
    up,
    right,
    down,
    left,

    pub fn dx(d: Dir) i8 {
        return switch (d) {
            .left => -1,
            .right => 1,
            else => 0,
        };
    }
    pub fn dy(d: Dir) i8 {
        return switch (d) {
            .up => -1,
            .down => 1,
            else => 0,
        };
    }
    pub fn opposite(d: Dir) Dir {
        return @fromBackingInt(@intCast(@backingInt(d) +% 2));
    }
    /// Clockwise (a right turn on screen).
    pub fn cw(d: Dir) Dir {
        return @fromBackingInt(@intCast(@backingInt(d) +% 1));
    }
    /// Counter-clockwise (a left turn).
    pub fn ccw(d: Dir) Dir {
        return @fromBackingInt(@intCast(@backingInt(d) -% 1));
    }
};

/// A heading press: the d-pad direction newly pressed this tick, if any.
pub const Press = enum(u3) {
    none,
    up,
    right,
    down,
    left,

    pub fn dir(p: Press) ?Dir {
        return switch (p) {
            .none => null,
            .up => .up,
            .right => .right,
            .down => .down,
            .left => .left,
        };
    }
    pub fn of(d: Dir) Press {
        return @fromBackingInt(@intCast(@as(u3, @backingInt(d)) + 1));
    }
};

/// One cycle's input for one tick, one byte (M2 logs it per tick, M3 sends
/// it over the link). `boost` and `brake` are A and B held (M1).
pub const Input = packed struct(u8) {
    press: Press = .none,
    boost: bool = false,
    brake: bool = false,
    _pad: u3 = 0,

    pub const idle: Input = .{};
};

pub const State = enum(u8) {
    /// Slot not in this round.
    off,
    alive,
    /// Crashed; the trail stays, then fades. `dead` once it is gone.
    dying,
    dead,
};

pub const Crash = enum(u8) {
    none,
    /// Into its own trail.
    segfault,
    /// Into another cycle's trail (credits that cycle).
    derezzed,
    /// Into the rim.
    out_of_bounds,
    /// Into a block (layouts, sudden death).
    access_violation,
    /// Two cycles into the same empty cell on the same tick.
    race_condition,
    /// Head-on: two heads swapping cells, or nose to nose.
    deadlock,

    /// The banner text (SPEC 4).
    pub fn name(c: Crash) []const u8 {
        return switch (c) {
            .none => "",
            .segfault => "SEGFAULT",
            .derezzed => "DEREZZED",
            .out_of_bounds => "OUT OF BOUNDS",
            .access_violation => "ACCESS VIOLATION",
            .race_condition => "RACE CONDITION",
            .deadlock => "DEADLOCK",
        };
    }
};

/// A queued turn. `uturn` is the opposite heading pressed: resolved when
/// applied (side with more room, then the reverse). `guarded` marks the
/// reverse half of a U-turn, which is skipped if its cell is blocked.
pub const Turn = packed struct(u8) {
    dir: Dir = .up,
    uturn: bool = false,
    guarded: bool = false,
    _pad: u4 = 0,
};

pub const Cycle = struct {
    /// Head cell.
    x: u8 = 0,
    y: u8 = 0,
    dir: Dir = .right,
    state: State = .off,
    /// Progress through the head cell toward the next, in 1/65536 cell.
    p: u32 = 0,
    /// Progress per tick.
    speed: u32 = 0,
    queue: [tuning.queue_len]Turn = @splat(.{}),
    queued: u8 = 0,
    /// A and B held this tick (M1 energy reads them).
    boost: bool = false,
    brake: bool = false,
    /// M1: rubber left (ticks of stall; the meter's size is
    /// `World.cfg.rubber`), its recharge counter, the energy bar
    /// (0..`tuning.energy_max`), stalled this tick (against a wall at
    /// p = one - 1), grinding this tick (0 none, 1 at distance 2, 2 at
    /// distance 1: sparks). `grind` is the head cell's, updated every tick.
    rubber: u8 = 0,
    rubber_tick: u8 = 0,
    energy: u16 = 0,
    stalled: bool = false,
    grind: u8 = 0,
    /// Set when it crashes.
    crash: Crash = .none,
    /// Whose trail it hit (no_cycle: own trail, rim, block, head-on).
    killer: u8 = no_cycle,
    died_tick: u32 = 0,
    /// Cycles this one derezzed (credited kills).
    kills: u8 = 0,
    turns: u32 = 0,
    /// Trail log ring positions, monotonic: entries tail..head-1 are the
    /// live trail, oldest first (`World.log_at`).
    log_head: u32 = 0,
    log_tail: u32 = 0,

    pub fn live(c: *const Cycle) bool {
        return c.state == .alive;
    }
    pub fn trail_len(c: *const Cycle) u32 {
        return c.log_head - c.log_tail;
    }
};

/// Per-round options. M0 uses `n_cycles`, `speed_pct` and `round_cap`;
/// the rest are the modifiers M1 and M2 implement (SPEC 6), here so their
/// tracks add behaviour without changing the type.
pub const Config = struct {
    n_cycles: u8 = 2,
    /// Base speed in percent (ladder loops, RUST's 1.1x, OPTIONS SPEED).
    speed_pct: u16 = 100,
    round_cap: u32 = tuning.round_cap_ticks,
    /// M1. `grinding`: trails beside a cycle speed it up. `rubber`: the
    /// stall meter in ticks (0 = no rubber; 12 is the default
    /// `tuning.rubber_max`, HARDCORE 4). `energy`: A boosts, B brakes.
    /// `sudden_death`: rings close in from 30 s (and `round_cap` is
    /// ignored). `layout`: index into `layouts.all` (0 = open arena).
    grinding: bool = false,
    rubber: u8 = 0,
    energy: bool = false,
    sudden_death: bool = false,
    layout: u8 = 0,
    /// M2 modifiers.
    wrap: bool = false,
    snake_len: u16 = 0,
    gaps: bool = false,
};

pub const Result = enum(u8) { running, won, draw };

pub const EventKind = enum(u8) {
    /// A cycle entered cell (x, y); `cycle` is its index.
    painted,
    /// A faded trail cell became empty.
    cleared,
    /// `cycle` crashed at its head (x, y): a = Crash, b = killer.
    crash,
    /// `cycle` turned at its head (x, y): a = new Dir.
    turn,
    /// M1: cell (x, y) became a block. Sudden death: a = the ring index
    /// (1..29). Layout blocks are drawn by `init`, which emits nothing
    /// (a round start repaints everything).
    block,
    /// M1: `cycle` is grinding a trail at distance 1: (x, y) is the trail
    /// cell beside its head, a = the side (`Dir` from the head to it).
    /// One per grinding side per tick (sparks).
    grind,
    /// M1: `cycle` is stalled on rubber at its head (x, y) against a wall:
    /// a = its `Dir`, b = rubber left. One per stalled tick (flicker).
    stall,
};

pub const Event = struct {
    kind: EventKind,
    cycle: u8 = no_cycle,
    x: u8,
    y: u8,
    a: u8 = 0,
    b: u8 = 0,
};

/// Start cells, headings toward the centre, symmetric under a half turn.
/// Pairs are one row or column apart so no two start on a head-on line.
const starts = [max_cycles]struct { x: u8, y: u8, dir: Dir }{
    .{ .x = 12, .y = 30, .dir = .right },
    .{ .x = 67, .y = 29, .dir = .left },
    .{ .x = 39, .y = 8, .dir = .down },
    .{ .x = 40, .y = 51, .dir = .up },
};

pub inline fn index(x: usize, y: usize) u16 {
    return @intCast(y * grid_w + x);
}

/// True for any wall: trail, rim, block (the fx bit is ignored).
pub inline fn is_wall(v: u8) bool {
    return v & ~fx_bit != empty;
}

/// The cycle index of a trail value, or null for empty, rim and block.
pub inline fn trail_owner(v: u8) ?u8 {
    const t = v & ~fx_bit;
    return if (t >= 1 and t <= max_cycles) t - 1 else null;
}

/// The sudden-death ring of interior cell (x, y): its distance to the
/// rim (1 = next to the rim, up to `tuning.sudden_death_rings`); 0 on the rim.
pub fn ring_of(x: u32, y: u32) u8 {
    return @intCast(@min(@min(x, y), @min(grid_w - 1 - x, grid_h - 1 - y)));
}

/// Half the cell count of ring k (its rectangle is (k, k) to
/// (79 - k, 59 - k); the count is 2 (w + h) - 4, always even).
fn ring_half(k: u8) u32 {
    return (grid_w - 2 * @as(u32, k)) + (grid_h - 2 * @as(u32, k)) - 2;
}

/// Cell `s` of ring k, clockwise from its top-left corner: top row left to
/// right, right column down, bottom row right to left, left column up.
/// Cell `s + half` is cell `s` turned a half turn about the centre.
fn ring_cell(k: u8, s: u32) [2]u8 {
    const kk: u32 = k;
    const rw = grid_w - 2 * kk;
    const rh = grid_h - 2 * kk;
    const x1 = grid_w - 1 - kk;
    const y1 = grid_h - 1 - kk;
    if (s < rw) return .{ @intCast(kk + s), @intCast(kk) };
    var r = s - rw;
    if (r < rh - 2) return .{ @intCast(x1), @intCast(kk + 1 + r) };
    r -= rh - 2;
    if (r < rw) return .{ @intCast(x1 - r), @intCast(y1) };
    r -= rw;
    return .{ @intCast(kk), @intCast(y1 - 1 - r) };
}

/// The whole simulation state. About 38 KB: keep it in a static, never on
/// the stack (the cart has 32 KB of stack), and initialise it in place
/// with `init`.
pub const World = struct {
    cfg: Config,
    seed: u32,
    tick: u32,
    result: Result,
    winner: u8,
    /// The round hit `cfg.round_cap` (a draw).
    timed_out: bool,
    grid: [cells]u8,
    cycles: [max_cycles]Cycle,
    logs: [max_cycles][log_cap]u16,
    events: [max_events]Event,
    n_events: u8,
    events_lost: bool,
    /// M1 sudden death: the ring being laid or last laid (1..29), 0 before
    /// it starts. Goes 0 -> 1 on tick `tuning.sudden_death_ticks`.
    sudden_death_ring: u8,

    pub fn init(w: *World, cfg: Config, seed: u32) void {
        std.debug.assert(cfg.n_cycles >= 1 and cfg.n_cycles <= max_cycles);
        w.cfg = cfg;
        w.seed = seed;
        w.tick = 0;
        w.result = .running;
        w.winner = no_cycle;
        w.timed_out = false;
        w.n_events = 0;
        w.events_lost = false;
        w.sudden_death_ring = 0;
        @memset(&w.grid, empty);
        for (0..grid_w) |x| {
            w.grid[index(x, 0)] = rim;
            w.grid[index(x, grid_h - 1)] = rim;
        }
        for (0..grid_h) |y| {
            w.grid[index(0, y)] = rim;
            w.grid[index(grid_w - 1, y)] = rim;
        }
        w.draw_layout(cfg.layout);
        for (&w.cycles, 0..) |*c, i| {
            c.* = .{};
            if (i >= cfg.n_cycles) continue;
            const s = starts[i];
            c.x = s.x;
            c.y = s.y;
            c.dir = s.dir;
            c.state = .alive;
            c.speed = w.base_speed();
            c.rubber = cfg.rubber;
            c.energy = tuning.energy_max;
            w.grid[index(s.x, s.y)] = @intCast(i + 1);
            w.logs[i][0] = index(s.x, s.y);
            c.log_head = 1;
        }
    }

    /// Draws `layouts.get(i)` as block cells, each rect mirrored across
    /// both centre lines, then clears every start cell and the
    /// `tuning.start_clear` cells ahead of it (all four starts, used or not).
    fn draw_layout(w: *World, i: u8) void {
        for (layouts.get(i).rects) |r| {
            for (r.y..@as(usize, r.y) + r.h) |y| {
                for (r.x..@as(usize, r.x) + r.w) |x| {
                    if (x < 1 or x > grid_w - 2 or y < 1 or y > grid_h - 2) continue;
                    w.grid[index(x, y)] = block;
                    w.grid[index(grid_w - 1 - x, y)] = block;
                    w.grid[index(x, grid_h - 1 - y)] = block;
                    w.grid[index(grid_w - 1 - x, grid_h - 1 - y)] = block;
                }
            }
        }
        for (starts) |st| {
            var x = st.x;
            var y = st.y;
            for (0..tuning.start_clear + 1) |_| {
                w.grid[index(x, y)] = empty;
                const n = w.next_cell(x, y, st.dir);
                x = n[0];
                y = n[1];
            }
        }
    }

    pub fn base_speed(w: *const World) u32 {
        return tuning.base_speed * w.cfg.speed_pct / 100;
    }

    /// Ticks until alive cycle i crosses into its next cell at its current
    /// speed: 1 when `will_step` is true. Exact for 1 (speed only changes
    /// after a step's moves); further out, grinding, energy and turns
    /// change the speed, so it is an estimate.
    pub fn ticks_to_step(w: *const World, i: usize) u32 {
        const c = &w.cycles[i];
        if (c.speed == 0) return std.math.maxInt(u32);
        return (tuning.one - c.p + c.speed - 1) / c.speed;
    }

    /// Cycle i's speed as a percentage of this round's base speed (100 =
    /// base, 150 = a full boost, 220 = the cap).
    pub fn speed_fraction(w: *const World, i: usize) u32 {
        return w.cycles[i].speed * 100 / w.base_speed();
    }

    /// True if (x, y) is a sudden-death block (the renderer draws those
    /// red): a block cell in a ring that has started closing.
    pub fn is_sudden_death_block(w: *const World, x: u32, y: u32) bool {
        if (w.sudden_death_ring == 0 or w.at(x, y) & ~fx_bit != block) return false;
        const r = ring_of(x, y);
        return r >= 1 and r <= w.sudden_death_ring;
    }

    pub inline fn at(w: *const World, x: u32, y: u32) u8 {
        return w.grid[index(x, y)];
    }

    /// The cell one step from (x, y) heading `d`. Cycles never stand on the
    /// rim, so this stays inside the grid. (M2 WRAP opens the rim and
    /// wraps here.)
    pub fn next_cell(w: *const World, x: u8, y: u8, d: Dir) [2]u8 {
        _ = w;
        return .{
            @intCast(@as(i16, x) + d.dx()),
            @intCast(@as(i16, y) + d.dy()),
        };
    }

    /// Empty cells in a straight line from (x, y) heading `d`, up to `n`.
    pub fn free_run(w: *const World, x: u8, y: u8, d: Dir, n: u32) u32 {
        var cx = x;
        var cy = y;
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            const c = w.next_cell(cx, cy, d);
            if (is_wall(w.at(c[0], c[1]))) break;
            cx = c[0];
            cy = c[1];
        }
        return k;
    }

    /// The k-th newest cell of cycle i's live trail (0 = the head), or null.
    pub fn log_at(w: *const World, i: usize, k: u32) ?u16 {
        const c = &w.cycles[i];
        if (k >= c.trail_len()) return null;
        return w.logs[i][(c.log_head - 1 - k) & log_mask];
    }

    /// The k-th oldest cell of cycle i's live trail (0 = the tail).
    pub fn log_from_tail(w: *const World, i: usize, k: u32) u16 {
        return w.logs[i][(w.cycles[i].log_tail + k) & log_mask];
    }

    /// The heading cycle i will have once its queued turns apply.
    pub fn planned_dir(w: *const World, i: usize) Dir {
        const c = &w.cycles[i];
        if (c.queued == 0) return c.dir;
        const t = c.queue[c.queued - 1];
        return t.dir;
    }

    /// True if cycle i crosses into its next cell on the coming step (the
    /// AI decides on this tick: SPEC 5). Exact: a step moves at the speed
    /// set at the end of the previous step. True on every tick of a rubber
    /// stall (the cycle keeps trying the edge).
    pub fn will_step(w: *const World, i: usize) bool {
        const c = &w.cycles[i];
        return c.state == .alive and w.result == .running and c.p + c.speed >= tuning.one;
    }

    /// Bit i set while cycle i is alive.
    pub fn alive_mask(w: *const World) u8 {
        var m: u8 = 0;
        for (w.cycles, 0..) |c, i| {
            if (c.state == .alive) m |= @as(u8, 1) << @intCast(i);
        }
        return m;
    }

    pub fn alive_count(w: *const World) u32 {
        return @popCount(w.alive_mask());
    }

    /// Sets cycle i's heading before the first step (the countdown: SPEC 4,
    /// "inputs during the countdown set your first heading").
    pub fn set_heading(w: *World, i: usize, d: Dir) void {
        if (w.tick != 0) return;
        w.cycles[i].dir = d;
    }

    /// Advances one tick. `inputs[i]` is cycle i's input (ignored for
    /// cycles not alive). Clears and refills `events`.
    pub fn step(w: *World, inputs: [max_cycles]Input) void {
        w.n_events = 0;
        w.events_lost = false;
        w.tick += 1;
        if (w.result == .running) {
            const n = w.cfg.n_cycles;
            for (0..n) |i| {
                if (w.cycles[i].state != .alive) continue;
                w.take_input(i, inputs[i]);
            }
            var target: [max_cycles]?[2]u8 = @splat(null);
            for (0..n) |i| {
                const c = &w.cycles[i];
                if (c.state != .alive) continue;
                const was_stalled = c.stalled;
                c.stalled = false;
                c.p += c.speed;
                if (c.p < tuning.one) continue;
                c.p -= tuning.one;
                w.apply_turn(i, was_stalled);
                const t = w.next_cell(c.x, c.y, c.dir);
                if (w.cfg.rubber != 0 and c.rubber != 0 and is_wall(w.at(t[0], t[1]))) {
                    // Rubber: a blocked step stalls at the cell edge and
                    // drains the meter; empty, the step goes ahead and
                    // crashes in `resolve`.
                    c.p = tuning.one - 1;
                    c.stalled = true;
                    c.rubber -= 1;
                    c.rubber_tick = 0;
                    w.emit(.{ .kind = .stall, .cycle = @intCast(i), .x = c.x, .y = c.y, .a = @backingInt(c.dir), .b = c.rubber });
                    continue;
                }
                target[i] = t;
            }
            w.resolve(target);
            if (w.cfg.sudden_death) w.sudden_death();
            // Speed for the coming tick, from this tick's cell and input
            // (so `will_step` before a step is exact).
            for (0..n) |i| {
                if (w.cycles[i].state != .alive) continue;
                w.update_grind(i);
                w.update_speed(i);
                w.update_rubber(i);
            }
            w.update_result();
        }
        for (0..w.cfg.n_cycles) |i| {
            if (w.cycles[i].state == .dying) w.fade(i);
        }
    }

    fn emit(w: *World, e: Event) void {
        if (w.n_events == max_events) {
            w.events_lost = true;
            return;
        }
        w.events[w.n_events] = e;
        w.n_events += 1;
    }

    /// Queues a heading press (SPEC 4): the planned heading again does
    /// nothing, its opposite queues a U-turn, a full queue drops it.
    fn take_input(w: *World, i: usize, in: Input) void {
        const c = &w.cycles[i];
        c.boost = in.boost;
        c.brake = in.brake;
        const d = in.press.dir() orelse return;
        const planned = w.planned_dir(i);
        if (d == planned) return;
        if (c.queued == tuning.queue_len) return;
        if (d == planned.opposite()) {
            // A U-turn takes two cells; it needs both queue slots' worth of
            // turns, so it is only accepted with an empty queue.
            if (c.queued != 0) return;
            c.queue[0] = .{ .dir = d, .uturn = true };
            c.queued = 1;
            return;
        }
        c.queue[c.queued] = .{ .dir = d };
        c.queued += 1;
    }

    fn pop_turn(c: *Cycle) Turn {
        const t = c.queue[0];
        var k: usize = 1;
        while (k < c.queued) : (k += 1) c.queue[k - 1] = c.queue[k];
        c.queued -= 1;
        return t;
    }

    /// At a cell boundary: applies the head of the turn queue (one turn per
    /// cell, so the minimum gap between turns is one cell). `stalled`: the
    /// cycle stalled on rubber last tick and is still at the same edge; a
    /// turn then applies at once if its cell is free and is dropped if not
    /// (the stall goes on, another press can try again).
    fn apply_turn(w: *World, i: usize, stalled: bool) void {
        const c = &w.cycles[i];
        if (c.queued == 0) return;
        const t = pop_turn(c);
        var d = t.dir;
        if (t.uturn) {
            // Turn toward the side with more free cells (ties right), and
            // queue the reverse for the next cell.
            const right = w.free_run(c.x, c.y, c.dir.cw(), tuning.uturn_lookahead);
            const left = w.free_run(c.x, c.y, c.dir.ccw(), tuning.uturn_lookahead);
            d = if (left > right) c.dir.ccw() else c.dir.cw();
            if (stalled and w.blocked(c.x, c.y, d)) return;
            // The queue had only the U-turn in it, so there is room.
            c.queue[c.queued] = .{ .dir = t.dir, .guarded = true };
            c.queued += 1;
        } else if (t.guarded) {
            // The reverse half of a U-turn never steers into a wall when
            // carrying on sideways is free.
            const n = w.next_cell(c.x, c.y, d);
            const s = w.next_cell(c.x, c.y, c.dir);
            if (is_wall(w.at(n[0], n[1])) and !is_wall(w.at(s[0], s[1]))) d = c.dir;
        }
        if (d == c.dir or d == c.dir.opposite()) return;
        if (stalled and w.blocked(c.x, c.y, d)) return;
        c.dir = d;
        c.turns += 1;
        const base = w.base_speed();
        if (c.speed > base) c.speed = @max(base, c.speed * tuning.turn_tax_num / tuning.turn_tax_den);
        w.emit(.{ .kind = .turn, .cycle = @intCast(i), .x = c.x, .y = c.y, .a = @backingInt(d) });
    }

    fn blocked(w: *const World, x: u8, y: u8, d: Dir) bool {
        const n = w.next_cell(x, y, d);
        return is_wall(w.at(n[0], n[1]));
    }

    /// The speed for the coming tick. The target is base speed, or with
    /// `cfg.energy` and a non-empty bar 3/2 base while A is held (boost) or
    /// 1/2 base while B is held (brake; B wins if both). Grinding adds its
    /// acceleration, then the speed eases toward the target: slowly from
    /// above (a boost lingers), quickly from below and while braking.
    /// Capped at 2.2x base.
    fn update_speed(w: *World, i: usize) void {
        const c = &w.cycles[i];
        const base = w.base_speed();
        var target = base;
        var fast = false;
        if (w.cfg.energy) {
            if ((c.boost or c.brake) and c.energy != 0) {
                if (c.brake) {
                    target = base * tuning.brake_num / tuning.brake_den;
                    fast = true;
                    c.energy -= @min(c.energy, tuning.brake_drain);
                } else {
                    target = base * tuning.boost_num / tuning.boost_den;
                    c.energy -= @min(c.energy, tuning.boost_drain);
                }
            } else if (!c.boost and !c.brake) {
                c.energy = @min(tuning.energy_max, c.energy + tuning.energy_recharge);
            }
        }
        if (w.cfg.grinding and c.grind != 0) {
            const g = if (c.grind == 2) tuning.grind1 else tuning.grind2;
            c.speed += base * g / tuning.grind_unit;
        }
        if (c.speed > target) {
            const shift = if (fast) tuning.decay_below_shift else tuning.decay_above_shift;
            c.speed -= @min(c.speed - target, ((c.speed - target) >> shift) + 1);
        } else if (c.speed < target) {
            c.speed += @min(target - c.speed, ((target - c.speed) >> tuning.decay_below_shift) + 1);
        }
        c.speed = @min(c.speed, base * tuning.max_speed_tenths / 10);
    }

    /// Grinding (SPEC 4): per side, a trail cell at lateral distance 1 is
    /// level 2 (and a `grind` event), else a trail cell at distance 2
    /// behind an empty distance-1 cell is level 1. Rim and blocks give
    /// nothing and shield what is behind them.
    fn update_grind(w: *World, i: usize) void {
        const c = &w.cycles[i];
        c.grind = 0;
        if (!w.cfg.grinding) return;
        for ([2]Dir{ c.dir.ccw(), c.dir.cw() }) |side| {
            const n1 = w.next_cell(c.x, c.y, side);
            const v1 = w.at(n1[0], n1[1]) & ~fx_bit;
            if (trail_owner(v1) != null) {
                c.grind = 2;
                w.emit(.{ .kind = .grind, .cycle = @intCast(i), .x = n1[0], .y = n1[1], .a = @backingInt(side) });
                continue;
            }
            // Rim and blocks shield; an empty cell is inside the rim, so
            // the cell beyond it is in the grid.
            if (v1 != empty) continue;
            const n2 = w.next_cell(n1[0], n1[1], side);
            if (trail_owner(w.at(n2[0], n2[1])) != null) c.grind = @max(c.grind, 1);
        }
    }

    /// Rubber recharges one per `tuning.rubber_recharge` ticks while not
    /// stalled, up to `cfg.rubber`.
    fn update_rubber(w: *World, i: usize) void {
        const c = &w.cycles[i];
        if (w.cfg.rubber == 0 or c.stalled) return;
        if (c.rubber >= w.cfg.rubber) {
            c.rubber_tick = 0;
            return;
        }
        c.rubber_tick += 1;
        if (c.rubber_tick >= tuning.rubber_recharge) {
            c.rubber_tick = 0;
            c.rubber += 1;
        }
    }

    /// Sudden death (SPEC 4): ring k is laid over `sudden_death_period`
    /// ticks by two sweeps, clockwise from opposite corners (symmetric
    /// under a half turn, like the starts). An empty cell becomes a block
    /// (a `block` event, a = k); trail and blocks stay. A cycle whose head
    /// is on a swept cell derezzes (ACCESS VIOLATION). At most 6 cells a tick.
    fn sudden_death(w: *World) void {
        if (w.tick < tuning.sudden_death_ticks) return;
        const e = w.tick - tuning.sudden_death_ticks;
        const k = e / tuning.sudden_death_period + 1;
        if (k > tuning.sudden_death_rings) return;
        const ring: u8 = @intCast(k);
        w.sudden_death_ring = ring;
        const o = e % tuning.sudden_death_period;
        const half = ring_half(ring);
        const s0 = o * half / tuning.sudden_death_period;
        const s1 = (o + 1) * half / tuning.sudden_death_period;
        for (s0..s1) |s| {
            for ([2]u32{ @intCast(s), @intCast(s + half) }) |pos| {
                const cell = ring_cell(ring, pos);
                const idx = index(cell[0], cell[1]);
                if (w.grid[idx] & ~fx_bit == empty) {
                    w.grid[idx] = block;
                    w.emit(.{ .kind = .block, .x = cell[0], .y = cell[1], .a = ring });
                }
                for (0..w.cfg.n_cycles) |j| {
                    const c = &w.cycles[j];
                    if (c.state == .alive and c.x == cell[0] and c.y == cell[1]) w.kill(j, .access_violation, no_cycle);
                }
            }
        }
    }

    /// Collisions after every cycle has moved (SPEC 4), in index order.
    fn resolve(w: *World, target: [max_cycles]?[2]u8) void {
        const n = w.cfg.n_cycles;
        var crash: [max_cycles]Crash = @splat(.none);
        var killer: [max_cycles]u8 = @splat(no_cycle);
        for (0..n) |i| {
            const t = target[i] orelse continue;
            const v = w.at(t[0], t[1]) & ~fx_bit;
            if (v == empty) continue;
            if (trail_owner(v)) |o| {
                if (o == i) {
                    crash[i] = .segfault;
                } else {
                    crash[i] = .derezzed;
                    killer[i] = o;
                }
            } else {
                crash[i] = if (v == rim) .out_of_bounds else .access_violation;
            }
        }
        for (0..n) |i| {
            const ti = target[i] orelse continue;
            for (i + 1..n) |j| {
                const tj = target[j] orelse continue;
                // Both into one empty cell: RACE CONDITION.
                if (ti[0] == tj[0] and ti[1] == tj[1] and !is_wall(w.at(ti[0], ti[1]))) {
                    crash[i] = .race_condition;
                    crash[j] = .race_condition;
                    killer[i] = no_cycle;
                    killer[j] = no_cycle;
                }
                // Heads swapping cells: DEADLOCK.
                const ci = &w.cycles[i];
                const cj = &w.cycles[j];
                if (ti[0] == cj.x and ti[1] == cj.y and tj[0] == ci.x and tj[1] == ci.y) {
                    crash[i] = .deadlock;
                    crash[j] = .deadlock;
                    killer[i] = no_cycle;
                    killer[j] = no_cycle;
                }
            }
        }
        // Nose to nose: a cycle steps into the head of a cycle facing it
        // that did not move this tick. Both derez, no credit.
        for (0..n) |i| {
            const t = target[i] orelse continue;
            if (crash[i] != .derezzed) continue;
            const j = killer[i];
            const cj = &w.cycles[j];
            if (cj.state == .alive and target[j] == null and cj.x == t[0] and cj.y == t[1] and cj.dir == w.cycles[i].dir.opposite()) {
                crash[i] = .deadlock;
                killer[i] = no_cycle;
                crash[j] = .deadlock;
                killer[j] = no_cycle;
            }
        }
        for (0..n) |i| {
            const c = &w.cycles[i];
            if (crash[i] != .none) {
                if (c.state == .alive) w.kill(i, crash[i], killer[i]);
                continue;
            }
            const t = target[i] orelse continue;
            c.x = t[0];
            c.y = t[1];
            const at_idx = index(t[0], t[1]);
            w.grid[at_idx] = @intCast(i + 1);
            w.logs[i][c.log_head & log_mask] = at_idx;
            c.log_head += 1;
            if (c.log_head - c.log_tail > log_cap) c.log_tail = c.log_head - log_cap;
            w.emit(.{ .kind = .painted, .cycle = @intCast(i), .x = t[0], .y = t[1] });
        }
    }

    fn kill(w: *World, i: usize, kind: Crash, by: u8) void {
        const c = &w.cycles[i];
        c.state = .dying;
        c.crash = kind;
        c.killer = by;
        c.died_tick = w.tick;
        c.queued = 0;
        if (by != no_cycle) w.cycles[by].kills += 1;
        w.emit(.{ .kind = .crash, .cycle = @intCast(i), .x = c.x, .y = c.y, .a = @backingInt(kind), .b = by });
    }

    /// After `wall_stay` ticks a dead cycle's trail empties from the tail,
    /// `fade_rate` cells per tick (space opens mid-round).
    fn fade(w: *World, i: usize) void {
        const c = &w.cycles[i];
        if (w.tick - c.died_tick < tuning.wall_stay) return;
        var k: u32 = 0;
        while (k < tuning.fade_rate and c.log_tail != c.log_head) : (k += 1) {
            const idx = w.logs[i][c.log_tail & log_mask];
            c.log_tail += 1;
            if (trail_owner(w.grid[idx]) == @as(u8, @intCast(i))) {
                w.grid[idx] = empty;
                w.emit(.{ .kind = .cleared, .x = @intCast(idx % grid_w), .y = @intCast(idx / grid_w) });
            }
        }
        if (c.log_tail == c.log_head) c.state = .dead;
    }

    fn update_result(w: *World) void {
        const alive = w.alive_count();
        const n = w.cfg.n_cycles;
        if (n >= 2 and alive == 1) {
            w.result = .won;
            w.winner = @ctz(w.alive_mask());
        } else if (alive == 0) {
            w.result = .draw;
        } else if (!w.cfg.sudden_death and w.tick >= w.cfg.round_cap) {
            w.result = .draw;
            w.timed_out = true;
        }
    }

    /// FNV-1a over everything the rules read: grid, cycles, the live trail
    /// logs, the clock and result (M3's link CRC, the determinism tests).
    pub fn hash(w: *const World) u32 {
        var h: u32 = 0x811c9dc5;
        const H = struct {
            fn bytes(hp: *u32, b: []const u8) void {
                for (b) |x| {
                    hp.* ^= x;
                    hp.* *%= 0x01000193;
                }
            }
            fn int(hp: *u32, v: u32) void {
                bytes(hp, std.mem.asBytes(&v));
            }
        };
        H.bytes(&h, &w.grid);
        H.int(&h, w.tick);
        H.int(&h, @backingInt(w.result));
        H.int(&h, w.winner);
        H.int(&h, w.sudden_death_ring);
        for (w.cycles, 0..) |c, i| {
            H.int(&h, c.x);
            H.int(&h, c.y);
            H.int(&h, @backingInt(c.dir));
            H.int(&h, @backingInt(c.state));
            H.int(&h, c.p);
            H.int(&h, c.speed);
            H.int(&h, c.queued);
            for (c.queue[0..c.queued]) |t| H.int(&h, @as(u8, @bitCast(t)));
            H.int(&h, c.rubber);
            H.int(&h, c.rubber_tick);
            H.int(&h, c.energy);
            H.int(&h, @intFromBool(c.stalled));
            H.int(&h, c.grind);
            H.int(&h, @backingInt(c.crash));
            H.int(&h, c.killer);
            H.int(&h, c.log_head);
            H.int(&h, c.log_tail);
            var k = c.log_tail;
            while (k != c.log_head) : (k += 1) H.int(&h, w.logs[i][k & log_mask]);
        }
        return h;
    }

    /// Same rule state (what `hash` covers), compared exactly.
    pub fn same_state(a: *const World, b: *const World) bool {
        if (!std.mem.eql(u8, &a.grid, &b.grid)) return false;
        if (a.tick != b.tick or a.result != b.result or a.winner != b.winner) return false;
        if (a.sudden_death_ring != b.sudden_death_ring) return false;
        for (a.cycles, b.cycles, 0..) |ca, cb, i| {
            if (!std.meta.eql(ca, cb)) return false;
            var k = ca.log_tail;
            while (k != ca.log_head) : (k += 1) {
                if (a.logs[i][k & log_mask] != b.logs[i][k & log_mask]) return false;
            }
        }
        return true;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Worlds are big: tests keep them in statics.
var tw: [2]World = undefined;

fn press(d: Dir) Input {
    return .{ .press = Press.of(d) };
}

fn idle_inputs() [max_cycles]Input {
    return @splat(Input.idle);
}

/// Steps until cycle i enters a new cell (or `limit` ticks pass).
fn step_to_next_cell(w: *World, inputs: [max_cycles]Input, i: usize, limit: u32) void {
    const start = w.cycles[i].log_head;
    var first = true;
    var t: u32 = 0;
    while (t < limit and w.cycles[i].log_head == start and w.cycles[i].state == .alive) : (t += 1) {
        w.step(if (first) inputs else idle_inputs());
        first = false;
    }
}

test "start: rim, start cells, headings toward the centre" {
    const w = &tw[0];
    w.init(.{ .n_cycles = 4 }, 1);
    try testing.expectEqual(rim, w.at(0, 0));
    try testing.expectEqual(rim, w.at(79, 30));
    try testing.expectEqual(rim, w.at(40, 59));
    try testing.expectEqual(empty, w.at(1, 1));
    for (0..4) |i| {
        const c = w.cycles[i];
        try testing.expectEqual(@as(u8, @intCast(i + 1)), w.at(c.x, c.y));
        try testing.expectEqual(@as(u32, 1), c.trail_len());
        // Heading toward the centre.
        const dx = @as(i32, 40) - c.x;
        const dy = @as(i32, 30) - c.y;
        try testing.expect(dx * c.dir.dx() + dy * c.dir.dy() > 0);
    }
}

test "movement: base speed is 16 cells per second, trail behind" {
    const w = &tw[0];
    w.init(.{ .n_cycles = 1 }, 1);
    const x0 = w.cycles[0].x;
    for (0..60) |_| w.step(idle_inputs());
    // 60 ticks * 68/256 = 15.9 cells.
    try testing.expectEqual(@as(u8, x0 + 15), w.cycles[0].x);
    try testing.expectEqual(@as(u32, 16), w.cycles[0].trail_len());
    for (x0..x0 + 16) |x| try testing.expectEqual(@as(u8, 1), w.at(@intCast(x), w.cycles[0].y));
    try testing.expectEqual(Result.running, w.result);
}

test "turn queue: turns apply at cell boundaries, one per cell, two deep" {
    const w = &tw[0];
    w.init(.{ .n_cycles = 1 }, 1);
    const y0 = w.cycles[0].y;
    // Press down then left on consecutive ticks: down at the next cell,
    // left one cell later.
    var in = idle_inputs();
    in[0] = press(.down);
    w.step(in);
    in[0] = press(.left);
    w.step(in);
    try testing.expectEqual(@as(u8, 2), w.cycles[0].queued);
    step_to_next_cell(w, idle_inputs(), 0, 10);
    try testing.expectEqual(Dir.down, w.cycles[0].dir);
    try testing.expectEqual(y0 + 1, w.cycles[0].y);
    step_to_next_cell(w, idle_inputs(), 0, 10);
    try testing.expectEqual(Dir.left, w.cycles[0].dir);
    try testing.expectEqual(@as(u8, 0), w.cycles[0].queued);
    // Pressing the current heading queues nothing; a full queue drops
    // presses (p = 0: no cell boundary within these three ticks).
    w.cycles[0].p = 0;
    in[0] = press(.left);
    w.step(in);
    try testing.expectEqual(@as(u8, 0), w.cycles[0].queued);
    in[0] = press(.up);
    w.step(in);
    in[0] = press(.right);
    w.step(in);
    try testing.expectEqual(@as(u8, 2), w.cycles[0].queued);
    try testing.expectEqual(Dir.right, w.planned_dir(0));
}

test "U-turn: turns toward the free side, then reverses, never into a wall" {
    const w = &tw[0];
    // Free on both sides: ties go right (clockwise). Heading right, cw = down.
    w.init(.{ .n_cycles = 1 }, 1);
    const y0 = w.cycles[0].y;
    var in = idle_inputs();
    in[0] = press(.left);
    step_to_next_cell(w, in, 0, 10);
    try testing.expectEqual(Dir.down, w.cycles[0].dir);
    step_to_next_cell(w, idle_inputs(), 0, 10);
    try testing.expectEqual(Dir.left, w.cycles[0].dir);
    try testing.expectEqual(y0 + 1, w.cycles[0].y);
    try testing.expectEqual(State.alive, w.cycles[0].state);

    // Blocked below: it goes up instead.
    w.init(.{ .n_cycles = 1 }, 1);
    const c = &w.cycles[0];
    w.grid[index(c.x, c.y + 1)] = block;
    w.grid[index(c.x + 1, c.y + 1)] = block;
    step_to_next_cell(w, in, 0, 10);
    try testing.expectEqual(Dir.up, c.dir);
    step_to_next_cell(w, idle_inputs(), 0, 10);
    try testing.expectEqual(Dir.left, c.dir);
    try testing.expectEqual(State.alive, c.state);

    // Against the wall: along the top rim heading right, a U-turn must go
    // down, and survives.
    w.init(.{ .n_cycles = 1 }, 1);
    c.y = 1;
    w.grid[index(c.x, 1)] = 1;
    step_to_next_cell(w, in, 0, 10);
    try testing.expectEqual(Dir.down, c.dir);
    step_to_next_cell(w, idle_inputs(), 0, 10);
    step_to_next_cell(w, idle_inputs(), 0, 10);
    try testing.expectEqual(State.alive, c.state);
    try testing.expectEqual(Dir.left, c.dir);
}

test "U-turn never crashes when one side is free, from any spot" {
    const w = &tw[0];
    var rng = @import("rng.zig").Xorshift.init(7);
    var tries: u32 = 0;
    while (tries < 300) : (tries += 1) {
        w.init(.{ .n_cycles = 1 }, 1);
        const c = &w.cycles[0];
        // A random interior position and heading, random clutter.
        w.grid[index(c.x, c.y)] = empty;
        c.x = @intCast(2 + rng.below(76));
        c.y = @intCast(2 + rng.below(56));
        c.dir = @fromBackingInt(@intCast(rng.below(4)));
        w.grid[index(c.x, c.y)] = 1;
        w.logs[0][0] = index(c.x, c.y);
        for (0..200) |_| {
            const x = 1 + rng.below(78);
            const y = 1 + rng.below(58);
            if (x != c.x or y != c.y) w.grid[index(x, y)] = block;
        }
        const side_free = w.free_run(c.x, c.y, c.dir.cw(), 1) + w.free_run(c.x, c.y, c.dir.ccw(), 1) > 0;
        if (!side_free) continue;
        var in = idle_inputs();
        in[0] = press(c.dir.opposite());
        step_to_next_cell(w, in, 0, 10);
        try testing.expectEqual(State.alive, c.state);
    }
}

test "crash kinds: own trail, rim, another trail with credit" {
    const w = &tw[0];
    // Rim: straight on until the far wall.
    w.init(.{ .n_cycles = 1 }, 1);
    for (0..400) |_| w.step(idle_inputs());
    try testing.expectEqual(Crash.out_of_bounds, w.cycles[0].crash);
    try testing.expectEqual(Result.draw, w.result);

    // Own trail: five cells on, then a tight box (down, left, up) runs
    // into itself.
    w.init(.{ .n_cycles = 2 }, 1);
    for (0..20) |_| w.step(idle_inputs());
    var in = idle_inputs();
    for ([_]Dir{ .down, .left, .up }) |d| {
        in[0] = press(d);
        step_to_next_cell(w, in, 0, 10);
    }
    for (0..20) |_| w.step(idle_inputs());
    try testing.expectEqual(Crash.segfault, w.cycles[0].crash);
    try testing.expectEqual(Result.won, w.result);
    try testing.expectEqual(@as(u8, 1), w.winner);

    // Another trail: cycle 1's wall across cycle 0's path.
    w.init(.{ .n_cycles = 2 }, 1);
    for (1..59) |y| w.grid[index(30, y)] = 2;
    for (0..200) |_| w.step(idle_inputs());
    try testing.expectEqual(Crash.derezzed, w.cycles[0].crash);
    try testing.expectEqual(@as(u8, 1), w.cycles[0].killer);
    try testing.expectEqual(@as(u8, 1), w.cycles[1].kills);
}

test "RACE CONDITION: two cycles into one empty cell on the same tick" {
    const w = &tw[0];
    w.init(.{ .n_cycles = 2 }, 1);
    const a = &w.cycles[0];
    const b = &w.cycles[1];
    // Put them two cells apart on one row, facing each other, in step.
    w.grid[index(a.x, a.y)] = empty;
    w.grid[index(b.x, b.y)] = empty;
    a.* = .{ .x = 30, .y = 20, .dir = .right, .state = .alive, .speed = w.base_speed(), .log_head = 1 };
    b.* = .{ .x = 32, .y = 20, .dir = .left, .state = .alive, .speed = w.base_speed(), .log_head = 1 };
    w.grid[index(30, 20)] = 1;
    w.grid[index(32, 20)] = 2;
    w.logs[0][0] = index(30, 20);
    w.logs[1][0] = index(32, 20);
    for (0..10) |_| w.step(idle_inputs());
    try testing.expectEqual(Crash.race_condition, a.crash);
    try testing.expectEqual(Crash.race_condition, b.crash);
    try testing.expectEqual(no_cycle, a.killer);
    try testing.expectEqual(@as(u8, 0), b.kills);
    try testing.expectEqual(Result.draw, w.result);
    try testing.expectEqual(empty, w.at(31, 20));
}

test "DEADLOCK: adjacent heads facing each other" {
    const w = &tw[0];
    w.init(.{ .n_cycles = 2 }, 1);
    const a = &w.cycles[0];
    const b = &w.cycles[1];
    w.grid[index(a.x, a.y)] = empty;
    w.grid[index(b.x, b.y)] = empty;
    // In step: they swap cells on the same tick.
    a.* = .{ .x = 30, .y = 20, .dir = .right, .state = .alive, .speed = w.base_speed(), .log_head = 1 };
    b.* = .{ .x = 31, .y = 20, .dir = .left, .state = .alive, .speed = w.base_speed(), .log_head = 1 };
    w.grid[index(30, 20)] = 1;
    w.grid[index(31, 20)] = 2;
    w.logs[0][0] = index(30, 20);
    w.logs[1][0] = index(31, 20);
    for (0..10) |_| w.step(idle_inputs());
    try testing.expectEqual(Crash.deadlock, a.crash);
    try testing.expectEqual(Crash.deadlock, b.crash);
    try testing.expectEqual(@as(u8, 0), a.kills + b.kills);

    // Out of step: a reaches b's head first; still a head-on, no credit.
    w.init(.{ .n_cycles = 2 }, 1);
    w.grid[index(a.x, a.y)] = empty;
    w.grid[index(b.x, b.y)] = empty;
    a.* = .{ .x = 30, .y = 20, .dir = .right, .state = .alive, .speed = w.base_speed(), .p = 30000, .log_head = 1 };
    b.* = .{ .x = 31, .y = 20, .dir = .left, .state = .alive, .speed = w.base_speed(), .log_head = 1 };
    w.grid[index(30, 20)] = 1;
    w.grid[index(31, 20)] = 2;
    w.logs[0][0] = index(30, 20);
    w.logs[1][0] = index(31, 20);
    for (0..10) |_| w.step(idle_inputs());
    try testing.expectEqual(Crash.deadlock, a.crash);
    try testing.expectEqual(Crash.deadlock, b.crash);
    try testing.expectEqual(@as(u8, 0), a.kills + b.kills);
}

test "derez: the trail stays wall_stay ticks, then fades tail to head" {
    const w = &tw[0];
    w.init(.{ .n_cycles = 2 }, 1);
    // Cycle 0 rides 20 cells, then turns back into itself.
    for (0..80) |_| w.step(idle_inputs());
    var in = idle_inputs();
    for ([_]Dir{ .down, .left, .up }) |d| {
        in[0] = press(d);
        step_to_next_cell(w, in, 0, 10);
    }
    while (w.cycles[0].state == .alive) w.step(idle_inputs());
    const c = &w.cycles[0];
    const len = c.trail_len();
    try testing.expect(len > 20);
    const tail = w.log_from_tail(0, 0);
    for (0..tuning.wall_stay - 1) |_| w.step(idle_inputs());
    try testing.expectEqual(len, c.trail_len());
    try testing.expectEqual(@as(u8, 1), w.grid[tail]);
    var cleared: u32 = 0;
    while (c.state == .dying) {
        w.step(idle_inputs());
        for (w.events[0..w.n_events]) |e| {
            if (e.kind == .cleared) cleared += 1;
        }
    }
    try testing.expectEqual(State.dead, c.state);
    try testing.expectEqual(len, cleared);
    try testing.expectEqual(empty, w.grid[tail]);
    for (w.grid) |v| try testing.expect(trail_owner(v) != 0);
}

test "turn tax only above base speed" {
    const w = &tw[0];
    w.init(.{ .n_cycles = 1 }, 1);
    const base = w.base_speed();
    w.cycles[0].speed = base * 2;
    var in = idle_inputs();
    in[0] = press(.down);
    step_to_next_cell(w, in, 0, 10);
    try testing.expect(w.cycles[0].speed < base * 2 * 19 / 20 + 1);
    w.cycles[0].speed = base;
    in[0] = press(.left);
    step_to_next_cell(w, in, 0, 10);
    try testing.expect(w.cycles[0].speed >= base);
}

// ------------------------------------------------------------- M1 tests

/// Lays a straight trail of cycle `owner` (value owner + 1) along row y.
fn trail_row(w: *World, y: u8, owner: u8) void {
    for (1..grid_w - 1) |x| w.grid[index(x, y)] = owner + 1;
}

test "grinding: a trail at distance 1 speeds up to ~1.5x in a second, and it lingers" {
    const w = &tw[0];
    w.init(.{ .n_cycles = 1, .grinding = true }, 1);
    const c = &w.cycles[0];
    trail_row(w, c.y - 1, 1);
    var events: u32 = 0;
    for (0..60) |_| {
        w.step(idle_inputs());
        for (w.events[0..w.n_events]) |e| {
            if (e.kind != .grind) continue;
            events += 1;
            try testing.expectEqual(c.x, e.x);
            try testing.expectEqual(c.y - 1, e.y);
            try testing.expectEqual(@backingInt(Dir.up), e.a);
        }
    }
    try testing.expectEqual(@as(u8, 2), c.grind);
    try testing.expectEqual(@as(u32, 60), events);
    const peak = w.speed_fraction(0);
    try testing.expect(peak >= 140 and peak <= 160);
    // Off the wall: still well above base two seconds later.
    for (1..grid_w - 1) |x| w.grid[index(x, c.y - 1)] = empty;
    for (0..60) |_| w.step(idle_inputs());
    try testing.expectEqual(@as(u8, 0), c.grind);
    const later = w.speed_fraction(0);
    try testing.expect(later >= 125 and later < peak);
    try testing.expectEqual(State.alive, c.state);

    // Distance 2: level 1, a gentler push, no events.
    w.init(.{ .n_cycles = 1, .grinding = true }, 1);
    trail_row(w, c.y + 2, 0);
    events = 0;
    for (0..60) |_| {
        w.step(idle_inputs());
        for (w.events[0..w.n_events]) |e| events += @intFromBool(e.kind == .grind);
    }
    try testing.expectEqual(@as(u8, 1), c.grind);
    try testing.expectEqual(@as(u32, 0), events);
    const d2 = w.speed_fraction(0);
    try testing.expect(d2 >= 110 and d2 < 130);
}

test "grinding: rim and blocks give nothing and shield, off without the flag" {
    const w = &tw[0];
    const c = &w.cycles[0];
    // Along the top rim.
    w.init(.{ .n_cycles = 1, .grinding = true }, 1);
    w.grid[index(c.x, c.y)] = empty;
    c.y = 1;
    w.grid[index(c.x, 1)] = 1;
    w.logs[0][0] = index(c.x, 1);
    for (0..60) |_| w.step(idle_inputs());
    try testing.expectEqual(@as(u8, 0), c.grind);
    try testing.expectEqual(@as(u32, 100), w.speed_fraction(0));
    // Blocks beside, a trail behind them.
    w.init(.{ .n_cycles = 1, .grinding = true }, 1);
    for (1..grid_w - 1) |x| w.grid[index(x, c.y + 1)] = block;
    trail_row(w, c.y + 2, 1);
    for (0..60) |_| w.step(idle_inputs());
    try testing.expectEqual(@as(u8, 0), c.grind);
    try testing.expectEqual(@as(u32, 100), w.speed_fraction(0));
    // Flag off.
    w.init(.{ .n_cycles = 1 }, 1);
    trail_row(w, c.y - 1, 1);
    for (0..60) |_| w.step(idle_inputs());
    try testing.expectEqual(@as(u8, 0), c.grind);
    try testing.expectEqual(@as(u32, 100), w.speed_fraction(0));
}

test "grinding: your own trail counts after a U-turn" {
    const w = &tw[0];
    w.init(.{ .n_cycles = 1, .grinding = true }, 1);
    for (0..40) |_| w.step(idle_inputs());
    var in = idle_inputs();
    in[0] = press(.left);
    step_to_next_cell(w, in, 0, 10);
    step_to_next_cell(w, idle_inputs(), 0, 10);
    step_to_next_cell(w, idle_inputs(), 0, 10);
    try testing.expectEqual(Dir.left, w.cycles[0].dir);
    try testing.expectEqual(@as(u8, 2), w.cycles[0].grind);
}

test "energy: A boosts to 1.5x and drains, B brakes to 0.5x, idle recharges" {
    const w = &tw[0];
    const c = &w.cycles[0];
    var in = idle_inputs();
    // Boost.
    w.init(.{ .n_cycles = 1, .energy = true }, 1);
    in[0] = .{ .boost = true };
    for (0..30) |_| w.step(in);
    try testing.expectEqual(@as(u16, 1000 - 30 * tuning.boost_drain), c.energy);
    try testing.expect(w.speed_fraction(0) >= 145 and w.speed_fraction(0) <= 150);
    // Held to empty: the boost ends, no recharge while A is still held.
    for (0..80) |_| w.step(in);
    try testing.expectEqual(@as(u16, 0), c.energy);
    const at_empty = w.speed_fraction(0);
    for (0..10) |_| w.step(in);
    try testing.expectEqual(@as(u16, 0), c.energy);
    try testing.expect(w.speed_fraction(0) < at_empty);
    // Released: recharges 2 per tick.
    for (0..10) |_| w.step(idle_inputs());
    try testing.expectEqual(@as(u16, 10 * tuning.energy_recharge), c.energy);

    // Brake, and B wins when both are held.
    w.init(.{ .n_cycles = 1, .energy = true }, 1);
    in[0] = .{ .boost = true, .brake = true };
    for (0..30) |_| w.step(in);
    try testing.expectEqual(@as(u16, 1000 - 30 * tuning.brake_drain), c.energy);
    try testing.expect(w.speed_fraction(0) <= 52);
    // Released: back to base quickly.
    for (0..40) |_| w.step(idle_inputs());
    try testing.expect(w.speed_fraction(0) >= 99);

    // Flag off: A does nothing.
    w.init(.{ .n_cycles = 1 }, 1);
    in[0] = .{ .boost = true };
    for (0..30) |_| w.step(in);
    try testing.expectEqual(@as(u32, 100), w.speed_fraction(0));
    try testing.expectEqual(tuning.energy_max, c.energy);
}

test "speed cap: never above 2.2x base" {
    const w = &tw[0];
    w.init(.{ .n_cycles = 1, .grinding = true, .energy = true }, 1);
    const c = &w.cycles[0];
    trail_row(w, c.y - 1, 1);
    trail_row(w, c.y + 1, 1);
    c.speed = 3 * w.base_speed();
    var in = idle_inputs();
    in[0] = .{ .boost = true };
    for (0..40) |_| {
        w.step(in);
        try testing.expect(c.speed <= w.base_speed() * 22 / 10);
        try testing.expect(c.speed < tuning.one);
    }
}

/// Cycle 0 heading right from its start into a block column at x = wall_x.
fn rubber_setup(w: *World, rubber: u8, wall_x: u8) void {
    w.init(.{ .n_cycles = 1, .rubber = rubber }, 1);
    for (1..grid_h - 1) |y| w.grid[index(wall_x, y)] = block;
}

test "rubber: a stall of cfg.rubber ticks, then the crash" {
    const w = &tw[0];
    const c = &w.cycles[0];
    for ([_]u8{ 12, 4 }) |rubber| {
        rubber_setup(w, rubber, 20);
        var stalls: u32 = 0;
        while (c.state == .alive and w.tick < 200) {
            w.step(idle_inputs());
            for (w.events[0..w.n_events]) |e| {
                if (e.kind != .stall) continue;
                stalls += 1;
                try testing.expectEqual(@as(u8, 19), e.x);
                try testing.expectEqual(c.rubber, e.b);
                try testing.expect(c.stalled);
                try testing.expectEqual(tuning.one - 1, c.p);
            }
        }
        try testing.expectEqual(@as(u32, rubber), stalls);
        try testing.expectEqual(Crash.access_violation, c.crash);
        try testing.expectEqual(@as(u8, 19), c.x);
    }
    // No rubber: straight into the wall.
    rubber_setup(w, 0, 20);
    var stalls: u32 = 0;
    while (c.state == .alive) {
        w.step(idle_inputs());
        for (w.events[0..w.n_events]) |e| stalls += @intFromBool(e.kind == .stall);
    }
    try testing.expectEqual(@as(u32, 0), stalls);
    try testing.expectEqual(Crash.access_violation, c.crash);
}

test "rubber: a turn during a stall applies at once if free, else is dropped; the meter recharges" {
    const w = &tw[0];
    const c = &w.cycles[0];
    rubber_setup(w, 12, 20);
    w.grid[index(19, c.y + 1)] = block;
    while (!c.stalled) w.step(idle_inputs());
    for (0..3) |_| w.step(idle_inputs());
    try testing.expect(c.stalled);
    const left = c.rubber;
    try testing.expectEqual(@as(u8, 12 - 4), left);
    // Down is blocked: dropped, still stalled facing right.
    var in = idle_inputs();
    in[0] = press(.down);
    w.step(in);
    try testing.expect(c.stalled);
    try testing.expectEqual(Dir.right, c.dir);
    try testing.expectEqual(@as(u8, 0), c.queued);
    // Up is free: taken on this very tick.
    const y0 = c.y;
    in[0] = press(.up);
    w.step(in);
    try testing.expect(!c.stalled);
    try testing.expectEqual(Dir.up, c.dir);
    try testing.expectEqual(y0 - 1, c.y);
    try testing.expectEqual(State.alive, c.state);
    // Recharge: one per 8 ticks, up to the meter.
    const r0 = c.rubber;
    for (0..8 * 3) |_| w.step(idle_inputs());
    try testing.expectEqual(r0 + 3, c.rubber);
    for (0..8 * 5) |_| w.step(idle_inputs());
    try testing.expectEqual(@as(u8, 12), c.rubber);
    try testing.expectEqual(State.alive, c.state);
}

test "rubber: a U-turn during a stall escapes sideways" {
    const w = &tw[0];
    const c = &w.cycles[0];
    rubber_setup(w, 12, 20);
    while (!c.stalled) w.step(idle_inputs());
    var in = idle_inputs();
    in[0] = press(.left);
    w.step(in);
    try testing.expect(!c.stalled);
    try testing.expectEqual(Dir.down, c.dir);
    step_to_next_cell(w, idle_inputs(), 0, 10);
    try testing.expectEqual(Dir.left, c.dir);
    try testing.expectEqual(State.alive, c.state);
}

test "rubber: two heads nose to nose stall, then DEADLOCK with no credit" {
    const w = &tw[0];
    w.init(.{ .n_cycles = 2, .rubber = 12 }, 1);
    const a = &w.cycles[0];
    const b = &w.cycles[1];
    w.grid[index(a.x, a.y)] = empty;
    w.grid[index(b.x, b.y)] = empty;
    a.* = .{ .x = 30, .y = 20, .dir = .right, .state = .alive, .speed = w.base_speed(), .rubber = 12, .log_head = 1 };
    b.* = .{ .x = 31, .y = 20, .dir = .left, .state = .alive, .speed = w.base_speed(), .rubber = 12, .log_head = 1 };
    w.grid[index(30, 20)] = 1;
    w.grid[index(31, 20)] = 2;
    w.logs[0][0] = index(30, 20);
    w.logs[1][0] = index(31, 20);
    for (0..40) |_| w.step(idle_inputs());
    try testing.expectEqual(Crash.deadlock, a.crash);
    try testing.expectEqual(Crash.deadlock, b.crash);
    try testing.expectEqual(@as(u8, 0), a.kills + b.kills);
}

test "sudden death: rings close from 30 s, trail stays, heads on the ring derez" {
    const w = &tw[0];
    w.init(.{ .n_cycles = 2, .sudden_death = true }, 1);
    // A trail cell and a head on ring 1.
    w.grid[index(5, 1)] = 2;
    const c = &w.cycles[0];
    w.grid[index(c.x, c.y)] = empty;
    c.x = 1;
    c.y = 30;
    c.dir = .up;
    w.grid[index(1, 30)] = 1;
    w.logs[0][0] = index(1, 30);
    w.tick = tuning.sudden_death_ticks - 1;
    w.sudden_death();
    try testing.expectEqual(@as(u8, 0), w.sudden_death_ring);
    var blocks: u32 = 0;
    for (0..tuning.sudden_death_period) |_| {
        w.tick += 1;
        w.n_events = 0;
        w.sudden_death();
        try testing.expectEqual(@as(u8, 1), w.sudden_death_ring);
        try testing.expect(w.n_events <= 7);
        for (w.events[0..w.n_events]) |e| {
            if (e.kind != .block) continue;
            blocks += 1;
            try testing.expectEqual(@as(u8, 1), e.a);
            try testing.expectEqual(@as(u8, 1), ring_of(e.x, e.y));
            try testing.expect(w.is_sudden_death_block(e.x, e.y));
        }
    }
    // Ring 1 has 2 * (78 + 58) - 4 = 268 cells, two of them were trail.
    try testing.expectEqual(@as(u32, 268 - 2), blocks);
    try testing.expectEqual(@as(u8, 2), w.at(5, 1));
    try testing.expectEqual(Crash.access_violation, c.crash);
    for (1..grid_h - 1) |y| {
        for (1..grid_w - 1) |x| {
            const r = ring_of(@intCast(x), @intCast(y));
            if (r == 1) try testing.expect(is_wall(w.grid[index(x, y)])) else try testing.expect(w.grid[index(x, y)] != block);
        }
    }
    // Every ring: by the last one the arena is full.
    while (w.tick < tuning.sudden_death_ticks + tuning.sudden_death_rings * tuning.sudden_death_period) {
        w.tick += 1;
        w.n_events = 0;
        w.sudden_death();
    }
    try testing.expectEqual(tuning.sudden_death_rings, w.sudden_death_ring);
    for (w.grid) |v| try testing.expect(is_wall(v));
}

test "ring cells: every interior cell once, half-turn pairs" {
    var seen: [cells]u8 = @splat(0);
    var k: u8 = 1;
    while (k <= tuning.sudden_death_rings) : (k += 1) {
        const half = ring_half(k);
        for (0..half) |s| {
            const a = ring_cell(k, @intCast(s));
            const b = ring_cell(k, @intCast(s + half));
            try testing.expectEqual(@as(u8, grid_w - 1 - a[0]), b[0]);
            try testing.expectEqual(@as(u8, grid_h - 1 - a[1]), b[1]);
            try testing.expectEqual(k, ring_of(a[0], a[1]));
            seen[index(a[0], a[1])] += 1;
            seen[index(b[0], b[1])] += 1;
        }
    }
    for (0..grid_h) |y| {
        for (0..grid_w) |x| {
            const interior = x > 0 and y > 0 and x < grid_w - 1 and y < grid_h - 1;
            try testing.expectEqual(@as(u8, @intFromBool(interior)), seen[index(x, y)]);
        }
    }
}

/// A test driver: at each cell boundary (and during a stall) keep the
/// heading unless a side has a longer free run; random A and B.
fn drive(w: *const World, i: usize, r: *@import("rng.zig").Xorshift) Input {
    var in: Input = .{ .boost = r.below(6) == 0, .brake = r.below(12) == 0 };
    const c = &w.cycles[i];
    if (!w.will_step(i)) return in;
    const d0 = w.planned_dir(i);
    var best = d0;
    var best_run = w.free_run(c.x, c.y, d0, 30) * 4 + r.below(4);
    for ([2]Dir{ d0.ccw(), d0.cw() }) |d| {
        const run = w.free_run(c.x, c.y, d, 30) * 4 + r.below(4);
        if (run > best_run) {
            best = d;
            best_run = run;
        }
    }
    if (best != d0) in.press = Press.of(best);
    return in;
}

test "sudden death: rounds always end before 1800 + 60 x 30 ticks" {
    const w = &tw[0];
    var r = @import("rng.zig").Xorshift.init(99);
    var long_rounds: u32 = 0;
    for (0..24) |round| {
        w.init(.{
            .n_cycles = @intCast(2 + round % 3),
            .grinding = true,
            .rubber = 12,
            .energy = true,
            .sudden_death = true,
            .layout = @intCast(round % layouts.count),
            .round_cap = 600,
        }, @intCast(round));
        while (w.result == .running) {
            var in = idle_inputs();
            for (0..w.cfg.n_cycles) |i| in[i] = drive(w, i, &r);
            w.step(in);
            if (w.tick < tuning.sudden_death_ticks) try testing.expectEqual(@as(u8, 0), w.sudden_death_ring);
            try testing.expect(w.tick < tuning.sudden_death_ticks + 30 * tuning.sudden_death_period);
        }
        try testing.expect(!w.timed_out);
        if (w.tick > tuning.sudden_death_ticks) long_rounds += 1;
    }
    // The driver is good enough that some rounds reach sudden death.
    try testing.expect(long_rounds > 0);
}

test "will_step is exact and ticks_to_step agrees, with grinding, energy and rubber" {
    const w = &tw[0];
    var r = @import("rng.zig").Xorshift.init(5);
    w.init(.{ .n_cycles = 4, .grinding = true, .rubber = 12, .energy = true, .sudden_death = true }, 3);
    while (w.result == .running) {
        var in = idle_inputs();
        for (0..4) |i| in[i] = drive(w, i, &r);
        var predicted: [4]bool = undefined;
        var heads: [4]u32 = undefined;
        for (0..4) |i| {
            predicted[i] = w.will_step(i);
            if (w.cycles[i].state == .alive) try testing.expectEqual(predicted[i], w.ticks_to_step(i) == 1);
            heads[i] = w.cycles[i].log_head;
        }
        w.step(in);
        for (0..4) |i| {
            const c = &w.cycles[i];
            if (c.state != .alive) continue;
            const moved = c.log_head != heads[i];
            // A predicted boundary moves the cycle or stalls it.
            try testing.expectEqual(predicted[i], moved or c.stalled);
        }
    }
    w.init(.{ .n_cycles = 1 }, 1);
    try testing.expectEqual(@as(u32, 100), w.speed_fraction(0));
    w.cycles[0].speed = w.base_speed() * 3 / 2;
    try testing.expectEqual(@as(u32, 150), w.speed_fraction(0));
    w.cycles[0].p = 0;
    try testing.expectEqual(@as(u32, 3), w.ticks_to_step(0));
}

test "determinism: two Worlds stay identical for 5000 ticks with every M1 flag" {
    const a = &tw[0];
    const b = &tw[1];
    var r = @import("rng.zig").Xorshift.init(1234);
    var round: u32 = 0;
    var ended: u32 = 0;
    var t: u32 = 0;
    while (t < 5000) : (t += 1) {
        ended = if (a.result == .running) 0 else ended + 1;
        if (t == 0 or ended == 90) {
            const cfg: Config = .{
                .n_cycles = @intCast(2 + round % 3),
                .grinding = true,
                .rubber = if (round % 2 == 0) 12 else 4,
                .energy = true,
                .sudden_death = true,
                .layout = @intCast(round % layouts.count),
                .speed_pct = @intCast(100 + 10 * (round % 3)),
            };
            a.init(cfg, round);
            b.init(cfg, round);
            round += 1;
        }
        var in = idle_inputs();
        for (0..max_cycles) |i| {
            const v = r.next();
            in[i] = .{
                .press = if (v & 7 == 0) @fromBackingInt(@as(u3, @intCast(1 + (v >> 3) % 4))) else .none,
                .boost = (v >> 8) & 3 == 0,
                .brake = (v >> 10) & 7 == 0,
            };
        }
        a.step(in);
        b.step(in);
        try testing.expect(World.same_state(a, b));
        try testing.expectEqual(a.hash(), b.hash());
        try testing.expectEqual(a.n_events, b.n_events);
        try testing.expect(!a.events_lost);
        for (a.events[0..a.n_events], b.events[0..b.n_events]) |ea, eb| try testing.expect(std.meta.eql(ea, eb));
    }
    try testing.expect(round > 2);
}

test "layouts: in bounds, symmetric, start lines free, arena connected" {
    const w = &tw[0];
    const corridor = struct {
        fn hit(x: usize, y: usize) bool {
            for (starts) |s| {
                for (0..tuning.start_clear + 1) |k| {
                    const kx: i32 = @as(i32, s.x) + @as(i32, s.dir.dx()) * @as(i32, @intCast(k));
                    const ky: i32 = @as(i32, s.y) + @as(i32, s.dir.dy()) * @as(i32, @intCast(k));
                    if (kx == x and ky == y) return true;
                }
            }
            return false;
        }
    };
    for (layouts.all, 0..) |lay, li| {
        // The data itself keeps clear of the start lines (init's clearing
        // is only a safety net) and inside the rim.
        for (lay.rects) |rc| {
            try testing.expect(rc.x >= 1 and rc.y >= 1 and rc.x + rc.w <= grid_w - 1 and rc.y + rc.h <= grid_h - 1);
            for (rc.y..rc.y + rc.h) |y| {
                for (rc.x..rc.x + rc.w) |x| {
                    try testing.expect(!corridor.hit(x, y));
                    try testing.expect(!corridor.hit(grid_w - 1 - x, y));
                    try testing.expect(!corridor.hit(x, grid_h - 1 - y));
                    try testing.expect(!corridor.hit(grid_w - 1 - x, grid_h - 1 - y));
                }
            }
        }
        w.init(.{ .n_cycles = 4, .layout = @intCast(li) }, 1);
        var n_blocks: u32 = 0;
        for (0..grid_h) |y| {
            for (0..grid_w) |x| {
                const v = w.grid[index(x, y)];
                try testing.expectEqual(v == block, w.grid[index(grid_w - 1 - x, grid_h - 1 - y)] == block);
                n_blocks += @intFromBool(v == block);
            }
        }
        try testing.expectEqual(li == 0, n_blocks == 0);
        // Connected: a fill from cycle 0's start reaches every empty cell.
        var seen: [cells]bool = @splat(false);
        var queue: [cells]u16 = undefined;
        var head: usize = 0;
        var tail: usize = 1;
        const s0 = index(w.cycles[0].x, w.cycles[0].y);
        queue[0] = s0;
        seen[s0] = true;
        var reached: u32 = 0;
        while (head < tail) : (head += 1) {
            const at_i = queue[head];
            reached += 1;
            const x = at_i % grid_w;
            const y = at_i / grid_w;
            for ([4]u16{ index(x - 1, y), index(x + 1, y), index(x, y - 1), index(x, y + 1) }) |n| {
                if (seen[n] or (is_wall(w.grid[n]) and trail_owner(w.grid[n]) == null)) continue;
                seen[n] = true;
                queue[tail] = n;
                tail += 1;
            }
        }
        var open: u32 = 0;
        for (w.grid) |v| open += @intFromBool(!is_wall(v) or trail_owner(v) != null);
        try testing.expectEqual(open, reached);
    }
    // Out of range is the open arena.
    try testing.expectEqual(@as(usize, 0), layouts.get(200).rects.len);
}
