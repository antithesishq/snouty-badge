//! Snouty Morph: a demoscene mesh that follows your hand in six degrees of
//! freedom and deforms with it, sensed by a TMF8820 time-of-flight
//! breakout on the Qwiic port (docs/TOF.md). See SPEC.md for the design,
//! PLAN.md for the status.
//!
//! update(): input (Start next mesh, Select sound; nothing while Start and
//! Select are both held, the OS chord; joystick click never bound), the
//! hand (sensor, stick or ghost: hand.zig), the body's springs and
//! deformations (body.zig), then the backdrop, the mesh and the HUD, and
//! the sound.
const std = @import("std");
const cart = @import("cart-api");
const build_options = @import("build_options");
const backdrop = @import("backdrop.zig");
const body = @import("body.zig");
const config = @import("config.zig");
const hand = @import("hand.zig");
const hud = @import("hud.zig");
const input = @import("input.zig");
const math = @import("math.zig");
const mesh = @import("mesh.zig");
const render = @import("render.zig");
const sound = @import("sound.zig");
const text = @import("text.zig");

comptime {
    cart.export_start_code();
}

/// The mesh the cart starts on. Exported on the badge build so badge-bench
/// can `--poke start_mesh=N` before start(); the wasm build has
/// debug_set_mesh for the same.
var start_mesh: u8 = 0;

var current: usize = 0;
var frame: u32 = 0;
var render_us: u32 = 0;
var show_overlay: bool = build_options.debug_overlay;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    math.init_tables();
    mesh.init();
    render.init();
    backdrop.init();
    hand.reset();
    body.reset();
    select_mesh(start_mesh % mesh.count);
}

fn select_mesh(i: usize) void {
    current = i;
    render.set_mesh(&mesh.meshes[i]);
    hud.show_mesh(mesh.meshes[i].name);
}

pub fn update() void {
    input.update(read_controls());
    var stick: hand.Stick = .{};
    if (input.held(.start) and input.held(.select)) {
        // Start+Select is the OS's chord: react to neither button.
    } else {
        if (input.pressed(.start)) select_mesh((current + 1) % mesh.count);
        if (input.pressed(.select)) {
            sound.set(!sound.enabled);
            hud.show_sound(sound.enabled);
        }
        stick = .{
            .up = input.held(.up),
            .down = input.held(.down),
            .left = input.held(.left),
            .right = input.held(.right),
            .b = input.held(.b),
            .a_pressed = input.pressed(.a),
        };
    }

    const t0 = cart.micros_since_boot();
    hand.update(stick, t0);
    const h = hand.hand;
    var params = body.update(h);
    params.scale *= mesh.meshes[current].size;
    if (h.punch) sound.thump();
    sound.drone(h.z, body.energy);

    const fb = cart.framebuffer;
    const m = &mesh.meshes[current];
    backdrop.draw(fb, m.backdrop, frame, .{
        .x = h.x,
        .y = h.y,
        .z = h.z,
        .vz = h.vz,
        .vx = h.vx,
        .flash = params.flash / config.flash_boost,
    });
    render.draw(fb, m, params);
    hud.draw(frame);
    render_us = @truncate(cart.micros_since_boot() - t0);
    if (show_overlay) draw_overlay();
    sound.update();
    frame +%= 1;

    if (cart.is_wasm) present_wasm();
}

/// Render time (us) and faces drawn, bottom-right, in -Ddebug_overlay=true builds.
fn draw_overlay() void {
    var buf: [11]u8 = undefined;
    text.put_uint(buf[0..5], render_us);
    buf[5] = 'u';
    buf[6] = ' ';
    text.put_uint(buf[7..11], render.drawn);
    cart.text(.{ .str = &buf, .x = 160 - 11 * 8, .y = 128 - 9, .text_color = .rgb(0xffff00), .background_color = .rgb(0x000000) });
}

// Debug exports for the headless harness (wasm), start_mesh for badge-bench.
comptime {
    if (cart.is_wasm) {
        @export(&debug_frame, .{ .name = "debug_frame" });
        @export(&debug_mesh, .{ .name = "debug_mesh" });
        @export(&debug_set_mesh, .{ .name = "debug_set_mesh" });
        @export(&debug_source, .{ .name = "debug_source" });
        @export(&debug_present, .{ .name = "debug_present" });
        @export(&debug_hand_z, .{ .name = "debug_hand_z" });
        @export(&debug_ripples, .{ .name = "debug_ripples" });
        @export(&debug_faces, .{ .name = "debug_faces" });
        @export(&debug_render_us, .{ .name = "debug_render_us" });
        @export(&debug_pixel_checksum, .{ .name = "debug_pixel_checksum" });
        @export(&debug_sound, .{ .name = "debug_sound" });
    } else {
        @export(&start_mesh, .{ .name = "start_mesh" });
    }
}

fn debug_frame() callconv(.c) u32 {
    return frame;
}
fn debug_mesh() callconv(.c) u32 {
    return @intCast(current);
}
fn debug_set_mesh(i: u32) callconv(.c) void {
    select_mesh(i % mesh.count);
}
/// 0 ghost, 1 stick, 2 sensor.
fn debug_source() callconv(.c) u32 {
    return @backingInt(hand.source);
}
/// 1 while the active pose (ghost or sensor) has a hand.
fn debug_present() callconv(.c) u32 {
    return @intFromBool(hand.pose.present);
}
/// Hand z (0 far .. 1000 near).
fn debug_hand_z() callconv(.c) u32 {
    return @intFromFloat(hand.hand.z * 1000.0);
}
fn debug_ripples() callconv(.c) u32 {
    return @intCast(body.ripples_alive());
}
fn debug_faces() callconv(.c) u32 {
    return render.drawn;
}
fn debug_render_us() callconv(.c) u32 {
    return render_us;
}
fn debug_sound() callconv(.c) u32 {
    return @intFromBool(sound.enabled);
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
            const c = src.to_color();
            dst.* = .from_color(.{ .r = c.b, .g = c.g, .b = c.r });
        }
    }
}
