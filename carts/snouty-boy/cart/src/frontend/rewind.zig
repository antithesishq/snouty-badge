//! Time scrubber storage (SPEC.md sections 10 and 19.3): a page store of
//! keyframes (`core.kstore`) taken every 30 game frames plus a
//! one-byte-per-frame input log covering the same span. The index
//! bookkeeping (which keyframe age, which log byte, truncation) is
//! `core.ring.Ring`, host-tested in `tests/ring_unit.zig`; the store is
//! host-tested in `tests/kstore_unit.zig` and `tests/determinism.zig`. This
//! file owns the bytes and talks to the console and the screen.
//!
//! Page store. A keyframe is the console's four state regions (packed
//! `Small`, VRAM, WRAM, cart RAM; `Gb.state_regions`) cut into 512-byte
//! pages; pages equal to the previous keyframe's are shared, all-zero pages
//! cost nothing, only changed pages are copied. When the pool is full the
//! oldest keyframes are evicted, so the depth adapts to how much the game
//! changes: 2048-gb copies about 8 pages (4 KB) per keyframe.
//!
//! Arena (PLAN.md M5 and M8). The ROM, and with it the cart RAM the console
//! and every keyframe carry (0 to 32 KB, `mmu.cart_ram_len`), is only known
//! at `start()` once the drive has been looked at, so `layout` places the
//! live console (50 KB, mostly VRAM and WRAM), its cart RAM and the whole
//! page store (pool, keyframe tables, free list, reference counts) at run
//! time in one arena: on the badge the
//! RAM the linker leaves between the end of `.bss` and the stack
//! (`__bss_end__`, `__stack_limit__` from the SDK's cart_ram.ld /
//! cart_xip.ld), minus 1 KB of guard below the stack limit. It is not
//! `.bss`, so it is not shipped as zeros in the UF2 (docs/ROM_DRIVE.md
//! section 3) and the OS does not clear it; `Gb.init` sets every console
//! field, `Gb.reset` zeroes the cart RAM and the store writes every page
//! before it reads it. The arena shrinks by
//! itself when the build embeds a big ROM in RAM (it sits in `.rodata`
//! below `.bss`) and is the whole RAM window of an XIP build. The keyframe
//! count is split from it as the M7 comptime budget did (`tuning.zig`):
//! each keyframe's table plus its typical copied pages, capped at
//! `tuning.max_keyframes`. When the arena cannot hold two keyframe tables
//! and a pool of half a keyframe with every page non-zero, `layout` fails
//! and the cart shows the `halted` screen (main.zig). A keyframe that does
//! not fit even alone empties the history until the next one that does. In wasm, which has no such linker symbols,
//! the arena is a static array.
//!
//! Frozen frame after a scrub step. The console is restored to the keyframe
//! exactly and stays there; to put a picture on screen the keyframe is
//! stepped one frame with the logged pad for that frame (the PPU draws
//! through the normal line sink into the back buffer) and then restored
//! again from the store. So the state is exactly the keyframe's, and the
//! picture is the frame the game showed 1/60 s later. This costs one
//! `step_frame` and two restores per scrub step and no RAM. Determinism
//! accounting is untouched: resuming steps the game from the keyframe
//! itself. If the pad for that frame is not logged yet (the newest keyframe,
//! taken on the very last frame played), the keyframe's own pad is used for
//! the preview only.
//!
//! Right from the newest keyframe returns to the live position by
//! replaying the logged frames since it (at most 29 `step_frame`s, drawing
//! only the last), which leaves the console exactly where it was when the
//! menu opened.
//!
//! Stepping the game while parked on a keyframe (resuming from the menu)
//! truncates the history to that keyframe: the keyframes and inputs ahead
//! are dropped and overwritten (`core.ring`, SPEC.md 10.1).
const std = @import("std");
const cart = @import("cart-api");
const core = @import("core");
const video = @import("video.zig");
const debug = @import("debug.zig");
const tuning = @import("tuning.zig");
const Gb = core.Gb;
const kstore = core.kstore;

/// SPEC.md 18 item 7: one keyframe every 0.5 s (knob in tuning.zig).
pub const frames_per_keyframe = tuning.frames_per_keyframe;

/// When true, every new keyframe is checked by replaying the previous one
/// into a spare console (SPEC.md 10.2, last sentence); a mismatch paints the
/// debug overlay red (`debug.alarm`). Costs a second `Gb` of RAM and doubles
/// the CPU per keyframe interval, so it is off for the badge.
const self_check = false;

// ---- Knobs (SPEC.md 19.5, tuning.zig) ----

