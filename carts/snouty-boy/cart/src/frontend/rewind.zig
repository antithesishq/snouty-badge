//! Time scrubber storage (SPEC.md section 10): a static ring of keyframes
//! taken every 30 game frames plus a one-byte-per-frame input log covering
//! the same span. The index bookkeeping (which slot, which log byte,
//! truncation) is `core.ring.Ring`, host-tested in `tests/ring_unit.zig`;
//! this file owns the bytes and talks to the console and the screen.
//!
//! Keyframe size. Slots are `Gb.KeyframeWith(mmu.cart_ram_len(rom))`: the
//! ROM is embedded, so the cart RAM the game can touch is known at compile
//! time (0, 2 KB or 8 KB) and the slot carries only that much. With
//! 2048-gb (2 KB RAM) a slot is about 18.9 KB instead of 24.9 KB.
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
const rom = @import("rom");
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

pub const Slot = Gb.KeyframeWith(core.mmu.ram_len_for(if (rom.data.len < 0x150) 0 else rom.data[0x149]));

// ---- Memory budget (SPEC.md 13) ----

/// Cart RAM for .text + .data + .bss: 307 KB minus the 32 KB stack.
const usable_ram = 268 * 1024;
/// Bytes the ring aims for: keyframes plus input log.
const ring_budget_target = 150 * 1024;
/// Code, constants and .data, not counting the ROM (M4 fast build: about
/// 50 KB), with headroom.
const code_estimate = 56 * 1024;
/// Other .bss: the live console plus frontend statics (palette LUT, line
/// buffers, menu, debug windows), with headroom.
const other_bss_estimate = @sizeOf(Gb) + 4 * 1024;
const self_check_bytes = if (self_check) @sizeOf(Gb) + @sizeOf(Slot) else 0;
const fixed_bytes = code_estimate + rom.data.len + other_bss_estimate + self_check_bytes;
const ring_budget = if (fixed_bytes >= usable_ram) 0 else @min(ring_budget_target, usable_ram - fixed_bytes);
const slot_cost = @sizeOf(Slot) + frames_per_keyframe; // keyframe + its log bytes

/// Keyframes in the ring, derived from the budget. 7 with 2048-gb:
/// 3.0 to 3.5 s of history.
pub const slots = ring_budget / slot_cost;

comptime {
    if (slots < 2) @compileError(std.fmt.comptimePrint(
        "rewind: the ROM ({d} bytes) leaves room for fewer than 2 keyframes of {d} bytes; " ++
            "a smaller ROM or SPEC.md 10.4 compression is needed",
        .{ rom.data.len, @sizeOf(Slot) },
    ));
    const total = fixed_bytes + slots * slot_cost;
    if (total > usable_ram) @compileError(std.fmt.comptimePrint(
        "rewind: estimated cart RAM {d} bytes exceeds the {d} usable (SPEC.md 13)",
        .{ total, usable_ram },
    ));
}

const R = core.ring.Ring(slots, frames_per_keyframe);

var ring: R = .{};
var keyframes: [slots]Slot = undefined;
var log: [R.log_len]u8 = @splat(0);

/// Forget all history and take the reset console as keyframe 0. Call after
/// `Gb.init` and after every `gb.reset()`.
pub fn reset(gb: *const Gb) void {
    gb.snapshot(&keyframes[ring.reset()]);
    debug.alarm = false;
}

/// Call after every stepped game frame with the pad it was stepped with.
/// Truncates the future if the game was resumed from a scrubbed position.
pub fn record_frame(gb: *const Gb, pad: u8) void {
    const rec = ring.record();
    log[rec.log_index] = pad;
    if (rec.snapshot_slot) |s| {
        gb.snapshot(&keyframes[s]);
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
                gb.restore(&keyframes[r.slot]);
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
    const k = &keyframes[slot];
    gb.restore(k);
    const f = ring.position();
    const pad = if (ring.has_pad(f)) log[R.log_index(f)] else gb.pad;
    gb.step_frame(pad);
    video.finish_frame();
    gb.restore(k);
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
var check_slot: Slot = undefined;

/// Replay the previous keyframe with the logged pads into `spare` and
/// compare with the keyframe just taken.
fn check_newest(game_rom: *const Gb.Rom) void {
    if (ring.count < 2) return;
    // No struct literals or by-value arrays here: the wasm stack is 14.7 KB
    // and a `Gb` temporary alone is 25 KB. `restore` sets every field but
    // these two.
    spare.rom = game_rom.*;
    spare.line_sink = null;
    spare.restore(&keyframes[ring.slot_of_age(1)]);
    var f = ring.frame_of_age(1);
    while (f < ring.frame_of_age(0)) : (f += 1) spare.step_frame(log[R.log_index(f)]);
    spare.snapshot(&check_slot);
    const newest = &keyframes[ring.slot_of_age(0)];
    inline for (@typeInfo(Slot).@"struct".field_names) |name| {
        const x = &@field(check_slot, name);
        const y = &@field(newest, name);
        const same = switch (@typeInfo(@TypeOf(x.*))) {
            .array => std.mem.eql(u8, x, y),
            else => std.meta.eql(x.*, y.*),
        };
        if (!same) debug.alarm = true;
    }
}
