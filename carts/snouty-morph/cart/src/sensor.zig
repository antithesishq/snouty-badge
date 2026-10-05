//! The one integration point with the TMF8820 driver (docs/TOF.md, lib/tof.zig,
//! not on this branch yet). Until it is wired, `sensor_frame` returns null
//! and the cart runs on the ghost hand and the stick.
//!
//! To wire it: give the cart's build a module that carries both the driver
//! and lib/tof_pose.zig (lib/tof_types.zig must live in exactly one module
//! per compilation, so the Frame type is one type), call the driver's
//! `poll(now_us)` from `poll`, return its latest frame from
//! `sensor_frame` (the same frame again is fine: hand.zig only consumes a
//! new `seq`) and its histograms from `histograms` when dumps are on.
const tof_pose = @import("tof_pose");
pub const types = tof_pose.types;

/// How the breakout faces (docs/TOF.md deferred question 2). The sensor
/// looks at the viewer, so x is mirrored: move your hand to your right and
/// the mesh goes right on screen. Settle from the hardware photos.
pub const orientation: types.Orientation = .{ .flip_x = true };

/// Once per update, before `sensor_frame`: a bounded slice of bus work.
pub fn poll(now_us: u64) void {
    _ = now_us;
}

/// The latest measurement, or null when there is no sensor.
pub fn sensor_frame() ?types.Frame {
    return null;
}

/// The histograms of the latest frame, when the driver dumps them.
pub fn histograms() ?*const types.Histograms {
    return null;
}
