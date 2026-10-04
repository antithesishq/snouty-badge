//! Performance and memory knobs, in one place (SPEC.md 8 and 19.5; the
//! numbers behind the defaults are in PLAN.md, M7 performance). Tune them
//! against badge-bench (`busy ms`, calibrated) and leave headroom: the
//! model is a floor.
//!
//! The core's own speed levers are not knobs: they are exact (the event
//! catch-up, `Gb.tick_lazy`; halted fast-forward, `Gb.halt_m`; skipped
//! pixel work for lines the frontend drops, `Gb.lines_wanted`) and change
//! nothing a game can observe.

// ---- Scrubber (frontend/rewind.zig, SPEC.md 10 and 19.3) ----

/// Game frames per keyframe. Shorter means quicker scrub steps and more
/// keyframes for the same pool (each costs its page table).
pub const frames_per_keyframe = 30;
/// Bytes per page-store page. Smaller pages share more but cost more
/// table entries (2 bytes per page per keyframe).
pub const page_size = 512;
/// Expected pages copied per keyframe, for splitting the arena between
/// pool pages and keyframe tables (frontend/rewind.zig `layout`). Measured
/// in tests/determinism.zig: 2048-gb 8, rex-runner 4, rebound 7 on average.
pub const typical_pages_per_keyframe = 8;

/// Keyframes at most, whatever the arena (frontend/rewind.zig lays it out
/// at start). 64 keyframes are 32 s of history at 30 frames each, about the
/// most the largest arena (an XIP build, about 250 KB) holds at the typical
/// 8 pages per keyframe: 64 x (8 x 515 + 2 x 162) bytes is 284 KB. The cap
/// also sizes the input log (`log_len` = 64 x 30 bytes in .bss), so a much
/// higher one would cost RAM for depth no arena can fill. At most 255 (the
/// store's reference count is a u8).
pub const max_keyframes = 64;

// ---- Debug overlay (frontend/debug.zig, SPEC.md 14) ----

/// Overlay on at boot (the menu toggles it). About 0.05 ms per frame with
/// the direct glyph blitter.
pub const debug_overlay = true;

// ---- Fast forward (main.zig `Ctx.step`, docs/FAST_FORWARD.md at the root) ----

/// Game frames per update at most while fast forwarding: 4x at 60 Hz.
/// All but the last skip their pixel work (`Gb.lines_wanted` cleared) and
/// render no sound.
pub const ff_max_frames = 4;
/// Microseconds of the 16.7 ms update, counted from its start, that the
/// skipped frames plus the final drawn frame may use (estimated from the
/// last measured frames); the rest is headroom for the overlay, the
/// present and a slow frame. On the badge only: in wasm
/// `micros_since_boot` is a stub, so there every fast update steps
/// `ff_max_frames`.
pub const ff_budget_us = 13_000;
/// The same for a game whose skipped frame plus drawn frame do not fit
/// `ff_budget_us` (DMG Tetris): the update takes two refreshes (33.3 ms)
/// on purpose and may step `2 * ff_max_frames` frames in this many
/// microseconds, so it still runs faster than 1x.
pub const ff_slow_budget_us = 28_000;
