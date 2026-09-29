//! PSG -> one tone2 voice (SPEC.md section 9). M2 stub with the frozen
//! public shape (PLAN.md M2 contract); Track B fills it in. The stub never
//! touches the buzzer.
const core = @import("core");

/// Sound approximation on/off; main.zig keeps it equal to the menu's
/// `sound_enabled` every frame.
pub var enabled: bool = true;

/// What the buzzer is doing, as last commanded (read by the `debug_tone_hz`
/// export): `playing` false means stopped, else `last_hz` is sounding.
pub var playing: bool = false;
pub var last_hz: u32 = 0;

/// Once per badge frame after `step_frame`, and every menu frame too (so a
/// toggle to off stops the tone while paused).
pub fn update(gg: *const core.Gg) void {
    _ = gg;
}

/// Boot chime: step 0 the first note, step 1 the second (SPEC.md 12).
pub fn chime(step: u8) void {
    _ = step;
}
