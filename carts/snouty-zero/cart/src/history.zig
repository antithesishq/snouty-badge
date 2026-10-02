//! The Antithesis part (SPEC 5.4): a ring of World keyframes every 30 game
//! ticks and a ring of logged button words, so any tick of the last few
//! seconds can be rebuilt exactly by copying a keyframe and replaying the
//! log through `sim.simulate`. History is meta-state: it lives here, not
//! in the World, and is never rewound. The design is the bugs cart's.
const std = @import("std");
const world = @import("world.zig");
const sim = @import("sim.zig");

pub const keyframe_count = 8;
pub const keyframe_every: u32 = 30;
/// Extra slots for `checkpoint` keyframes (after a rewind resume), so they
/// never evict the periodic keyframe of their own window.
pub const extra_count = 4;
pub const log_len = 512;
pub const invalid: u32 = 0xFFFF_FFFF;

/// slot = (tick / 30) % 16; `keyframe_tick` says which tick a slot holds.
var keyframes: [keyframe_count + extra_count]world.World = undefined;
var keyframe_tick: [keyframe_count + extra_count]u32 = @splat(invalid);
var extra_next: usize = 0;
/// Buttons used for tick t, at log[t % 512].
var log: [log_len]u16 = @splat(0);

// --- Window cache (M4): states every `cache_step` ticks of the window the
// race is in and of the two windows below it, so a rewind frame replays at
// most cache_step - 1 ticks instead of up to 29 from a keyframe. Live play
// fills the top window; a finished window slides down; while rewinding,
// `prefill` rebuilds the windows below from their keyframes a few ticks per
// frame. Two prefilled windows are kept because a checkpoint window (made
// at a rewind resume) can be only a few ticks long and is crossed in one
// frame. Keyframes stay the fallback.
pub const cache_step: u32 = 3;
pub const cache_len = keyframe_every / cache_step; // 10
pub const window_count = 3;

const Window = struct {
    base: u32 = invalid,
    /// Entries 0..filled-1 are valid: entry k is the state at the start of tick base + 3k.
    filled: u8 = 0,
    /// Prefill in progress: the replay tick (invalid when complete or not prefilling).
    replay_tick: u32 = invalid,
    states: [cache_len]world.World = undefined,
};
/// Left undefined (so the 16 KB sit in .bss, not .data) until `reset`.
var windows: [window_count]Window = undefined;
/// order[0] is the current window, order[1] the one below it, order[2] below that.
var order: [window_count]usize = .{ 0, 1, 2 };
/// Scratch for the prefill replay (the live world is swapped out meanwhile).
var replay_world: world.World = undefined;
/// Counters for the debug exports: keyframe rebuilds since reset, and
/// simulate calls made by restore/prefill this frame (main clears it).
pub var rebuilds: u32 = 0;
pub var replay_calls: u32 = 0;

fn fresh(base: u32) Window {
    return .{ .base = base, .states = undefined };
}

/// New race: all keyframes and windows invalid.
pub fn reset() void {
    keyframe_tick = @splat(invalid);
    log = @splat(0);
    for (&windows) |*wnd| wnd.* = fresh(invalid);
    order = .{ 0, 1, 2 };
    extra_next = 0;
    rebuilds = 0;
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
    if (t % keyframe_every == 0) {
        save_keyframe(slot_of(t));
    } else {
        cache_live(t);
    }
}

/// Store the live state into the current window if this tick is one of its entries.
fn cache_live(t: u32) void {
    const c = &windows[order[0]];
    if (c.base == invalid or t < c.base or t >= c.base + keyframe_every) return;
    const off = t - c.base;
    if (off % cache_step != 0) return;
    const k: u8 = @intCast(off / cache_step);
    if (k > c.filled) return; // a gap: should not happen, keep the cache honest
    c.states[k] = world.w;
    c.filled = k + 1;
}

/// Saves the world as it is now as a keyframe in one of the extra slots
/// and starts a new cache window there. Called after anything outside
/// `simulate` edits the World (the resume immunity), so no later restore
/// replays across the edit.
pub fn checkpoint() void {
    save_keyframe(keyframe_count + extra_next);
    extra_next = (extra_next + 1) % extra_count;
}

