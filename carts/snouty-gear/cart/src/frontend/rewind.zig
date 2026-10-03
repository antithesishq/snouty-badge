//! Time scrubber storage (SPEC.md section 10), ported from Snouty Boy's
//! frontend/rewind.zig: a page store of keyframes (`core.kstore`) taken
//! every 30 game frames plus a one-byte-per-frame input log covering the
//! same span. The index bookkeeping (which keyframe age, which log byte,
//! truncation) is `core.ring.Ring`, host-tested in `tests/ring_unit.zig`;
//! the store is host-tested in `tests/kstore_unit.zig` and
//! `tests/determinism.zig`. This file owns the bytes and talks to the
//! console and the screen.
//!
//! Page store. A keyframe is the console's four state regions (packed
//! `Small`, 8 KB RAM, 16 KB VRAM, 8 KB cart RAM; `Gg.state_regions`) cut
//! into `tuning.page_size` pages; pages equal to the previous keyframe's
//! are shared, all-zero pages cost nothing, only changed pages are copied.
//! When the pool is full the oldest keyframes are evicted, so the depth
//! adapts to how much the game changes.
//!
//! Arena. Unlike Snouty Boy the console (`gg`, ~33 KB) stays a static in
//! main.zig's `.bss` and its cart RAM is a fixed 8 KB array inside it, so
//! only the page store (pool, keyframe tables, free list, reference counts)
//! lives in the arena: on the badge the RAM the linker leaves between the
//! end of `.bss` and the stack (`__bss_end__`, `__stack_limit__` from the
//! SDK's cart_ram.ld), minus `tuning.stack_guard` below the stack limit. It
//! is not `.bss`, so it is not shipped as zeros in the UF2
//! (docs/ROM_DRIVE.md section 3) and the OS does not clear it; the store
//! writes every page before it reads it. In wasm, which has no such linker
//! symbols, the arena is a 54 KB static array, the badge's size, so the
//! preview shows badge-like depth. The keyframe count is split from the
//! arena as Snouty Boy does: each keyframe's table plus its typical copied
//! pages, capped at `tuning.max_keyframes`. When fewer than two keyframes
//! fit, `init` returns false and the scrubber is off: the cart still runs,
//! the menu reads "Scrub: no memory" and `keyframe_capacity` is 0.
//!
//! Frozen frame after a scrub step. The console is restored to the keyframe
//! exactly and stays there; to put a picture on screen the keyframe is
//! stepped one frame with the logged pad for that frame (the VDP draws
//! through the normal line sink into the back buffer) and then restored
//! again from the store. So the state is exactly the keyframe's, and the
//! picture is the frame the game showed 1/60 s later. This costs one
//! `step_frame` and two restores per scrub step and no RAM. If the pad for
//! that frame is not logged yet (the newest keyframe, taken on the very
//! last frame played), the keyframe's own pad is used for the preview only.
//!
//! Right from the newest keyframe returns to the live position by
//! replaying the logged frames since it (at most 29 `step_frame`s, drawing
//! only the last), which leaves the console exactly where it was when the
//! menu opened.
//!
//! Stepping the game while parked on a keyframe (resuming from the menu)
//! truncates the history to that keyframe: the keyframes and inputs ahead
//! are dropped and overwritten (`core.ring`, SPEC.md 10).
const std = @import("std");
const cart = @import("cart-api");
const core = @import("core");
const video = @import("video.zig");
const debug = @import("debug.zig");
const tuning = @import("tuning.zig");
const Gg = core.Gg;
const kstore = core.kstore;

/// One keyframe every 0.5 s (knob in tuning.zig).
pub const frames_per_keyframe = tuning.frames_per_keyframe;
/// Bytes per store page (knob in tuning.zig).
pub const page_size = tuning.page_size;

/// When true, every new keyframe is checked by replaying the previous one
/// into a spare console (SPEC.md 10); a mismatch paints the debug overlay
/// red (`debug.alarm`). Costs a second `Gg` of RAM and doubles the CPU per
/// keyframe interval, so it is off for the badge.
const self_check = false;

const Store = kstore.Store(page_size);
const R = core.ring.Ring(tuning.max_keyframes, frames_per_keyframe);

