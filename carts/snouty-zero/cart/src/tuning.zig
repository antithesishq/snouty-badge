//! Every tunable constant in one place (SPEC 5, 6.2). Values are the M0/M1
//! starting points; Adrian's play test sets them.

// --- Screen and camera (SPEC 6.1, 6.2) --------------------------------------

/// Horizon row: the strip covers rows 0..horizon_y, the floor rows below.
pub const horizon_y: i32 = 32;
/// Camera height over the floor in world pixels (free camera start value).
pub const cam_height: i32 = 64;
/// Focal length in screen pixels: half FOV = atan(80 / focal).
pub const focal: i32 = 128;
/// Distance of the camera behind the followed machine, world px (M1).
pub const cam_behind: i32 = 72;
/// Fog bank thresholds on the row distance z (world px): bank 1, 2, 3.
pub const fog_z = [3]i32{ 160, 320, 640 };

// --- M0 free camera -----------------------------------------------------------

pub const free_yaw_rate: i32 = 256;
pub const free_speed: i32 = 3 << 16;
pub const free_height_min: i32 = 24;
pub const free_height_max: i32 = 160;
