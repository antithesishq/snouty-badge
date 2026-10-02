//! Rewind core (SPEC.md 9.2, 9.3; PLAN.md "Contract: rewind core"):
//! keyframes + input log + deterministic replay. Pure sim-side code, no
//! cart-api, so `zig test cart/src/rewind.zig` runs on the host. All state
//! is module-level fixed pools (`.bss`), no allocation.
//!
//! Tick conventions (the whole module hangs on these):
//!
//! - "State at tick t" is a GameState with `s.tick == t`. `sim.step`
//!   applied with input `b` turns state t into state t+1.
//! - `log_input(t, b)` records the input that `sim.step` applies to state t
//!   (so it is called with `t == s.tick`, *before* the step). It lives at
//!   `inputs[t % input_len]`.
//! - `after_step(s)` is called after the step (`s.tick` is now t+1). It
//!   moves the forward head to `s.tick` and, when `s.tick % keyframe_every
//!   == 0`, stores `s` as the keyframe of that tick.
//! - `reset(s)` stores `s` (normally tick 0, any tick works) as the first
//!   keyframe; it is the base of the history.
//! - Rebuilding state T from keyframe K (K <= T) copies the keyframe and
//!   applies inputs K, K+1, .., T-1 (T-K steps).
//! - Keyframe ring slot = (tick / keyframe_every) % keyframe_count, and
//!   every slot remembers its tick in `kf_tick` (`none` = empty).
//! - Span cache: one "block" of consecutive states starting at a keyframe.
//!   `cache[i]` is the state at tick `cache_lo + i` for `i < cache_n`, with
//!   `cache[0]` a copy of the keyframe at `cache_lo`. So the block of
//!   keyframe K covers ticks [K, K + span) (or up to the head, if nearer).
//!   Going back from K to K-1 refills the cache with the block of the
//!   previous keyframe, ending at K-1 (29 steps).
//! - `earliest()` is the oldest tick still reachable: the oldest stored
//!   keyframe whose inputs from its tick up to the head are still in the
//!   input ring. In steady state the keyframe ring binds first: 21
//!   keyframes span 600 ticks, so the reachable window is 600..629 ticks
//!   (head - floor(head/30)*30 + 600), always < input_len = 640.
//!   Rewinding 600 ticks is therefore always possible once the game has
//!   run that long; the rewind meter (max 600) is the gameplay bound.
//! - Patches: a commit changes the live state out of band (the meter is
//!   drained, `rewinds` is bumped, `revive` after a rewind out of death),
//!   which a replay from an earlier keyframe would not reproduce. So `commit` records the change as a patch on the
//!   tick it committed at (`patch[t % input_len]`, valid while
//!   `patch_tick[..] == t`), and "state at tick t" always means "with the
//!   patch of tick t applied". Replay applies patches after each step,
//!   keyframes are stored pre-patch (they come from `after_step`), and a
//!   commit drops the patches of the abandoned future like it drops
//!   keyframes. A patch holds absolute values (the meter and the rewind
//!   count to set), so applying it to a state that already has it is a
//!   no-op: a second patch at the same tick (the attract takeover's
//!   `set_meter` right after a commit) cannot count a rewind twice.
const std = @import("std");
const state = @import("state.zig");
const sim = @import("sim.zig");
const levels = @import("levels.zig");

const GameState = state.GameState;
const Buttons = state.Buttons;
const Level = levels.Level;

pub const keyframe_every: u32 = 30;
pub const keyframe_count: u32 = 21;
pub const input_len: u32 = 640;
pub const span: u32 = keyframe_every;

const none: u32 = std.math.maxInt(u32);