/// Page references per keyframe (every region at its fixed length).
pub const max_pages = kstore.pages_for(page_size, .{ @sizeOf(Gg.Small), 0x2000, 0x4000, core.cart_ram_size });

var ring: R = .{};
var store: Store = .{};
/// In .bss (zeroed by the OS), unlike the arena. `R.log_len` bytes.
var log: [R.log_len]u8 = @splat(0);
/// Packed small state, the first store region (`Gg.state_regions`).
var small: Gg.Small = undefined;
/// `init` found room for at least two keyframes.
var ready: bool = false;

// ---- Arena ----

/// The wasm arena; the badge build never references it.
var wasm_arena: [54 * 1024]u8 align(8) = undefined;

const linker = struct {
    extern var __bss_end__: u8;
    extern var __stack_limit__: u8;
};

/// The whole arena (0 bytes before `init`).
var arena: []align(4) u8 = &.{};

fn find_arena() []align(4) u8 {
    if (cart.is_wasm) return &wasm_arena;
    const lo = std.mem.alignForward(usize, @intFromPtr(&linker.__bss_end__), 4);
    const hi = @intFromPtr(&linker.__stack_limit__) -| tuning.stack_guard;
    const len = if (hi > lo) hi - lo else 0;
    return @as([*]align(4) u8, @ptrFromInt(lo))[0..len];
}

/// Find the arena and lay out the page store in it. Returns false when
/// fewer than two keyframes fit (the scrubber then stays off and every
/// other function here is a no-op). Call once at start, before `reset`.
pub fn init() bool {
    arena = find_arena();
    ready = false;
    // The Snouty Boy split: per keyframe its table plus the pages it
    // typically copies; the pool gets whatever the tables leave.
    const per_keyframe = max_pages * 2 + tuning.typical_pages_per_keyframe * (page_size + 3);
    const keyframes = @min(arena.len / per_keyframe, tuning.max_keyframes);
    if (keyframes < 2) return false;
    const pool = kstore.pages_fitting(page_size, arena.len, keyframes, max_pages);
    // A keyframe is its non-zero pages: at most `max_pages`, in practice far
    // fewer. Half of them still holds any real keyframe; one that does not
    // fit even alone only costs the history until the next keyframe that
    // does (`record_frame`), never the game.
    if (pool < max_pages / 2) return false;
    store = Store.init(arena, pool, keyframes, max_pages);
    ring = R.init(keyframes);
    ready = true;
    return true;
}

/// Arena bytes (0 before `init`).
pub fn arena_bytes() usize {
    return arena.len;
}

/// Keyframes the store can hold at most (0 before `init` or when it failed).
pub fn keyframe_capacity() usize {
    return if (ready) store.max_keyframes else 0;
}

/// Pool bytes (0 before `init` or when it failed).
pub fn pool_capacity_bytes() usize {
    return if (ready) store.capacity_pages() * page_size else 0;
}

/// Forget all history and take the current console as keyframe 0. Call
/// after `init` at start and after every `gg.reset()` (the menu's Reset).
pub fn reset(gg: *Gg) void {
    debug.alarm = false;
    if (!ready) return;
    ring.reset();
    store.reset();
    gg.save_small(&small);
    // Fits unless the arena is tiny: RAM, VRAM and cart RAM are zero.
    store.put(gg.state_regions(&small)) catch ring.lose_history();
    update_stats();
}

/// Call after every stepped game frame with the pad it was stepped with.
/// Truncates the future if the game was resumed from a scrubbed position.
/// Every `frames_per_keyframe`th call compares the 32 KB of state with the
/// previous keyframe and copies the changed pages.
pub fn record_frame(gg: *Gg, pad: u8) void {
    if (!ready) return;
    const rec = ring.record();
    if (rec.drop_newest != 0) store.drop_newest(rec.drop_newest);
    log[rec.log_index] = pad;
    if (!rec.snapshot) return;
    gg.save_small(&small);
    const regions = gg.state_regions(&small);
    if (store.put(regions)) |_| {
        ring.set_count(store.count);
    } else |_| {
        // Not even the previous keyframe and this one fit: start the
        // history again from here.
        store.reset();
        if (store.put(regions)) |_| ring.restart_at_live() else |_| ring.lose_history();
    }
    update_stats();
    if (self_check) check_newest(gg);
}

