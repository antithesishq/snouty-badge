//! Time travel (SPEC.md section 9, PLAN.md M2 Track R item 1).
//!
//! While a ladder round plays, `record` keeps, per World tick, the
//! player's input and what the step changed (each cycle's trail log moves
//! and a journal of the cells it cleared or blocked), and every
//! `tuning.keyframe_every` ticks a keyframe of the rule state. Two things
//! use them when you derez:
//!
//! - `retract` plays the round backwards on screen: per undone tick the
//!   newest trail cells pop (newest first), faded cells and sudden-death
//!   blocks go back, heads slide back along their trails and crashed
//!   cycles ride again. It writes the World in place and leaves events for
//!   the renderer, like a step. It is the picture only: exact for the grid
//!   and heads when the journal is complete, but nothing relies on it.
//! - `restore` + replay is the exact part: the keyframe at or before the
//!   target tick T goes back into the World (and the Brains and score into
//!   the game), then the game replays the logged inputs up to T with the
//!   same programs (`input_at`). The programs are deterministic (ai.zig:
//!   a Brain's own rng, decisions a function of World and Brain, the shared
//!   pool reset by `restore`), so the World at T is byte for byte the one
//!   the round had (host tests below).
//!
//! What a keyframe holds is `Rewindable`, copied field by field by name
//! from the World, plus the Brains and the game's score: about 5.2 KB.
//! The World's 32 KB of trail logs are left out: they are append-only
//! rings (a step writes at `log_head`; a fade or a SNAKE clear only moves
//! `log_tail`), so restoring each cycle's head and tail (in `cycles`)
//! restores the logs. A test checks that every World field is either in
//! `Rewindable` or listed in `not_keyframed` with a reason, so a field
//! added to World later fails it until it is keyframed: add it to
//! `Rewindable` (same name and type) and nothing else changes.
//!
//! Memory: `History` is ~46 KB (8 keyframes, 256 ticks of inputs and
//! moves, a 1024-entry journal), inside PLAN's 48 KB; `tuning` has the
//! knobs.
//!
//! Besides `World.init`/`step`/`set_heading`, this module is the only
//! writer of a World.
const std = @import("std");
const sim = @import("sim.zig");
const ai = @import("ai.zig");

pub const tuning = struct {
    /// A keyframe on every tick that is a multiple of this.
    pub const keyframe_every: u32 = 30;
    /// Keyframes kept: 8 x 30 ticks = 4 s of history (SPEC 9).
    pub const keyframes: u32 = 8;
    /// Ticks of inputs and moves kept (a power of two, more than the
    /// keyframes span).
    pub const ticks: u32 = 256;
    /// Journal entries kept (cleared and blocked cells, for `retract`):
    /// sudden death lays up to 6 cells a tick, fades 6 per dying cycle.
    pub const journal: u32 = 1024;
    /// How far a rewind goes back (SPEC 6: 2 s).
    pub const rewind_ticks: u32 = 120;
    /// Ticks undone per frame while retracting (SPEC 6: 3x speed).
    pub const retract_per_frame: u32 = 3;
};

/// The World state a keyframe restores, by field name (same names and
/// types as `sim.World`). `cycles` carries each trail log's head and tail.
pub const Rewindable = struct {
    tick: u32,
    result: sim.Result,
    winner: u8,
    timed_out: bool,
    sudden_death_ring: u8,
    grid: [sim.cells]u8,
    cycles: [sim.max_cycles]sim.Cycle,
};

/// World fields a keyframe leaves out, and why:
/// `cfg` and `seed` never change during a round; `logs` are append-only
/// rings whose heads and tails are in `cycles`; `events`, `n_events` and
/// `events_lost` are each step's output (refilled by the replay's steps).
pub const not_keyframed = [_][]const u8{ "cfg", "seed", "logs", "events", "n_events", "events_lost" };