/// Keyframe ring, slot = (tick / keyframe_every) % keyframe_count.
var kf: [keyframe_count]GameState = undefined;
/// Tick of each keyframe slot, `none` when empty.
var kf_tick: [keyframe_count]u32 = @splat(none);
/// Input applied to state t, at inputs[t % input_len].
var inputs: [input_len]Buttons = undefined;
/// Out-of-band changes made at a commit, by tick (see the patch note above):
/// the values `rewind_meter`, `rewinds`, `player.hp` and `player.grace`
/// take at that tick. Absolute, not deltas, so applying a patch is
/// idempotent.
const Patch = struct { meter: u16, rewinds: u16, hp: i16, grace: u8 };
var patch: [input_len]Patch = undefined;
var patch_tick: [input_len]u32 = @splat(none);
/// Span cache: cache[i] = state at tick cache_lo + i, i < cache_n.
var cache: [span]GameState = undefined;
var cache_lo: u32 = 0;
var cache_n: u32 = 0;

/// Tick of the newest live state (after the last `after_step`/`reset`/`commit`).
var head: u32 = 0;
/// Inputs are logged for ticks [base, logged_hi).
var base: u32 = 0;
var logged_hi: u32 = 0;
/// Tick of `current()` while rewinding.
var cur: u32 = 0;
var active: bool = false;

/// Self-check failures (SPEC.md 9.3), exported by main as `debug_desync`.
pub var desyncs: u32 = 0;

/// Bytes of the three big pools (keyframes + span cache + inputs), plus
/// the keyframe tick table.
pub const memory_bytes = @sizeOf(@TypeOf(kf)) + @sizeOf(@TypeOf(cache)) +
    @sizeOf(@TypeOf(inputs)) + @sizeOf(@TypeOf(kf_tick)) +
    @sizeOf(@TypeOf(patch)) + @sizeOf(@TypeOf(patch_tick));

comptime {
    if (memory_bytes > 80 * 1024) @compileError("rewind pools exceed 80 KB; GameState grew too much");
    // A block (keyframe to next keyframe) must fit the span cache, and the
    // input ring must cover the whole keyframe ring window.
    std.debug.assert(span >= keyframe_every);
    std.debug.assert(input_len >= keyframe_every * keyframe_count);
}

fn slot_of(tick: u32) usize {
    return (tick / keyframe_every) % keyframe_count;
}

fn keyframe(tick: u32) ?*const GameState {
    const i = slot_of(tick);
    return if (kf_tick[i] == tick) &kf[i] else null;
}

fn store_keyframe(s: *const GameState) void {
    const i = slot_of(s.tick);
    kf[i] = s.*;
    kf_tick[i] = s.tick;
}

/// Oldest tick whose input is still in the ring (and was ever logged).
fn inputs_lo() u32 {
    return @max(base, logged_hi -| input_len);
}

/// Largest stored keyframe tick <= t that can be replayed (its inputs are
/// all still logged), or null.
fn block_start(t: u32) ?u32 {
    const lo = inputs_lo();
    var best: ?u32 = null;
    for (kf_tick) |k| {
        if (k == none or k > t or k < lo) continue;
        if (best == null or k > best.?) best = k;
    }
    return best;
}

/// Apply the patch of tick `s.tick`, if one is recorded.
fn apply_patch(s: *GameState) void {
    const i = s.tick % input_len;
    if (patch_tick[i] != s.tick) return;
    s.player.rewind_meter = patch[i].meter;
    s.rewinds = patch[i].rewinds;
    s.player.hp = patch[i].hp;
    s.player.grace = patch[i].grace;
}

/// Fill the span cache with states [k, hi] replayed from keyframe k.
fn fill(level: *const Level, k: u32, hi: u32) bool {
    const src = keyframe(k) orelse return false;
    if (hi < k or hi - k >= span) return false;
    cache[0] = src.*;
    apply_patch(&cache[0]);
    var t = k;
    while (t < hi) : (t += 1) {
        const i = t - k;
        cache[i + 1] = cache[i];
        sim.step(&cache[i + 1], level, inputs[t % input_len]);
        apply_patch(&cache[i + 1]);
    }
    cache_lo = k;
    cache_n = hi - k + 1;
    return true;
}

// ---------------------------------------------------------------- forward play

