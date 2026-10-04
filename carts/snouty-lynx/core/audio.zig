//! Mikey's four audio channels, heard (PLAN.md "M5 Sound: contract",
//! SPEC.md section 9). M5 interface stub: the constants and the output
//! format are frozen; the channel model (Track A) replaces the silence.
//!
//! Output: `Lynx.audio_out`, `samples_per_frame` unsigned 8-bit mono
//! samples at `sample_rate` (128 = silence), the badge firmware's
//! streaming format, covering exactly the Lynx time of the last
//! `step_frame` (1/60 s). Not console state: `Lynx.Small` leaves it out.

/// The badge firmware's streaming rate (sycl-badge upstream api.zig
/// `audio_sample_rate`).
pub const sample_rate: u32 = 44100;
/// 1/60 s at `sample_rate`, exactly.
pub const samples_per_frame: u32 = sample_rate / 60;
/// The unsigned 8-bit midpoint.
pub const silence: u8 = 128;

comptime {
    if (samples_per_frame * 60 != sample_rate) @compileError("44.1 kHz / 60 must be whole");
}
