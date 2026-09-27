//! Spawner and stage flow: the SPEC.md section 9 stage-1 table as data,
//! then the stage phases (PLAN.md "Gameplay numbers for M3"): at 66 s the
//! table goes quiet (`.warning`), at 72 s the boss enters (`.boss`), its
//! death clears the stage (`.cleared`, a 120-tick breather) and the table
//! starts over with `loop` one higher. The loop modifiers (bullet speed,
//! fire interval, extra HP) are read by the fire programs in `enemies.zig`.
const enemies = @import("enemies.zig");
const rng = @import("rng.zig");
const world = @import("world.zig");

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
    /// Completed stages (drives the loop modifiers).
    loop: u8 = 0,
    phase: StagePhase = .waves,
    /// Monotonic count of boss kills; `main` refills the rewind fuel when
    /// it passes its high water.
    stage_clears: u8 = 0,
    /// `game_tick` when the last boss died (0 = never).
    clear_tick: u32 = 0,
};

pub fn update() void {
    const st = &world.w.waves;
    if (st.phase == .cleared and world.w.game_tick -% st.clear_tick >= breather) {
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

/// Called by the boss on the last tick of its death sequence.
pub fn boss_cleared() void {
    const st = &world.w.waves;
    st.stage_clears +%= 1;
    st.clear_tick = world.w.game_tick;
    st.loop +|= 1;
    st.phase = .cleared;
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

// Loop modifiers (SPEC.md section 9). The tables hold 1.1^k and 0.9^k for
// k in 0..8, built at comptime by repeated multiplication (no pow); later
// loops use the last entry, which the caps have already reached.
const loop_table_len = 8;
const speed_table: [loop_table_len]f32 = power_table(1.1);
const interval_table: [loop_table_len]f32 = power_table(0.9);
const max_bullet_speed: f32 = 2.0;

fn power_table(comptime base: f32) [loop_table_len]f32 {
    var t: [loop_table_len]f32 = @splat(1.0);
    for (1..loop_table_len) |k| t[k] = t[k - 1] * base;
    return t;
}

fn loop_index() usize {
    return @min(world.w.waves.loop, loop_table_len - 1);
}

/// 1.1^loop (uncapped); use `bullet_speed` for a capped speed.
pub fn speed_mul() f32 {
    return speed_table[loop_index()];
}

/// `base` * 1.1^loop, capped at 2.0 px/tick. Loop 0 returns `base`.
pub fn bullet_speed(base: f32) f32 {
    if (world.w.waves.loop == 0) return base;
    return @min(base * speed_mul(), max_bullet_speed);
}

/// `base` * 0.9^loop rounded, floored at `base` / 2 (and at 1). Loop 0
/// returns `base`.
pub fn fire_interval(base: u32) u32 {
    if (world.w.waves.loop == 0) return base;
    const scaled: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(base)) * interval_table[loop_index()]));
    return @max(scaled, base / 2, 1);
}

/// Extra HP for beetles and spiders at spawn: one per completed stage.
pub fn extra_hp() u8 {
    return world.w.waves.loop;
}

fn pick(lo: i32, hi: i32, y: i16) f32 {
    return @floatFromInt(if (y == random) rng.range(lo, hi) else y);
}

fn run(e: Entry) void {
    switch (e.kind) {
        .gnat => enemies.spawn_gnat_string(pick(min_y, max_y, e.y)),
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
