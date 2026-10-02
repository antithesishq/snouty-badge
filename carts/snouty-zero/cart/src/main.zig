//! Snouty Zero: an F-Zero style Mode 7 hover racer on a planet-sized AI
//! datacenter. SPEC.md is the design, PLAN.md the milestone contract.
//! M2: a full race against four rivals and traffic, results screen.
const cart = @import("cart-api");
const build_options = @import("build_options");
const input = @import("input.zig");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const camera = @import("camera.zig");
const render = @import("render.zig");
const track = @import("track.zig");
const world = @import("world.zig");
const sim = @import("sim.zig");
const sprites = @import("sprites.zig");
const hud = @import("hud.zig");
const ai = @import("ai.zig");
const results = @import("results.zig");

/// Screens: the race (countdown, racing, the cool-down after the finish)
/// and the results.
const Screen = enum { race, results };
var screen: Screen = .race;
/// Ticks since the player finished (the results come after `results_after`).
var finished_ticks: u32 = 0;
const results_after: u32 = 150;
/// Machines in a race: the player, 4 rivals, 6 traffic.
pub const race_machines: u8 = 11;

comptime {
    cart.export_start_code();
}

/// Frames since start(); one frame is one update() at 60 Hz.
var frame: u32 = 0;
/// Microseconds spent in the last frame's simulate + render (hardware timer; 0 on wasm).
var render_us: u32 = 0;
/// The M0 free camera (debug_set_freecam; debugging the floor).
var free_cam: bool = false;
/// The autopilot drives the player (attract mode in M2; `debug_set_autopilot` now).
pub var autopilot: bool = false;
/// Crash starts since boot (debug_crashes).
var crashes: u32 = 0;
var last_crash: world.Crash = .none;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    sprites.init();
    new_race(&track.cold_aisle);
}

fn new_race(t: *const track.Track) void {
    render.set_track(t);
    hud.init_minimap(t);
    sim.reset(t, race_machines);
    const p = &world.w.machines[world.player];
    camera.follow(p.x, p.y, p.heading, true);
    screen = .race;
    finished_ticks = 0;
    results.rewinds = 0;
}

pub fn update() void {
    input.update(read_controls());
    const t0 = cart.micros_since_boot();

    if (screen == .results) {
        if (input.pressed(.start)) new_race(sim.current);
        results.draw(frame);
        render_us = @truncate(cart.micros_since_boot() - t0);
        frame +%= 1;
        if (cart.is_wasm) present_wasm();
        return;
    }
    if (input.pressed(.select)) hud.minimap_large = !hud.minimap_large;
    if (world.w.phase == .finished) {
        finished_ticks += 1;
        if (finished_ticks >= results_after or input.pressed(.start)) screen = .results;
    }

    const pressed: world.Buttons = @bitCast(@as(u16, @bitCast(input.current)));
    const buttons: world.Buttons = if (autopilot) ai.drive(&world.w.machines[world.player], 0) else pressed;
    sim.simulate(if (free_cam) .{} else buttons);
    const p = &world.w.machines[world.player];
    if (p.crash != .none and last_crash == .none) crashes += 1;
    last_crash = p.crash;

    if (free_cam) camera.free_fly() else camera.follow(p.x, p.y, p.heading, false);
    render.draw();
    sprites.draw_machines();
    hud.draw();

    render_us = @truncate(cart.micros_since_boot() - t0);
    if (build_options.debug_overlay) draw_overlay();

    frame +%= 1;
    if (cart.is_wasm) present_wasm();
}

/// -Ddebug_overlay=true: "uuuuuus" top-right.
fn draw_overlay() void {
    var buf: [8]u8 = "      us".*;
    put_uint(buf[0..6], @min(render_us, 999_999));
    cart.text(.{
        .str = &buf,
        .x = 160 - 8 * @as(i32, buf.len),
        .y = 9,
        .text_color = .{ .r = 31, .g = 63, .b = 31 },
        .background_color = .{ .r = 0, .g = 0, .b = 0 },
    });
}

/// Right-aligned decimal into `out`, space-padded. `v` must fit.
fn put_uint(out: []u8, v: u32) void {
    var n = v;
    var i = out.len;
    while (i > 0) {
        i -= 1;
        out[i] = @intCast('0' + n % 10);
        n /= 10;
        if (n == 0) break;
    }
}

// Debug exports for the headless harness (wasm only).
comptime {
    if (cart.is_wasm) {
        @export(&debug_frame, .{ .name = "debug_frame" });
        @export(&debug_render_us, .{ .name = "debug_render_us" });
        @export(&debug_pixel_checksum, .{ .name = "debug_pixel_checksum" });
        @export(&debug_cam_x, .{ .name = "debug_cam_x" });
        @export(&debug_cam_y, .{ .name = "debug_cam_y" });
        @export(&debug_cam_yaw, .{ .name = "debug_cam_yaw" });
        @export(&debug_cam_height, .{ .name = "debug_cam_height" });
        @export(&debug_tile_under, .{ .name = "debug_tile_under" });
        @export(&debug_px, .{ .name = "debug_px" });
        @export(&debug_py, .{ .name = "debug_py" });
        @export(&debug_heading, .{ .name = "debug_heading" });
        @export(&debug_speed, .{ .name = "debug_speed" });
        @export(&debug_lap, .{ .name = "debug_lap" });
        @export(&debug_progress, .{ .name = "debug_progress" });
        @export(&debug_phase, .{ .name = "debug_phase" });
        @export(&debug_tick, .{ .name = "debug_tick" });
        @export(&debug_thermal, .{ .name = "debug_thermal" });
        @export(&debug_crashes, .{ .name = "debug_crashes" });
        @export(&debug_best_lap, .{ .name = "debug_best_lap" });
        @export(&debug_set_autopilot, .{ .name = "debug_set_autopilot" });
        @export(&debug_set_freecam, .{ .name = "debug_set_freecam" });
        @export(&debug_rank, .{ .name = "debug_rank" });
        @export(&debug_screen, .{ .name = "debug_screen" });
        @export(&debug_machine_px, .{ .name = "debug_machine_px" });
        @export(&debug_machine_py, .{ .name = "debug_machine_py" });
        @export(&debug_machine_lap, .{ .name = "debug_machine_lap" });
    }
}

