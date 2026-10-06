//! The TMF8820 behind input.zig's `sensor_frame` (docs/TOF.md): lib/tof.zig
//! on the badge's Qwiic port, or its register-level model in a
//! `-Dtof-fake=true` badge build (badge-bench). The simulator and the host
//! tests have no sensor (the demo hand stands in for it there), so this
//! returns null and the stick plays.
//!
//! ZONES (docs/TOF.md M5): GRID measures with the wide pre-defined map
//! below, STRIPES with lib/tof_spad.zig's 8-stripe user mask. `set_layout`
//! hands the choice to the driver (stop, pages, start on the next polls);
//! every frame carries the layout it was measured with (`Frame.layout`).
const tof = @import("tof");
const build_options = @import("build_options");

const fake = build_options.tof_fake;
const enabled = fake or tof.i2c.is_badge;

/// GRID: the wide SPAD map (41x52 deg, datasheet 7.4.1 map 6), the field
/// the lip range was tuned on (the normal map is ~12 cm across at 20 cm).
pub const config: tof.Config = .{ .spad_map = 6 };
const bus_hz = 400_000;
const frame_us: u64 = 16_667;

var sensor: tof.Sensor(fake) = undefined;
var started = false;
var ticks: u64 = 0;
/// The layout asked for (applied at the first poll, or at once if running).
var layout: tof.types.Layout = .stripes;

/// ZONES: GRID or STRIPES. Before the first poll this only sets what the
/// sensor boots into (a STRIPES boot goes straight to the mask).
pub fn set_layout(l: tof.types.Layout) void {
    layout = l;
    if (enabled and started) sensor.set_layout(l, config);
}

/// Poll the driver (one bounded slice of bus work) and return its latest
/// frame; input.zig drops repeats by `seq`.
pub fn frame(now_us: u64) ?tof.types.Frame {
    if (!enabled) return null;
    if (!started) {
        // The model's STRIPES frames show its wandering hand, not the
        // depth photo's room (-Dtof-fake=true builds only).
        if (fake) tof.virtual.shared.user_scene = .hand;
        sensor = tof.open(fake, bus_hz);
        sensor.configure(config);
        sensor.set_layout(layout, config);
        started = true;
    }
    ticks += 1;
    // badge-bench's clock stops while the cart waits for vsync, so the
    // model runs on the update count (as in snouty-sense).
    sensor.poll(if (fake) 1_000_000 + ticks * frame_us else now_us);
    const f = sensor.latest() orelse return null;
    return f.*;
}
