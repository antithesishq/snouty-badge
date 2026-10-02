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
//! | `tufty20`| 160x128  | 20  | full15's scene at 20 fps (Tufty 2350, 250 MHz)|
//!
//! M2.2: full20, cut20 and full15 show the Iris logo to primary rays only,
//! with 3 samples (knobs 5-7, iris_cut); half30 shows it everywhere.
//!
//! M3: cut20 turns the rings, noon's water shadows and noon's small sphere
//! off (the M3 knobs, scene.zig; m3_cut) and renders presets without a
//! second sphere with their own instance (class_split); full20 and full15
//! follow m3_cut, half30 keeps noon's shadows and small sphere; the three
//! keep one render instance.
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
    /// M3 knobs (scene.zig): rings for every preset, noon's exact water
    /// shadows and its small chrome sphere.
    rings: bool = true,
    noon_shadows: bool = true,
    noon_third_sphere: bool = true,
    /// M3: a second render instance for the presets without a second sphere
    /// (trace.Class); +17 KB, -1.4 ms in sunset.
    class_split: bool = false,
};

/// The logo knobs cut20 needs (PLAN.md M2.2 "Budget and order of work":
/// knob 7 to 3, then knobs 5 and 6 off), which the other variants follow
/// unless their budget allows more: half30 keeps everything.
const iris_cut: Config = .{ .fps = 0, .iris_in_chrome = false, .iris_in_water = false, .iris_samples = 3 };

/// The M3 knobs cut20 needs (PLAN.md M3 "Knobs": rings, then noon's
/// shadows and small sphere), followed by full20 and full15; half30's
/// budget allows noon's but not the rings (33.1 ms in sunset with them).
const m3_cut: Config = .{ .fps = 0, .rings = false, .noon_shadows = false, .noon_third_sphere = false };

/// The table for every variant (`config_of(variant)` is this build's).
pub fn config_of(v: Variant) Config {
    return switch (v) {
        .full20 => .{ .fps = 20, .iris_in_chrome = iris_cut.iris_in_chrome, .iris_in_water = iris_cut.iris_in_water, .iris_samples = iris_cut.iris_samples, .rings = m3_cut.rings, .noon_shadows = m3_cut.noon_shadows, .noon_third_sphere = m3_cut.noon_third_sphere },
        .cut20 => .{ .fps = 20, .glass_enabled = false, .water_shadows = .off, .iris_in_chrome = iris_cut.iris_in_chrome, .iris_in_water = iris_cut.iris_in_water, .iris_samples = iris_cut.iris_samples, .rings = m3_cut.rings, .noon_shadows = m3_cut.noon_shadows, .noon_third_sphere = m3_cut.noon_third_sphere, .class_split = true },
        .full15 => .{ .fps = 15, .glass_primary = .env, .iris_in_chrome = iris_cut.iris_in_chrome, .iris_in_water = iris_cut.iris_in_water, .iris_samples = iris_cut.iris_samples, .rings = m3_cut.rings, .noon_shadows = m3_cut.noon_shadows, .noon_third_sphere = m3_cut.noon_third_sphere },
        .half30 => .{ .fps = 30, .render_scale = 2, .rings = m3_cut.rings },
        // The Tufty 2350 port (snouty-tufty): the same core at 250 MHz, so
        // full15's scene fits 20 fps there (docs/variants.md "tufty20").
        // Over budget on the SYCL badge at 150 MHz.
        .tufty20 => blk: {
            var c = config_of(.full15);
            c.fps = 20;
            break :blk c;
        },
    };
}

const config: Config = config_of(variant);

pub const fps: u32 = config.fps;

// ---- Frozen path tracer pacing (pt.zig, review G3) ----

/// Microseconds of every frozen update kept free of path tracing: what
/// runs outside pt.step's deadline loop (input, pt.display()'s full-screen
/// dither, dither.end_frame, the overshoot of the column that crosses the
/// deadline; 6.9 ms worst in the M4 cut20 bench, 42.89 ms busy for a
/// 36 ms slice, docs/RUNNING.md "Frozen path tracer pacing" for every
/// variant) plus the M4 gate's margin to the period and some slack for
/// the vsync wait. Shared by every variant: display() does not depend on
/// the render scale, and the frozen scene is the same in every variant.
pub const pt_reserve_us: u32 = 14_000;

/// The vsync period at `f` frames per second, in whole microseconds.
pub fn frame_period_us(f: u32) u32 {
    return 1_000_000 / f;
}

/// Tracing time per frozen update at `f` frames per second: the frame
/// period minus `pt_reserve_us`. cut20 (50 ms): 36 ms, as M4 shipped;
/// half30 (33.3 ms): 19.3 ms, so frozen mode keeps 30 fps.
pub fn pt_slice_for(f: u32) u32 {
    return frame_period_us(f) - pt_reserve_us;
}

/// This build's slice (pt.slice_us).
pub const pt_slice_us: u32 = pt_slice_for(config.fps);

comptime {
    // Every variant leaves time for the display after its slice.
    for (@typeInfo(Variant).@"enum".field_values) |raw| {
        const v: Variant = @fromBackingInt(raw);
        const f = config_of(v).fps;
        if (f == 0 or frame_period_us(f) <= pt_reserve_us) @compileError("pt slice: frame period too short for pt_reserve_us");
    }
}
pub const render_scale: u32 = config.render_scale;
pub const glass_enabled: bool = config.glass_enabled;
pub const water_shadows: scene.WaterShadows = config.water_shadows;
pub const glass_primary: scene.GlassPrimary = config.glass_primary;
pub const iris_in_chrome: bool = config.iris_in_chrome;
pub const iris_in_water: bool = config.iris_in_water;
pub const iris_samples: u32 = config.iris_samples;
pub const rings: bool = config.rings;
pub const noon_shadows: bool = config.noon_shadows;
pub const noon_third_sphere: bool = config.noon_third_sphere;
pub const class_split: bool = config.class_split;

comptime {
    if (render_scale != 1 and render_scale != 2) @compileError("render_scale must be 1 or 2");
}