fn debug_frame() callconv(.c) u32 {
    return frame;
}
fn debug_render_us() callconv(.c) u32 {
    return render_us;
}
fn debug_cam_x() callconv(.c) u32 {
    return @bitCast(camera.cam.x >> fixed.Q);
}
fn debug_cam_y() callconv(.c) u32 {
    return @bitCast(camera.cam.y >> fixed.Q);
}
fn debug_cam_yaw() callconv(.c) u32 {
    return camera.cam.yaw;
}
fn debug_cam_height() callconv(.c) u32 {
    return @bitCast(camera.cam.height);
}
/// Attribute of the tile under the player.
fn debug_tile_under() callconv(.c) u32 {
    const p = &world.w.machines[world.player];
    return @backingInt(sim.current.attr_at(p.x >> fixed.Q, p.y >> fixed.Q));
}
fn debug_px() callconv(.c) u32 {
    return @bitCast(world.w.machines[world.player].x >> fixed.Q);
}
fn debug_py() callconv(.c) u32 {
    return @bitCast(world.w.machines[world.player].y >> fixed.Q);
}
fn debug_heading() callconv(.c) u32 {
    return world.w.machines[world.player].heading;
}
/// Player speed in 1/100 px per tick.
fn debug_speed() callconv(.c) u32 {
    return @bitCast((sim.speed(&world.w.machines[world.player]) * 100) >> fixed.Q);
}
fn debug_lap() callconv(.c) u32 {
    return world.w.machines[world.player].lap;
}
fn debug_progress() callconv(.c) u32 {
    return world.w.machines[world.player].progress;
}
/// 0 countdown, 1 racing, 2 finished.
fn debug_phase() callconv(.c) u32 {
    return @backingInt(world.w.phase);
}
fn debug_tick() callconv(.c) u32 {
    return world.w.tick;
}
fn debug_thermal() callconv(.c) u32 {
    return @bitCast(@as(i32, world.w.machines[world.player].thermal));
}
fn debug_crashes() callconv(.c) u32 {
    return crashes;
}
/// --call debug_set_autopilot:1 hands the player to the centerline autopilot.
fn debug_set_autopilot(v: u32) callconv(.c) void {
    autopilot = v != 0;
}
/// --call debug_set_freecam:1 switches to the M0 free camera (Left/Right
/// yaw, A forward, B back, Up/Down height); the race keeps running unsteered.
fn debug_set_freecam(v: u32) callconv(.c) void {
    free_cam = v != 0;
}
/// Player rank 1..5 (0 before the first tick).
fn debug_rank() callconv(.c) u32 {
    return world.w.machines[world.player].rank;
}
/// 0 race, 1 results.
fn debug_screen() callconv(.c) u32 {
    return @backingInt(screen);
}
/// Machine i's world position and laps (two-argument exports for --call-at style checks).
fn debug_machine_px(i: u32) callconv(.c) u32 {
    return @bitCast(world.w.machines[i % world.machine_count].x >> fixed.Q);
}
fn debug_machine_py(i: u32) callconv(.c) u32 {
    return @bitCast(world.w.machines[i % world.machine_count].y >> fixed.Q);
}
fn debug_machine_lap(i: u32) callconv(.c) u32 {
    return world.w.machines[i % world.machine_count].lap;
}
fn debug_best_lap() callconv(.c) u32 {
    return world.w.machines[world.player].best_lap;
}
/// Sum of all framebuffer words, for render regression tests.
fn debug_pixel_checksum() callconv(.c) u32 {
    var sum: u32 = 0;
    for (cart.framebuffer) |*column| {
        for (column) |px| sum +%= @as(u16, @bitCast(px));
    }
    return sum;
}

/// Button state. Upstream's platform_wasm.zig exposes `controls` but never
/// fills it from the simulator, which writes its button word (same bit
/// layout as cart.Controls) to linear address 0x04; read that directly on
/// wasm. Hardware gets the OS-maintained cart.controls.
pub fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// Simulator shim (see snouty-bugs CLAUDE.md): upstream's wasm platform never
/// presents, and the web simulator reads a legacy framebuffer at 0x20 with
/// red and blue swapped relative to DisplayColor. Hardware compiles none of this.
fn present_wasm() void {
    const sim_framebuffer: *cart.Framebuffer = @ptrFromInt(0x20);
    for (cart.framebuffer, sim_framebuffer) |*src_column, *dst_column| {
        for (src_column, dst_column) |src, *dst| {
            const c = src.to_color();
            dst.* = .from_color(.{ .r = c.b, .g = c.g, .b = c.r });
        }
    }
}
