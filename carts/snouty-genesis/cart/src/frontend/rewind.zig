//! Time scrubber, the frontend half (SPEC.md section 10, PLAN.md "M3
//! Scrub: contract"): finds the RAM for the undo records and drives
//! `core.undo`, which owns the records and the dirty bytes and is
//! host-tested (`tests/undo_unit.zig`, `tests/determinism.zig`). This file
//! owns the arena and talks to the screen. Ported from Snouty Gear's
//! frontend/rewind.zig minus its page store and input log: an undo record
//! is applied by swapping its blocks with the console's, so Left and Right
//! are the same operation and nothing is replayed.
//!
//! Arena. On the badge the RAM the linker leaves between the end of `.bss`
//! and the stack (`__bss_end__`, `__stack_limit__` from the SDK's
//! cart_xip.ld), minus `tuning.stack_guard` below the stack limit, as in
//! Gear. It is not `.bss`, so it is not shipped as zeros in the UF2 and the
//! OS does not clear it; `core.undo` writes every slot before it reads it.
//! In wasm, which has no such symbols, it is a static array of
//! `tuning.wasm_arena_bytes`, about the badge's size, so the preview shows
//! badge-like depth. When fewer than two records' small state plus 64
//! blocks fit, `init` returns false and the scrubber stays off: the cart
//! runs untracked, the menu reads "Scrub: no memory" and
//! `capacity_slots` is 0.
//!
//! Picture while parked. `step` leaves the console exactly at the record
//! boundary; `show` draws all 128 rows from that state through the line
//! sink without stepping (`Md.render_still`), so the parked state is never
//! disturbed and the picture is the frame the game was about to draw.
//!
//! Resuming. The first frame stepped after a scrub must drop the records
//! ahead (they hold the future) and open a fresh record from the parked
//! state: main.zig calls `resume_if_parked` at the top of every running
//! update, before `step_frame` (`core.undo.resume_here`).
const std = @import("std");
const cart = @import("cart-api");
const core = @import("core");
const video = @import("video.zig");
const tuning = @import("tuning.zig");
const undo = core.undo;

/// Slots of one record's packed small state (`core.Md.Small`), from the
/// core when it says, else from the struct's size.
const small_slots = if (@hasDecl(undo, "small_slots"))
    undo.small_slots
else
    (@sizeOf(core.Md.Small) + undo.block_size - 1) / undo.block_size;
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
/// console exists (the arena does not depend on the ROM).
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

/// Forget all history and open record 0 from the console. Call at the end
/// of `begin` (new console, also after Pick ROM) and after the menu's Reset
/// (`Md.reset` writes the memories directly, past the write hooks).
pub fn reset(md: *core.Md) void {
    if (ready) undo.reset(md) else undo.disable();
}

/// Call after every stepped Genesis frame.
pub fn record_frame(md: *core.Md) void {
    if (ready) undo.record_frame(md);
}

/// Call before the first `step_frame` of a running update: after a scrub
/// the console is parked on a record boundary, and playing on from there
/// drops the future.
pub fn resume_if_parked(md: *core.Md) void {
    if (ready and undo.parked()) undo.resume_here(md);
}

/// True if a step in `dir` (-1 back, 1 forward) would move.
pub fn can_step(dir: i2) bool {
    return ready and undo.can_step(dir);
}

/// Move one record back (dir < 0) or forward (dir > 0) and draw the
/// restored state into the back buffer. False, changing nothing, at either
/// end of the history.
pub fn step(md: *core.Md, dir: i2) bool {
    if (!ready or !undo.step(md, dir)) return false;
    show(md);
    return true;
}

/// Draw the current (parked) state: the menu's Scale setting first, since
/// the recorded state keeps the console's `line_mode` and the player may
/// have changed it in this menu visit.
pub fn show(md: *core.Md) void {
    video.apply(md);
    md.render_still();
    video.finish_frame();
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