pub const Keyframe = struct {
    valid: bool,
    world: Rewindable,
    brains: [sim.max_cycles]ai.Brain,
    /// The game's score after this tick (the replay re-scores from it).
    score: u32,
};

/// A trail log entry's cell (bits above are free for marks).
const cell_bits: u16 = 0x1FFF;
/// Journal entry: the cell (13 bits) and the value it had before the
/// step (3 bits: 0 empty, 1..4 a trail of cycle 0..3).
const old_shift: u4 = 13;

pub const History = struct {
    keys: [tuning.keyframes]Keyframe,
    /// Per tick t (slot t % `tuning.ticks`): the step that made tick t.
    /// `stamp` is t (low 16 bits) when the slot is t's.
    stamp: [tuning.ticks]u16,
    input: [tuning.ticks]sim.Input,
    /// Per cycle: trail log head moves (low nibble) and tail moves (high).
    moves: [tuning.ticks][sim.max_cycles]u8,
    /// The step's journal entries: `jcount` from position `jstart`.
    jstart: [tuning.ticks]u16,
    jcount: [tuning.ticks]u8,
    journal: [tuning.journal]u16,
    /// Journal entries ever written (wraps; positions are mod 2^16).
    jpos: u16,
    last_head: [sim.max_cycles]u32,
    last_tail: [sim.max_cycles]u32,
    /// `retract` undoes ticks down to this one.
    target: u32,

    /// A round starts (tick 0): forgets everything, keyframes tick 0.
    pub fn start(h: *History, w: *const sim.World, brains: *const [sim.max_cycles]ai.Brain, score: u32) void {
        for (&h.keys) |*k| k.valid = false;
        // A stamp no tick within a round has (tick 0 is never stepped to).
        @memset(&h.stamp, 0xFFFF);
        h.jpos = 0;
        h.target = 0;
        h.sync(w);
        h.save(w, brains, score);
    }

    fn sync(h: *History, w: *const sim.World) void {
        for (w.cycles, 0..) |c, i| {
            h.last_head[i] = c.log_head;
            h.last_tail[i] = c.log_tail;
        }
    }

    /// After every play step (and every replayed one): the player's input
    /// that made `w.tick`, the step's moves and journal, and a keyframe
    /// on every `keyframe_every`-th tick. `brains` and `score` as they are
    /// after the step.
    pub fn record(h: *History, w: *const sim.World, input: sim.Input, brains: *const [sim.max_cycles]ai.Brain, score: u32) void {
        const t = w.tick;
        const s = t % tuning.ticks;
        h.stamp[s] = @truncate(t);
        h.input[s] = input;
        var tail_moved: [sim.max_cycles]u32 = @splat(0);
        for (w.cycles, 0..) |c, i| {
            const hd = c.log_head -% h.last_head[i];
            const td = c.log_tail -% h.last_tail[i];
            tail_moved[i] = td;
            h.moves[s][i] = @as(u8, @intCast(@min(hd, 15))) | (@as(u8, @intCast(@min(td, 15))) << 4);
            h.last_head[i] = c.log_head;
            h.last_tail[i] = c.log_tail;
        }
        h.jstart[s] = h.jpos;
        var n: u8 = 0;
        for (w.events[0..w.n_events]) |e| {
            const old: ?u16 = switch (e.kind) {
                .block => 0,
                .cleared => owner_of_cleared(w, &tail_moved, sim.index(e.x, e.y)),
                else => null,
            };
            const o = old orelse continue;
            if (n == std.math.maxInt(u8)) break;
            h.journal[h.jpos % tuning.journal] = sim.index(e.x, e.y) | (o << old_shift);
            h.jpos +%= 1;
            n += 1;
        }
        h.jcount[s] = n;
        if (t % tuning.keyframe_every == 0) h.save(w, brains, score);
    }

    /// The trail value a cleared cell had: the cycle whose log tail moved
    /// past it this step (a fade, a SNAKE clear), else unknown (null: the
    /// retraction leaves it).
    fn owner_of_cleared(w: *const sim.World, tail_moved: *const [sim.max_cycles]u32, idx: u16) ?u16 {
        for (w.cycles, 0..) |c, i| {
            const n = tail_moved[i];
            if (n == 0 or n > sim.log_cap) continue;
            var k: u32 = c.log_tail -% n;
            while (k != c.log_tail) : (k +%= 1) {
                if (w.logs[i][k % sim.log_cap] & cell_bits == idx) return @intCast(i + 1);
            }
        }
        return null;
    }

    fn save(h: *History, w: *const sim.World, brains: *const [sim.max_cycles]ai.Brain, score: u32) void {
        const k = &h.keys[(w.tick / tuning.keyframe_every) % tuning.keyframes];
        k.valid = true;
        inline for (@typeInfo(Rewindable).@"struct".field_names) |name| @field(k.world, name) = @field(w, name);
        k.brains = brains.*;
        k.score = score;
    }

    fn key_at(h: *const History, t: u32) ?*const Keyframe {
        const k = &h.keys[(t / tuning.keyframe_every) % tuning.keyframes];
        if (!k.valid or k.world.tick != t) return null;
        return k;
    }

    fn has_record(h: *const History, t: u32) bool {
        return h.stamp[t % tuning.ticks] == @as(u16, @truncate(t));
    }

    /// The tick a rewind from `now` should land on: `back` ticks earlier
    /// (not before the round's start) when a keyframe at or before it is
    /// kept, else the oldest kept keyframe after it (a crash right after
    /// a rewind may find the older ones gone), else null. Sets `target`.
    pub fn plan(h: *History, now: u32, back: u32) ?u32 {
        const want = now -| back;
        var t: ?u32 = null;
        if (h.key_at(want / tuning.keyframe_every * tuning.keyframe_every) != null) {
            t = want;
        } else {
            for (&h.keys) |*k| {
                if (!k.valid or k.world.tick < want or k.world.tick > now) continue;
                if (t == null or k.world.tick < t.?) t = k.world.tick;
            }
        }
        if (t) |tt| h.target = tt;
        return t;
    }

    /// The player's input of the step that made tick t (replays read it).
    pub fn input_at(h: *const History, t: u32) sim.Input {
        std.debug.assert(h.has_record(t));
        return h.input[t % tuning.ticks];
    }

    /// Puts the keyframe at or before `target` back into the World, the
    /// Brains and the score, forgets the keyframes after it (another
    /// timeline) and the AI's per-tick pool. Returns the keyframe's tick:
    /// the caller replays from there to `target` (`input_at`, `record`).
    pub fn restore(h: *History, w: *sim.World, brains: *[sim.max_cycles]ai.Brain, score: *u32) ?u32 {
        const k0 = h.target / tuning.keyframe_every * tuning.keyframe_every;
        const k = h.key_at(k0) orelse return null;
        inline for (@typeInfo(Rewindable).@"struct".field_names) |name| @field(w, name) = @field(k.world, name);
        brains.* = k.brains;
        score.* = k.score;
        w.n_events = 0;
        w.events_lost = false;
        for (&h.keys) |*o| {
            if (o.valid and o.world.tick > k0) o.valid = false;
        }
        h.sync(w);
        ai.reset_pool();
        return k0;
    }

    /// What one `retract` call did.
    pub const Retracted = struct {
        /// A crashed cycle rides again (its trail changes colour: the
        /// caller repaints the screen).
        revived: bool = false,
        /// `target` reached (or no record left to undo).
        done: bool = false,
    };

    /// Undoes up to `n` ticks of the World, newest first, toward `target`
    /// (the picture of a rewind; `restore` makes it exact afterwards).
    /// Leaves `cleared` events for every cell it empties or refills and a
    /// `painted` event at each head that moved (the renderer re-colours the
    /// newest cells), then lowers `w.tick`, so the renderer applies them
    /// as one World tick.
    pub fn retract(h: *History, w: *sim.World, n: u32) Retracted {
        var out: Retracted = .{};
        w.n_events = 0;
        w.events_lost = false;
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            if (w.tick <= h.target or !h.has_record(w.tick)) {
                out.done = true;
                break;
            }
            if (h.undo_tick(w)) out.revived = true;
        }
        if (w.tick <= h.target or !h.has_record(w.tick)) out.done = true;
        return out;
    }

    /// Undoes the step that made `w.tick`, in reverse step order: fades
    /// and sudden-death blocks (the journal, newest first; tails move
    /// back), crashes, then the head moves. True if a cycle revived.
    fn undo_tick(h: *History, w: *sim.World) bool {
        const t = w.tick;
        const s = t % tuning.ticks;
        // The journal, if it has not been overwritten since.
        const cnt = h.jcount[s];
        const first = h.jstart[s];
        if (h.jpos -% first <= tuning.journal and cnt <= h.jpos -% first) {
            var j: u16 = cnt;
            while (j > 0) {
                j -= 1;
                const e = h.journal[(first +% j) % tuning.journal];
                const idx = e & cell_bits;
                if (idx >= sim.cells) continue;
                w.grid[idx] = @intCast(e >> old_shift);
                emit(w, .{ .kind = .cleared, .x = @intCast(idx % sim.grid_w), .y = @intCast(idx / sim.grid_w) });
            }
        }
        var revived = false;
        for (&w.cycles, 0..) |*c, i| {
            if (c.state == .off) continue;
            const m = h.moves[s][i];
            c.log_tail -%= m >> 4;
            if (c.state == .dead and c.trail_len() != 0) c.state = .dying;
            if (c.state != .alive and c.died_tick == t) {
                c.state = .alive;
                c.crash = .none;
                c.killer = sim.no_cycle;
                revived = true;
            }
            const pops = m & 15;
            if (pops == 0) continue;
            var p: u32 = 0;
            while (p < pops and c.trail_len() != 0) : (p += 1) {
                c.log_head -%= 1;
                const idx = w.logs[i][c.log_head % sim.log_cap] & cell_bits;
                if (idx >= sim.cells) continue;
                if (sim.trail_owner(w.grid[idx]) == @as(u8, @intCast(i))) {
                    w.grid[idx] = sim.empty;
                    emit(w, .{ .kind = .cleared, .x = @intCast(idx % sim.grid_w), .y = @intCast(idx / sim.grid_w) });
                }
            }
            place_head(w, i);
        }
        if (revived) w.result = .running;
        w.tick -= 1;
        return revived;
    }

    /// Puts cycle i's head on its newest trail cell, facing the way it
    /// came, at the start of the cell.
    fn place_head(w: *sim.World, i: usize) void {
        const c = &w.cycles[i];
        const a = w.log_at(i, 0) orelse return;
        const ia = a & cell_bits;
        if (ia >= sim.cells) return;
        c.x = @intCast(ia % sim.grid_w);
        c.y = @intCast(ia / sim.grid_w);
        c.p = 0;
        c.stalled = false;
        if (w.log_at(i, 1)) |b| {
            const ib = b & cell_bits;
            if (ib < sim.cells) {
                if (dir_between(ib, ia)) |d| c.dir = d;
            }
        }
        emit(w, .{ .kind = .painted, .cycle = @intCast(i), .x = c.x, .y = c.y });
    }

    fn emit(w: *sim.World, e: sim.Event) void {
        if (w.n_events == sim.max_events) {
            w.events_lost = true;
            return;
        }
        w.events[w.n_events] = e;
        w.n_events += 1;
    }
};

