//! M1 spawner: an intro, then a looping table of gnat strings.
const enemies = @import("enemies.zig");
const rng = @import("rng.zig");

const Placement = enum {
    /// String at the entry's fixed y.
    fixed,
    /// String at a random y in [16, 104].
    random,
    /// Two strings at a random y and y + 32.
    random_double,
};

const Entry = struct { at: u32, place: Placement, y: i32 = 0 };

/// Runs once at the start of a game.
const intro = [_]Entry{
    .{ .at = 0, .place = .fixed, .y = 40 },
    .{ .at = 0, .place = .fixed, .y = 80 },
};

/// Repeats every `loop_len` ticks, starting at `loop_start`: one string every
/// 150 ticks, every third one doubled.
const loop = [_]Entry{
    .{ .at = 0, .place = .random },
    .{ .at = 150, .place = .random },
    .{ .at = 300, .place = .random_double },
};
const loop_start: u32 = 150;
const loop_len: u32 = 450;

const min_y = 16;
const max_y = 104;
const double_gap = 32;

var t: u32 = 0;

pub fn reset() void {
    t = 0;
}

pub fn update() void {
    for (intro) |e| {
        if (e.at == t) run(e);
    }
    if (t >= loop_start) {
        const lt = (t - loop_start) % loop_len;
        for (loop) |e| {
            if (e.at == lt) run(e);
        }
    }
    t += 1;
}

fn run(e: Entry) void {
    switch (e.place) {
        .fixed => enemies.spawn_gnat_string(@floatFromInt(e.y)),
        .random => enemies.spawn_gnat_string(@floatFromInt(rng.range(min_y, max_y))),
        .random_double => {
            // Keep the lower string inside the range too.
            const y = rng.range(min_y, max_y - double_gap);
            enemies.spawn_gnat_string(@floatFromInt(y));
            enemies.spawn_gnat_string(@floatFromInt(y + double_gap));
        },
    }
}
