//! APU state -> one tone2 voice (SPEC.md section 9). Owner: M3 track E.
//! `core.apu.pick_voice` chooses the channel; this module converts it to a
//! buzzer tone and only calls `tone2` when the audible result changes.
//! Allocation-free; f32 is fine here (frontend, not core).
//!
//! Integrator: call `update(&gb)` once per badge frame after `step_frame`
//! (also while paused in the menu, so a toggle to off stops the tone);
//! keep `enabled` equal to the menu's sound setting; `chime(0)` / `chime(1)`
//! for the two notes of the boot chime.
const cart = @import("cart-api");
const core = @import("core");
const apu = core.apu;

/// Sound approximation on/off (menu toggle, default on; SPEC.md 18.6).
pub var enabled: bool = true;

/// Frequencies outside this range are treated as silence (games park a
/// channel at period 2047, which would be 131 kHz).
const min_hz: u32 = 20;
const max_hz: u32 = 16000;

const Shape = cart.Tone2Options.Shape;

/// What the buzzer is currently doing, as last commanded.
var playing: bool = false;
var last_hz: u32 = 0;
var last_shape: Shape = .square;
var last_volume: u8 = 0;

/// Envelope volume 1..15 -> tone2 volume 0.2..1.0.
pub fn volume_f32(v: u8) f32 {
    const c: f32 = @floatFromInt(@min(@max(v, 1), 15) - 1);
    return 0.2 + c * (0.8 / 14.0);
}

fn stop() void {
    if (!playing) return;
    cart.tone2(cart.Tone2Options.stop);
    playing = false;
}

pub fn update(gb: *const core.Gb) void {
    if (!enabled) return stop();
    const v = apu.pick_voice(gb);
    if (v.channel == 0) return stop();
    const hz = apu.period_to_hz(v.channel, v.period);
    if (hz < min_hz or hz > max_hz) return stop();
    const shape: Shape = if (v.channel == 3) .triangle else .square;
    if (playing and hz == last_hz and shape == last_shape and v.volume == last_volume) return;
    cart.tone2(.{
        .frequency = @floatFromInt(hz),
        .duration = -1.0,
        .volume = volume_f32(v.volume),
        .flags = .{ .shape = shape },
    });
    playing = true;
    last_hz = hz;
    last_shape = shape;
    last_volume = v.volume;
}

/// DMG-style boot chime: step 0 = 1046 Hz, step 1 = 2093 Hz, 60 ms each.
/// Plays regardless of the voice state; the next `update` re-issues the
/// game's voice if one is audible.
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
