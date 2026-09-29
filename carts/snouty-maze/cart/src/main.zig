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
const autopilot = @import("autopilot.zig");
const actors = @import("actors.zig");
const leds = @import("leds.zig");
const raster = @import("render/raster.zig");
const textures = @import("render/textures.zig");
const scene = @import("render/scene.zig");
const overlay = @import("render/overlay.zig");

comptime {
    cart.export_start_code();
}

/// walk = 0, turn = 1, pause = 2, rise = 3, overhead = 4, descend = 5,
/// teleport = 6, fly = 7, manual = 8 (stable: debug_state returns these). The state
/// itself lives in autopilot.zig.
pub const State = autopilot.State;

var tick: u32 = 0;
var render_us: u32 = 0;
var fps_x10: u32 = 0;
var show_debug: bool = build_options.debug_overlay;
var random: rng.Xorshift = undefined;
var world: maze.Maze = .{};
/// Exported on the badge build too, so badge-bench can `--poke maze_size=16`
/// before start() (unexported, the compiler folds it to the build option).
var maze_size: u8 = build_options.maze_size;
/// Seed of the current rng stream, so debug_set_size and debug_set_seed
/// give the same maze whichever order the harness calls them in.
var seed: u32 = 0;
/// debug_fade level; the frame gets max(this, autopilot.fade_level()).
var fade_level: u8 = 0;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    textures.init();
    reseed(cart.rand());
}

fn reseed(s: u32) void {
    seed = s;
    random = rng.Xorshift.init(s);
    new_maze();
    autopilot.begin_walk(&world);
}

fn new_maze() void {
    world.generate(maze_size, maze_size, &random);
    camera.reset(&world);
    actors.reset(&world, &random, actors.cell_of(camera.cam.pos));
}

pub fn update() void {
    input.update(read_controls());

    // B+Select (either order) toggles fly, compiled in only with
    // -Ddebug_overlay=true (debug_set_camera still enters fly on wasm);
    // Select alone toggles the neopixels in the screensaver states and
    // the debug overlay in fly.
    if (build_options.debug_overlay and ((input.pressed(.select) and input.held(.b)) or (input.pressed(.b) and input.held(.select)))) {
        autopilot.toggle_fly(&world);
    } else if (input.pressed(.select)) {
        if (autopilot.state == .fly) show_debug = !show_debug else leds.toggle();
    }

    if (autopilot.state == .fly) {
        if (input.pressed(.start)) camera.reset(&world);
        // A+B: new maze, once per chord (the tick the second button goes down).
        if (input.held(.a) and input.held(.b) and (input.pressed(.a) or input.pressed(.b))) new_maze();
        camera.debug_fly(.{
            .up = input.held(.up),
            .down = input.held(.down),
            .left = input.held(.left),
            .right = input.held(.right),
            .a = input.held(.a),
            .b = input.held(.b),
        });
    } else {
        if (input.pressed(.start)) autopilot.name_strip_forced = !autopilot.name_strip_forced;
        // The stick takes the camera over in WALK/TURN and drives MANUAL.
        autopilot.stick(&world, .{
            .up = input.held(.up),
            .down = input.held(.down),
            .left = input.held(.left),
            .right = input.held(.right),
        }, .{
            .up = input.pressed(.up),
            .down = input.pressed(.down),
            .left = input.pressed(.left),
            .right = input.pressed(.right),
        });
        if (input.pressed(.a)) {
            autopilot.skip();
        } else {
            autopilot.step(&world, &random, raster.focal);
        }
    }
    // Actors tick in every state; the smiley and sphere fire only while
    // walking (WALK/TURN/MANUAL).
    const triggers = autopilot.walking();
    actors.step(&world, &random, actors.cell_of(camera.cam.pos), triggers);

    const t0 = cart.micros_since_boot();
    raster.begin_frame();
    clear_screen();
    scene.draw(&world, &camera.cam);
    const dt: u32 = @truncate(cart.micros_since_boot() - t0);
    render_us = dt;
    fps_x10 = if (dt > 0) @min(999, 10_000_000 / @max(dt, 16_667)) else 0;
    if (name_strip_on()) overlay.draw_name_strip();
    if (show_debug) overlay.draw_debug(render_us, fps_x10);
    const fade = @max(fade_level, autopilot.fade_level());
    if (fade != 0) overlay.fade(fade);
    leds.update(autopilot.state, actors.flips, actors.teleports);

    tick +%= 1;
    if (cart.is_wasm) present_wasm();
}

