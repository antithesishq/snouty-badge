//! `Md.tone()` -> the badge's one `tone2` voice (SPEC.md section 9). Calls
//! `tone2` only when the note changes, and stops the buzzer when nothing
//! is keyed on. f32 is fine here (frontend, not core). M1 Track C owns
//! this file; app.zig toggles `enabled` (A in the M1 menu placeholder, the
//! menu's Sound row from M2).
//!
//! Volume: `Tone.level` 0..15 maps linearly onto tone2 volume 0.2..1.0
//! (level 0 is still audible: silence is `tone()` returning null).
//!
//! Simulator (wasm). The upstream wasm shim turns `duration = -1` into
//! `0xFFFFFFFF`, which the simulator's WASM-4 style worklet unpacks as a
//! 255-frame attack, decay, sustain and release: every tone starts with a
//! 4 s fade-in from silence, so music that changes note every few frames
//! is never heard (found in snouty-gear with Sonic, 2026-09-29). The badge
//! OS plays an infinite tone correctly, so only the wasm build bypasses
//! `cart.tone2` and calls the simulator's `tone` import itself with WASM-4
//! packing: no attack, a short sustain re-issued every frame while the
//! voice is audible (the worklet keeps the phase of a channel that is
//! still playing, so this is one continuous tone), 50% duty. The same
//! import is what `cart.tone2` reaches on wasm; hardware builds compile
//! none of it. `tone_calls` counts note changes on both targets, not the
//! per-frame re-issues.
const cart = @import("cart-api");
const core = @import("core");
const build_options = @import("build_options");

/// Sound exists in this build: the tone comes from the Z80's sound driver
/// (YM2612 and PSG), so the RAM cart, which has the Z80 stub, is silent
/// and its menu has no Sound row (PLAN.md M5).
pub const available = core.tunables.z80_enabled;

/// Sound on/off. Starts as `-Dsound` says (off by default, docs/SOUND.md);
/// the menu toggles it. Always false without `available`.
pub var enabled: bool = build_options.sound and available;

/// Frequencies outside this range are treated as silence.
const min_hz: u16 = 20;
const max_hz: u16 = 16000;

/// What the buzzer is doing, as last commanded (null: silent).
var playing: ?core.Tone = null;
/// Voice changes since boot, what `tone2` sees on the badge (a `debug_*`
/// export; the simulator's per-frame re-issues are not counted).
pub var tone_calls: u32 = 0;

/// `Tone.level` 0..15 -> tone volume 0.2..1.0.
fn volume_f32(level: u8) f32 {
    return 0.2 + @as(f32, @floatFromInt(level)) * (0.8 / 15.0);
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
    /// Frames one issue sustains; re-issued every update while audible, so
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
    if (playing == null) return;
    if (cart.is_wasm) sim.stop() else cart.tone2(cart.Tone2Options.stop);
    tone_calls +%= 1;
    playing = null;
}

/// Stop the buzzer (the game is paused).
pub fn silence() void {
    stop();
}

/// The frequency now sounding, 0 when silent (a `debug_*` export).
pub fn playing_hz() u32 {
    return if (playing) |p| p.hz else 0;
}

/// Once per update, after the frames ran.
pub fn update(md: *const core.Md) void {
    if (!available or !enabled) return stop();
    const t = md.tone() orelse return stop();
    if (t.hz < min_hz or t.hz > max_hz) return stop();
    if (playing) |p| if (p.hz == t.hz and p.level == t.level) {
        // Same note: the badge's infinite tone2 is still sounding; the
        // simulator plays finite tones only, so re-issue it every update.
        if (cart.is_wasm) sim.play(t.hz, volume_f32(t.level), sim.sustain_frames);
        return;
    };
    if (cart.is_wasm) {
        sim.play(t.hz, volume_f32(t.level), sim.sustain_frames);
    } else {
        cart.tone2(.{
            .frequency = @floatFromInt(t.hz),
            .duration = -1.0,
            .volume = 0.2 + @as(f32, @floatFromInt(t.level)) * (0.8 / 15.0),
            .flags = .{ .shape = .square },
        });
    }
    tone_calls +%= 1;
    playing = t;
}