/// New history: drops everything and stores `s` as the first keyframe.
pub fn reset(s: *const GameState) void {
    kf_tick = @splat(none);
    patch_tick = @splat(none);
    store_keyframe(s);
    head = s.tick;
    base = s.tick;
    logged_hi = s.tick;
    cache_n = 0;
    active = false;
}

/// Record the input `sim.step` is about to apply to the state at `tick`
/// (call with `tick == s.tick`, before the step).
pub fn log_input(tick: u32, b: Buttons) void {
    inputs[tick % input_len] = b;
    logged_hi = tick + 1;
}

/// Call after each forward `sim.step`: advances the head and stores a
/// keyframe every `keyframe_every` ticks.
pub fn after_step(s: *const GameState) void {
    head = s.tick;
    if (s.tick % keyframe_every == 0) store_keyframe(s);
}

/// Oldest tick still reachable by `back` (bounded by both rings). Equals
/// the head when nothing is reachable.
pub fn earliest() u32 {
    const lo = inputs_lo();
    var best: u32 = head;
    for (kf_tick) |k| {
        if (k == none or k < lo or k > head) continue;
        if (k < best) best = k;
    }
    return best;
}

// ---------------------------------------------------------------- rewind

/// Enter rewind at `s.tick` (the live state, normally `== head`). Replays
/// the block that contains `s.tick` into the span cache (<= 29 steps) and
/// checks the replay against `s` (a mismatch counts a desync; the live
/// state is then used as the current state).
pub fn begin(s: *const GameState, level: *const Level) void {
    active = true;
    cur = s.tick;
    const k = block_start(s.tick);
    if (k == null or !fill(level, k.?, s.tick)) {
        cache[0] = s.*;
        cache_lo = s.tick;
        cache_n = 1;
        return;
    }
    const top = &cache[cache_n - 1];
    if (sim.hash(top) != sim.hash(s)) {
        desyncs += 1;
        top.* = s.*;
    }
}

/// Step one tick back: returns the state at `current().tick - 1`, or null
/// (and stays put) once `earliest()` is reached.
pub fn back(level: *const Level) ?*const GameState {
    if (!active or cur == 0 or cur - 1 < earliest()) return null;
    const t = cur - 1;
    if (t < cache_lo or t >= cache_lo + cache_n) {
        const k = block_start(t) orelse return null;
        if (!fill(level, k, t)) return null;
    }
    cur = t;
    return &cache[t - cache_lo];
}

/// The state being shown while rewinding.
pub fn current() *const GameState {
    return &cache[cur - cache_lo];
}

/// Leave rewind: the current state becomes live (copied into `s`) with
/// its meter set to `meter` and `rewinds` bumped if `count_rewind`; both
/// are recorded as the patch of this tick so replays reproduce them.
/// Keyframes, patches and inputs after it are dropped so forward play
/// continues on the new timeline.
pub fn commit(s: *GameState, meter: u16, count_rewind: bool) void {
    s.* = current().*;
    for (&kf_tick) |*k| {
        if (k.* != none and k.* > cur) k.* = none;
    }
    for (&patch_tick) |*t| {
        if (t.* != none and t.* > cur) t.* = none;
    }
    const i = cur % input_len;
    // current() already carries any earlier patch of this tick.
    patch[i] = .{ .meter = meter, .rewinds = s.rewinds + @intFromBool(count_rewind), .hp = s.player.hp, .grace = s.player.grace };
    patch_tick[i] = cur;
    apply_patch(s);
    head = cur;
    logged_hi = @min(logged_hi, cur);
    cache_n = 0;
    active = false;
}