/// The heading from cell a to the neighbouring cell b (across the edge
/// too: WRAP), or null if they are not neighbours.
fn dir_between(a: u16, b: u16) ?sim.Dir {
    const ax: i32 = a % sim.grid_w;
    const ay: i32 = a / sim.grid_w;
    const bx: i32 = b % sim.grid_w;
    const by: i32 = b / sim.grid_w;
    const dx = @mod(bx - ax + sim.grid_w, sim.grid_w);
    const dy = @mod(by - ay + sim.grid_h, sim.grid_h);
    if (dy == 0 and dx == 1) return .right;
    if (dy == 0 and dx == sim.grid_w - 1) return .left;
    if (dx == 0 and dy == 1) return .down;
    if (dx == 0 and dy == sim.grid_h - 1) return .up;
    return null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const rng = @import("rng.zig");

/// Big things in statics (the tests' stack is not the cart's, but the
/// World is 38 KB and History 46 KB).
var th: History = undefined;
var tw: sim.World = undefined;
/// The original run's World at the rewind target and at the crash.
var at_target: sim.World = undefined;
var at_end: sim.World = undefined;

test "every World field is keyframed or listed as not needed" {
    var missing: u32 = 0;
    const info = @typeInfo(sim.World).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        const f = .{ .name = name, .type = T };
        const in_key = @hasField(Rewindable, f.name);
        var listed = false;
        for (not_keyframed) |n| {
            if (std.mem.eql(u8, n, f.name)) listed = true;
        }
        if (in_key == listed) {
            std.debug.print("history: World.{s} must be in exactly one of Rewindable and not_keyframed\n", .{f.name});
            missing += 1;
        }
        if (in_key) {
            if (@FieldType(Rewindable, f.name) != f.type) {
                std.debug.print("history: Rewindable.{s} has another type than World's\n", .{f.name});
                missing += 1;
            }
        }
    }
    try testing.expectEqual(@as(u32, 0), missing);
}