fn update_stats() void {
    debug.pool_kb = @intCast(store.bytes_in_use() / 1024);
    debug.keyframes = @intCast(store.count);
}

/// True if a step in `dir` (-1 back, 1 forward) would move.
pub fn can_step(dir: i2) bool {
    return ready and ring.can_step(dir);
}

/// Keyframe `age` into the console (`load_small` rebuilds the read map).
fn restore(gg: *Gg, age: usize) void {
    store.get(age, gg.state_regions(&small));
    gg.load_small(&small);
}

/// Move one keyframe back (dir < 0) or forward (dir > 0), restore it into
/// `gg` and draw its picture into the back buffer (see the file comment).
/// Returns false, changing nothing, at either end of the history.
pub fn step(gg: *Gg, dir: i2) bool {
    if (!ready) return false;
    const s = ring.step(dir) orelse return false;
    switch (s) {
        .restore => |age| show_keyframe(gg, age),
        .replay => |r| {
            if (r.from == r.to) {
                // Live was the newest keyframe itself.
                show_keyframe(gg, 0);
            } else {
                restore(gg, 0);
                const sink = gg.line_sink;
                gg.line_sink = null;
                var f = r.from;
                while (f < r.to) : (f += 1) {
                    if (f + 1 == r.to) gg.line_sink = sink;
                    gg.step_frame(log[R.log_index(f)]);
                }
                gg.line_sink = sink;
                video.finish_frame();
            }
        },
    }
    // The menu runs in .copy_forward, where only marked rects reach the
    // panel; without this a scrub step showed just the bar over the old menu.
    cart.mark_dirty_rect(0, 0, cart.screen_width, cart.screen_height);
    return true;
}

/// Restore keyframe `age`, render one frame from it, restore it again.
fn show_keyframe(gg: *Gg, age: usize) void {
    restore(gg, age);
    const f = ring.position();
    const pad = if (ring.has_pad(f)) log[R.log_index(f)] else gg.pad;
    gg.step_frame(pad);
    video.finish_frame();
    restore(gg, age);
}

/// How far behind the live position the game is parked, in frames (0 live).
pub fn depth_frames() u32 {
    return if (ready) ring.depth_frames() else 0;
}

/// Frames of history reachable from the live position.
pub fn history_frames() u32 {
    return if (ready) ring.history_frames() else 0;
}

/// How full the history is, 0..5: the larger of the ring's span and the
/// pool's use, since either one running out means old keyframes are being
/// dropped. (Snouty Boy lights a neopixel per fifth; Gear leaves them off.)
pub fn history_fraction() u8 {
    if (!ready) return 0;
    const used = store.pages_in_use();
    const cap = store.capacity_pages();
    const pool: u8 = @intCast((used * 5 + cap - 1) / cap);
    return @max(ring.history_fraction(), @min(pool, 5));
}

/// Valid keyframes in the store.
pub fn keyframe_count() usize {
    return if (ready) ring.count else 0;
}

/// Pool bytes holding keyframe pages.
pub fn pool_bytes() usize {
    return if (ready) store.bytes_in_use() else 0;
}

// ---- Self-check (SPEC.md 10 in the cart; compiled only if enabled) ----

var spare: Gg = undefined;
var spare_small: Gg.Small = undefined;

/// Replay the previous keyframe with the logged pads into `spare` and
/// compare with the keyframe just taken.
fn check_newest(gg: *const Gg) void {
    if (ring.count < 2) return;
    // No struct literals or by-value consoles here: the wasm stack is
    // 14.7 KB and a `Gg` temporary is 33 KB. The restore sets every field
    // but these.
    spare.rom = gg.rom;
    spare.line_sink = null;
    spare.console_sink = null;
    store.get(1, spare.state_regions(&spare_small));
    spare.load_small(&spare_small);
    var f = ring.frame_of_age(1);
    while (f < ring.frame_of_age(0)) : (f += 1) spare.step_frame(log[R.log_index(f)]);
    spare.save_small(&spare_small);
    if (!store.matches(0, spare.state_regions(&spare_small))) debug.alarm = true;
}