/// Out-of-band meter change while playing (the attract-mode takeover
/// refills it, PLAN.md M5): recorded as the patch of `s.tick` so a replay
/// reproduces it and the keyframe self-check keeps agreeing. The rewind
/// count is kept as `s` has it (`s` already carries the patch of a commit
/// at this very tick, so its count is that patch's). Only valid when not
/// rewinding and `s.tick == head`.
pub fn set_meter(s: *GameState, meter: u16) void {
    std.debug.assert(!active and s.tick == head);
    const i = s.tick % input_len;
    patch[i] = .{ .meter = meter, .rewinds = s.rewinds, .hp = s.player.hp, .grace = s.player.grace };
    patch_tick[i] = s.tick;
    apply_patch(s);
}

/// The post-death revive (`sim.death_grace`, `sim.death_hp_floor`) at the
/// live tick, called by main.zig right after the commit of a rewind out of
/// death: recorded as the patch of `s.tick` like `set_meter`, keeping the
/// meter and count `s` already has.
pub fn revive(s: *GameState) void {
    std.debug.assert(!active and s.tick == head);
    const i = s.tick % input_len;
    patch[i] = .{
        .meter = s.player.rewind_meter,
        .rewinds = s.rewinds,
        .hp = @max(s.player.hp, sim.death_hp_floor),
        .grace = sim.death_grace,
    };
    patch_tick[i] = s.tick;
    apply_patch(s);
}

pub fn rewinding() bool {
    return active;
}

// ---------------------------------------------------------------- self-check

/// SPEC.md 9.3: at a keyframe tick, re-simulate from the previous keyframe
/// with the logged inputs and compare with `s` (and with the stored
/// keyframe of `s.tick`, if any). Returns true when they agree or when
/// there is nothing to check; false (and `desyncs += 1`) on a mismatch.
/// Uses the span cache as scratch, so not during a rewind.
pub fn check(s: *const GameState, level: *const Level) bool {
    if (active or s.tick == 0) return true;
    const k = block_start(s.tick - 1) orelse return true;
    if (s.tick - k > span) return true;
    const h = sim.hash(s);
    var ok = true;
    if (keyframe(s.tick)) |stored| ok = sim.hash(stored) == h;
    if (fill(level, k, s.tick - 1)) {
        var last = cache[cache_n - 1];
        sim.step(&last, level, inputs[(s.tick - 1) % input_len]);
        apply_patch(&last);
        if (sim.hash(&last) != h) ok = false;
    }
    cache_n = 0;
    if (!ok) desyncs += 1;
    return ok;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn script(seed: u32, tick: u32) Buttons {
    var x = seed ^ (tick / 20 *% 0x9E3779B9);
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return .{
        .up = x & 3 != 0,
        .down = x & 3 == 0 and x & 4 != 0,
        .left = x & 0x30 == 0x10,
        .right = x & 0x30 == 0x20,
        .a = x & 0x300 == 0x100,
    };
}

const L = &levels.all[0];

/// Commit that changes nothing but the timeline (the pre-M4 behaviour).
fn commit_plain(s: *GameState) void {
    commit(s, current().player.rewind_meter, false);
}

fn fresh(s: *GameState) void {
    sim.init(s, L, 0, 1234);
}

/// Forward play as main.zig does it: log, step, after_step.
fn play(s: *GameState, seed: u32, until: u32) void {
    while (s.tick < until) {
        const b = script(seed, s.tick);
        log_input(s.tick, b);
        sim.step(s, L, b);
        after_step(s);
    }
}

/// Straight run without the rewind module, recording the hash at every tick.
fn straight(hashes: []u32, seed: u32) GameState {
    var s: GameState = undefined;
    fresh(&s);
    hashes[0] = sim.hash(&s);
    var t: u32 = 0;
    while (t + 1 < hashes.len) : (t += 1) {
        sim.step(&s, L, script(seed, t));
        hashes[t + 1] = sim.hash(&s);
    }
    return s;
}

test "memory budget" {
    try testing.expect(memory_bytes <= 80 * 1024);
}

test "rewind 100 across keyframes, commit, replay forward matches a straight run" {
    var ref: [301]u32 = undefined;
    const want = straight(&ref, 1);

    var s: GameState = undefined;
    fresh(&s);
    reset(&s);
    play(&s, 1, 300);
    try testing.expectEqual(ref[300], sim.hash(&s));

    begin(&s, L);
    try testing.expectEqual(@as(u32, 300), current().tick);
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const p = back(L) orelse return error.TestUnexpectedNull;
        try testing.expectEqual(300 - i - 1, p.tick);
        try testing.expectEqual(p, current());
        try testing.expectEqual(ref[p.tick], sim.hash(p));
        // Keyframe boundaries 270, 240 and 210 are crossed on the way.
        if (p.tick == 269 or p.tick == 239 or p.tick == 209)
            try testing.expectEqual(p.tick - 29, cache_lo);
    }
    try testing.expectEqual(@as(u32, 200), current().tick);
    try testing.expectEqual(@as(u32, 180), cache_lo);

    commit_plain(&s);
    try testing.expect(!rewinding());
    try testing.expectEqual(@as(u32, 200), s.tick);
    try testing.expectEqual(ref[200], sim.hash(&s));
    for (kf_tick) |k| try testing.expect(k == none or k <= 200);

    play(&s, 1, 300);
    try testing.expectEqual(ref[300], sim.hash(&s));
    try testing.expect(std.mem.eql(u8, std.mem.asBytes(&want), std.mem.asBytes(&s)));

    // A second rewind from the replayed timeline works too.
    begin(&s, L);
    i = 0;
    while (i < 75) : (i += 1) _ = back(L) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u32, 225), current().tick);
    try testing.expectEqual(ref[225], sim.hash(current()));
}

