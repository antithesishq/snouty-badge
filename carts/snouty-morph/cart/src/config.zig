//! Every tunable in one place (SPEC.md section 5): mesh resolution, render
//! knobs, the hand-to-mesh mapping and the deformation strengths. Perf
//! knobs first.

// ---------------------------------------------------------------------------
// Perf knobs.

/// KNOT tube: segments along the curve and sides around it.
pub const knot_segments = 64;
pub const knot_sides = 8;
/// BOING sphere: latitude bands (pole to pole) and longitude segments.
pub const boing_lat = 16;
pub const boing_lon = 32;
/// IRIS: segments per ring arc; diamond subdivision levels.
pub const iris_arc_segments = 20;
pub const iris_diamond_levels = 2;
/// Per-frame buffers: the largest mesh must fit.
pub const max_verts = 640;
pub const max_faces = 1152;
/// Painter's sort buckets over the mesh's depth range.
pub const sort_buckets = 512;
/// 4x4 ordered dither on the Gouraud ramp index.
pub const dither = true;
/// Plasma backdrop (else BOING gets the starfield).
pub const plasma = true;
/// Concurrent shockwaves.
pub const max_ripples = 3;

// ---------------------------------------------------------------------------
// Camera and shading.

/// Focal length (pixels) and the camera distance to the mesh at rest.
pub const focal: f32 = 118.0;
pub const rest_distance: f32 = 2.9;
/// Shade ramp: entries per material; diffuse reaches `ramp_base`, the
/// specular highlight runs from there to white at the top.
pub const ramp_levels = 64;
pub const ramp_base = 42;
pub const ambient_index: f32 = 7.0;
pub const specular_power = 16;

// ---------------------------------------------------------------------------
// Hand to mesh (SPEC.md section 3, Transform).

/// Mesh travel at hand x, y = +-1 (world units) and its follow gain: the
/// mesh goes this fraction of the way, so the hand leads it.
pub const travel_x: f32 = 1.8;
pub const travel_y: f32 = 1.3;
pub const follow_gain: f32 = 0.6;
/// Depth travel: hand z 1 (near) brings the mesh this much closer.
pub const travel_z: f32 = 0.9;
/// Follow spring (rad/s; critically damped).
pub const follow_omega: f32 = 9.0;
/// Hand tilt to mesh tilt.
pub const tilt_gain: f32 = 1.5;
/// Hand yaw to mesh yaw.
pub const yaw_gain: f32 = 1.5;
/// Autonomous spin (turns per second) about the vertical axis.
pub const auto_spin: f32 = 0.06;

// ---------------------------------------------------------------------------
// Deformations (SPEC.md section 3).

/// REACH: bulge (fraction of the mesh radius) at hand z = 1 and its
/// sharpness (power of n . h, a power of two).
pub const reach_amp: f32 = 0.55;
pub const reach_power = 8;
/// JELLY: lateral shear spring and squash spring (stiffness rad/s,
/// damping ratio), and how hard the mesh's acceleration drives them.
pub const jelly_omega: f32 = 11.0;
pub const jelly_zeta: f32 = 0.12;
pub const jelly_drive: f32 = 0.6;
pub const squash_omega: f32 = 13.0;
pub const squash_zeta: f32 = 0.14;
pub const squash_drive: f32 = 0.12;
pub const jelly_max: f32 = 0.6;
/// TWIST: torsional spring, driven by yaw velocity and swirl.
pub const twist_omega: f32 = 7.0;
pub const twist_zeta: f32 = 0.15;
pub const twist_drive: f32 = 0.35;
pub const swirl_twist: f32 = 0.5;
pub const twist_max: f32 = 1.6;
/// SHOCKWAVE: amplitude (fraction of the radius), wave number (crests
/// over the half-surface), speed (half-surfaces per second), lifetime.
pub const ripple_amp: f32 = 0.22;
pub const ripple_waves: f32 = 3.0;
pub const ripple_speed: f32 = 1.1;
pub const ripple_life: f32 = 1.4;
/// Punch flash: ramp index boost at the hit, decay per frame.
pub const flash_boost: f32 = 26.0;
pub const flash_decay: f32 = 0.90;
/// Screen shake frames and amplitude (pixels).
pub const shake_frames = 10;
pub const shake_px = 3;

// ---------------------------------------------------------------------------
// Sources.

/// Hand distance mapping: z_mm at hand z = 1 and 0.
pub const near_mm: f32 = 90.0;
pub const far_mm: f32 = 420.0;
/// A punch: the fast z velocity beyond this toward the sensor (mm/s),
/// then a cooldown (ticks).
pub const punch_mm_s: f32 = 900.0;
pub const punch_cooldown = 30;
/// Stick: hand speed (units/s), z speed, yaw speed (rad/s).
pub const stick_speed: f32 = 1.3;
pub const stick_z_speed: f32 = 0.9;
pub const stick_yaw_speed: f32 = 2.6;
/// Ticks without stick input before the ghost takes over again.
pub const stick_timeout = 360;
/// Ticks without a sensed hand before the ghost takes over.
pub const hand_timeout = 120;
