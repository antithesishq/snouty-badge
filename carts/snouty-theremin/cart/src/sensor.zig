//! The TMF8820 behind input.zig's `sensor_frame` (docs/TOF.md): lib/tof.zig
//! on the badge's Qwiic port, or its register-level model in a
//! `-Dtof-fake=true` badge build (badge-bench). The simulator and the host
//! tests have no sensor (the demo hand stands in for it there), so this
//! returns null and the stick plays.
const tof = @import("tof");
const build_options = @import("build_options");

const fake = build_options.tof_fake;
const enabled = fake or tof.i2c.is_badge;

/// The wide SPAD map (41x52 deg, datasheet 7.4.1 map 6): the two-hand
/// layout needs the room (the normal map is ~12 cm across at 20 cm). Also
/// GRID's configuration when ZONES switches back from STRIPES.
pub const config: tof.Config = .{ .spad_map = 6 };
const bus_hz = 400_000;
const frame_us: u64 = 16_667;

var sensor: tof.Sensor(fake) = undefined;
var started = false;
var ticks: u64 = 0;
/// ZONES (docs/TOF.md M5): the layout asked for, applied when the driver
/// starts (so a STRIPES boot goes straight to the mask) and on every change.
var layout: tof.types.Layout = .stripes;

/// ZONES: GRID (map 6) or STRIPES (the 8-stripe user mask). The driver
/// stops, reconfigures and restarts over the next polls (no reset); frames
/// carry the layout they were measured with (`Frame.layout`).
pub fn set_layout(l: tof.types.Layout) void {
    layout = l;
    if (enabled and started) sensor.set_layout(l, config);
}

/// Poll the driver (one bounded slice of bus work) and return its latest
/// frame; input.zig drops repeats by `seq`.
pub fn frame(now_us: u64) ?tof.types.Frame {
    if (!enabled) return null;
    if (!started) {
        // The model's SPADs see its wandering hand under the stripes mask
        // (its default user-mask scene is the depth photo's room).
        if (fake) tof.virtual.shared.user_scene = .hand;
        sensor = tof.open(fake, bus_hz);
        sensor.configure(config);
        if (layout != .grid) sensor.set_layout(layout, config);
        started = true;
    }
    ticks += 1;
    // badge-bench's clock stops while the cart waits for vsync, so the
    // model runs on the update count (as in snouty-sense).
    sensor.poll(if (fake) 1_000_000 + ticks * frame_us else now_us);
    const f = sensor.latest() orelse return null;
    return f.*;
}
