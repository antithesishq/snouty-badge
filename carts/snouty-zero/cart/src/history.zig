//! The Antithesis part (SPEC 5.4): a ring of World keyframes every 30 game
//! ticks and a ring of logged button words, so any tick of the last few
//! seconds can be rebuilt exactly by copying a keyframe and replaying the
//! log through `sim.simulate`. History is meta-state: it lives here, not
//! in the World, and is never rewound. The design is the bugs cart's.
const std = @import("std");
const world = @import("world.zig");
const sim = @import("sim.zig");

pub const keyframe_count = 16;
pub const keyframe_every: u32 = 30;
pub const log_len = 512;
pub const invalid: u32 = 0xFFFF_FFFF;

/// slot = (tick / 30) % 16; `keyframe_tick` says which tick a slot holds.
var keyframes: [keyframe_count]world.World = undefined;
var keyframe_tick: [keyframe_count]u32 = @splat(invalid);
/// Buttons used for tick t, at log[t % 512].
var log: [log_len]u16 = @splat(0);

/// New race: all keyframes invalid.
pub fn reset() void {
    keyframe_tick = @splat(invalid);
    log = @splat(0);
}

fn slot_of(tick: u32) usize {
    return (tick / keyframe_every) % keyframe_count;
}

/// Called before each live racing tick with the buttons that tick gets:
/// logs them and, every 30 ticks, saves the world as it is now (the state
/// at the start of this tick).
pub fn record(buttons: world.Buttons) void {
    const t = world.w.tick;
    log[t % log_len] = @bitCast(buttons);
    if (t % keyframe_every == 0) checkpoint();
}

/// Saves the world as it is now as the keyframe of the current tick.
/// Called by `record` and after anything outside `simulate` edits the
/// World (the resume immunity), so no later restore replays across the edit.
pub fn checkpoint() void {
    const t = world.w.tick;
    const i = slot_of(t);
    keyframes[i] = world.w;
    keyframe_tick[i] = t;
}

/// Oldest tick a restore can reach, or the current tick with no keyframe.
pub fn earliest_tick() u32 {
    var best: u32 = invalid;
    for (keyframe_tick) |t| {
        if (t != invalid and t < best) best = t;
    }
    return if (best == invalid) world.w.tick else best;
}

/// Rebuilds the world as it was at the start of tick `tick`: copies the
/// newest keyframe at or before it, then replays the logged buttons of
/// the ticks in between. Drops keyframes newer than `tick` (the future
/// that was rewound away). False (world untouched) if out of range.
pub fn restore(tick: u32) bool {
    if (tick > world.w.tick) return false;
    var best: ?usize = null;
    for (keyframe_tick, 0..) |t, i| {
        if (t == invalid or t > tick) continue;
        if (best == null or t > keyframe_tick[best.?]) best = i;
    }
    const i = best orelse return false;
    const kf_tick = keyframe_tick[i];
    if (tick - kf_tick >= log_len) return false;
    world.w = keyframes[i];
    while (world.w.tick < tick) {
        sim.simulate(@bitCast(log[world.w.tick % log_len]));
    }
    for (&keyframe_tick) |*t| {
        if (t.* != invalid and t.* > tick) t.* = invalid;
    }
    return true;
}

// --- Tests -------------------------------------------------------------------

const track = @import("track.zig");
const ai = @import("ai.zig");

// A scripted run: the autopilot with an occasional lean, logged through
// `record`, keeping a copy of the world at every tick.
test "restore(t) equals the direct state at t for every t" {
    const alloc = std.testing.allocator;
    const n: u32 = 600;
    const states = try alloc.alloc(world.World, n + 1);
    defer alloc.free(states);
    sim.reset(&track.cold_aisle, 11);
    while (world.w.phase == .countdown) sim.simulate(.{});
    reset();
    for (0..n) |k| {
        states[k] = world.w;
        var b = ai.drive(&world.w.machines[0], 0);
        if ((k / 50) % 4 == 1) b.right = true;
        if ((k / 70) % 5 == 2) b.up = true;
        record(b);
        sim.simulate(b);
    }
    states[n] = world.w;
    const t_end = world.w.tick;
    const t0 = t_end - n;
    // Every reachable tick, newest first (restore drops the future, so go backwards).
    var t: u32 = t_end;
    var checked: u32 = 0;
    while (t > t0) : (t -= 1) {
        if (t < earliest_tick()) break;
        try std.testing.expect(restore(t));
        try std.testing.expect(sim.worlds_equal(&states[t - t0], &world.w));
        checked += 1;
    }
    // 16 keyframes every 30 ticks cover 480 ticks: at least 400 restorable.
    try std.testing.expect(checked >= 400);
}
