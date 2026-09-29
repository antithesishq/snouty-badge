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
/// Expected pages copied per keyframe, for splitting the budget between
/// pool pages and keyframe tables. Measured in tests/determinism.zig:
/// 2048-gb 8, rex-runner 4, rebound 7 on average.
pub const typical_pages_per_keyframe = 8;

// ---- RAM cart budget (frontend/rewind.zig, SPEC.md 13 and 19.4) ----

/// Code, constants and .data of the RAM cart, not counting the ROM; the
/// page pool gets what is left. Too small and the link fails ("BSS
/// overflows into stack region"); every KB above what the link needs is a
/// KB of pool lost. 2026-09-29, fast build: code about 67.9 KB, and 66 KB
/// here leaves about 3 KB unused (the other estimates in rewind.zig carry
/// some slack too).
pub const code_estimate = 66 * 1024;

// ---- Debug overlay (frontend/debug.zig, SPEC.md 14) ----

/// Overlay on at boot (the menu toggles it). About 0.05 ms per frame with
/// the direct glyph blitter.
pub const debug_overlay = true;
