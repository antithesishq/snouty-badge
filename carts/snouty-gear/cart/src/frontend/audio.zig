//! PSG -> one tone2 voice (SPEC.md section 9), adapted from Snouty Boy.
//! `core.psg.Psg.voice()` chooses the channel (loudest tone channel, noise
//! and periods below 2 dropped, ties to the lowest channel); this module
//! turns it into a square buzzer tone and only calls `tone2` when the
//! audible result (frequency or volume) changes. Allocation-free; f32 is
//! fine here (frontend, not core).
//!
//! main.zig calls `update(&gg)` once per badge frame after `step_frame` and
//! on every menu frame (so switching sound off stops the tone while
//! paused), keeps `enabled` equal to the menu's sound setting, and plays
//! `chime(0)` / `chime(1)` for the two notes of the boot chime.
const cart = @import("cart-api");
const core = @import("core");

/// Sound approximation on/off; main.zig keeps it equal to the menu's
/// `sound_enabled` every frame.
pub var enabled: bool = true;

/// What the buzzer is doing, as last commanded (read by the `debug_tone_hz`
/// export): `playing` false means stopped, else `last_hz` is sounding.
pub var playing: bool = false;
pub var last_hz: u32 = 0;
/// Attenuation (0..14) of the voice last sent.
var last_atten: u4 = 0;

/// Frequencies outside this range are treated as silence: period 2 is
/// 56 kHz and period 7 (16 kHz) is the first one kept. The longest period
/// (1023) is 109 Hz, so the low bound is only a guard.
const min_hz: u32 = 20;
const max_hz: u32 = 16000;

/// Attenuation 0 (loudest) .. 14 -> tone2 volume 1.0 .. 0.2, linear in the
/// 2 dB steps (Snouty Boy is linear in its envelope volume too).
pub fn volume_f32(atten: u4) f32 {
    const a: f32 = @floatFromInt(@min(atten, 14));
    return 1.0 - a * (0.8 / 14.0);
}

fn stop() void {
    if (!playing) return;
    cart.tone2(cart.Tone2Options.stop);
    playing = false;
}

/// Once per badge frame after `step_frame`, and every menu frame too.
pub fn update(gg: *const core.Gg) void {
    if (!enabled) return stop();
    const v = gg.psg.voice() orelse return stop();
    if (v.hz < min_hz or v.hz > max_hz) return stop();
    if (playing and v.hz == last_hz and v.atten == last_atten) return;
    cart.tone2(.{
        .frequency = @floatFromInt(v.hz),
        .duration = -1.0,
        .volume = volume_f32(v.atten),
        .flags = .{ .shape = .square },
    });
    playing = true;
    last_hz = v.hz;
    last_atten = v.atten;
}

/// Boot chime (SPEC.md 12): step 0 = 1046 Hz, step 1 = 2093 Hz, 60 ms each
/// at full volume. Plays regardless of the voice state; the next `update`
/// re-issues the game's voice if one is audible.
pub fn chime(step: u8) void {
    if (!enabled) return;
    cart.tone2(.{
        .frequency = if (step == 0) 1046.0 else 2093.0,
        .duration = 0.06,
        .volume = 1.0,
        .flags = .{ .shape = .square },
    });
    // The chime cancelled whatever was playing. Mark the buzzer idle so
    // `update` does not stop the chime early when the game is silent, and
    // re-sends the game's voice if one is audible.
    playing = false;
}
