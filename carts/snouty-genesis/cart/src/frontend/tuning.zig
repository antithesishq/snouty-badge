//! Memory knobs of the time scrubber (SPEC.md section 10; PLAN.md "M3
//! Scrub: contract" freezes the names), in one place as in Snouty Gear's
//! frontend/tuning.zig. The record interval, block size and record cap are
//! the core's (`core.undo.frames_per_record`, `block_size`, `max_records`):
//! they are part of the undo format, not a frontend choice.

/// Bytes kept free between the arena and the stack limit on the badge
/// (frontend/rewind.zig `find_arena`).
pub const stack_guard = 1024;

/// The wasm build has no linker symbols for the free RAM, so its arena is a
/// static array of this size. It should match the badge's arena (RAM window
/// 0x4AF00 minus the 32 KB stack, `.data`, `.bss` and `stack_guard`, from
/// `size -A` of the XIP ELF) so the simulator and the headless preview show
/// badge-like depth; integration sets the final figure. 100 KB until then.
pub const wasm_arena_bytes = 100 * 1024;
