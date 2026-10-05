//! Sound (SPEC.md section 3): off at boot unless -Dsound=true, Select
//! toggles it. A drone whose pitch follows the hand's distance (closer =
//! higher) and whose level follows the deformation energy, and a short low
//! thump on a punch. The badge build renders both into the newer
//! firmware's streaming ring through lib/tone_stream.zig (that OS ignores
//! `tone2` and the old tone words are now the ring's, so `cart.tone2` is
//! never called); `update` once per cart update keeps the ring fed. The
//! wasm build drives the simulator's `tone` import directly, as
//! snouty-zero does (the drone re-struck every frame on channel 1).
const cart = @import("cart-api");
const tone_stream = @import("tone_stream");
const build_options = @import("build_options");

pub var enabled: bool = build_options.sound;

const sim_shim = struct {
    extern fn tone(frequency: u32, duration: u32, volume: u32, flags: u32) void;
    /// Channel 0 (pulse), 50% duty, centre: the thump.
    const flags: u32 = 0 | (2 << 2);
    /// Channel 1 (pulse), 25% duty, centre: the drone.
    const drone_flags: u32 = 1 | (1 << 2);
};

/// Once per update: the drone for this frame. `z` 0 (far) .. 1 (near),
/// `energy` the deformation energy (0..~2).
pub fn drone(z: f32, energy: f32) void {
    if (!enabled) return;
    const hz: u32 = @intFromFloat(55.0 + 165.0 * @max(0.0, @min(1.0, z)) + 20.0 * @min(2.0, energy));
    const level: u32 = @intFromFloat(14.0 + 40.0 * @min(1.0, energy));
    if (cart.is_wasm) {
        sim_shim.tone(hz, 3, level * 100 / 127, sim_shim.drone_flags);
    } else {
        tone_stream.drone(hz, @intCast(level));
    }
}

pub fn thump() void {
    if (!enabled) return;
    if (cart.is_wasm) {
        sim_shim.tone(70, 8, 70, sim_shim.flags);
    } else {
        tone_stream.play(70, tone_stream.ms(130), tone_stream.level_from_volume(70), .square);
    }
}

pub fn set(on: bool) void {
    enabled = on;
    if (!on) {
        if (cart.is_wasm) sim_shim.tone(0, 0, 0, sim_shim.flags) else {
            tone_stream.stop();
            tone_stream.drone_stop();
        }
    }
}

/// Once per cart update (renders the sounding voices into the ring).
pub fn update() void {
    tone_stream.update();
}
