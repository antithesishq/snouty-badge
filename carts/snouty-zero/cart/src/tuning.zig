//! Every tunable constant in one place (SPEC 5, 6.2). Values are the M0/M1
//! starting points; Adrian's play test sets them.

// --- Screen and camera (SPEC 6.1, 6.2) --------------------------------------

/// Horizon row: the strip covers rows 0..horizon_y, the floor rows below.
pub const horizon_y: i32 = 32;
/// Camera height over the floor in world pixels (free camera start value).
pub const cam_height: i32 = 64;
/// Focal length in screen pixels: half FOV = atan(80 / focal).
pub const focal: i32 = 128;
/// Distance of the camera behind the followed machine, world px: with
/// cam_height 64 and focal 128 the machine sits at row 32 + 64*128/95 = 118.
pub const cam_behind: i32 = 95;
/// Fog bank thresholds on the row distance z (world px): bank 1, 2, 3.
pub const fog_z = [3]i32{ 160, 320, 640 };

// --- M0 free camera -----------------------------------------------------------

pub const free_yaw_rate: i32 = 256;
pub const free_speed: i32 = 3 << 16;
pub const free_height_min: i32 = 24;
pub const free_height_max: i32 = 160;

// --- Driving model (SPEC 5.1), Q16.16 unless noted -----------------------------

/// Thrust while A is held, px/tick^2 (0.04).
pub const accel: i32 = 2621;
/// Overclock thrust multiplier in 1/256 (1.45x) and its cap on the drag term.
pub const overclock_thrust: i32 = 371;
/// Brake: v -= v * brake per tick (0.03).
pub const brake: i32 = 1966;
/// Drag: v *= (1 - drag) per tick; 0.011 -> terminal speed accel / drag = 3.6 px/tick.
pub const drag_keep: i32 = 64815;
/// Drag kept while overclocked (0.0077 -> terminal 5.2).
pub const drag_keep_overclock: i32 = 65031;
/// Lateral velocity kept per tick: normal, tight turn, throttled zone.
pub const grip: i32 = 55705;
pub const grip_tight: i32 = 61604;
pub const grip_throttled: i32 = 63570;
/// Yaw per tick at low speed, turn units; tight turn multiplies by 1.6.
/// (SPEC said 190; Cold Aisle corners have a 33 px radius at the control
/// points, so 300 keeps them drivable at a third of top speed.)
pub const steer_rate: i32 = 300;
pub const steer_tight_num: i32 = 8;
pub const steer_tight_den: i32 = 5;
/// Steering falls from 100% below 40% of top speed to 55% at top speed.
pub const top_speed: i32 = 236000; // 3.6 px/tick
pub const steer_full_below: i32 = top_speed * 2 / 5;
pub const steer_min_pct: i32 = 55;
/// Machine footprint half extents (world px): along heading, lateral.
pub const half_len: i32 = 12;
pub const half_wid: i32 = 6;
/// Rail: normal velocity reflected with this restitution (1/256), speed loss.
pub const rail_restitution: i32 = 77; // 0.3
pub const rail_speed_keep: i32 = 58982; // 0.9
/// Throttled zone caps speed to half of top speed.
pub const throttled_keep: i32 = 63000;
/// Hop duration (ticks) and overclock pad / Up boost durations.
pub const hop_ticks: u8 = 40;
pub const pad_ticks: u8 = 60;
pub const overclock_ticks: u8 = 90;
/// Thermal (SPEC 5.2): bar 0..1000.
pub const thermal_max: i32 = 1000;
pub const thermal_rail_per_speed: i32 = 40; // * impact speed in px/tick
pub const thermal_hot: i32 = 150;
pub const thermal_collision: i32 = 60;
pub const thermal_overclock: i32 = 250;
pub const thermal_overclock_min: i32 = 100;
pub const thermal_cold_refill: i32 = 8;
/// Collision immunity after a rewind/reset, ticks.
pub const immune_ticks: u8 = 30;
/// Hit-stop with the crash message, ticks; message display, ticks.
pub const hitstop_ticks: u8 = 20;
pub const message_ticks: u8 = 45;
/// Countdown: PROVISIONING, 3, 2, 1 each this many ticks.
pub const countdown_step: u16 = 50;
pub const laps: u8 = 3;
/// Hover height of the machine body over its shadow, world px.
pub const hover_height: i32 = 3;
/// Camera yaw lag: 1/8 of the heading difference per tick.
pub const cam_lag_shift: u5 = 3;

