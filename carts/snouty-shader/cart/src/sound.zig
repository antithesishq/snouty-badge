//! Sound (SPEC.md section 5): off at boot unless -Dsound=true, Start
//! toggles it. A drone whose pitch follows the hand's distance over a root
//! per program and whose level follows the field, a low thump on a punch
//! and a short blip on a program change. The badge build renders into the
//! newer firmware's streaming ring through lib/tone_stream.zig (`cart.tone2`
//! is never called); `update` once per cart update keeps the ring fed. The
//! wasm build drives the simulator's `tone` import directly, as
//! snouty-morph does.
const cart = @import("cart-api");
const tone_stream = @import("tone_stream");
const build_options = @import("build_options");

pub var enabled: bool = build_options.sound;

const sim_shim = struct {
    extern fn tone(frequency: u32, duration: u32, volume: u32, flags: u32) void;
    /// Channel 0 (pulse), 50% duty, centre: thump and blip.
    const flags: u32 = 0 | (2 << 2);
    /// Channel 1 (pulse), 25% duty, centre: the drone.
    const drone_flags: u32 = 1 | (1 << 2);
};

/// Drone roots (Hz) per program: a minor pentatonic-ish set.
const roots = [_]f32{ 55.0, 65.4, 73.4, 82.4, 98.0, 110.0 };

/// Once per update. `z` 0 (far) .. 1 (near), `presence` the field's mean
/// (0..1), `program` the gallery index.
pub fn drone(z: f32, presence: f32, program: usize) void {
    if (!enabled) return;
    const root = roots[program % roots.len];
    const zc = @max(0.0, @min(1.0, z));
    const hz: u32 = @intFromFloat(root * (1.0 + 1.5 * zc * zc));
    const level: u32 = @intFromFloat(10.0 + 50.0 * @min(1.0, presence * 2.5));
    if (cart.is_wasm) {
        sim_shim.tone(hz, 3, level * 100 / 127, sim_shim.drone_flags);
    } else {
        tone_stream.drone(hz, @intCast(level));
    }
}

pub fn thump() void {
    if (!enabled) return;
    if (cart.is_wasm) {
        sim_shim.tone(65, 8, 70, sim_shim.flags);
    } else {
        tone_stream.play(65, tone_stream.ms(140), tone_stream.level_from_volume(70), .square);
    }
}

pub fn blip(program: usize) void {
    if (!enabled) return;
    const hz: u32 = @intFromFloat(roots[program % roots.len] * 8.0);
    if (cart.is_wasm) {
        sim_shim.tone(hz, 4, 30, sim_shim.flags);
    } else {
        tone_stream.play(hz, tone_stream.ms(60), tone_stream.level_from_volume(30), .triangle);
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