test "memory: History within PLAN's 48 KB" {
    try testing.expect(@sizeOf(History) <= 48 * 1024);
}

/// The configs the exactness test runs: the ladder's rules (every M1
/// flag), layouts, HARDCORE's rubber, and the M2 modifiers (Track O's,
/// inert until they land) alone and together.
fn test_config(k: u32, n_cycles: u8) sim.Config {
    var c: sim.Config = .{
        .n_cycles = n_cycles,
        .grinding = true,
        .energy = true,
        .rubber = sim.tuning.rubber_max,
        .sudden_death = true,
        .layout = @intCast(k % 9),
    };
    switch (k % 6) {
        1 => c.snake_len = 200,
        2 => c.gaps = true,
        3 => c.wrap = true,
        4 => {
            c.snake_len = 200;
            c.gaps = true;
            c.wrap = true;
        },
        5 => {
            c.rubber = 4;
            c.speed_pct = 125;
        },
        else => {},
    }
    return c;
}

const Run = struct {
    brains: [sim.max_cycles]ai.Brain,
    /// Player input per tick (index = the tick it made).
    inputs: [4096]sim.Input,
    rnd: rng.Xorshift,

    /// The player: a T1 that slips now and then, boosts and brakes at
    /// random (random inputs alone crash in a second; this rides on into
    /// sudden death). Its decide runs before the programs' as the game's
    /// does, so the shared AI pool sees the same order on a replay.
    fn player_input(r: *Run, w: *const sim.World) sim.Input {
        var in = ai.decide(&r.brains[0], w, 0);
        const x = r.rnd.below(100);
        if (x < 3) in.press = sim.Press.of(@fromBackingInt(@intCast(r.rnd.below(4))));
        in.boost = x >= 80 and x < 90;
        in.brake = x >= 90 and x < 94;
        return in;
    }

    fn step(r: *Run, w: *sim.World, player: sim.Input, decide0: bool) void {
        var in: [sim.max_cycles]sim.Input = @splat(.idle);
        // The game calls decide for an autopilot player too: keep the order.
        if (decide0) _ = ai.decide(&r.brains[0], w, 0);
        in[0] = player;
        for (1..w.cfg.n_cycles) |i| in[i] = ai.decide(&r.brains[i], w, i);
        w.step(in);
    }
};
var run: Run = undefined;