test "back returns null exactly at earliest" {
    var ref: [301]u32 = undefined;
    _ = straight(&ref, 3);
    var s: GameState = undefined;
    fresh(&s);
    reset(&s);
    play(&s, 3, 300);
    try testing.expectEqual(@as(u32, 0), earliest());
    begin(&s, L);
    var n: u32 = 0;
    while (back(L)) |p| {
        n += 1;
        try testing.expectEqual(ref[p.tick], sim.hash(p));
    }
    try testing.expectEqual(@as(u32, 300), n);
    try testing.expectEqual(earliest(), current().tick);
    try testing.expect(back(L) == null);
    try testing.expectEqual(@as(u32, 0), current().tick);
    try testing.expectEqual(ref[0], sim.hash(current()));
}

test "700 ticks wrap the rings; rewind is bounded by the keyframe ring" {
    var ref: [701]u32 = undefined;
    _ = straight(&ref, 5);
    var s: GameState = undefined;
    fresh(&s);
    reset(&s);
    play(&s, 5, 700);

    // Newest keyframe 690, 21 slots back to 690 - 600 = 90. The input ring
    // alone would allow 700 - 640 = 60, so the keyframe ring binds: 610.
    const newest = 700 / keyframe_every * keyframe_every;
    const kf_bound = newest - (keyframe_count - 1) * keyframe_every;
    const in_bound = 700 - input_len;
    const expected: u32 = @max(kf_bound, (in_bound + keyframe_every - 1) / keyframe_every * keyframe_every);
    try testing.expectEqual(@as(u32, 90), expected);
    try testing.expectEqual(expected, earliest());

    begin(&s, L);
    var n: u32 = 0;
    while (back(L)) |p| {
        n += 1;
        try testing.expectEqual(ref[p.tick], sim.hash(p));
    }
    try testing.expectEqual(@as(u32, 700 - expected), n);
    try testing.expect(n >= 600);
    try testing.expectEqual(expected, current().tick);
}

test "the input ring bounds the rewind when keyframes reach further" {
    // In steady state the keyframe ring always binds first (600..629 <
    // 640), so simulate lost inputs by moving the log's high-water mark.
    var s: GameState = undefined;
    fresh(&s);
    reset(&s);
    play(&s, 7, 400);
    try testing.expectEqual(@as(u32, 0), earliest());
    logged_hi = 400 + input_len - 100; // pretend inputs before tick 300 were overwritten
    try testing.expectEqual(@as(u32, 300), earliest());
    logged_hi = 400;
}

