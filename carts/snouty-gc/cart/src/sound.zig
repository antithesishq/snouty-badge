//! Forked from snouty-zero/cart/src/sound.zig at f8f6962.
//! Sound (SPEC 2, decision 11; docs/SOUND.md): Zero's, unchanged but for
//! names. Off at boot unless -Dsound=true, a menu toggle, four short tones
//! (countdown beep, GO, wall click, the two-note finish) and the engine, a
//! held drone under them whose pitch follows the followed car's speed
//! (`engine`). The wasm build drives the simulator's `tone` import
//! directly (finite tones only; docs/SOUND.md). The badge build renders
//! the tones itself into the newer firmware's streaming ring
//! (lib/tone_stream.zig): that OS ignores `tone2`, and the old tone words
//! are now the ring's, so `cart.tone2` must never be called; `update`
//! once per cart update keeps the ring fed. The engine is tone_stream's
//! drone there, and in the simulator a 25% pulse on channel 1 re-struck
//! every frame (the tones keep channel 0).
const cart = @import("cart-api");
const tone_stream = @import("tone_stream");
const build_options = @import("build_options");
const engine_model = @import("engine.zig");
pub const Engine = engine_model.Engine;

pub var enabled: bool = build_options.sound;

const sim_shim = struct {
    extern fn tone(frequency: u32, duration: u32, volume: u32, flags: u32) void;
    /// Channel 0 (pulse), 50% duty, centre.
    const flags: u32 = 0 | (2 << 2);
    /// The engine: channel 1 (pulse), 25% duty, centre.
    const engine_flags: u32 = 1 | (1 << 2);
};

/// A square tone of `hz` for `ms` milliseconds at volume 0..100.
fn play(hz: u32, ms: u32, volume: u32) void {
    if (!enabled) return;
    if (cart.is_wasm) {
        sim_shim.tone(hz, @max(1, ms * 60 / 1000), volume, sim_shim.flags);
    } else {
        tone_stream.play(hz, tone_stream.ms(ms), tone_stream.level_from_volume(volume), .square);
    }
}

/// Once per cart update (renders the sounding tone into the ring).
pub fn update() void {
    tone_stream.update();
}

pub fn countdown_beep() void {
    play(880, 80, 60);
}
pub fn go() void {
    play(1760, 200, 70);
}
pub fn wall_click() void {
    play(220, 30, 50);
}
/// Two notes: call with step 0 then, a few frames later, 1.
pub fn finish(step: u8) void {
    play(if (step == 0) 1046 else 1568, 120, 70);
}
pub fn menu_move() void {
    play(1200, 20, 30);
}
pub fn menu_confirm() void {
    play(1600, 60, 50);
}
pub fn stop() void {
    if (cart.is_wasm) sim_shim.tone(0, 0, 0, sim_shim.flags) else tone_stream.stop();
    engine_off();
}

/// Run the engine this frame (call every frame it should sound).
pub fn engine(e: Engine) void {
    if (!enabled) return engine_off();
    const hz = engine_model.hz(e);
    if (cart.is_wasm) {
        // Re-struck every frame for 3 frames, so it holds while called.
        const volume: u32 = @as(u32, engine_model.level(e)) * 100 / 127;
        sim_shim.tone(hz, 3, volume, sim_shim.engine_flags);
    } else {
        tone_stream.drone(hz, engine_model.level(e));
    }
}

/// Silence the engine (a short fade; the simulator's lasts its 3 frames).
pub fn engine_off() void {
    if (!cart.is_wasm) tone_stream.drone_stop();
}
