//! TEMPORARY (Track B branch only; the integrator deletes this file).
//!
//! Stands in for Track A's M3 interfaces (PLAN.md "M3 Fixed interfaces") so
//! app.zig and main.zig build against the M2.2 tracer:
//!   scene.Preset, camera.default_height/min_height/max_height,
//!   trace.View, trace.render_frame(view).
//! At integration: in app.zig and main.zig replace the `m3_shim` import
//! block with the real `@import("scene.zig")`, `@import("camera.zig")`,
//! `@import("trace.zig")`, then delete this file.
//!
//! The stand-in render draws M2.2 frame `view.t` (orbit, preset and height
//! are ignored; the tracer cannot take them yet) and applies `view.fade`
//! afterwards by scaling the finished RGB565 pixels, so the attract fade is
//! visible in previews. The real tracer scales before dither instead.
const cart = @import("cart-api");
const real_trace = @import("trace.zig");
const real_camera = @import("camera.zig");

pub const scene = struct {
    pub const Preset = enum(u32) { sunset = 0, midnight = 1, noon = 2, storm = 3 };
};

pub const camera = struct {
    pub const default_height: f32 = 1.6;
    pub const min_height: f32 = 1.0;
    pub const max_height: f32 = 3.0;
    pub const orbit_frames = real_camera.orbit_frames;
};

pub const trace = struct {
    pub const View = struct {
        preset: scene.Preset,
        t: u32,
        orbit: u32,
        height: f32,
        fade: f32,
    };

    pub fn init() void {
        real_trace.init();
    }

    pub fn render_frame(view: View) void {
        real_trace.render_frame(view.t);
        if (view.fade >= 1.0) return;
        const k: u32 = @intFromFloat(@max(0.0, view.fade) * 256.0);
        for (cart.framebuffer) |*column| {
            for (column) |*px| {
                const c = px.to_color();
                px.* = .from_color(.{
                    .r = @intCast((@as(u32, c.r) * k) >> 8),
                    .g = @intCast((@as(u32, c.g) * k) >> 8),
                    .b = @intCast((@as(u32, c.b) * k) >> 8),
                });
            }
        }
    }
};