test "check is true on a clean run and false after poking a keyframe" {
    desyncs = 0;
    var s: GameState = undefined;
    fresh(&s);
    reset(&s);
    while (s.tick < 300) {
        const b = script(9, s.tick);
        log_input(s.tick, b);
        sim.step(&s, L, b);
        after_step(&s);
        if (s.tick % keyframe_every == 0) try testing.expect(check(&s, L));
    }
    try testing.expectEqual(@as(u32, 0), desyncs);

    // Poke the previous keyframe (270): the replay to 300 now diverges.
    const slot = slot_of(270);
    try testing.expectEqual(@as(u32, 270), kf_tick[slot]);
    kf[slot].rng ^= 0x40;
    try testing.expect(!check(&s, L));
    try testing.expectEqual(@as(u32, 1), desyncs);
    kf[slot].rng ^= 0x40;
    try testing.expect(check(&s, L));

    // Poking the stored keyframe of the checked tick is caught too.
    std.mem.asBytes(&kf[slot_of(300)])[20] ^= 1;
    try testing.expect(!check(&s, L));
    try testing.expectEqual(@as(u32, 2), desyncs);
    desyncs = 0;
}

test "commit onto a new timeline, keep playing, rewind again" {
    // Reference: seed 1 for ticks 0..204, seed 2 from 205 on.
    var ref: [331]u32 = undefined;
    {
        var r: GameState = undefined;
        fresh(&r);
        ref[0] = sim.hash(&r);
        var t: u32 = 0;
        while (t < 330) : (t += 1) {
            sim.step(&r, L, script(if (t < 205) 1 else 2, t));
            ref[t + 1] = sim.hash(&r);
        }
    }
    desyncs = 0;
    var s: GameState = undefined;
    fresh(&s);
    reset(&s);
    play(&s, 1, 300);
    begin(&s, L);
    var i: u32 = 0;
    while (i < 95) : (i += 1) _ = back(L).?;
    commit_plain(&s);
    try testing.expectEqual(@as(u32, 205), s.tick);
    try testing.expectEqual(@as(u32, 0), earliest());

    // Rewinding right after a commit, before the next keyframe exists.
    play(&s, 2, 208);
    begin(&s, L);
    try testing.expectEqual(@as(u32, 180), cache_lo);
    try testing.expectEqual(ref[207], sim.hash(back(L).?));
    commit_plain(&s);
    try testing.expectEqual(@as(u32, 207), s.tick);

    while (s.tick < 330) {
        const b = script(2, s.tick);
        log_input(s.tick, b);
        sim.step(&s, L, b);
        after_step(&s);
        if (s.tick % keyframe_every == 0) try testing.expect(check(&s, L));
    }
    try testing.expectEqual(ref[330], sim.hash(&s));
    try testing.expectEqual(@as(u32, 0), desyncs);

    begin(&s, L);
    var n: u32 = 0;
    while (back(L)) |p| : (n += 1) try testing.expectEqual(ref[p.tick], sim.hash(p));
    try testing.expectEqual(@as(u32, 330), n);
    try testing.expectEqual(@as(u32, 0), desyncs);
}