/// Bytes per store page.
pub const page_size = tuning.page_size;

const Store = kstore.Store(page_size);
const R = core.ring.Ring(tuning.max_keyframes, frames_per_keyframe);

/// Page references per keyframe at most (32 KB of cart RAM), for the report.
pub const max_pages = kstore.pages_for(page_size, .{ @sizeOf(Gb.Small), 0x4000, 0x8000, Gb.max_cart_ram });

var ring: R = .{};
var store: Store = .{};
/// In .bss (zeroed by the OS), unlike the arena. `R.log_len` bytes.
var log: [R.log_len]u8 = @splat(0);
/// Packed small state, the first store region (`Gb.state_regions`).
var small: Gb.Small = undefined;

// ---- Arena ----

/// Bytes kept free between the arena and the stack limit.
const stack_guard = 1024;
/// The wasm arena; the badge build never references it.
var wasm_arena: [256 * 1024]u8 align(8) = undefined;

const linker = struct {
    extern var __bss_end__: u8;
    extern var __stack_limit__: u8;
};

/// The whole arena (0 bytes before `layout`).
var arena: []align(4) u8 = &.{};

fn find_arena() []align(4) u8 {
    if (cart.is_wasm) return &wasm_arena;
    const lo = std.mem.alignForward(usize, @intFromPtr(&linker.__bss_end__), 4);
    const hi = @intFromPtr(&linker.__stack_limit__) -| stack_guard;
    const len = if (hi > lo) hi - lo else 0;
    return @as([*]align(4) u8, @ptrFromInt(lo))[0..len];
}

/// Where `layout` put the console and its cart RAM.
pub const Layout = struct {
    /// Room for the console, not initialised: the caller `Gb.init`s it.
    gb: *Gb,
    /// The console's cart RAM, `mmu.cart_ram_len` bytes, word aligned (the
    /// store compares and copies words).
    cart_ram: []u8,
};

/// Lay out the arena for `rom`: the live console, its cart RAM, then the
/// page store. Returns null when fewer than two keyframes fit (the cart then
/// refuses to start; see main.zig). Call once, before `Gb.init` and `reset`.
pub fn layout(rom: *const core.Rom) ?Layout {
    arena = find_arena();
    const base = std.mem.alignForward(usize, @intFromPtr(arena.ptr), @alignOf(Gb));
    const gb_end = base - @intFromPtr(arena.ptr) + std.mem.alignForward(usize, @sizeOf(Gb), 4);
    const ram_len = core.mmu.cart_ram_len(rom);
    const ram_end = gb_end + std.mem.alignForward(usize, ram_len, 4);
    if (arena.len < ram_end) return null;
    const rest: []align(4) u8 = @alignCast(arena[ram_end..]);
    const pages = kstore.pages_for(page_size, .{ @sizeOf(Gb.Small), 0x4000, 0x8000, ram_len });
    // The M7 split: per keyframe its table plus the pages it typically
    // copies; the pool gets whatever the tables leave.
    const per_keyframe = pages * 2 + tuning.typical_pages_per_keyframe * (page_size + 3);
    const keyframes = @min(rest.len / per_keyframe, tuning.max_keyframes);
    if (keyframes < 2) return null;
    const pool = kstore.pages_fitting(page_size, rest.len, keyframes, pages);
    // A keyframe is its non-zero pages: at most `pages`, in practice far
    // fewer (tests/determinism.zig prints them; 2048-gb's largest is 24 of
    // 102). Half of `pages` still holds any real keyframe seen so far; one
    // that does not fit even alone only costs the history until the next
    // keyframe that does (`record_frame`), never the game.
    if (pool < pages / 2) return null;
    store = Store.init(rest, pool, keyframes, pages);
    ring = R.init(keyframes);
    return .{ .gb = @ptrFromInt(base), .cart_ram = arena[gb_end..][0..ram_len] };
}

/// Arena bytes (0 before `layout`).
pub fn arena_bytes() usize {
    return arena.len;
}

/// Keyframes the store can hold at most (0 before `layout`).
pub fn keyframe_capacity() usize {
    return store.max_keyframes;
}

/// Pool bytes (0 before `layout`).
pub fn pool_capacity_bytes() usize {
    return store.capacity_pages() * page_size;
}