/// Keyframe of the current tick into slot `i`, plus a new window on top
/// (the current one slides down, the bottom one is dropped).
fn save_keyframe(i: usize) void {
    const t = world.w.tick;
    keyframes[i] = world.w;
    keyframe_tick[i] = t;
    if (windows[order[0]].base != t) {
        push_window(fresh(t));
    }
    windows[order[0]].states[0] = world.w;
    windows[order[0]].filled = 1;
}

/// The bottom buffer becomes the new top window.
fn push_window(wnd: Window) void {
    const bottom = order[window_count - 1];
    var i: usize = window_count - 1;
    while (i > 0) : (i -= 1) order[i] = order[i - 1];
    order[0] = bottom;
    windows[bottom] = wnd;
}

/// The top window is dropped; the ones below move up and the freed buffer
/// becomes the (invalid) bottom.
fn pop_window() void {
    const top = order[0];
    for (0..window_count - 1) |i| order[i] = order[i + 1];
    order[window_count - 1] = top;
    windows[top] = fresh(invalid);
}

/// Newest keyframe at or before `tick` (slot), or null.
fn keyframe_before(tick: u32) ?usize {
    var best: ?usize = null;
    for (keyframe_tick, 0..) |t, i| {
        if (t == invalid or t > tick) continue;
        if (best == null or t > keyframe_tick[best.?]) best = i;
    }
    return best;
}

/// Rebuild the top window from the keyframe covering `tick` while
/// replaying up to `tick`: the keyframe fallback that also refills the cache.
fn rebuild_top(tick: u32) bool {
    const i = keyframe_before(tick) orelse return false;
    const kf_tick = keyframe_tick[i];
    if (tick - kf_tick >= log_len) return false;
    rebuilds += 1;
    const wnd = &windows[order[0]];
    wnd.* = fresh(kf_tick);
    world.w = keyframes[i];
    wnd.states[0] = world.w;
    wnd.filled = 1;
    while (world.w.tick < tick) {
        sim.simulate(@bitCast(log[world.w.tick % log_len]));
        replay_calls += 1;
        const off = world.w.tick - kf_tick;
        if (off < keyframe_every and off % cache_step == 0) {
            const k: u8 = @intCast(off / cache_step);
            wnd.states[k] = world.w;
            wnd.filled = k + 1;
        }
    }
    return true;
}

/// Rewinding: rebuild the windows below the top from their keyframes,
/// `ticks` replay ticks at a time (called once per rewind frame). Works on
/// the first incomplete window below; nothing to do once both are complete
/// or there is no older keyframe.
pub fn prefill(ticks: u32) void {
    var budget = ticks;
    var level: usize = 1;
    while (level < window_count and budget > 0) : (level += 1) {
        const above = &windows[order[level - 1]];
        if (above.base == invalid or above.base == 0) return;
        const o = &windows[order[level]];
        if (o.base != invalid and o.base < above.base and o.replay_tick == invalid) continue; // complete
        if (o.base == invalid or o.base >= above.base) {
            // Start: the newest keyframe below the window above.
            const i = keyframe_before(above.base - 1) orelse return;
            o.* = fresh(keyframe_tick[i]);
            o.filled = 1;
            o.replay_tick = keyframe_tick[i];
            o.states[0] = keyframes[i];
            replay_world = keyframes[i];
            if (o.replay_tick + 1 >= above.base) o.replay_tick = invalid;
        }
        const saved = world.w;
        world.w = replay_world;
        while (budget > 0 and o.replay_tick != invalid) : (budget -= 1) {
            sim.simulate(@bitCast(log[world.w.tick % log_len]));
            replay_calls += 1;
            o.replay_tick = world.w.tick;
            const off = o.replay_tick - o.base;
            if (off % cache_step == 0 and off < keyframe_every) {
                const k: u8 = @intCast(off / cache_step);
                o.states[k] = world.w;
                o.filled = k + 1;
            }
            if (o.replay_tick + 1 >= above.base or o.filled >= cache_len) o.replay_tick = invalid;
        }
        replay_world = world.w;
        world.w = saved;
    }
}