/// Rule state, bytewise: every World field but the logs, and the logs as
/// far back as this round wrote them.
fn expect_same(a: *const sim.World, b: *const sim.World) !void {
    try testing.expect(sim.World.same_state(a, b));
    try testing.expectEqual(a.hash(), b.hash());
    inline for (@typeInfo(sim.World).@"struct".field_names) |name| {
        const f = .{ .name = name };
        // The logs below; the events are the last step's output (stale
        // past n_events, and none right after a restore that needed no
        // replay step): compared below when both have them.
        if (comptime std.mem.eql(u8, f.name, "logs") or std.mem.eql(u8, f.name, "events") or
            std.mem.eql(u8, f.name, "n_events") or std.mem.eql(u8, f.name, "events_lost")) continue;
        if (!std.mem.eql(u8, std.mem.asBytes(&@field(a, f.name)), std.mem.asBytes(&@field(b, f.name)))) {
            std.debug.print("history: World.{s} differs after the replay\n", .{f.name});
            return error.TestExpectedEqual;
        }
    }
    if (b.n_events != 0) {
        try testing.expectEqual(a.n_events, b.n_events);
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(a.events[0..a.n_events]), std.mem.sliceAsBytes(b.events[0..b.n_events]));
    }
    for (0..sim.max_cycles) |i| {
        const head = a.cycles[i].log_head;
        var k: u32 = head -| sim.log_cap;
        while (k < head) : (k += 1) try testing.expectEqual(a.logs[i][k % sim.log_cap], b.logs[i][k % sim.log_cap]);
    }
}

