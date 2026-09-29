//! Time scrubber storage (SPEC.md section 10): a ring of keyframes
//! taken every 30 game frames plus a one-byte-per-frame input log covering
//! the same span. The index bookkeeping (which slot, which log byte,
//! truncation) is `core.ring.Ring`, host-tested in `tests/ring_unit.zig`;
//! this file owns the bytes and talks to the console and the screen.
//!
//! Keyframe pool (SPEC.md 13, PLAN.md M5). The ROM, and with it the cart
//! RAM a keyframe must carry (0, 2 KB or 8 KB, `mmu.cart_ram_len`), is only
//! known at `start()` once the drive has been looked at, so the slots are
//! laid out at run time in one byte pool: slot i is a `Gb.Fixed` followed by
//! that much cart RAM, at `i * stride`. On the badge the pool is the RAM the
//! linker leaves between the end of `.bss` and the stack (`__bss_end__`,
//! `__stack_limit__` from the SDK's cart_ram.ld / cart_xip.ld), minus 1 KB
//! of guard below the stack limit. It is not `.bss`, so it is not shipped
//! as zeros in the UF2 (docs/ROM_DRIVE.md section 3) and the OS does not
//! clear it; that is fine because every slot is written before it is read
//! (the ring only hands out slots it has recorded). In wasm, which has no
//! such linker symbols, it is a static 160 KB array.
//!
//! Frozen frame after a scrub step. The console is restored to the keyframe
//! exactly and stays there; to put a picture on screen the keyframe is
//! stepped one frame with the logged pad for that frame (the PPU draws
//! through the normal line sink into the back buffer) and then restored
//! again from the same slot. So the state is exactly the keyframe's, and
//! the picture is the frame the game showed 1/60 s later. This costs one
//! `step_frame` per scrub step and no RAM, where storing a 2-bit 160x144
//! image per keyframe would cost 5,760 bytes each (N 7 -> 5 at the same
//! budget). Determinism accounting is untouched: resuming steps the game
//! from the keyframe itself. If the pad for that frame is not logged yet
//! (the newest keyframe, taken on the very last frame played), the
//! keyframe's own pad is used for the preview only.
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
const Gb = core.Gb;

/// SPEC.md 18 item 7: one keyframe every 0.5 s.
pub const frames_per_keyframe = 30;

/// When true, every new keyframe is checked by replaying the previous one
/// into a spare console (SPEC.md 10.2, last sentence); a mismatch paints the
/// debug overlay red (`debug.alarm`). Costs a second `Gb` plus one slot of
/// RAM and doubles the CPU per frame, so it is off for the badge.
const self_check = false;

/// Slot count cap (SPEC.md 18 item 12): 12 keyframes are 5.5 to 6 s of
/// history, and the input log is sized for it.
const R = core.ring.Ring(12, frames_per_keyframe);

var ring: R = .{};
/// In .bss (zeroed by the OS), unlike the pool.
var log: [R.log_len]u8 = @splat(0);

/// Bytes kept free between the pool and the stack limit.
const stack_guard = 1024;

/// The wasm pool; the badge build never references it.
var wasm_pool: [160 * 1024]u8 align(@alignOf(Gb.Fixed)) = undefined;

const linker = struct {
    extern var __bss_end__: u8;
    extern var __stack_limit__: u8;
};

var pool: []align(@alignOf(Gb.Fixed)) u8 = &.{};
/// Bytes per slot: a `Gb.Fixed` plus `ram_len`, rounded up so every slot's
/// `Fixed` stays aligned.
var stride: usize = 0;
/// Cart RAM bytes per keyframe for the running ROM.
var ram_len: usize = 0;

/// Lay out the pool for the ROM in `gb`. Call once, after `Gb.init_rom` and
/// before `reset`. Returns false when fewer than 2 slots fit (the cart then
/// refuses to start; see main.zig).
pub fn init(gb: *const Gb) bool {
    if (cart.is_wasm) {
        pool = &wasm_pool;
    } else {
        const lo = std.mem.alignForward(usize, @intFromPtr(&linker.__bss_end__), @alignOf(Gb.Fixed));
        const hi = @intFromPtr(&linker.__stack_limit__) -| stack_guard;
        const len = if (hi > lo) hi - lo else 0;
        pool = @as([*]align(@alignOf(Gb.Fixed)) u8, @ptrFromInt(lo))[0..len];
    }
    ram_len = core.mmu.cart_ram_len(&gb.rom);
    stride = std.mem.alignForward(usize, @sizeOf(Gb.Fixed) + ram_len, @alignOf(Gb.Fixed));
    const n = @min(pool.len / stride, R.max_slots);
    ring = R.init(n);
    return n >= 2;
}

