//! Memory knobs of the time scrubber (SPEC.md section 10; PLAN.md "M3
//! Scrub: contract" freezes the names), in one place as in Snouty Gear's
//! frontend/tuning.zig. The record interval, block size and record cap are
//! the core's (`core.undo.frames_per_record`, `block_size`, `max_records`):
//! they are part of the undo format, not a frontend choice. Below them the
//! fast-forward knobs (docs/FAST_FORWARD.md at the root), named as in
//! Gear.

/// Bytes kept free between the arena and the stack limit on the badge
/// (frontend/rewind.zig `find_arena`).
pub const stack_guard = 1024;

/// The wasm build has no linker symbols for the free RAM, so its arena is a
/// static array of this size. It should match the badge's arena (RAM window
/// 0x4AF00 minus the 32 KB stack, `.data`, `.bss` and `stack_guard`, from
/// `size -A` of the XIP ELF) so the simulator and the headless preview show
/// badge-like depth; integration sets the final figure. 100 KB until then.
pub const wasm_arena_bytes = 101 * 1024;

// ---- Fast forward (app.zig, docs/FAST_FORWARD.md at the root) ----

/// Updates after a short Select press (released before the menu hold) in
/// which a second press starts fast forward (frontend/input.zig): 200 ms
/// at 30 updates a second. The tap itself (a Genesis button) is held back
/// until the window runs out, so it reaches the game this much later.
pub const ff_tap_window_updates = 6;

/// Genesis frames at most in one fast-forward update, the rendered one
/// included: the speed cap (8 = 4x the 1x pair). The simulator, whose
/// `micros_since_boot` is a stub, always runs this many.
pub const ff_max_frames = 8;
/// Microseconds of the 33.3 ms update that fast forward may use, measured
/// from the top of the update. Another unrendered frame is stepped only
/// while the time so far plus the dearest unrendered frame (this update's,
/// or the last one before it) and the last rendered frame stays within it:
/// 5.3 ms of headroom for the overlay, the present and a dearer frame.
/// (Gear's "twice the dearest frame" held Miniplanets and Sonic 1 to 1x
/// here: a rendered Genesis frame costs about 1.5x an unrendered one.)
/// Fast forward never steps fewer than the 1x pair.
pub const ff_budget_us = 28_000;

/// A link race (docs/LINK_PLAY.md): the update pumps the link
/// until this long after it began (the vsync wait between updates would
/// otherwise leave the receive FIFO unread), and waits for the partner's
/// pad only while the tick (its last cost) still ends before it.
pub const link_pump_until_us: u64 = 31_000;
