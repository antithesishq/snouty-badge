//! Memory knobs of the time scrubber (SPEC.md section 10; PLAN.md "M3
//! Scrub: contract" freezes the names), as in Snouty Genesis's
//! frontend/tuning.zig. The record interval, block size and record cap are
//! the core's (`core.undo.frames_per_record`, `block_size`, `max_records`):
//! they are part of the undo format, not a frontend choice.

/// Bytes kept free between the arena and the stack limit on the badge
/// (frontend/rewind.zig `find_arena`).
pub const stack_guard = 1024;

/// The wasm build has no linker symbols for the free RAM, so its arena is a
/// static array of this size. It should match the badge's arena
/// (`__stack_limit__` - `__bss_end__` - `stack_guard` of the build
/// integration picks) so the simulator and the headless preview show
/// badge-like depth; integration sets the final figure. The ReleaseFast
/// RAM build of the M3 prep commit leaves 40,632 B, so 40 KB until then.
/// The badge's figure at M3 integration: `__stack_limit__` 0x20078000 -
/// `__bss_end__` 0x200683b0 - `stack_guard` = 63,568 B (ReleaseFast, exec
/// not inlined; docs/SCRUB.md). Re-measure when the cart grows.
pub const wasm_arena_bytes = 63_568;
