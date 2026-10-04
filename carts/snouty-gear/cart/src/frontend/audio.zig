//! Sound (SPEC.md section 9). Two paths:
//!
//! Badge (the new firmware's streaming audio, docs/EMU_SOUND.md). The core
//! renders the PSG itself (`Gg.audio_render`, set by main.zig from
//! `renders()`): after every stepped frame `update` hands `gg.audio_out` to
//! the shared `audio_feed` (lib/audio_feed.zig), which keeps the OS's
//! 44.1 kHz ring (lib/stream_audio.zig) near two frames full. Every update
//! that does not step the game (splash, menu, scrub, Sound off) calls
//! `idle`, which ramps out once and then pushes nothing. The boot chime is
//! a two-note square burst pushed the same way. The badge build never
//! calls `cart.tone2` or the `tone` import: on the new firmware those
//! write the old tone words, which are now the ring's pointer, length and
//! indices. On old firmware the badge is silent (the show badges run the
//! new one).
//!
//! Simulator (wasm): unchanged since M2, one square voice from
//! `core.psg.Psg.voice()` (loudest tone channel, noise and periods below 2
//! dropped, ties to the lowest channel). The upstream wasm shim turns
//! `duration = -1` into `0xFFFFFFFF`, which the simulator's WASM-4 style
//! worklet unpacks as a 255-frame attack, decay, sustain and release:
//! every tone starts with a 4 s fade-in from silence, so music that
//! changes note every few frames is never heard (found with Sonic,
//! 2026-09-29). So the wasm build calls the simulator's `tone` import
//! itself with WASM-4 packing: no attack, a short sustain re-issued every
//! frame while the voice is audible (the worklet keeps the phase of a
//! channel that is still playing, so this is one continuous tone), 50%
//! duty. f32 is fine here (frontend, not core).
//!
//! main.zig keeps `enabled` equal to the menu's sound setting, calls
//! `update(&gg)` after each `step_frame`, `idle(&gg)` in every update that
//! does not step, and `chime(0)` / `chime(1)` for the two boot notes.
const cart = @import("cart-api");
const core = @import("core");
const audio_feed = @import("audio_feed");

/// Sound on/off; main.zig keeps it equal to the menu's `sound_enabled`
/// every frame.
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

// ---- Badge path (streaming) ----

/// The feed: 736 samples per Game Gear frame (735.95), up to 738 in one.
/// Lives in RAM for as long as the cart runs (the OS reads its ring).
const Feed = audio_feed.Feed(.{ .nominal = 736, .max_src = core.psg.max_frame_samples, .ring_bytes = 4096 });
var feed: Feed = .{};

/// Whether the core should render this frame (badge only; the simulator
/// plays `voice()` instead).
pub fn renders() bool {
    return enabled and !cart.is_wasm;
}

/// Samples queued for the OS, for the debug overlay (0 in wasm).
pub fn queued() u32 {
    if (comptime cart.is_wasm) return 0;
    return feed.queued();
}

/// Updates that found the ring empty while playing (0 in wasm).
pub fn underruns() u32 {
    if (comptime cart.is_wasm) return 0;
    return feed.underruns;
}

/// The boot chime on the badge: note 1 (1046 Hz) for 60 ms, note 2
/// (2093 Hz) from 4 frames later for 60 ms, a square at `chime_amp`.
const chime_note_len = audio_feed.sample_rate * 60 / 1000;
const chime_second_at = 4 * 736;
const chime_len = chime_second_at + chime_note_len;
const chime_amp = 48;
/// Samples of the chime played so far; `chime_len` when idle.
var chime_pos: u32 = chime_len;
var chime_buf: [736]u8 = undefined;

fn chime_frame() void {
    for (&chime_buf, 0..) |*b, i| {
        const t = chime_pos + @as(u32, @intCast(i));
        var v: i32 = 0;
        if (t < chime_note_len or (t >= chime_second_at and t < chime_len)) {
            const hz: u32 = if (t < chime_note_len) 1046 else 2093;
            // Half periods of a square at `hz`: high on the even ones.
            const half = (t * hz * 2) / audio_feed.sample_rate;
            v = if (half & 1 == 0) chime_amp else -chime_amp;
        }
        b.* = @intCast(128 + v);
    }
    chime_pos = @min(chime_pos + chime_buf.len, chime_len);
    feed.frame(&chime_buf);
}

// ---- Shared entry points ----

fn stop() void {
    if (!playing) return;
    sim.stop();
    playing = false;
}

/// After every `step_frame`.
pub fn update(gg: *const core.Gg) void {
    if (comptime cart.is_wasm) {
        sim_update(gg);
    } else if (enabled and gg.audio_len > 0) {
        feed.frame(gg.audio_out[0..gg.audio_len]);
    } else {
        feed.stop();
    }
}

/// Every update that does not step the game (splash, menu, scrub).
pub fn idle(gg: *const core.Gg) void {
    if (comptime cart.is_wasm) {
        sim_update(gg);
    } else if (enabled and chime_pos < chime_len) {
        chime_frame();
    } else {
        feed.stop();
    }
}

/// The simulator's voice, once per update.
fn sim_update(gg: *const core.Gg) void {
    if (!enabled) return stop();
    const v = gg.psg.voice() orelse return stop();
    if (v.hz < min_hz or v.hz > max_hz) return stop();
    // Re-issued every frame: the simulator plays finite tones only.
    sim.play(v.hz, volume_f32(v.atten), sim.sustain_frames);
    playing = true;
    last_hz = v.hz;
    last_atten = v.atten;
}

/// Boot chime (SPEC.md 12): step 0 = 1046 Hz, step 1 = 2093 Hz, 60 ms each
/// at full volume. On the badge step 0 starts the whole two-note burst
/// (`idle` pushes it) and step 1 does nothing. In the simulator it plays
/// regardless of the voice state; the next update re-issues the game's
/// voice if one is audible.
pub fn chime(step: u8) void {
    if (!enabled) return;
    if (comptime cart.is_wasm) {
        const hz: u32 = if (step == 0) 1046 else 2093;
        sim.play(hz, max_volume, 4); // 4 frames, about 60 ms
        // The chime cancelled whatever was playing. Mark the voice idle so
        // the next update does not stop the chime early when the game is
        // silent, and re-sends the game's voice if one is audible.
        playing = false;
    } else if (step == 0) {
        chime_pos = 0;
    }
}
