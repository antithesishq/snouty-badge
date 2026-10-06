//! The TMF8820 (docs/TOF.md): lib/tof.zig on the badge's Qwiic port, or
//! its register-level model in a `-Dtof-fake=true` badge build
//! (badge-bench). The simulator and the host tests have no sensor, so
//! `sensor_frame` returns null there and only the stick moves the hand.
const tof = @import("tof");
const build_options = @import("build_options");
pub const types = tof.types;

const fake = build_options.tof_fake;
const enabled = fake or tof.i2c.is_badge;
/// Normal SPAD map (33x32 deg): lib/tof_pose.zig's zone geometry, and
/// GRID's configuration when ZONES switches back from STRIPES. No
/// histogram dumps: they cut the frame rate to a few per second at 400 kHz.
const config: tof.Config = .{};
/// ZONES (docs/TOF.md M5): the layout asked for, applied when the driver
/// starts and on every change.
var layout: types.Layout = .grid;
const bus_hz = 400_000;
const frame_us: u64 = 16_667;

var sensor: tof.Sensor(fake) = undefined;
var started = false;
var ticks: u64 = 0;

/// How the breakout faces (docs/TOF.md deferred question 2). The sensor
/// looks at the viewer, so x is mirrored: move your hand to your right and
/// the image reacts on the right of the screen. Settle from the hardware photos.
pub const default_orientation: types.Orientation = .{ .flip_x = true };
/// The orientation in use: the default, or mirrored by the MIRROR toggle.
pub var orientation: types.Orientation = default_orientation;

/// MIRROR (Select): flip left-right relative to the default.
pub fn set_mirror(on: bool) void {
    orientation = default_orientation;
    if (on) orientation.flip_x = !orientation.flip_x;
}

/// ZONES: GRID (the normal map) or STRIPES (the 8-stripe user mask). The
/// driver stops, reconfigures and restarts over the next polls (no reset);
/// frames carry the layout they were measured with.
pub fn set_layout(l: types.Layout) void {
    layout = l;
    if (enabled and started) sensor.set_layout(l, config);
}

/// Once per update, before `sensor_frame`: a bounded slice of bus work.
pub fn poll(now_us: u64) void {
    if (!enabled) return;
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
}

/// The latest measurement (the same one again until a new `seq` lands;
/// hand.zig only consumes new ones), or null when there is no sensor.
pub fn sensor_frame() ?types.Frame {
    if (!enabled or !started) return null;
    const f = sensor.latest() orelse return null;
    return f.*;
}

/// The histograms of the latest frame, when the driver dumps them.
pub fn histograms() ?*const types.Histograms {
    if (!enabled or !started) return null;
    return sensor.histograms();
}