/// One round: play to `crash` (or the end), retract to `crash - back`,
/// restore and replay; the World then equals the original at the target,
/// and replaying the original inputs on to `crash` equals it there too.
/// Returns false if the round ended before `crash`.
fn rewind_round(cfg: sim.Config, seed: u32, crash: u32, back: u32) !bool {
    const w = &tw;
    const h = &th;
    w.init(cfg, seed);
    run.rnd = .init(seed ^ 0xABCD);
    run.brains[0] = .from(ai.preset(.avoid, 2), rng.mix(seed, 0));
    run.brains[0].mistake_permille = 20;
    const tiers = [_]ai.Tier{ .territory, .search, .avoid };
    for (1..sim.max_cycles) |i| run.brains[i] = .from(ai.preset(tiers[(seed + i) % 3], 2), rng.mix(seed, @intCast(i)));
    ai.reset_pool();
    var score: u32 = seed;
    h.start(w, &run.brains, score);
    const target = crash -| back;
    while (w.tick < crash) {
        if (w.tick == target) at_target = w.*;
        if (w.result != .running) return false;
        const in = run.player_input(w);
        run.inputs[w.tick + 1] = in;
        run.step(w, in, false);
        score +%= w.tick;
        h.record(w, in, &run.brains, score);
    }
    at_end = w.*;
    const kept_brains = run.brains;

    // Backwards on screen: the grid and heads at the target, exactly,
    // when the journal kept everything.
    try testing.expectEqual(target, h.plan(w.tick, back).?);
    var frames: u32 = 0;
    while (true) {
        const r = h.retract(w, tuning.retract_per_frame);
        frames += 1;
        if (r.done) break;
    }
    try testing.expectEqual(target, w.tick);
    try testing.expect(frames <= back / tuning.retract_per_frame + 2);
    try testing.expectEqualSlices(u8, &at_target.grid, &w.grid);
    for (w.cycles, at_target.cycles) |c, o| {
        try testing.expectEqual(o.state == .alive, c.state == .alive);
        try testing.expectEqual(o.log_head, c.log_head);
        try testing.expectEqual(o.log_tail, c.log_tail);
        if (o.state != .alive) continue;
        try testing.expectEqual(o.x, c.x);
        try testing.expectEqual(o.y, c.y);
    }

    // Exact: the keyframe, then the replay.
    var replay_score: u32 = 0;
    const k0 = h.restore(w, &run.brains, &replay_score).?;
    try testing.expect(k0 <= target and target - k0 < tuning.keyframe_every);
    while (w.tick < target) {
        const in = h.input_at(w.tick + 1);
        run.step(w, in, true);
        replay_score +%= w.tick;
        h.record(w, in, &run.brains, replay_score);
    }
    try expect_same(&at_target, w);
    // The game's score came back with it.
    var want_score: u32 = seed;
    for (1..target + 1) |t| want_score +%= @intCast(t);
    try testing.expectEqual(want_score, replay_score);

    // Onwards with the original inputs: the same World at the crash, and
    // the same Brains.
    while (w.tick < crash) {
        const in = run.inputs[w.tick + 1];
        run.step(w, in, true);
        h.record(w, in, &run.brains, 0);
    }
    try expect_same(&at_end, w);
    try testing.expect(std.meta.eql(kept_brains, run.brains));
    return true;
}

