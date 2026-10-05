//! Memory knobs of the time scrubber (SPEC.md section 10; PLAN.md "M3
//! Scrub: contract" freezes the names), as in Snouty Genesis's
//! frontend/tuning.zig. The record interval, block size and record cap are
//! the core's (`core.undo.frames_per_record`, `block_size`, `max_records`):
//! they are part of the undo format, not a frontend choice. The
//! fast-forward knobs (Snouty Gear's names and numbers) are at the end.

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
/// not inlined; docs/SCRUB.md). M4 (the opcode switch inside the run
/// loop, .text 728 B smaller): `__bss_end__` 0x20068118, 64,232 B. M5
/// plan commit (`audio_out` and later M4 changes): 0x200686e0, 62,752 B;
/// M5 Track B (the 4 KB streaming ring, 830 B of push scratch, 1.5 KB of
/// sound code): 0x2006a058, 56,232 B. Re-measure when the cart grows.
pub const wasm_arena_bytes = 56_232;

// ---- Fast forward (main.zig, docs/FAST_FORWARD.md at the root) ----

/// Frames after a short Select press (released before the menu hold) in
/// which a second press starts fast forward (frontend/input.zig): 200 ms.
/// The tap itself (Option 1) is held back until the window runs out.
pub const ff_tap_window = 12;

/// Game frames at most per 60 Hz badge frame while fast forwarding, the
/// rendered one included: the speed cap (4x). The simulator, whose
/// `micros_since_boot` is a stub, runs this many every update.
pub const ff_max_frames = 4;
/// Badge frames (vsync periods) one fast-forward update spans on the
/// badge. A Lynx frame costs 6-10 ms on the badge (raycast walking ~7.5,
/// Hard Drivin' driving ~9), so two rarely fit one 16.7 ms update with
/// headroom and Snouty Gear's one-period update gives ~1x (PLAN.md "Fast
/// forward"). Over two periods three or four fit: the update runs ~30 ms,
/// the present waits for the second vsync, and the picture changes 30
/// times a second while fast. `ff_max_frames * ff_periods` frames at most.
pub const ff_periods = 2;
/// Microseconds of the `ff_periods` x 16.7 ms that a fast-forward update
/// may use, measured from the top of the update. Another unrendered frame
/// is stepped only while the time so far plus twice the dearest frame of
/// this update (the next unrendered one and the final rendered one) stays
/// within it: Gear's rule, with its 3.7 ms of headroom for the picture,
/// the strip, the present and a dearer frame.
pub const ff_budget_us = ff_periods * 16_667 - 3_700;

// ---- Link cable (frontend/cable.zig, docs/CABLE.md) ----

/// While linked the cart keeps reading and answering the cable until this
/// long after the update began (Snouty Boy's figure): acks return within
/// a pump instead of a frame. Unlinked nothing pumps.
pub const link_pump_until_us = 14_000;

/// While linked a game frame steps in this many slices with the cable
/// serviced after each (`Lynx.run_to`): a ComLynx frame waits at most a
/// slice before it leaves, not a whole frame (docs/CABLE.md "Timing").
pub const link_slices = 4;
