//! APU state -> one tone2 voice (SPEC.md section 9). Owner: M3 track E.
//! `core.apu.pick_voice` chooses the channel; this module converts it to a
//! buzzer tone and only calls `tone2` when the audible result changes.
//! Allocation-free; f32 is fine here (frontend, not core).
//!
//! Integrator: call `update(&gb)` once per badge frame after `step_frame`
//! (also while paused in the menu, so a toggle to off stops the tone);
//! keep `enabled` equal to the menu's sound setting; `chime(0)` / `chime(1)`
//! for the two notes of the boot chime.
//!
//! Simulator (wasm). The upstream wasm shim turns `duration = -1` into
//! `0xFFFFFFFF`, which the simulator's WASM-4 style worklet unpacks as a
//! 255-frame attack, decay, sustain and release: every tone starts with a
//! 4 s fade-in from silence, so music that changes note every few frames
//! is never heard (found in snouty-gear with Sonic, 2026-09-29; this cart
//! had the same defect). The badge OS plays an infinite tone correctly, so
//! only the wasm build bypasses `cart.tone2` and calls the simulator's
//! `tone` import itself with WASM-4 packing: no attack, a short sustain
//! re-issued every frame while the voice is audible (the worklet keeps the
//! phase of a channel that is still playing, so this is one continuous
//! tone), pulse channel at 50% duty for the square voice and the worklet's
//! triangle channel for the wave channel. The same import is what
//! `cart.tone2` reaches on wasm; hardware builds compile none of it.
const cart = @import("cart-api");
const core = @import("core");
const apu = core.apu;

/// Sound approximation on/off (the menu's Sound row; off at boot unless
/// built with `-Dsound=true`; SPEC.md 18.6).
pub var enabled: bool = true;

/// Frequencies outside this range are treated as silence (games park a
/// channel at period 2047, which would be 131 kHz).
const min_hz: u32 = 20;
const max_hz: u32 = 16000;

const Shape = cart.Tone2Options.Shape;

/// What the buzzer is currently doing, as last commanded (`playing` false
/// means stopped, else `last_hz` is sounding; read by `debug_tone_hz`).
pub var playing: bool = false;
pub var last_hz: u32 = 0;
var last_shape: Shape = .square;
var last_volume: u8 = 0;

/// Envelope volume 1..15 -> tone2 volume 0.2..1.0.
pub fn volume_f32(v: u8) f32 {
    const c: f32 = @floatFromInt(@min(@max(v, 1), 15) - 1);
    return 0.2 + c * (0.8 / 14.0);
}

// ---- Simulator path (wasm only) ----

const sim = struct {
    /// The simulator's audio import (sycl-badge/simulator/src/apu-worklet.ts,
    /// WASM-4 packing): `frequency` start | end << 16; `duration` sustain |
    /// release << 8 | decay << 16 | attack << 24, in 60 Hz frames; `volume`
    /// sustain | peak << 8, 0..100; `flags` channel | mode << 2 | pan << 4.
    extern fn tone(frequency: u32, duration: u32, volume: u32, flags: u32) void;

    /// Frames one issue sustains; re-issued every frame while audible, so
    /// only a stall longer than this leaves a gap.
    const sustain_frames: u32 = 6;

    /// Channel 0 (pulse) at mode 2 = 50% duty for the square voice; channel
    /// 2 (triangle) for the wave channel. Centre pan.
    fn flags(shape: Shape) u32 {
        return if (shape == .triangle) 2 else (0 | (2 << 2));
    }

    fn play(hz: u32, volume: f32, shape: Shape, frames: u32) void {
        const v: u32 = @intFromFloat(@round(@max(0.0, @min(1.0, volume)) * 100.0));
        tone(hz, frames, v, flags(shape));
    }

    fn stop(shape: Shape) void {
        tone(0, 0, 0, flags(shape));
    }
};

fn stop() void {
    if (!playing) return;
    if (cart.is_wasm) sim.stop(last_shape) else cart.tone2(cart.Tone2Options.stop);
    playing = false;
}

pub fn update(gb: *const core.Gb) void {
    if (!enabled) return stop();
    const v = apu.pick_voice(gb);
    if (v.channel == 0) return stop();
    const hz = apu.period_to_hz(v.channel, v.period);
    if (hz < min_hz or hz > max_hz) return stop();
    const shape: Shape = if (v.channel == 3) .triangle else .square;
    if (cart.is_wasm) {
        // Re-issued every frame: the simulator plays finite tones only. A
        // shape change moves to another worklet channel; silence the old
        // one so its remaining sustain does not overlap the new voice.
        if (playing and shape != last_shape) sim.stop(last_shape);
        sim.play(hz, volume_f32(v.volume), shape, sim.sustain_frames);
    } else {
        if (playing and hz == last_hz and shape == last_shape and v.volume == last_volume) return;
        cart.tone2(.{
            .frequency = @floatFromInt(hz),
            .duration = -1.0,
            .volume = volume_f32(v.volume),
            .flags = .{ .shape = shape },
        });
    }
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
    if (cart.is_wasm) {
        sim.play(if (step == 0) 1046 else 2093, 1.0, .square, 4); // 4 frames, about 60 ms
    } else {
        cart.tone2(.{
            .frequency = if (step == 0) 1046.0 else 2093.0,
            .duration = 0.06,
            .volume = 1.0,
            .flags = .{ .shape = .square },
        });
    }
    // The chime cancelled whatever was playing. Mark the buzzer idle so
    // `update` does not stop the chime early when the game is silent, and
    // re-sends the game's voice if one is audible.
    playing = false;
}
