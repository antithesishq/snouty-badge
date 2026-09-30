//! Perf variants (PLAN.md "M2.1 Perf variants"): the one place that maps
//! `-Dreflections_variant` to frame rate, render scale and scene knobs. The
//! picture logic is shared; a variant only sets these constants. cut20 is
//! the default build (Adrian, 2026-09-29); the others stay buildable.
//!
//! | name     | res      | fps | scene                                         |
//! |----------|----------|-----|-----------------------------------------------|
//! | `full20` | 160x128  | 20  | everything, knobs 1-4 at defaults (baseline)  |
//! | `cut20`  | 160x128  | 20  | no glass sphere; water_shadows = off          |
//! | `full15` | 160x128  | 15  | everything; glass_primary = env (knob 4)      |
//! | `half30` | 80x64 x2 | 30  | everything, knobs at defaults                 |
//!
//! M2.2: full20, cut20 and full15 show the Iris logo to primary rays only,
//! with 3 samples (knobs 5-7, iris_cut); half30 shows it everywhere.
const build_options = @import("build_options");
const scene = @import("scene.zig");

pub const Variant = @TypeOf(build_options.reflections_variant);
pub const variant: Variant = build_options.reflections_variant;

const Config = struct {
    /// Frames per second: vsync period, orbit length (30 s) and water time.
    fps: u32,
    /// 1: a ray per pixel. 2: a ray per even (x, y), written to its 2x2
    /// block, each pixel dithered with its own threshold.
    render_scale: u32 = 1,
    /// false: no glass sphere at all (hit tests, spans, shadow caster).
    glass_enabled: bool = true,
    /// Knob 2 override.
    water_shadows: scene.WaterShadows = .all,
    /// Knob 4 override.
    glass_primary: scene.GlassPrimary = .full,
    /// Knobs 5-7 (M2.2): the Iris logo in chrome and water reflections, and
    /// its mask samples per ray.
    iris_in_chrome: bool = true,
    iris_in_water: bool = true,
    iris_samples: u32 = 4,
    /// M3 knob rings (scene.zig), for every preset.
    rings: bool = true,
};

/// The logo knobs cut20 needs (PLAN.md M2.2 "Budget and order of work":
/// knob 7 to 3, then knobs 5 and 6 off), which the other variants follow
/// unless their budget allows more: half30 keeps everything.
const iris_cut: Config = .{ .fps = 0, .iris_in_chrome = false, .iris_in_water = false, .iris_samples = 3 };

const config: Config = switch (variant) {
    .full20 => .{ .fps = 20, .iris_in_chrome = iris_cut.iris_in_chrome, .iris_in_water = iris_cut.iris_in_water, .iris_samples = iris_cut.iris_samples },
    .cut20 => .{ .fps = 20, .glass_enabled = false, .water_shadows = .off, .iris_in_chrome = iris_cut.iris_in_chrome, .iris_in_water = iris_cut.iris_in_water, .iris_samples = iris_cut.iris_samples, .rings = false },
    .full15 => .{ .fps = 15, .glass_primary = .env, .iris_in_chrome = iris_cut.iris_in_chrome, .iris_in_water = iris_cut.iris_in_water, .iris_samples = iris_cut.iris_samples },
    .half30 => .{ .fps = 30, .render_scale = 2 },
};

pub const fps: u32 = config.fps;
pub const render_scale: u32 = config.render_scale;
pub const glass_enabled: bool = config.glass_enabled;
pub const water_shadows: scene.WaterShadows = config.water_shadows;
pub const glass_primary: scene.GlassPrimary = config.glass_primary;
pub const iris_in_chrome: bool = config.iris_in_chrome;
pub const iris_in_water: bool = config.iris_in_water;
pub const iris_samples: u32 = config.iris_samples;
pub const rings: bool = config.rings;

comptime {
    if (render_scale != 1 and render_scale != 2) @compileError("render_scale must be 1 or 2");
}
