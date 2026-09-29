//! Perf variants (PLAN.md "M2.1 Perf variants"): the one place that maps
//! `-Dreflections_variant` to frame rate, render scale and scene knobs. The
//! picture logic is shared; a variant only sets these constants.
//!
//! | name     | res      | fps | scene                                         |
//! |----------|----------|-----|-----------------------------------------------|
//! | `full20` | 160x128  | 20  | everything, knobs 1-4 at defaults (baseline)  |
//! | `cut20`  | 160x128  | 20  | no glass sphere; water_shadows = off          |
//! | `full15` | 160x128  | 15  | everything; glass_primary = env (knob 4)      |
//! | `half30` | 80x64 x2 | 30  | everything, knobs at defaults                 |
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
};

const config: Config = switch (variant) {
    .full20 => .{ .fps = 20 },
    .cut20 => .{ .fps = 20, .glass_enabled = false, .water_shadows = .off },
    .full15 => .{ .fps = 15, .glass_primary = .env },
    .half30 => .{ .fps = 30, .render_scale = 2 },
};

pub const fps: u32 = config.fps;
pub const render_scale: u32 = config.render_scale;
pub const glass_enabled: bool = config.glass_enabled;
pub const water_shadows: scene.WaterShadows = config.water_shadows;
pub const glass_primary: scene.GlassPrimary = config.glass_primary;

comptime {
    if (render_scale != 1 and render_scale != 2) @compileError("render_scale must be 1 or 2");
}
