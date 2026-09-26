//! Snouty Maze: a from-scratch clone of the Windows 3D Maze screensaver,
//! drawn by a small software rasterizer. See SPEC.md for the design,
//! PLAN.md for the current milestone's contract, CLAUDE.md for the toolchain.
const std = @import("std");
const cart = @import("cart-api");
const build_options = @import("build_options");
const input = @import("input.zig");
const math = @import("math.zig");
const rng = @import("rng.zig");
const maze = @import("maze.zig");
const camera = @import("camera.zig");
const raster = @import("render/raster.zig");
const textures = @import("render/textures.zig");
const scene = @import("render/scene.zig");
const overlay = @import("render/overlay.zig");

comptime {
    cart.export_start_code();
}

pub const State = enum(u32) { walk, turn, pause, rise, overhead, descend, teleport, fly };

var state: State = .fly;
var tick: u32 = 0;
var render_us: u32 = 0;
var fps_x10: u32 = 0;
var show_debug: bool = build_options.debug_overlay;
var random: rng.Xorshift = undefined;
var world: maze.Maze = .{};
var maze_size: u8 = 12;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    textures.init();
    random = rng.Xorshift.init(cart.rand());
    new_maze();
}

fn new_maze() void {
    world.generate(maze_size, maze_size, &random);
    camera.reset(&world);
}

pub fn update() void {
    input.update(read_controls());

    if (input.pressed(.select)) show_debug = !show_debug;
    if (input.pressed(.start)) camera.reset(&world);
    if (input.pressed(.a) and input.held(.b) or input.pressed(.b) and input.held(.a)) new_maze();
    camera.debug_fly(.{
        .up = input.held(.up),
        .down = input.held(.down),
        .left = input.held(.left),
        .right = input.held(.right),
        .a = input.held(.a),
        .b = input.held(.b),
    });

    const t0 = cart.micros_since_boot();
    raster.begin_frame();
    clear_screen();
    scene.draw(&world, &camera.cam);
    const dt: u32 = @truncate(cart.micros_since_boot() - t0);
    render_us = dt;
    fps_x10 = if (dt > 0) @min(999, 10_000_000 / @max(dt, 16_667)) else 0;
    if (show_debug) overlay.draw_debug(render_us, fps_x10);

    tick +%= 1;
    if (cart.is_wasm) present_wasm();
}

/// Background for pixels no polygon covers (only visible when the camera
/// is outside the maze). Tracks A may replace this with a sky colour.
fn clear_screen() void {
    const bg: cart.Pixel = .from_color(.rgb(0x101018));
    for (cart.framebuffer) |*column| @memset(column, bg);
}

// Debug exports for the headless harness (wasm only).
comptime {
    if (cart.is_wasm) {
        @export(&debug_tick, .{ .name = "debug_tick" });
        @export(&debug_state, .{ .name = "debug_state" });
        @export(&debug_render_us, .{ .name = "debug_render_us" });
        @export(&debug_pixel_checksum, .{ .name = "debug_pixel_checksum" });
        @export(&debug_set_camera, .{ .name = "debug_set_camera" });
        @export(&debug_set_seed, .{ .name = "debug_set_seed" });
        @export(&debug_cell_x, .{ .name = "debug_cell_x" });
        @export(&debug_cell_z, .{ .name = "debug_cell_z" });
    }
}

fn debug_tick() callconv(.c) u32 {
    return tick;
}
fn debug_state() callconv(.c) u32 {
    return @backingInt(state);
}
fn debug_render_us() callconv(.c) u32 {
    return render_us;
}
/// Sum of all framebuffer words, for render regression tests.
fn debug_pixel_checksum() callconv(.c) u32 {
    var sum: u32 = 0;
    for (cart.framebuffer) |*column| {
        for (column) |px| sum +%= @as(u16, @bitCast(px));
    }
    return sum;
}
/// Places the camera; angles in degrees. Switches to the fly state so the
/// autopilot does not move it.
fn debug_set_camera(x: f32, y: f32, z: f32, yaw_deg: f32, pitch_deg: f32, roll_deg: f32) callconv(.c) void {
    state = .fly;
    camera.cam = .{
        .pos = math.vec3(x, y, z),
        .yaw = deg_to_angle(yaw_deg),
        .pitch = deg_to_angle(pitch_deg),
        .roll = deg_to_angle(roll_deg),
    };
}
/// Reseeds and regenerates the maze (call before the first update()).
fn debug_set_seed(seed: u32) callconv(.c) void {
    random = rng.Xorshift.init(seed);
    new_maze();
}
fn debug_cell_x() callconv(.c) u32 {
    return @intFromFloat(@max(0.0, camera.cam.pos[0]));
}
fn debug_cell_z() callconv(.c) u32 {
    return @intFromFloat(@max(0.0, camera.cam.pos[2]));
}

fn deg_to_angle(d: f32) math.Angle {
    const turns = d / 360.0;
    return @intFromFloat((turns - @floor(turns)) * 65536.0);
}

/// Button state. Upstream's platform_wasm.zig exposes `controls` but never
/// fills it from the simulator, which writes its button word (same bit
/// layout as cart.Controls) to linear address 0x04; read that directly on
/// wasm. Hardware gets the OS-maintained cart.controls.
pub fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// Simulator shim (see snouty-bugs/CLAUDE.md): upstream's wasm platform
/// never presents, and the web simulator reads a legacy framebuffer at 0x20
/// with red and blue swapped. Hardware builds compile none of this.
fn present_wasm() void {
    const sim_framebuffer: *cart.Framebuffer = @ptrFromInt(0x20);
    for (cart.framebuffer, sim_framebuffer) |*src_column, *dst_column| {
        for (src_column, dst_column) |src, *dst| {
            const c = src.to_color();
            dst.* = .from_color(.{ .r = c.b, .g = c.g, .b = c.r });
        }
    }
}
