//! Spawner and stage flow: the SPEC.md section 9 stage-1 table as data,
//! then the stage phases (PLAN.md "Gameplay numbers for M3"): at 66 s the
//! table goes quiet (`.warning`), at 72 s the boss enters (`.boss`), its
//! death clears the stage (`.cleared`, a 120-tick breather) and the next
//! stage starts. Since M7 the difficulty comes from `rank.zig` (the loop
//! modifiers are gone) and the state carries a stage index: there is one
//! table so far, so `stage_count` is 1 and every clear is also a new loop;
//! track B1 adds the other three tables (PLAN.md M7 "Stages").
const enemies = @import("enemies.zig");
const rng = @import("rng.zig");
const world = @import("world.zig");
const formations = @import("formations.zig");

const Kind = enemies.Kind;

/// `y` value meaning "draw from the world rng".
const random: i16 = -1;

/// One scripted spawn. Gnat entries spawn one string of 5 at `y` (count and
/// spacing are ignored). Other kinds spawn `count` enemies, the i-th with
/// `i * spacing` ticks of delay; each draws its own random y when `y` is
/// `random`. Spider: `y` is its column x (random: [64, 136]).
pub const Entry = struct {
    at: u32,
    kind: Kind,
    y: i16 = random,
    count: u8 = 1,
    spacing: u8 = 0,
};

fn s(sec: u32) u32 {
    return sec * 60;
}

/// Stage 1, sorted by `at`.
pub const stage1 = [_]Entry{
    // 0 s: learn the zapper.
    .{ .at = s(0), .kind = .gnat, .y = 40 },
    .{ .at = s(0), .kind = .gnat, .y = 80 },
    // 8 s
    .{ .at = s(8), .kind = .beetle, .y = 64 },
    // 14 s
    .{ .at = s(14), .kind = .gnat, .y = 30 },
    .{ .at = s(14), .kind = .wasp, .y = 100 },
    // 22 s
    .{ .at = s(22), .kind = .spider, .count = 2, .spacing = spider_stagger },
    .{ .at = s(22), .kind = .gnat },
    // 32 s
    .{ .at = s(32), .kind = .moth, .count = 2 },
    .{ .at = s(32), .kind = .beetle, .y = 40 },
    .{ .at = s(32), .kind = .beetle, .y = 88 },
    // 44 s
    .{ .at = s(44), .kind = .wasp, .count = 3, .spacing = 30 },
    .{ .at = s(44), .kind = .spider },
    // 54 s
    .{ .at = s(54), .kind = .moth, .count = 3 },
    .{ .at = s(54), .kind = .beetle },
    .{ .at = s(54), .kind = .gnat },
    .{ .at = s(54), .kind = .gnat },
};

/// SPEC.md gives no spacing for "spider x2"; 60 ticks keeps two random
/// columns from dropping on top of each other at the same moment.
const spider_stagger = 60;

/// 66 s: the table is done; "WARNING" until the boss enters.
pub const stage_len: u32 = s(66);
pub const warning_at: u32 = stage_len;
/// 72 s: the boss enters.
pub const boss_at: u32 = s(72);
/// Ticks of `.cleared` between the boss death and the table restarting.
pub const breather: u32 = 120;
/// Boss spawn point (cell top-left).
const boss_x: f32 = 168;
const boss_y: f32 = 40;

const min_y = 16;
const max_y = 104;
const spider_min_x = 64;
const spider_max_x = 136;

pub const StagePhase = enum(u8) { waves, warning, boss, cleared };

/// Spawner state, stored in `world.w.waves`.
pub const State = struct {
    /// Ticks since the start of the current pass through the table.
    t: u32 = 0,
    /// Index of the next entry of `stage1` to run.
    next: u8 = 0,
    /// Completed loops through all `stage_count` stages (rank +400 each).
    /// With one stage table so far, every boss clear is a new loop.
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

pub fn update() void {
    const st = &world.w.waves;
    if (st.phase == .cleared and world.w.game_tick -% st.clear_tick >= breather) {
        // The stage index already moved on at the clear (`advance`).
        st.t = 0;
        st.next = 0;
        st.phase = .waves;
    }
    if (st.phase == .waves and st.t >= warning_at) st.phase = .warning;
    if (st.phase == .warning and st.t >= boss_at) {
        // A full pool delays the boss by a tick rather than losing it.
        if (enemies.spawn(.boss, boss_x, boss_y, 0) != null) st.phase = .boss;
    }
    if (st.phase == .waves) {
        while (st.next < stage1.len and stage1[st.next].at <= st.t) {
            run(stage1[st.next]);
            st.next += 1;
        }
    }
    st.t += 1;
}

/// Stage tables so far (track B1 makes it 4).
pub const stage_count: u8 = 1;

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

/// Debug hook (`debug_next_stage`): jumps to the start of the next stage at
/// once. Clears the enemies (the boss too), enemy bullets, crates and
/// formations, moves the stage index on as a clear does (not again during
/// the breather after a clear, which already did), and starts the table
/// from its first entry: no breather, +500, fuel refill or `stage_clears`
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

/// count. The caller checkpoints the history.
pub fn next_stage() void {
    const w = &world.w;
    w.enemies = @splat(.{});
    w.enemy_bullets = @splat(.{});
    w.pickups = @splat(.{});
    formations.clear();
    if (w.waves.phase == .cleared) w.waves.t = 0 else advance();
    w.waves.next = 0;
    w.waves.phase = .waves;
}

/// The stage across loops, stage + 4 x loop (PLAN.md M7's numbering for
/// four stages per loop).
pub fn stage_index() u32 {
    const st = &world.w.waves;
    return @as(u32, st.stage) + 4 * @as(u32, st.loop);
}

/// Debug hook: jump to the 66 s mark (the rest of the table is skipped).
/// Only acts while the table is running, so it can never spawn a second
/// boss.
pub fn warp_to_warning() void {
    const st = &world.w.waves;
    if (st.phase != .waves) return;
    st.t = warning_at;
    st.next = stage1.len;
    st.phase = .warning;
}

fn pick(lo: i32, hi: i32, y: i16) f32 {
    return @floatFromInt(if (y == random) rng.range(lo, hi) else y);
}

fn run(e: Entry) void {
    switch (e.kind) {
        // Every gnat string is a formation that drops (PLAN.md M7).
        .gnat => enemies.spawn_gnat_string(pick(min_y, max_y, e.y), true),
        .spider => for (0..e.count) |i| {
            const col = pick(spider_min_x, spider_max_x, e.y);
            _ = enemies.spawn(.spider, col, 0, @intCast(i * e.spacing));
        },
        else => for (0..e.count) |i| {
            const y = pick(min_y, max_y, e.y);
            _ = enemies.spawn(e.kind, enemies.spawn_x, y, @intCast(i * e.spacing));
        },
    }
}
