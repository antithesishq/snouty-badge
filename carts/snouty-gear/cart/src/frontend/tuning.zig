//! Performance and memory knobs of the time scrubber, in one place
//! (SPEC.md sections 10 and 13; PLAN.md "M3 Scrub: contract" freezes the
//! names). Copied from Snouty Boy's frontend/tuning.zig with the Game Gear
//! numbers. Tune them against badge-bench (`busy ms`, calibrated) and leave
//! headroom: the model is a floor.

// ---- Scrubber (frontend/rewind.zig, SPEC.md 10) ----

/// Game frames per keyframe: one every 0.5 s, the scrub step. Shorter
/// means quicker scrub steps and more keyframes for the same pool (each
/// costs its page table).
pub const frames_per_keyframe = 30;
/// Bytes per page-store page. Smaller pages share more but cost more table
/// entries (2 bytes per page per keyframe): at 128 B a keyframe's table is
/// 257 references (514 B) for the 32.1 KB of Game Gear state (small state,
/// 8 KB RAM, 16 KB VRAM, 8 KB cart RAM). The integration may change it
/// after Track A's sizing numbers (tests/scrub_sizing.zig).
pub const page_size = 128;
/// Expected pages copied per keyframe, for splitting the arena between pool
/// pages and keyframe tables (frontend/rewind.zig `init`). Measured through
/// the store (tests/scrub_sizing.zig, 2026-09-30): Waternet copies 13 pages
/// per keyframe on average, Sonic 29. 24 splits the badge's 54 KB arena
/// into 15 keyframe tables and a 46 KB pool: Waternet keeps all 15 (7 s),
/// Sonic fills the pool at about 12 (5.5 s) and evicts from there.
pub const typical_pages_per_keyframe = 24;
/// Keyframes at most, whatever the arena: 32 are 16 s of history at 30
/// frames each. The cap also sizes the input log (`32 x 30` bytes in
/// `.bss`). At most 255 (the store's reference count is a u8). The RAM
/// cart's arena (54 KB) holds about 15 at the typical rate.
pub const max_keyframes = 32;
/// Bytes kept free between the arena and the stack limit on the badge.
pub const stack_guard = 1024;

// ---- Fast forward (main.zig, docs/FAST_FORWARD.md at the root) ----

/// Frames after a short Select press (released before the menu hold) in
/// which a second press starts fast forward (frontend/input.zig): 200 ms.
pub const ff_tap_window = 12;

/// Game frames at most in one fast-forward update, the rendered one
/// included: the speed cap (4x at 60 Hz). The simulator, whose
/// `micros_since_boot` is a stub, always runs this many.
pub const ff_max_frames = 4;
/// Microseconds of the 16.7 ms update that fast forward may use, measured
/// from just before the first frame. Another unrendered frame is stepped
/// only while the time so far plus twice the dearest frame of this update
/// (the next unrendered one and the final rendered one) stays within it:
/// 3.7 ms of headroom for the overlay, the present and a dearer frame.
pub const ff_budget_us = 13_000;