// --- M2 race: rivals, traffic, collisions, rank (SPEC 5.3, 7) ----------------

/// Machine indices: 0 player, 1..4 rivals (ranked), 5..10 traffic.
pub const rival_first: usize = 1;
pub const traffic_first: usize = 5;
pub const ranked_count: usize = 5;
/// Machine circle radius for machine-against-machine contact, world px.
pub const machine_radius: i32 = 10;
/// Share of the relative normal velocity exchanged on contact (0.3, 1/256).
pub const collision_exchange: i32 = 77;
/// A contact closing at this relative normal speed or more (Q16.16 px/tick)
/// involving the player is a COLLISION crash.
pub const collision_crash_speed: i32 = 4 << 16;
/// No thermal damage below this closing speed (resting contact), Q16.16.
pub const collision_min_speed: i32 = 1 << 15; // 0.5 px/tick
/// Collision immunity after a damaging contact, ticks (one hit per bump).
pub const collision_immune_ticks: u8 = 12;
/// Knockouts (SPEC 5.5): ram damage per px/tick of closing speed when the
/// player is the rammer (Q16 closing * this >> 16), the Overclock bonus in
/// 1/256, the credit window after a hit, and the batch jobs' thermal.
pub const ram_damage_per_px: i32 = 200;
pub const ram_overclock_q8: i32 = 384;
pub const ko_credit_ticks: u8 = 120;
pub const traffic_thermal: i16 = 400;
/// Rubber band (SPEC 5.3): target scale 1 + clamp(gap / 1500, -8%, +10%),
/// in 1/1000.
pub const rubber_px: i32 = 1500;
pub const rubber_min_permille: i32 = -80;
pub const rubber_max_permille: i32 = 100;
/// Grid: rows behind the start line, px; first row distance; column offset.
pub const grid_first_row: i32 = 20;
pub const grid_row_gap: i32 = 30;
pub const grid_side: i32 = 18;
/// Traffic: no traffic within this many samples of the start line; the
/// six start samples (two per third of the lap).
pub const traffic_clear_samples: u8 = 24;
pub const traffic_samples = [6]u8{ 40, 72, 106, 140, 186, 218 };
/// AI passing (ai.avoid): look this far ahead (px) within this lateral
/// band for a slower machine; pass it this far to its side, keeping this
/// margin from the edge; ease off to its speed when this close behind.
pub const avoid_ahead: i32 = 64;
pub const avoid_width: i32 = 22;
pub const avoid_pass: i32 = 26;
pub const avoid_margin: i32 = 16;
pub const avoid_brake: i32 = 30;
pub const avoid_brake_width: i32 = 14;

// --- Rewind (SPEC 5.4) ---------------------------------------------------------

/// Snapshot bar capacity in ticks of rewind (3 s) and its refill rate (1 per 10 ticks).
pub const snapshot_max: u32 = 180;
pub const snapshot_refill_every: u32 = 10;
/// Hold-B: game ticks stepped back per frame (and bar cost per frame).
pub const rewind_per_frame: u32 = 2;
/// Crash: the auto rewind needs this much bar, costs it, and goes back this far at this rate.
pub const auto_rewind_cost: u32 = 90;
pub const auto_rewind_ticks: u32 = 120;
pub const auto_rewind_per_frame: u32 = 4;
/// Window-cache prefill: replay ticks per rewind frame (history.zig).
pub const prefill_per_frame: u32 = 8;