test "a commit's meter drain and rewind count survive replay and self-check" {
    // Reference: seed 1 to tick 300, rewind 100, resume at 200 with the
    // meter drained to 123 and one rewind counted, seed 2 onwards.
    var ref: [401]u32 = undefined;
    {
        var r: GameState = undefined;
        fresh(&r);
        ref[0] = sim.hash(&r);
        var t: u32 = 0;
        while (t < 200) : (t += 1) {
            sim.step(&r, L, script(1, t));
            ref[t + 1] = sim.hash(&r);
        }
        r.player.rewind_meter = 123;
        r.rewinds += 1;
        ref[200] = sim.hash(&r);
        while (t < 400) : (t += 1) {
            sim.step(&r, L, script(2, t));
            ref[t + 1] = sim.hash(&r);
        }
    }
    desyncs = 0;
    var s: GameState = undefined;
    fresh(&s);
    reset(&s);
    play(&s, 1, 300);
    begin(&s, L);
    var i: u32 = 0;
    while (i < 100) : (i += 1) _ = back(L).?;
    commit(&s, 123, true);
    try testing.expectEqual(@as(u16, 123), s.player.rewind_meter);
    try testing.expectEqual(@as(u16, 1), s.rewinds);
    try testing.expectEqual(ref[200], sim.hash(&s));

    // Forward through several keyframe checks; the first replays across
    // the commit from keyframe 180.
    while (s.tick < 400) {
        const b = script(2, s.tick);
        log_input(s.tick, b);
        sim.step(&s, L, b);
        after_step(&s);
        if (s.tick % keyframe_every == 0) try testing.expect(check(&s, L));
    }
    try testing.expectEqual(ref[400], sim.hash(&s));
    try testing.expectEqual(@as(u32, 0), desyncs);

    // Rewinding across the commit shows the patched states, and past it
    // the un-patched original ones.
    begin(&s, L);
    while (back(L)) |p| try testing.expectEqual(ref[p.tick], sim.hash(p));
    try testing.expectEqual(@as(u32, 0), current().tick);
    try testing.expectEqual(@as(u32, 0), desyncs);

    // Committing before the old commit drops its patch: replaying through
    // tick 200 on the new timeline no longer drains the meter.
    commit_plain(&s);
    try testing.expectEqual(@as(u32, 0), s.tick);
    play(&s, 1, 260);
    var r: GameState = undefined;
    fresh(&r);
    var t: u32 = 0;
    while (t < 260) : (t += 1) sim.step(&r, L, script(1, t));
    try testing.expectEqual(sim.hash(&r), sim.hash(&s));
    try testing.expectEqual(@as(u32, 0), desyncs);
    begin(&s, L);
    i = 0;
    while (i < 70) : (i += 1) _ = back(L).?;
    try testing.expectEqual(@as(u32, 190), current().tick);
    var r2: GameState = undefined;
    fresh(&r2);
    t = 0;
    while (t < 190) : (t += 1) sim.step(&r2, L, script(1, t));
    try testing.expectEqual(sim.hash(&r2), sim.hash(current()));
}

// Review 2026-10-01 G1: the attract takeover commits a rewind and then
// refills the meter at the same tick (main.zig take_over: end_rewind, then
// set_meter). The live state gets both patches applied; a replay applies
// the tick's patch once. They must agree.
test "a commit and set_meter at the same tick: live and replay agree" {
    // Reference: seed 1 to tick 250, the commit's count and the refill
    // applied once at 250, seed 2 onwards.
    var ref: [331]u32 = undefined;
    {
        var r: GameState = undefined;
        fresh(&r);
        ref[0] = sim.hash(&r);
        var t: u32 = 0;
        while (t < 250) : (t += 1) {
            sim.step(&r, L, script(1, t));
            ref[t + 1] = sim.hash(&r);
        }
        r.player.rewind_meter = 600;
        r.rewinds = 1;
        ref[250] = sim.hash(&r);
        while (t < 330) : (t += 1) {
            sim.step(&r, L, script(2, t));
            ref[t + 1] = sim.hash(&r);
        }
    }
    desyncs = 0;
    var s: GameState = undefined;
    fresh(&s);
    reset(&s);
    play(&s, 1, 300);
    begin(&s, L);
    var i: u32 = 0;
    while (i < 50) : (i += 1) _ = back(L).?;
    commit(&s, 550, true);
    set_meter(&s, 600);
    // Applying the tick's patch again (a second refill) changes nothing.
    set_meter(&s, 600);
    try testing.expectEqual(@as(u16, 1), s.rewinds);
    try testing.expectEqual(@as(u16, 600), s.player.rewind_meter);
    try testing.expectEqual(ref[250], sim.hash(&s));

    // The keyframe self-checks replay across tick 250 with its patch once.
    while (s.tick < 330) {
        const b = script(2, s.tick);
        log_input(s.tick, b);
        sim.step(&s, L, b);
        after_step(&s);
        if (s.tick % keyframe_every == 0) try testing.expect(check(&s, L));
    }
    try testing.expectEqual(ref[330], sim.hash(&s));
    try testing.expectEqual(@as(u32, 0), desyncs);

    // Rewinding back over the patch tick shows the same states as live play.
    begin(&s, L);
    try testing.expectEqual(@as(u32, 0), desyncs);
    while (back(L)) |p| try testing.expectEqual(ref[p.tick], sim.hash(p));
    try testing.expectEqual(@as(u32, 0), desyncs);
}

