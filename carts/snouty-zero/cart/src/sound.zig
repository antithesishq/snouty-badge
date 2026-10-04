//! Sound (SPEC 9, docs/SOUND.md): off at boot unless -Dsound=true, a menu
//! toggle, and four short tones (countdown beep, DEPLOY, rail click, the
//! two-note finish). The wasm build drives the simulator's `tone` import
//! directly (finite tones only; docs/SOUND.md). The badge build renders
//! the tones itself into the newer firmware's streaming ring
//! (lib/tone_stream.zig): that OS ignores `tone2`, and the old tone words
//! are now the ring's, so `cart.tone2` must never be called; `update`
//! once per cart update keeps the ring fed.
const cart = @import("cart-api");
const tone_stream = @import("tone_stream");
const build_options = @import("build_options");

pub var enabled: bool = build_options.sound;

const sim_shim = struct {
    extern fn tone(frequency: u32, duration: u32, volume: u32, flags: u32) void;
    /// Channel 0 (pulse), 50% duty, centre.
    const flags: u32 = 0 | (2 << 2);
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
pub fn deploy() void {
    play(1760, 200, 70);
}
pub fn rail_click() void {
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
}
