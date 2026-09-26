//! Spawner: the SPEC.md section 9 stage-1 table as data, through the 54 s
//! entry. At 66 s (3960 ticks) the table wraps to t = 0; M3 inserts the
//! warning and the boss there and adds a loop counter.
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

/// 66 s: the table starts over (boss slot in M3).
pub const stage_len: u32 = s(66);

const min_y = 16;
const max_y = 104;
const spider_min_x = 64;
const spider_max_x = 136;

/// Spawner state, stored in `world.w.waves`.
pub const State = struct {
    /// Ticks since the start of the current pass through the table.
    t: u32 = 0,
    /// Index of the next entry of `stage1` to run.
    next: u8 = 0,
};

pub fn update() void {
    const st = &world.w.waves;
    while (st.next < stage1.len and stage1[st.next].at <= st.t) {
        run(stage1[st.next]);
        st.next += 1;
    }
    st.t += 1;
    if (st.t >= stage_len) st.* = .{};
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
