//! Time scrubber, the frontend half (SPEC.md section 10, PLAN.md "M3
//! Scrub: contract"): finds the RAM for the undo records and drives
//! `core.undo`, which owns the records and the dirty bytes and is
//! host-tested. This file owns the arena and talks to the screen. Ported
//! from Snouty Genesis's frontend/rewind.zig: an undo record is applied by
//! swapping its blocks with the console's, so Left and Right are the same
//! operation and nothing is replayed.
//!
//! Arena. On the badge the RAM the linker leaves between the end of `.bss`
//! and the stack (`__bss_end__`, `__stack_limit__` from the SDK's linker
//! script), minus `tuning.stack_guard` below the stack limit, as in Gear
//! and Genesis. It is not `.bss`, so it is not shipped as zeros in the UF2
//! and the OS does not clear it; `core.undo` writes every slot before it
//! reads it. In wasm, which has no such symbols, it is a static array of
//! `tuning.wasm_arena_bytes`, about the badge's size, so the preview shows
//! badge-like depth. When fewer than two records' small state plus 64
//! blocks fit, `init` returns false and the scrubber stays off: the cart
//! runs untracked, the menu reads "Scrub: no memory" and `capacity_slots`
//! is 0.
//!
//! Picture while parked. `step` leaves the console exactly at the record
//! boundary; `show` copies the frame at the latched DISPADR and the
//! palette into the console's display (`Lynx.refresh_display`, what the
//! vertical blank does) without stepping, then draws it and the status
//! strip, so the parked state is never disturbed.
//!
//! Resuming. The first frame stepped after a scrub must drop the records
//! ahead (they hold the future) and open a fresh record from the parked
//! state: main.zig calls `resume_if_parked` before every `step_frame`
//! (`core.undo.resume_here`).
const std = @import("std");
const cart = @import("cart-api");
const core = @import("core");
const video = @import("video.zig");
const strip = @import("strip.zig");
const debug = @import("debug.zig");
const tuning = @import("tuning.zig");
const undo = core.undo;

/// Slots of one record's packed small state (`core.Lynx.Small`): the
/// core's figure when it gives one, else from the struct, else (the M3
/// prep stub has no `Small`) an over-estimate: everything outside RAM and
/// the display copy.
const small_slots = if (@hasDecl(undo, "small_slots"))
    undo.small_slots
else if (@hasDecl(core.Lynx, "Small"))
    (@sizeOf(core.Lynx.Small) + undo.block_size - 1) / undo.block_size
else
    (@sizeOf(core.Lynx) - @sizeOf(@FieldType(core.Lynx, "ram")) - @sizeOf(@FieldType(core.Lynx, "display")) + undo.block_size - 1) / undo.block_size;
/// Fewest slots worth running with: two records' small state and 64
/// blocks (PLAN.md Track B).
const min_slots = 2 * small_slots + 64;

/// `init` found room; every other function is a no-op until then.
var ready: bool = false;

// ---- Arena ----

/// The wasm arena; the badge build never references it.
var wasm_arena: [tuning.wasm_arena_bytes]u8 align(4) = undefined;

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

/// Find the arena and hand it to `core.undo`. Returns false (scrubber off)
/// when fewer than `min_slots` fit. Call once in `start`, before the
/// console boots (the arena does not depend on the ROM).
pub fn init() bool {
    arena = find_arena();
    ready = false;
    if (arena.len / @sizeOf(undo.Slot) < min_slots) {
        undo.init(arena[0..0]);
        return false;
    }
    undo.init(arena);
    ready = true;
    return true;
}

/// Forget all history and open record 0 from the console. Call after every
/// boot (`init_in_place` writes RAM directly, past the write hooks): start,
/// a picker choice, the menu's Reset.
pub fn reset(l: *core.Lynx) void {
    if (ready) undo.reset(l) else undo.disable();
    debug.core_moved();
}

/// Call after every stepped Lynx frame.
pub fn record_frame(l: *core.Lynx) void {
    if (ready) undo.record_frame(l);
}

/// Call before the first `step_frame` of a running update: after a scrub
/// the console is parked on a record boundary, and playing on from there
/// drops the future.
pub fn resume_if_parked(l: *core.Lynx) void {
    if (ready and undo.parked()) undo.resume_here(l);
}

/// True if a step in `dir` (-1 back, 1 forward) would move.
pub fn can_step(dir: i2) bool {
    return ready and undo.can_step(dir);
}

/// Move one record back (dir < 0) or forward (dir > 0) and draw the
/// restored state into the back buffer. False, changing nothing, at either
/// end of the history.
pub fn step(l: *core.Lynx, dir: i2) bool {
    if (!ready or !undo.step(l, dir)) return false;
    debug.core_moved();
    show(l);
    return true;
}

/// Draw the current (parked) state: the picture at the latched display
/// address and the status strip under it. Out of line: one copy for every
/// step.
pub noinline fn show(l: *core.Lynx) void {
    l.refresh_display();
    video.show(l.frame());
    strip.draw(l);
    // The menu runs in .copy_forward, where only marked rects reach the
    // panel; without this a scrub step showed just the bar over the old menu.
    cart.mark_dirty_rect(0, 0, cart.screen_width, cart.screen_height);
}

/// Frames behind live (0 live).
pub fn depth_frames() u32 {
    return if (ready) undo.depth_frames() else 0;
}

/// Frames reachable back from live.
pub fn history_frames() u32 {
    return if (ready) undo.history_frames() else 0;
}

/// Closed records held.
pub fn record_count() usize {
    return if (ready) undo.record_count() else 0;
}

/// Slots the ring holds (0: no room, scrubber off).
pub fn capacity_slots() usize {
    return if (ready) undo.capacity_slots() else 0;
}

/// Slots in use by closed records and the open one.
pub fn slots_in_use() usize {
    return if (ready) undo.slots_in_use() else 0;
}

/// Arena bytes found (0 before `init`), whether or not it was enough.
pub fn arena_bytes() usize {
    return arena.len;
}