// Adrian, 2026-10-02: in a mob, death, a short rewind, death again,
// forever. The Build Farm opening (three gnats, see ai.zig's balance
// tests): stand still until dead, rewind `back_n` ticks out of death the
// way main.zig does (begin, back, commit, `revive` unless `no_revive`),
// then stand still or fight back with the zapper for up to 600 ticks.
// Returns the ticks survived; `out_hp` the HP at the end.
const MobRun = struct { back_n: u32, revive: bool, fire: bool };
fn mob_after_death_rewind(r: MobRun, out_hp: *i16) !u32 {
    const level_parse = @import("level_parse.zig");
    const fixed = @import("fixed.zig");
    var st: level_parse.Parsed = undefined;
    const farm = try level_parse.parse_level(&st, "build_farm", @embedFile("levels/build_farm.txt"), 0);
    desyncs = 0;
    var s: GameState = undefined;
    sim.init(&s, &farm, 0, 1);
    s.player.x = fixed.from_int(12) + fixed.half;
    reset(&s);
    while (s.player.hp > 0) {
        log_input(s.tick, .{});
        sim.step(&s, &farm, .{});
        after_step(&s);
        try testing.expect(s.tick < 2000);
    }
    begin(&s, &farm);
    for (0..r.back_n) |_| _ = back(&farm).?;
    commit(&s, 0, true);
    try testing.expect(s.player.hp > 0);
    if (r.revive) {
        revive(&s);
        try testing.expect(s.player.hp >= sim.death_hp_floor);
        try testing.expectEqual(sim.death_grace, s.player.grace);
    }
    const resumed = s.tick;
    while (s.player.hp > 0 and s.tick < resumed + 600) {
        const b: Buttons = .{ .a = r.fire };
        log_input(s.tick, b);
        sim.step(&s, &farm, b);
        after_step(&s);
        // The keyframe self-check replays across the revive patch.
        if (s.tick % keyframe_every == 0) try testing.expect(check(&s, &farm));
    }
    try testing.expectEqual(@as(u32, 0), desyncs);
    out_hp.* = s.player.hp;
    return s.tick - resumed;
}

test "death revive: a short rewind out of death no longer lands in a mob that kills again" {
    var hp: i16 = 0;
    // The bug: a tap out of death resumes on the last living tick (4 HP)
    // and the next bite kills, even fighting back.
    try testing.expect(try mob_after_death_rewind(.{ .back_n = 1, .revive = false, .fire = true }, &hp) < 60);
    // Revived, the same tap lasts over 5 s of fighting without even
    // aiming (measured 382 ticks), the reserve the full 10 s.
    try testing.expect(try mob_after_death_rewind(.{ .back_n = 1, .revive = true, .fire = true }, &hp) >= 300);
    try testing.expectEqual(@as(u32, 600), try mob_after_death_rewind(.{ .back_n = 180, .revive = true, .fire = true }, &hp));
    try testing.expect(hp > 0);
    // Standing still, nothing bites for the whole grace.
    try testing.expect(try mob_after_death_rewind(.{ .back_n = 1, .revive = true, .fire = false }, &hp) > sim.death_grace);
}
