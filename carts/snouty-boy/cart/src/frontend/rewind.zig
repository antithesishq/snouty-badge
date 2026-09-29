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
const rom = @import("rom");
const options = @import("cart_options");
const video = @import("video.zig");
const debug = @import("debug.zig");
const Gb = core.Gb;
const kstore = core.kstore;

/// SPEC.md 18 item 7: one keyframe every 0.5 s.
pub const frames_per_keyframe = 30;

/// When true, every new keyframe is checked by replaying the previous one
/// into a spare console (SPEC.md 10.2, last sentence); a mismatch paints the
/// debug overlay red (`debug.alarm`). Costs a second `Gb` of RAM and doubles
/// the CPU per keyframe interval, so it is off for the badge.
const self_check = false;

// ---- Knobs (SPEC.md 19.5) ----

/// Bytes per store page. Smaller pages share more but cost more table
/// entries (2 bytes per page per keyframe).
pub const page_size = 512;
/// Expected pages copied per keyframe, for splitting the budget between
/// pool pages and keyframe tables. Measured in tests/determinism.zig:
/// 2048-gb 8, rex-runner 4, rebound 7 on average.
const typical_pages_per_keyframe = 8;

// ---- Memory budget (SPEC.md 13 and 19.4) ----

/// Built as an execute-in-place cart (-Dcart-mode=xip): code and ROM are in
/// the 256 KB cart flash window and the whole RAM window is for state.
pub const xip = options.xip;
/// Cart RAM for .text + .data + .bss: the 0x4AF00-byte RAM window minus the
/// 32 KB stack the linker script reserves (`cart_ram.ld`, `cart_xip.ld`).
const usable_ram = 0x4AF00 - 32 * 1024;
/// Code, constants and .data, not counting the ROM (M4 fast build: about
/// 52 KB; the CGB renderer, DMA and page store add some), with headroom.
const code_estimate = 64 * 1024;
const flash_window = 256 * 1024;
const cart_ram_len = core.mmu.cart_ram_len(rom.data);
/// Other .bss: the live console, its cart RAM, and frontend statics (colour
/// LUT, line maps, menu, debug windows), with headroom.
const statics_estimate = 6 * 1024;
const self_check_bytes = if (self_check) @sizeOf(Gb) + cart_ram_len else 0;
const fixed_bytes = (if (xip) 0 else code_estimate + rom.data.len) +
    @sizeOf(Gb) + cart_ram_len + statics_estimate + self_check_bytes;
/// What is left for the page store and the input log.
const budget = if (fixed_bytes >= usable_ram) 0 else usable_ram - fixed_bytes;

/// Page references per keyframe (the state regions in pages).
pub const max_pages = kstore.pages_for(page_size, .{ @sizeOf(Gb.Small), 0x4000, 0x8000, cart_ram_len });
/// Per keyframe: its page table plus its input log bytes.
const keyframe_overhead = max_pages * 2 + frames_per_keyframe;
/// Per pool page: the page, its reference count, its free-list entry.
const page_cost = page_size + 1 + 2;
/// Ring capacity: the budget split for typical keyframes, 2..255.
pub const max_keyframes = @max(2, @min(255, budget / (keyframe_overhead + typical_pages_per_keyframe * page_cost)));
/// Pool pages: the rest of the budget (64 bytes for the store's counters).
pub const pool_pages = if (budget > max_keyframes * keyframe_overhead + 64)
    (budget - max_keyframes * keyframe_overhead - 64) / page_cost
else
    0;

const Store = kstore.Store(page_size, @max(1, pool_pages), max_keyframes, max_pages);
const R = core.ring.Ring(max_keyframes, frames_per_keyframe);

comptime {
    // The minimum: one keyframe with every page non-zero and changed must
    // fit, so the store can always hold a restore point (after a PoolFull it
    // restarts from the live frame). Real keyframes are far smaller
    // (tests/determinism.zig prints them), so this is still several seconds.
    if (pool_pages < max_pages) @compileError(std.fmt.comptimePrint(
        "rewind: the ROM ({d} bytes) leaves {d} bytes of cart RAM for the page store, less than one full " ++
            "keyframe ({d} pages of {d} bytes); build the XIP cart with -Dcart-mode=xip, which keeps code and ROM in flash",
        .{ rom.data.len, budget, max_pages, page_size },
    ));
    if (@sizeOf(Store) + R.log_len > budget) @compileError(std.fmt.comptimePrint(
        "rewind: page store {d} + log {d} bytes exceed the {d}-byte budget",
        .{ @sizeOf(Store), R.log_len, budget },
    ));
    if (xip and code_estimate + rom.data.len > flash_window) @compileError(std.fmt.comptimePrint(
        "rewind: ROM {d} bytes plus about {d} of code does not fit the {d}-byte XIP flash window",
        .{ rom.data.len, code_estimate, flash_window },
    ));
}

var ring: R = .{};
var store: Store = undefined;
var log: [R.log_len]u8 = @splat(0);
/// Packed small state, the first store region (`Gb.state_regions`).
var small: Gb.Small = undefined;

/// Forget all history and take the current console as keyframe 0. Call
/// after `Gb.init` and after every `gb.reset()`.
pub fn reset(gb: *Gb) void {
    ring.reset();
    store.reset();
    gb.save_small(&small);
    // A single keyframe always fits (the comptime minimum above).
    store.put(gb.state_regions(&small)) catch unreachable;
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
        store.put(regions) catch unreachable;
        ring.restart_at_live();
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
    const pool: u8 = @intCast((used * 5 + Store.capacity_pages - 1) / Store.capacity_pages);
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
var spare_ram: [if (self_check) cart_ram_len else 0]u8 = undefined;

/// Replay the previous keyframe with the logged pads into `spare` and
/// compare with the keyframe just taken.
fn check_newest(gb: *const Gb) void {
    if (ring.count < 2) return;
    // No struct literals or by-value arrays here: the wasm stack is 14.7 KB
    // and a `Gb` temporary alone is 50 KB. The restore sets every field but
    // these.
    spare.rom = gb.rom;
    spare.model = gb.model;
    spare.cart_ram = &spare_ram;
    spare.line_sink = null;
    store.get(1, spare.state_regions(&spare_small));
    spare.load_small(&spare_small);
    var f = ring.frame_of_age(1);
    while (f < ring.frame_of_age(0)) : (f += 1) spare.step_frame(log[R.log_index(f)]);
    spare.save_small(&spare_small);
    if (!store.matches(0, spare.state_regions(&spare_small))) debug.alarm = true;
}