/// Entries filled in the window just below the top (tests, debug).
pub fn other_filled() u32 {
    return windows[order[1]].filled;
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
    // Slide down to the window holding `tick` (dropping the ones above).
    var hops: usize = 0;
    while (hops < window_count) : (hops += 1) {
        const c = &windows[order[0]];
        if (c.base != invalid and tick >= c.base) break;
        const o = &windows[order[1]];
        const covers = o.base != invalid and tick >= o.base and tick < o.base + keyframe_every and tick < o.base + @as(u32, o.filled) * cache_step;
        if (!covers) break;
        pop_window();
    }
    const c = &windows[order[0]];
    if (c.base == invalid or tick < c.base or tick - c.base >= keyframe_every or (tick - c.base) / cache_step >= c.filled) {
        if (!rebuild_top(tick)) return false;
        drop_future(tick);
        return true;
    }
    const k: u32 = (tick - c.base) / cache_step;
    world.w = c.states[k];
    while (world.w.tick < tick) {
        sim.simulate(@bitCast(log[world.w.tick % log_len]));
        replay_calls += 1;
    }
    c.filled = @intCast(k + 1);
    drop_future(tick);
    return true;
}

/// Drops keyframes newer than `tick` (the future that was rewound away).
fn drop_future(tick: u32) void {
    for (&keyframe_tick) |*t| {
        if (t.* != invalid and t.* > tick) t.* = invalid;
    }
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
    // 8 keyframes every 30 ticks cover 240 ticks (the 180-tick bar needs 210): at least 200 restorable.
    try std.testing.expect(checked >= 200);
}

test "a frame-by-frame rewind with prefill matches and stays cheap" {
    const alloc = std.testing.allocator;
    const n: u32 = 400;
    const states = try alloc.alloc(world.World, n + 1);
    defer alloc.free(states);
    sim.reset(&track.cold_aisle, 11);
    while (world.w.phase == .countdown) sim.simulate(.{});
    reset();
    for (0..n) |k| {
        states[k] = world.w;
        var b = ai.drive(&world.w.machines[0], 0);
        if ((k / 40) % 3 == 1) b.left = true;
        record(b);
        sim.simulate(b);
    }
    states[n] = world.w;
    const t_end = world.w.tick;
    const t0 = t_end - n;
    // Rewind 2 ticks a frame as main does, prefilling 6 ticks a frame;
    // every restore must come from a cache window (no keyframe rebuild),
    // which `sim_calls` would show: count simulate calls through the log.
    var t: u32 = t_end;
    var frames: u32 = 0;
    while (t >= t0 + 2 and t - 2 >= earliest_tick()) : (frames += 1) {
        t -= 2;
        try std.testing.expect(restore(t));
        try std.testing.expect(sim.worlds_equal(&states[t - t0], &world.w));
        prefill(6);
    }
    // 240 ticks of coverage at 2 a frame: about 115 frames.
    try std.testing.expect(frames >= 100);
    // Resume there with a checkpoint (as main does), play 100 more ticks,
    // rewind 200 at 4 a frame: every restore must come from the cache.
    checkpoint();
    for (0..100) |_| {
        const b = ai.drive(&world.w.machines[0], 0);
        record(b);
        sim.simulate(b);
    }
    const before = rebuilds;
    var t2 = world.w.tick;
    var f2: u32 = 0;
    while (f2 < 50 and t2 >= 4 and t2 - 4 >= earliest_tick()) : (f2 += 1) {
        t2 -= 4;
        try std.testing.expect(restore(t2));
        prefill(6);
    }
    try std.testing.expectEqual(before, rebuilds);
    // Memory figures (PLAN.md M4 status): World 544 B, windows 16.4 KB, keyframes 6.5 KB.
    try std.testing.expect(@sizeOf(world.World) <= 640);
}