/// Keyframe slots in use (0 before `init`).
pub fn slot_count() usize {
    return if (stride == 0) 0 else ring.n;
}

/// Bytes in the pool (for the report; 0 before `init`).
pub fn pool_bytes() usize {
    return pool.len;
}

fn fixed(slot: usize) *Gb.Fixed {
    return @ptrCast(@alignCast(pool[slot * stride ..].ptr));
}

fn ram(slot: usize) []u8 {
    return pool[slot * stride + @sizeOf(Gb.Fixed) ..][0..ram_len];
}

fn snapshot(gb: *const Gb, slot: usize) void {
    gb.snapshot_pool(fixed(slot), ram(slot));
}

fn restore(gb: *Gb, slot: usize) void {
    gb.restore_pool(fixed(slot), ram(slot));
}

/// Forget all history and take the reset console as keyframe 0. Call after
/// `Gb.init` and after every `gb.reset()`.
pub fn reset(gb: *const Gb) void {
    snapshot(gb, ring.reset());
    debug.alarm = false;
}

/// Call after every stepped game frame with the pad it was stepped with.
/// Truncates the future if the game was resumed from a scrubbed position.
pub fn record_frame(gb: *const Gb, pad: u8) void {
    const rec = ring.record();
    log[rec.log_index] = pad;
    if (rec.snapshot_slot) |s| {
        snapshot(gb, s);
        if (self_check) check_newest(&gb.rom);
    }
}

pub fn can_step(dir: i2) bool {
    return ring.can_step(dir);
}

/// Move one keyframe back (dir < 0) or forward (dir > 0), restore it into
/// `gb` and draw its picture into the back buffer (see the file comment).
/// Returns false, changing nothing, at either end of the history.
pub fn step(gb: *Gb, dir: i2) bool {
    const s = ring.step(dir) orelse return false;
    switch (s) {
        .restore => |slot| show_keyframe(gb, slot),
        .replay => |r| {
            if (r.from == r.to) {
                // Live was the newest keyframe itself.
                show_keyframe(gb, r.slot);
            } else {
                restore(gb, r.slot);
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

/// Restore `slot`, render one frame from it, restore it again.
fn show_keyframe(gb: *Gb, slot: usize) void {
    restore(gb, slot);
    const f = ring.position();
    const pad = if (ring.has_pad(f)) log[R.log_index(f)] else gb.pad;
    gb.step_frame(pad);
    video.finish_frame();
    restore(gb, slot);
}

/// How far behind the live position the game is parked, in frames (0 live).
pub fn depth_frames() u32 {
    return ring.depth_frames();
}

/// Frames of history reachable from the live position.
pub fn history_frames() u32 {
    return ring.history_frames();
}

/// History as fifths of the full ring, 0..5 (one neopixel per fifth).
pub fn history_fraction() u8 {
    return ring.history_fraction();
}

/// Valid keyframes in the ring.
pub fn keyframe_count() usize {
    return ring.count;
}

// ---- Self-check (SPEC.md 10.2 in the cart; compiled only if enabled) ----

var spare: Gb = undefined;
/// Pool-shaped scratch slot for the replayed console.
var check_fixed: Gb.Fixed = undefined;
var check_ram: [0x2000]u8 = undefined;

/// Replay the previous keyframe with the logged pads into `spare` and
/// compare with the keyframe just taken.
fn check_newest(game_rom: *const core.Rom) void {
    if (ring.count < 2) return;
    // No struct literals or by-value arrays here: the wasm stack is 14.7 KB
    // and a `Gb` temporary alone is 25 KB. `restore` sets every field but
    // these two.
    spare.rom = game_rom.*;
    spare.line_sink = null;
    restore(&spare, ring.slot_of_age(1));
    var f = ring.frame_of_age(1);
    while (f < ring.frame_of_age(0)) : (f += 1) spare.step_frame(log[R.log_index(f)]);
    spare.snapshot_pool(&check_fixed, check_ram[0..ram_len]);
    const newest = ring.slot_of_age(0);
    const k = fixed(newest);
    inline for (@typeInfo(Gb.Fixed).@"struct".field_names) |name| {
        const x = &@field(check_fixed, name);
        const y = &@field(k, name);
        const same = switch (@typeInfo(@TypeOf(x.*))) {
            .array => std.mem.eql(u8, x, y),
            else => std.meta.eql(x.*, y.*),
        };
        if (!same) debug.alarm = true;
    }
    if (!std.mem.eql(u8, check_ram[0..ram_len], ram(newest))) debug.alarm = true;
}
