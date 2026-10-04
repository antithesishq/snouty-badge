//! Forked from snouty-zero/cart/src/tuning.zig at f8f6962.
//! Every tunable constant in one place (SPEC 4.2, 5). Zero's hover values
//! are retuned for wheels (SPEC 5.2); thermal, Overclock, traffic and the
//! rewind are gone. Adrian's play test sets the numbers.

// --- Screen and camera (Zero SPEC 6.1, 6.2) ----------------------------------

/// Horizon row: the strip covers rows 0..horizon_y, the floor rows below.
pub const horizon_y: i32 = 32;
/// Camera height over the floor in world pixels.
pub const cam_height: i32 = 64;
/// Focal length in screen pixels: half FOV = atan(80 / focal).
pub const focal: i32 = 128;
/// Distance of the camera behind the followed car, world px: with
/// cam_height 64 and focal 128 the car sits at row 32 + 64*128/95 = 118.
pub const cam_behind: i32 = 95;
/// Fog bank thresholds on the row distance z (world px): bank 1, 2, 3.
pub const fog_z = [3]i32{ 160, 320, 640 };
/// Camera yaw lag: 1/8 of the heading difference per tick.
pub const cam_lag_shift: u5 = 3;

// --- Driving model (SPEC 5.1, 5.2), Q16.16 unless noted ------------------------

/// Thrust, always on while racing (auto-throttle), px/tick^2 (0.036).
pub const accel: i32 = 2359;
/// Drag: v *= (1 - drag) per tick; 0.012 -> terminal speed accel / drag = 3.0 px/tick.
/// A chassis' accel multiplier scales the drag as well (sim.chassis_keep),
/// so it changes how fast the car reaches its top speed, not the top speed.
pub const drag: i32 = 786;
/// Top speed for a WORKSTATION, Q16 (accel / drag = 3.0 px/tick).
pub const top_speed: i32 = 196608;
/// Brake: v -= v * brake per tick (0.04). With the throttle on, holding the
/// brake settles near accel / (drag + brake) = 0.69 px/tick.
pub const brake: i32 = 2621;
/// Lateral velocity kept per tick (SPEC 5.2): normal, powerslide, coolant.
pub const grip: i32 = 45875; // 0.70
pub const grip_slide: i32 = 57672; // 0.88
pub const grip_coolant: i32 = 63570; // 0.97
/// Yaw per tick at low speed, turn units; a powerslide multiplies by 1.6.
pub const steer_rate: i32 = 300;
pub const steer_slide_num: i32 = 8;
pub const steer_slide_den: i32 = 5;
/// Steering falls from 100% below 40% of top speed to 55% at top speed.
pub const steer_full_below: i32 = top_speed * 2 / 5;
pub const steer_min_pct: i32 = 55;
/// BURST (Up, SPEC 5.1): thrust x1.35 for burst_ticks (+35% top speed,
/// about 4.0 px/tick), one charge per lap (garage BURST BUFFER L0).
pub const burst_thrust_q8: i32 = 346;
pub const burst_ticks: u8 = 60;
pub const burst_per_lap: u8 = 1;
/// Car footprint half extents (world px): along heading, lateral.
pub const half_len: i32 = 12;
pub const half_wid: i32 = 6;
/// Wall: normal velocity reflected with this restitution (1/256), speed loss.
pub const wall_restitution: i32 = 77; // 0.3
pub const wall_speed_keep: i32 = 58982; // 0.9
/// Ramp: airborne ticks (projectiles pass under from M1).
pub const ramp_ticks: u8 = 40;
/// Wreck (a fall into a pit in M0; armor at 0 from M1): the car is out for
/// the WATCHDOG delay (SPEC 5.3, garage L0), then respawns on the
/// centerline with this much immunity.
pub const watchdog_ticks: u8 = 120;
pub const respawn_immune: u8 = 60;
/// Per-car message display, ticks.
pub const message_ticks: u8 = 45;
/// Countdown: four steps of this many ticks.
pub const countdown_step: u16 = 50;
pub const laps: u8 = 3;
/// Height of the car body over its shadow, world px.
pub const ride_height: i32 = 1;

// --- Chassis (SPEC 4.2): multipliers in 1/256 of the base values --------------

pub const Chassis = struct {
    top_q8: u16,
    accel_q8: u16,
    grip_q8: u16,
    /// Base armor (M1 wires damage).
    armor: u8,
    /// Ram mass: the contact response weights the velocity exchange by it.
    mass_q8: u16,
};
pub const thin_client = Chassis{ .top_q8 = 276, .accel_q8 = 307, .grip_q8 = 243, .armor = 80, .mass_q8 = 179 };
pub const workstation = Chassis{ .top_q8 = 256, .accel_q8 = 256, .grip_q8 = 256, .armor = 100, .mass_q8 = 256 };
pub const mainframe = Chassis{ .top_q8 = 230, .accel_q8 = 205, .grip_q8 = 269, .armor = 140, .mass_q8 = 410 };

// --- Field: contacts, rank, grid, AI (Zero SPEC 5.3) --------------------------

/// Car circle radius for car-against-car contact, world px (SPEC 6).
pub const car_radius: i32 = 10;
/// Share of the relative normal velocity exchanged on contact (0.3, 1/256),
/// split by mass.
pub const collision_exchange: i32 = 77;
/// Shake ticks after a contact closing faster than this (Q16 px/tick).
pub const collision_shake_speed: i32 = 1 << 15;
/// Rubber band (Zero SPEC 5.3), keyed on the leading human: target scale
/// 1 + clamp(gap / 1500, -8%, +10%), in 1/1000.
pub const rubber_px: i32 = 1500;
pub const rubber_min_permille: i32 = -80;
pub const rubber_max_permille: i32 = 100;
/// Grid: rows behind the start line, px; first row distance; column offset.
pub const grid_first_row: i32 = 20;
pub const grid_row_gap: i32 = 30;
pub const grid_side: i32 = 18;
/// AI passing (ai.avoid): look this far ahead (px) within this lateral
/// band for a slower car; pass it this far to its side, keeping this
/// margin from the edge; ease off to its speed when this close behind.
pub const avoid_ahead: i32 = 64;
pub const avoid_width: i32 = 22;
pub const avoid_pass: i32 = 26;
pub const avoid_margin: i32 = 16;
pub const avoid_brake: i32 = 30;
pub const avoid_brake_width: i32 = 14;