fn name_strip_on() bool {
    return autopilot.state != .fly and (autopilot.name_strip_visible or autopilot.name_strip_forced);
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
        @export(&debug_set_size, .{ .name = "debug_set_size" });
        @export(&debug_finish_x, .{ .name = "debug_finish_x" });
        @export(&debug_finish_z, .{ .name = "debug_finish_z" });
        @export(&debug_run_count, .{ .name = "debug_run_count" });
        @export(&debug_cycles, .{ .name = "debug_cycles" });
        @export(&debug_state_tick, .{ .name = "debug_state_tick" });
        @export(&debug_heading, .{ .name = "debug_heading" });
        @export(&debug_set_roll, .{ .name = "debug_set_roll" });
        @export(&debug_skip, .{ .name = "debug_skip" });
        @export(&debug_name_strip, .{ .name = "debug_name_strip" });
        @export(&debug_fade, .{ .name = "debug_fade" });
        @export(&debug_snouty_x, .{ .name = "debug_snouty_x" });
        @export(&debug_snouty_z, .{ .name = "debug_snouty_z" });
        @export(&debug_smiley_x, .{ .name = "debug_smiley_x" });
        @export(&debug_smiley_z, .{ .name = "debug_smiley_z" });
        @export(&debug_sphere_x, .{ .name = "debug_sphere_x" });
        @export(&debug_sphere_z, .{ .name = "debug_sphere_z" });
        @export(&debug_logo_x, .{ .name = "debug_logo_x" });
        @export(&debug_logo_z, .{ .name = "debug_logo_z" });
        @export(&debug_flips, .{ .name = "debug_flips" });
        @export(&debug_teleports, .{ .name = "debug_teleports" });
        @export(&debug_roll_deg, .{ .name = "debug_roll_deg" });
        @export(&debug_leds, .{ .name = "debug_leds" });
        @export(&debug_manual_idle, .{ .name = "debug_manual_idle" });
        @export(&debug_carve_shown, .{ .name = "debug_carve_shown" });
        @export(&debug_carve_count, .{ .name = "debug_carve_count" });
        @export(&debug_led_max, .{ .name = "debug_led_max" });
        @export(&debug_place, .{ .name = "debug_place" });
        @export(&debug_fade_level, .{ .name = "debug_fade_level" });
    } else {
        @export(&maze_size, .{ .name = "maze_size" });
    }
}

fn debug_tick() callconv(.c) u32 {
    return tick;
}
fn debug_state() callconv(.c) u32 {
    return @backingInt(autopilot.state);
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
    autopilot.state = .fly;
    camera.cam = .{
        .pos = math.vec3(x, y, z),
        .yaw = deg_to_angle(yaw_deg),
        .pitch = deg_to_angle(pitch_deg),
        .roll = deg_to_angle(roll_deg),
    };
}
/// Reseeds and regenerates the maze (call before the first update()).
fn debug_set_seed(s: u32) callconv(.c) void {
    reseed(s);
}
/// Sets the maze to n x n (clamped to 4..16) and regenerates it from the
/// current seed, so set_size then set_seed or the reverse agree.
fn debug_set_size(n: u32) callconv(.c) void {
    maze_size = @intCast(std.math.clamp(n, 4, maze.max_size));
    reseed(seed);
}
fn debug_finish_x() callconv(.c) u32 {
    return world.finish[0];
}
fn debug_finish_z() callconv(.c) u32 {
    return world.finish[1];
}
fn debug_run_count() callconv(.c) u32 {
    return world.run_count;
}
fn debug_cell_x() callconv(.c) u32 {
    return @intFromFloat(@max(0.0, camera.cam.pos[0]));
}
fn debug_cell_z() callconv(.c) u32 {
    return @intFromFloat(@max(0.0, camera.cam.pos[2]));
}

