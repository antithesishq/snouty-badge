//! Emulator menu: M2 (SPEC.md sections 5 and 17), a stub in M0.
//!
//! Plan (copied from Snouty Gear's frontend/menu.zig when M2 starts): a
//! 500 ms Select hold pauses the game under a panel titled "SNOUTY LYNX"
//! with the ROM name and "verified by deterministic replay"; rows Resume,
//! Buttons (A/B swap), Sound (off at boot, docs/SOUND.md), Debug overlay,
//! "Press Option 2", "Press Pause + Option 1" (restart), the drive ROM
//! list (SPEC.md 18.6: restart into the chosen file), About. Left/Right
//! scrub time 0.5 s once frontend/rewind.zig lands (M3).
//!
//! Until then main.zig ignores `GameInput.open_menu`, and only the title
//! below is used (the status strip).

/// The title the strip and, later, the menu band show.
pub const title = "SNOUTY LYNX";
