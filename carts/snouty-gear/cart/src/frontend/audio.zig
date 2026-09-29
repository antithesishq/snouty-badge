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
//!
//! Simulator (wasm). The upstream wasm shim turns `duration = -1` into
//! `0xFFFFFFFF`, which the simulator's WASM-4 style worklet unpacks as a
//! 255-frame attack, decay, sustain and release: every tone starts with a
//! 4 s fade-in from silence, so music that changes note every few frames
//! is never heard (found with Sonic, 2026-09-29). The badge OS plays an
//! infinite tone correctly, so only the wasm build bypasses `cart.tone2`
//! and calls the simulator's `tone` import itself with WASM-4 packing: no
//! attack, a short sustain re-issued every frame while the voice is
//! audible (the worklet keeps the phase of a channel that is still
//! playing, so this is one continuous tone), 50% duty. The same import is
//! what `cart.tone2` reaches on wasm; hardware builds compile none of it.
const cart = @import("cart-api");
const core = @import("core");

/// Sound approximation on/off; main.zig keeps it equal to the menu's
/// `sound_enabled` every frame.
pub var enabled: bool = true;

/// Cap on every tone the cart plays (the game's voice and the chime), 0..1
/// on the OS's perceptually linear scale (about 50 dB from 0 to 1). A
/// knob for the badge speaker, which coworkers find loud.
pub const max_volume: f32 = 1.0;

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
/// 2 dB steps (Snouty Boy is linear in its envelope volume too), then the
/// `max_volume` cap.
pub fn volume_f32(atten: u4) f32 {
    const a: f32 = @floatFromInt(@min(atten, 14));
    return (1.0 - a * (0.8 / 14.0)) * max_volume;
}

// ---- Simulator path (wasm only) ----

const sim = struct {
    /// The simulator's audio import (sycl-badge/simulator/src/apu-worklet.ts,
    /// WASM-4 packing): `frequency` start | end << 16; `duration` sustain |
    /// release << 8 | decay << 16 | attack << 24, in 60 Hz frames; `volume`
    /// sustain | peak << 8, 0..100; `flags` channel | mode << 2 | pan << 4.
    extern fn tone(frequency: u32, duration: u32, volume: u32, flags: u32) void;

    /// Channel 0 (pulse), mode 2 = 50% duty, centre.
    const flags: u32 = 0 | (2 << 2);
    /// Frames one issue sustains; re-issued every frame while audible, so
    /// only a stall longer than this leaves a gap.
    const sustain_frames: u32 = 6;

    fn play(hz: u32, volume: f32, frames: u32) void {
        const v: u32 = @intFromFloat(@round(@max(0.0, @min(1.0, volume)) * 100.0));
        tone(hz, frames, v, flags);
    }

    fn stop() void {
        tone(0, 0, 0, flags);
    }
};

fn stop() void {
    if (!playing) return;
    if (cart.is_wasm) sim.stop() else cart.tone2(cart.Tone2Options.stop);
    playing = false;
}

/// Once per badge frame after `step_frame`, and every menu frame too.
pub fn update(gg: *const core.Gg) void {
    if (!enabled) return stop();
    const v = gg.psg.voice() orelse return stop();
    if (v.hz < min_hz or v.hz > max_hz) return stop();
    if (cart.is_wasm) {
        // Re-issued every frame: the simulator plays finite tones only.
        sim.play(v.hz, volume_f32(v.atten), sim.sustain_frames);
    } else {
        if (playing and v.hz == last_hz and v.atten == last_atten) return;
        cart.tone2(.{
            .frequency = @floatFromInt(v.hz),
            .duration = -1.0,
            .volume = volume_f32(v.atten),
            .flags = .{ .shape = .square },
        });
    }
    playing = true;
    last_hz = v.hz;
    last_atten = v.atten;
}

/// Boot chime (SPEC.md 12): step 0 = 1046 Hz, step 1 = 2093 Hz, 60 ms each
/// at full volume. Plays regardless of the voice state; the next `update`
/// re-issues the game's voice if one is audible.
pub fn chime(step: u8) void {
    if (!enabled) return;
    const hz: u32 = if (step == 0) 1046 else 2093;
    if (cart.is_wasm) {
        sim.play(hz, max_volume, 4); // 4 frames, about 60 ms
    } else {
        cart.tone2(.{
            .frequency = @floatFromInt(hz),
            .duration = 0.06,
            .volume = max_volume,
            .flags = .{ .shape = .square },
        });
    }
    // The chime cancelled whatever was playing. Mark the buzzer idle so
    // `update` does not stop the chime early when the game is silent, and
    // re-sends the game's voice if one is audible.
    playing = false;
}