/// Forget all history and take the current console as keyframe 0. Call
/// after `Gb.init` and after every `gb.reset()`.
pub fn reset(gb: *Gb) void {
    ring.reset();
    store.reset();
    gb.save_small(&small);
    // Fits unless the arena is tiny: VRAM, WRAM and cart RAM are zero.
    store.put(gb.state_regions(&small)) catch ring.lose_history();
    update_stats();
    debug.alarm = false;
}
/// Call after every stepped game frame with the pad it was stepped with.
/// Truncates the future if the game was resumed from a scrubbed position.
pub fn record_frame(gb: *Gb, pad: u8) void {
    const rec = ring.record();
    if (rec.drop_newest != 0) store.drop_newest(rec.drop_newest);
    log[rec.log_index] = pad;
    if (!rec.snapshot) return;
    gb.save_small(&small);
    const regions = gb.state_regions(&small);
    if (store.put(regions)) |_| {
        ring.set_count(store.count);
    } else |_| {
        // Not even the previous keyframe and this one fit: start the
        // history again from here.
        store.reset();
        if (store.put(regions)) |_| ring.restart_at_live() else |_| ring.lose_history();
    }
    update_stats();
    if (self_check) check_newest(gb);
}

fn update_stats() void {
    debug.pool_kb = @intCast(store.bytes_in_use() / 1024);
    debug.keyframes = @intCast(store.count);
}

pub fn can_step(dir: i2) bool {
    return ring.can_step(dir);
}

/// Keyframe `age` into the console (sets `gb.pal_dirty` via `load_small`).
fn restore(gb: *Gb, age: usize) void {
    store.get(age, gb.state_regions(&small));
    gb.load_small(&small);
}

/// Move one keyframe back (dir < 0) or forward (dir > 0), restore it into
/// `gb` and draw its picture into the back buffer (see the file comment).
/// Returns false, changing nothing, at either end of the history.
pub fn step(gb: *Gb, dir: i2) bool {
    const s = ring.step(dir) orelse return false;
    switch (s) {
        .restore => |age| show_keyframe(gb, age),
        .replay => |r| {
            if (r.from == r.to) {
                // Live was the newest keyframe itself.
                show_keyframe(gb, 0);
            } else {
                restore(gb, 0);
                const sink = gb.line_sink;
                gb.line_sink = null;
                var f = r.from;
                while (f < r.to) : (f += 1) {
                    if (f + 1 == r.to) gb.line_sink = sink;
                    gb.step_frame(log[R.log_index(f)]);
                }
                gb.line_sink = sink;
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
fn show_keyframe(gb: *Gb, age: usize) void {
    restore(gb, age);
    const f = ring.position();
    const pad = if (ring.has_pad(f)) log[R.log_index(f)] else gb.pad;
    gb.step_frame(pad);
    video.finish_frame();
    restore(gb, age);
}

/// How far behind the live position the game is parked, in frames (0 live).
pub fn depth_frames() u32 {
    return ring.depth_frames();
}

/// Frames of history reachable from the live position.
pub fn history_frames() u32 {
    return ring.history_frames();
}

/// How full the history is, 0..5 (one neopixel per fifth): the larger of
/// the ring's span and the pool's use, since either one running out means
/// old keyframes are being dropped.
pub fn history_fraction() u8 {
    const used = store.pages_in_use();
    const cap = store.capacity_pages();
    const pool: u8 = @intCast((used * 5 + cap - 1) / cap);
    return @max(ring.history_fraction(), @min(pool, 5));
}

/// Valid keyframes in the store.
pub fn keyframe_count() usize {
    return ring.count;
}

/// Pool bytes holding keyframe pages.
pub fn pool_bytes() usize {
    return store.bytes_in_use();
}

// ---- Self-check (SPEC.md 10.2 in the cart; compiled only if enabled) ----

var spare: Gb = undefined;
var spare_small: Gb.Small = undefined;
var spare_ram: [if (self_check) Gb.max_cart_ram else 0]u8 align(4) = undefined;

/// Replay the previous keyframe with the logged pads into `spare` and
/// compare with the keyframe just taken.
fn check_newest(gb: *const Gb) void {
    if (ring.count < 2) return;
    // No struct literals or by-value arrays here: the wasm stack is 14.7 KB
    // and a `Gb` temporary alone is 50 KB. The restore sets every field but
    // these.
    spare.rom = gb.rom;
    spare.model = gb.model;
    spare.cart_ram = spare_ram[0..gb.cart_ram.len];
    spare.line_sink = null;
    store.get(1, spare.state_regions(&spare_small));
    spare.load_small(&spare_small);
    var f = ring.frame_of_age(1);
    while (f < ring.frame_of_age(0)) : (f += 1) spare.step_frame(log[R.log_index(f)]);
    spare.save_small(&spare_small);
    if (!store.matches(0, spare.state_regions(&spare_small))) debug.alarm = true;
}
