//! The console's sound to the speaker (SPEC.md section 9).
//!
//! Badge: the core renders all four channels at 44,100 Hz
//! (`core.apu` "Sample generation") into `snd`, and every stepped frame's
//! samples go to the newer firmware's streaming ring through the shared
//! `audio_feed` (lib/audio_feed.zig, docs/EMU_SOUND.md at the root). The
//! badge build never calls `cart.tone2` or the `tone` import: on the new
//! firmware those write the old tone words, which are now the ring's
//! ptr/len/head/tail. On old firmware the badge is silent (the show badges
//! run the new one; no detection).
//!
//! Integrator (main.zig): `attach` once the console exists;
//! `before_step` before and `frame` after every `step_frame`; `pause` when
//! the menu opens (its scrub replays render nothing); `idle` in every
//! update that does not step the game (splash, picker, menu, halted: the
//! feed ramps out once, or plays the boot chime); keep `enabled` equal to
//! the menu's Sound setting; `chime(0)` / `chime(1)` for the two notes of
//! the boot chime. `menu_tick` in menu frames (wasm only does anything).
//!
//! Simulator (wasm), unchanged since 2026-09-30: it has no streaming audio,
//! so `core.apu.pick_voice` chooses one channel from the register model and
//! this module plays it through the simulator's `tone` import. The upstream
//! wasm shim turns `duration = -1` into `0xFFFFFFFF`, which the simulator's
//! WASM-4 style worklet unpacks as a 255-frame attack, decay, sustain and
//! release: every tone starts with a 4 s fade-in from silence, so music
//! that changes note every few frames is never heard (found in snouty-gear
//! with Sonic, 2026-09-29; this cart had the same defect). So the wasm build
//! calls the `tone` import itself with WASM-4 packing: no attack, a short
//! sustain re-issued every frame while the voice is audible (the worklet
//! keeps the phase of a channel that is still playing, so this is one
//! continuous tone), pulse channel at 50% duty for the square voice and the
//! worklet's triangle channel for the wave channel. f32 is fine here
//! (frontend, not core).
const cart = @import("cart-api");
const core = @import("core");
const apu = core.apu;
const audio_feed = @import("audio_feed");

/// Sound on/off (the menu's Sound row; off at boot unless built with
/// `-Dsound=true`; SPEC.md 18.6).
pub var enabled: bool = true;

// ---- Badge path: streaming ----

/// One Game Boy frame is 738.4 samples (738 or 739 from the core).
pub const Feed = audio_feed.Feed(.{ .nominal = 738, .max_src = 739, .ring_bytes = 4096 });
/// The ring the OS reads (it must outlive every update), and the core's
/// render state and output (`Gb.snd`). Both start `undefined` so they
/// land in .bss, not as 9 KB of initial values in the UF2; `init` sets
/// what must start defined.
var feed: Feed = undefined;
var snd: apu.Snd = undefined;

/// Call once in `start()`.
pub fn init() void {
    if (cart.is_wasm) return;
    // The buffers' contents are never read before they are written.
    feed = .{ .ring = undefined, .scratch = undefined };
    snd.reset();
}

/// Give the console its render memory (badge only).
pub fn attach(gb: *core.Gb) void {
    if (cart.is_wasm) return;
    gb.snd = &snd;
}

/// Before `step_frame`: render while sound is on.
pub fn before_step(gb: *core.Gb) void {
    if (cart.is_wasm) return;
    apu.set_render(gb, enabled);
}

/// After `step_frame`: the frame's samples to the ring (wasm: the voice).
pub fn frame(gb: *core.Gb) void {
    if (cart.is_wasm) return update(gb);
    const s = apu.samples(gb);
    if (enabled and s.len > 0) feed.frame(s) else feed.stop();
}

/// The menu opened: scrub replays must not render.
pub fn pause(gb: *core.Gb) void {
    if (cart.is_wasm) return;
    apu.set_render(gb, false);
}

/// A menu frame: the wasm voice holds or stops (the badge's `idle` ramps out).
pub fn menu_tick(gb: *const core.Gb) void {
    if (cart.is_wasm) update(gb);
}

/// Boot chime on the badge: samples left of the current note and its
/// phase step (16.16 of a cycle per sample).
var chime_left: u32 = 0;
var chime_inc: u32 = 0;
var chime_phase: u32 = 0;
/// The chime's square swings +-40 around silence.
const chime_amp = 40;

/// Every update that did not step the game: the chime, else a ramp-out.
pub fn idle() void {
    if (cart.is_wasm) return;
    if (chime_left == 0 or !enabled) {
        chime_left = 0;
        feed.stop();
        return;
    }
    // The core's output buffer is free while the game is not stepping.
    const buf = snd.out[0..738];
    for (buf) |*v| {
        if (chime_left == 0) {
            v.* = 128;
            continue;
        }
        chime_left -= 1;
        chime_phase +%= chime_inc;
        v.* = if ((chime_phase & 0x8000) != 0) 128 + chime_amp else 128 - chime_amp;
    }
    feed.frame(buf);
}

/// The ring's queue and underruns, for the debug overlay.
pub fn queued() u32 {
    return if (cart.is_wasm) 0 else feed.queued();
}
pub fn underruns() u32 {
    return if (cart.is_wasm) 0 else feed.underruns;
}

// ---- Wasm path: one simulator voice ----

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
    sim.stop(last_shape);
    playing = false;
}

fn update(gb: *const core.Gb) void {
    if (!enabled) return stop();
    const v = apu.pick_voice(gb);
    if (v.channel == 0) return stop();
    const hz = apu.period_to_hz(v.channel, v.period);
    if (hz < min_hz or hz > max_hz) return stop();
    const shape: Shape = if (v.channel == 3) .triangle else .square;
    // Re-issued every frame: the simulator plays finite tones only. A
    // shape change moves to another worklet channel; silence the old
    // one so its remaining sustain does not overlap the new voice.
    if (playing and shape != last_shape) sim.stop(last_shape);
    sim.play(hz, volume_f32(v.volume), shape, sim.sustain_frames);
    playing = true;
    last_hz = hz;
    last_shape = shape;
    last_volume = v.volume;
}

/// DMG-style boot chime: step 0 = 1046 Hz, step 1 = 2093 Hz, 60 ms each.
/// Wasm: a simulator tone, regardless of the voice state (the next
/// `update` re-issues the game's voice if one is audible). Badge: a square
/// burst through the feed, played by `idle`.
pub fn chime(step: u8) void {
    if (!enabled) return;
    const hz: u32 = if (step == 0) 1046 else 2093;
    if (!cart.is_wasm) {
        chime_left = audio_feed.sample_rate * 60 / 1000;
        chime_inc = (hz << 16) / audio_feed.sample_rate;
        return;
    }
    sim.play(hz, 1.0, .square, 4); // 4 frames, about 60 ms
    // The chime cancelled whatever was playing. Mark the buzzer idle so
    // `update` does not stop the chime early when the game is silent, and
    // re-sends the game's voice if one is audible.
    playing = false;
}
