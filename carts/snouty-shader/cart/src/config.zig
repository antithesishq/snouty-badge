//! Every tunable in one place: sources, uniforms, attract, HUD timing.
//! Each program's own look knobs sit at the top of its file.

// ---------------------------------------------------------------------------
// Sources (hand.zig).

/// Hand distance mapping: z_mm at hand z = 1 and 0 (snouty-morph's).
pub const near_mm: f32 = 90.0;
pub const far_mm: f32 = 420.0;
/// A punch: the fast z velocity beyond this toward the sensor (mm/s),
/// then a cooldown (ticks).
pub const punch_mm_s: f32 = 900.0;
pub const punch_cooldown = 30;
/// Stick hand: speed (units/s), the distance it holds while steered.
pub const stick_speed: f32 = 1.3;
pub const stick_z: f32 = 0.75;
/// Ticks without stick input before the stick hand lets go.
pub const stick_timeout = 240;

// ---------------------------------------------------------------------------
// Uniforms (uniforms.zig).

/// A cell's field value is presence * (base + (1 - base) * nearness).
pub const field_base: f32 = 0.35;
/// Per-tick glide of the cell values toward the newest frame (30 Hz sensor).
pub const field_glide: f32 = 0.3;
/// Punch flash peak (0..1 toward white) and decay per tick, and the
/// palette kick (turns) per punch.
pub const flash_peak: f32 = 0.8;
pub const flash_decay: f32 = 0.88;
pub const kick_turns: f32 = 0.333;
/// Per-tick ease of the palette phase toward the kicked target.
pub const kick_ease: f32 = 0.08;

// ---------------------------------------------------------------------------
// App (app.zig).

/// No sensed hand and no button for this long advances the program.
pub const attract_ticks = 30 * 60;
/// Parameter range and default (Up/Down).
pub const param_max = 8;
pub const param_default = 4;
/// Toast lifetime (ticks).
pub const toast_ticks = 100;