/// Mazes completed (bumped when OVERHEAD swaps in the new maze).
fn debug_cycles() callconv(.c) u32 {
    return autopilot.cycles;
}
fn debug_state_tick() callconv(.c) u32 {
    return autopilot.state_tick;
}
/// Autopilot heading (n = 0, e, s, w); in fly, the camera's compass quadrant.
fn debug_heading() callconv(.c) u32 {
    const d = if (autopilot.state == .fly) camera.heading(camera.cam.yaw) else autopilot.dir;
    return @backingInt(d);
}
/// Sets the camera roll in degrees and restarts the roll-cap timer.
fn debug_set_roll(roll_deg: f32) callconv(.c) void {
    autopilot.set_roll(deg_to_angle(roll_deg));
}
/// Same as pressing A: WALK/TURN/MANUAL jump to PAUSE.
fn debug_skip() callconv(.c) void {
    autopilot.skip();
}
fn debug_name_strip() callconv(.c) u32 {
    return @intFromBool(name_strip_on());
}
/// Applies overlay.fade(level) (0..16) to every following frame, for
/// testing the teleport dissolve; 0 turns it off. The teleport's own fade
/// is combined with it by max.
fn debug_fade(level: u32) callconv(.c) void {
    fade_level = @intCast(@min(level, 16));
}

// Actor cells (floor of x, z).
fn debug_snouty_x() callconv(.c) u32 {
    return actors.cell_of(actors.snouty.pos)[0];
}
fn debug_snouty_z() callconv(.c) u32 {
    return actors.cell_of(actors.snouty.pos)[1];
}
fn debug_smiley_x() callconv(.c) u32 {
    return actors.cell_of(actors.smiley.pos)[0];
}
fn debug_smiley_z() callconv(.c) u32 {
    return actors.cell_of(actors.smiley.pos)[1];
}
fn debug_sphere_x() callconv(.c) u32 {
    return actors.cell_of(actors.sphere.pos)[0];
}
fn debug_sphere_z() callconv(.c) u32 {
    return actors.cell_of(actors.sphere.pos)[1];
}
fn debug_logo_x() callconv(.c) u32 {
    return actors.cell_of(actors.logo.pos)[0];
}
fn debug_logo_z() callconv(.c) u32 {
    return actors.cell_of(actors.logo.pos)[1];
}
/// Smiley flips and sphere teleports since boot.
fn debug_flips() callconv(.c) u32 {
    return actors.flips;
}
fn debug_teleports() callconv(.c) u32 {
    return actors.teleports;
}
/// Camera roll in whole degrees, 0..359.
fn debug_roll_deg() callconv(.c) u32 {
    const r: u32 = camera.cam.roll;
    return ((r * 360 + 32768) >> 16) % 360;
}
/// 1 when the neopixels are enabled (Select in the screensaver states).
fn debug_leds() callconv(.c) u32 {
    return @intFromBool(leds.enabled);
}
/// Ticks since a stick direction was last held (MANUAL returns to WALK
/// at autopilot.manual_idle_ticks).
fn debug_manual_idle() callconv(.c) u32 {
    return autopilot.manual_idle;
}
/// Largest channel value across the five neopixels (must stay <= 10).
fn debug_led_max() callconv(.c) u32 {
    var hi: u32 = 0;
    for (0..cart.neopixels.len) |i| {
        const p = cart.neopixels[i];
        hi = @max(hi, @max(p.r, @max(p.g, p.b)));
    }
    return hi;
}
/// Moves an actor: code = kind * 10000 + x * 100 + z, kind 0 Snouty,
/// 1 smiley, 2 sphere, 3 logo (one integer so `preview.mjs --call` can
/// drive it). Unknown kinds are ignored.
fn debug_place(code: u32) callconv(.c) void {
    const kind = code / 10000;
    if (kind > 3) return;
    const x: u8 = @intCast((code / 100) % 100);
    const z: u8 = @intCast(code % 100);
    actors.place(&world, @fromBackingInt(@intCast(kind)), x, z);
}
/// Carves the maze's runs show (C4: < debug_carve_count while OVERHEAD
/// carves) and the carve total, w*h - 1.
fn debug_carve_shown() callconv(.c) u32 {
    return world.revealed;
}
fn debug_carve_count() callconv(.c) u32 {
    return world.carve_count;
}
/// The fade level applied to the last frame (0..16).
fn debug_fade_level() callconv(.c) u32 {
    return @max(fade_level, autopilot.fade_level());
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
