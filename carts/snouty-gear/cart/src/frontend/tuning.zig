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
/// pages and keyframe tables (frontend/rewind.zig `init`): about 5 KB per
/// keyframe, the SPEC.md 10 measurement on Waternet.
pub const typical_pages_per_keyframe = 40;
/// Keyframes at most, whatever the arena: 64 are 32 s of history at 30
/// frames each. The cap also sizes the input log (`64 x 30` bytes in
/// `.bss`). At most 255 (the store's reference count is a u8). The RAM
/// cart's arena (about 69 KB) holds far fewer at the typical rate.
pub const max_keyframes = 64;
/// Bytes kept free between the arena and the stack limit on the badge.
pub const stack_guard = 1024;
