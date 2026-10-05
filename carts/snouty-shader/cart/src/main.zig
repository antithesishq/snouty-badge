//! Snouty Shader: a Shadertoy-style gallery of abstract real-time shaders
//! played by hand over a TMF8820 time-of-flight breakout on the Qwiic port
//! (docs/TOF.md). See SPEC.md for the design, PLAN.md for the status.
//!
//! update(): buttons (app.zig: nothing while Start and Select are both
//! held; joystick click never bound), the hand (sensor, stick or ghost:
//! hand.zig), the uniforms and field (uniforms.zig), the program into the
//! 80x64 surface, the 2x upscale, the HUD, the sound.
const std = @import("std");
const cart = @import("cart-api");
const build_options = @import("build_options");
const app = @import("app.zig");
const field = @import("field.zig");
const hand = @import("hand.zig");
const hud = @import("hud.zig");
const math = @import("math.zig");
const noise = @import("noise.zig");
const palette = @import("palette.zig");
const programs = @import("programs.zig");
const sound = @import("sound.zig");
const surface = @import("surface.zig");
const text = @import("text.zig");
const uniforms = @import("uniforms.zig");

comptime {
    cart.export_start_code();
}

/// The program the cart starts on. Exported on the badge build so
/// badge-bench can `--poke start_program=N` before start(); the wasm build
/// has debug_set_program for the same.
var start_program: u8 = 0;

var surf: surface.Surface = undefined;
var frame: u32 = 0;
var render_us: u32 = 0;
var show_overlay: bool = build_options.debug_overlay;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    math.init_tables();
    noise.init();
    field.init();
    programs.init_all();
    hand.reset();
    uniforms.reset();
    app.reset(start_program, sound.enabled);
    programs.list[app.program].enter();
}

pub fn update() void {
    const c = read_controls();
    const out = app.step(.{
        .start = c.start,
        .select = c.select,
        .a = c.a,
        .b = c.b,
        .up = c.up,
        .down = c.down,
        .left = c.left,
        .right = c.right,
    }, hand.sensed());
    if (out.sound_changed) sound.set(app.sound);
    if (out.program_changed) {
        programs.list[app.program].enter();
        sound.blip(app.program);
    }

    const t0 = cart.micros_since_boot();
    hand.update(out.stick, t0);
    uniforms.update(app.param());
    const u = &uniforms.u;
    if (u.hand.punch) sound.thump();
    sound.drone(if (u.hand.present) u.hand.z else 0, u.total, app.program);

    const pr = &programs.list[app.program];
    pr.render(u, &palette.all[app.palette_index()], &surf);
    surface.upscale(&surf, @ptrCast(cart.framebuffer));
    hud.draw(u);
    render_us = @truncate(cart.micros_since_boot() - t0);
    if (show_overlay) draw_overlay();
    sound.update();
    frame +%= 1;

    if (cart.is_wasm) present_wasm();
}

/// Render time (us), bottom-right, in -Ddebug_overlay=true builds.
fn draw_overlay() void {
    var buf: [6]u8 = undefined;
    text.put_uint(buf[0..5], render_us);
    buf[5] = 'u';
    cart.text(.{ .str = &buf, .x = 160 - 6 * 8, .y = 128 - 9, .text_color = .rgb(0xffff00), .background_color = .rgb(0x000000) });
}

// Debug exports for the headless harness (wasm), start_program for badge-bench.
comptime {
    if (cart.is_wasm) {
        @export(&debug_frame, .{ .name = "debug_frame" });
        @export(&debug_program, .{ .name = "debug_program" });
        @export(&debug_set_program, .{ .name = "debug_set_program" });
        @export(&debug_palette, .{ .name = "debug_palette" });
        @export(&debug_param, .{ .name = "debug_param" });
        @export(&debug_source, .{ .name = "debug_source" });
        @export(&debug_present, .{ .name = "debug_present" });
        @export(&debug_hand_z, .{ .name = "debug_hand_z" });
        @export(&debug_field_peak, .{ .name = "debug_field_peak" });
        @export(&debug_punch_age, .{ .name = "debug_punch_age" });
        @export(&debug_render_us, .{ .name = "debug_render_us" });
        @export(&debug_pixel_checksum, .{ .name = "debug_pixel_checksum" });
        @export(&debug_sound, .{ .name = "debug_sound" });
        @export(&debug_hud, .{ .name = "debug_hud" });
    } else {
        @export(&start_program, .{ .name = "start_program" });
    }
}

fn debug_frame() callconv(.c) u32 {
    return frame;
}
fn debug_program() callconv(.c) u32 {
    return app.program;
}
fn debug_set_program(i: u32) callconv(.c) u32 {
    app.program = @intCast(i % programs.count);
    programs.list[app.program].enter();
    return app.program;
}
fn debug_palette() callconv(.c) u32 {
    return app.palette_index();
}
fn debug_param() callconv(.c) u32 {
    return app.param();
}
/// 0 ghost, 1 stick, 2 sensor.
fn debug_source() callconv(.c) u32 {
    return @backingInt(hand.source);
}
fn debug_present() callconv(.c) u32 {
    return @intFromBool(hand.hand.present);
}
/// Hand z (0 far .. 1000 near).
fn debug_hand_z() callconv(.c) u32 {
    return @intFromFloat(hand.hand.z * 1000.0);
}
fn debug_field_peak() callconv(.c) u32 {
    return field.peak;
}
fn debug_punch_age() callconv(.c) u32 {
    return uniforms.u.punch_age;
}
fn debug_render_us() callconv(.c) u32 {
    return render_us;
}
fn debug_sound() callconv(.c) u32 {
    return @intFromBool(sound.enabled);
}
fn debug_hud() callconv(.c) u32 {
    return @intFromBool(app.hud);
}
/// Sum of all framebuffer words of the last frame, for regression checks.
fn debug_pixel_checksum() callconv(.c) u32 {
    var sum: u32 = 0;
    for (cart.framebuffer) |*column| {
        for (column) |px| sum +%= @as(u16, @bitCast(px));
    }
    return sum;
}

/// Button state. Upstream's platform_wasm.zig never fills `controls` from
/// the simulator, which writes its button word (same bit layout as
/// cart.Controls) to linear address 0x04; read that directly on wasm.
pub fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// Simulator shim: upstream's wasm platform never presents, and the web
/// simulator reads a legacy framebuffer at 0x20 with red and blue swapped.
/// Hardware builds compile none of this.
fn present_wasm() void {
    const sim_framebuffer: *cart.Framebuffer = @ptrFromInt(0x20);
    for (cart.framebuffer, sim_framebuffer) |*src_column, *dst_column| {
        for (src_column, dst_column) |src, *dst| {
            const col = src.to_color();
            dst.* = .from_color(.{ .r = col.b, .g = col.g, .b = col.r });
        }
    }
}