test "rewind: retract, restore and replay give the original World, byte for byte" {
    var done: u32 = 0;
    var seed: u32 = 1;
    while (seed <= 36) : (seed += 1) {
        const cfg = test_config(seed, @intCast(2 + seed % 3));
        // Early, mid-round, and into sudden death (layouts, rings).
        const crash: u32 = switch (seed % 3) {
            0 => 100, // a rewind to the round's start
            1 => 700,
            else => 1950,
        };
        if (try rewind_round(cfg, seed, crash, tuning.rewind_ticks)) done += 1;
    }
    try testing.expect(done >= 24);
}

test "rewind: any distance a keyframe covers, odd ticks, every config" {
    var seed: u32 = 100;
    var done: u32 = 0;
    while (seed < 124) : (seed += 1) {
        const back = 1 + (seed * 37) % (tuning.keyframe_every * (tuning.keyframes - 1));
        if (try rewind_round(test_config(seed, 4), seed, 900 + seed, back)) done += 1;
    }
    try testing.expect(done >= 12);
}

/// Restore after a retraction and replay the logged inputs to `target`.
fn restore_and_replay(h: *History, w: *sim.World) !void {
    while (!h.retract(w, tuning.retract_per_frame).done) {}
    var sc: u32 = 0;
    _ = h.restore(w, &run.brains, &sc) orelse return error.NoKeyframe;
    replay_to(h, w, h.target);
}

fn replay_to(h: *History, w: *sim.World, t: u32) void {
    while (w.tick < t) {
        const in = h.input_at(w.tick + 1);
        run.step(w, in, true);
        h.record(w, in, &run.brains, 0);
    }
}

test "rewind: a second crash right after a rewind (older keyframes gone)" {
    const w = &tw;
    const h = &th;
    try testing.expect(try rewind_round(test_config(0, 3), 4242, 1000, tuning.rewind_ticks));
    // At tick 1000 on the original timeline, keyframes 780..990 kept.
    // Rewind to 880 (drops 900..990), ride 10 ticks on a new path.
    try testing.expectEqual(@as(u32, 880), h.plan(w.tick, tuning.rewind_ticks).?);
    try restore_and_replay(h, w);
    try testing.expectEqual(@as(u32, 880), w.tick);
    run.rnd = .init(99);
    for (0..10) |_| {
        const in = run.player_input(w);
        run.step(w, in, false);
        h.record(w, in, &run.brains, 0);
    }
    at_end = w.*;
    // 2 s back is tick 770, whose keyframe (750) went with 990: the
    // oldest kept one, 780, is the target instead.
    try testing.expectEqual(@as(u32, 780), h.plan(w.tick, tuning.rewind_ticks).?);
    try restore_and_replay(h, w);
    try testing.expectEqual(@as(u32, 780), w.tick);
    // On to the second crash with the logged inputs: the same World.
    replay_to(h, w, at_end.tick);
    try expect_same(&at_end, w);
}
