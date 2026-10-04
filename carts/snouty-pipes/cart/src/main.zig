//! Snouty Pipes: a clone of the Windows 3D Pipes screensaver. The camera
//! holds still while pipes grow, so every frame draws only the new pieces
//! into the OS's copy-forward framebuffer. SPEC.md is the design, PLAN.md
//! the current milestone, CLAUDE.md the toolchain.
const std = @import("std");
const cart = @import("cart-api");
const build_options = @import("build_options");
const input = @import("input.zig");
const camera = @import("camera.zig");
const director = @import("director.zig");
const draw = @import("render/draw.zig");
const overlay = @import("render/overlay.zig");
const steer = @import("steer.zig");

comptime {
    cart.export_start_code();
}

/// Pixel sink for the renderer: the cart framebuffer plus the OS dirty rect.
const Screen = struct {
    pub inline fn put(x: u32, y: u32, c: u16) void {
        cart.framebuffer[x][y] = .from_color(@bitCast(c));
    }
    pub fn mark_dirty(r: camera.Rect) void {
        if (r.is_empty()) return;
        cart.mark_dirty_rect(r.x0, r.y0, @as(i32, r.x1) - r.x0, @as(i32, r.y1) - r.y0);
    }
    pub fn fill(c: u16) void {
        const px: cart.Pixel = .from_color(@bitCast(c));
        for (cart.framebuffer) |*col| @memset(col, px);
    }
};
const R = draw.Renderer(Screen);

/// Steer mode's play box outline and floor grid: dim blue greys.
const frame_color: u16 = @bitCast(cart.DisplayColor.rgb(0x405478));
const floor_color: u16 = @bitCast(cart.DisplayColor.rgb(0x1c2638));

var tick: u32 = 0;
var render_us: u32 = 0;
var seed: u32 = 0;
/// Commands run on the last tick (debug_cmds).
var cmds_run: u32 = 0;

/// Timing readout: on at boot in -Ddebug_overlay builds, where Select+B
/// toggles it (plain Select is steer mode); compiled out otherwise.
const debug_build = build_options.debug_overlay;
var debug_on: bool = debug_build;
var last_update_us: u64 = 0;
var fps_x10: u32 = 0;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.copy_forward);
    if (bench_seed != 0) return reseed(bench_seed);
    reseed(if (clock_seeded) cart.rand() ^ clock_mix() else cart.rand());
}

/// badge-bench hook (firmware only, 0 on the badge): `--poke
/// snouty_pipes_seed=N` starts from seed N, the seed the wasm build gets
/// when cart.rand() first returns N, so a steer script recorded headless
/// (tools/steer_bot.mjs) replays the same run on the bench.
var bench_seed: u32 = 0;
comptime {
    if (!cart.is_wasm) @export(&bench_seed, .{ .name = "snouty_pipes_seed" });
}

/// Badge builds only: cart.rand() reads 0 on the RP2350, so the badge mixes
/// in the microsecond clock (same as snouty-maze). Wasm keeps cart.rand()
/// alone so preview.mjs --seed reproduces runs.
const clock_seeded = !cart.is_wasm;

fn clock_mix() u32 {
    const t = cart.micros_since_boot();
    var h: u32 = @as(u32, @truncate(t)) ^ @as(u32, @truncate(t >> 32)) ^ 0x9e3779b9;
    h ^= h >> 16;
    h *%= 0x85ebca6b;
    h ^= h >> 13;
    h *%= 0xc2b2ae35;
    h ^= h >> 16;
    return h;
}

fn reseed(s: u32) void {
    seed = s;
    director.reset(s);
}

pub fn update() void {
    input.update(read_controls());
    // Newer firmware opens its settings box on Start+Select over the running
    // cart: react to neither while both are held.
    const chord = input.held(.start) and input.held(.select);
    // -Ddebug_overlay builds: Select with B held toggles the readout instead
    // of steer mode.
    const debug_toggle = debug_build and !chord and input.held(.b) and input.pressed(.select);
    const held: director.Input = if (chord) .{} else .{
        .a = input.held(.a),
        .b = input.held(.b),
        .start = input.held(.start),
        .up = input.held(.up),
        .down = input.held(.down),
        .left = input.held(.left),
        .right = input.held(.right),
    };
    const pressed: director.Input = if (chord) .{} else .{
        .a = input.pressed(.a),
        .b = input.pressed(.b),
        .start = input.pressed(.start),
        .select = input.pressed(.select) and !debug_toggle,
        .up = input.pressed(.up),
        .down = input.pressed(.down),
        .left = input.pressed(.left),
        .right = input.pressed(.right),
    };
    director.step(held, pressed);
    if (debug_toggle) debug_on = !debug_on;

    // Overlays sit on the persistent picture: put back what they covered,
    // draw this tick's pieces, then save and draw the overlays again.
    overlay.restore();
    draw.set_steer(director.in_run);
    const t0 = cart.micros_since_boot();
    for (director.commands()) |c| switch (c) {
        .cell => |cell| R.draw_cell(&director.cam, cell.p, cell.s0, cell.s1),
        .clear_all => {
            Screen.fill(0);
            R.clear_all();
        },
        .clear_blocks => |b| R.clear_blocks(b.from, b.to),
        .frame => |f| R.box_edges(&director.cam, f.lo, f.hi, frame_color, floor_color),
    };
    cmds_run = @intCast(director.commands().len);
    director.commands_done();
    const t1 = cart.micros_since_boot();
    render_us = @truncate(t1 - t0);
    if (t0 > last_update_us) fps_x10 = @intCast(@min(9999, 10_000_000 / (t0 - last_update_us)));
    last_update_us = t0;

    const strip: overlay.StripKind = if (director.nametag) .nametag else if (director.name_strip()) .title else .none;
    overlay.draw(strip, director.steer_overlay(), if (debug_build and debug_on) .{
        .render_us = render_us,
        .fps_x10 = fps_x10,
        .filled = director.filled(),
        .alive = director.alive(),
        .scene = director.scene,
        .speed = @as(u32, 1) << director.speed,
    } else null);

    tick +%= 1;
    if (cart.is_wasm) present_wasm();
}

// Debug exports for the headless harness (wasm only).
comptime {
    if (cart.is_wasm) {
        @export(&debug_tick, .{ .name = "debug_tick" });
        @export(&debug_state, .{ .name = "debug_state" });
        @export(&debug_render_us, .{ .name = "debug_render_us" });
        @export(&debug_pixel_checksum, .{ .name = "debug_pixel_checksum" });
        @export(&debug_set_seed, .{ .name = "debug_set_seed" });
        @export(&debug_scene, .{ .name = "debug_scene" });
        @export(&debug_filled, .{ .name = "debug_filled" });
        @export(&debug_alive, .{ .name = "debug_alive" });
        @export(&debug_pipes, .{ .name = "debug_pipes" });
        @export(&debug_view, .{ .name = "debug_view" });
        @export(&debug_teapots, .{ .name = "debug_teapots" });
        @export(&debug_force_teapot, .{ .name = "debug_force_teapot" });
        @export(&debug_name_strip, .{ .name = "debug_name_strip" });
        @export(&debug_cmds, .{ .name = "debug_cmds" });
        @export(&debug_orbit, .{ .name = "debug_orbit" });
        @export(&debug_speed, .{ .name = "debug_speed" });
        @export(&debug_joint_style, .{ .name = "debug_joint_style" });
        @export(&debug_paused, .{ .name = "debug_paused" });
        @export(&debug_history, .{ .name = "debug_history" });
        @export(&debug_nametag, .{ .name = "debug_nametag" });
        @export(&debug_iris_width, .{ .name = "debug_iris_width" });
        @export(&debug_steer, .{ .name = "debug_steer" });
        @export(&debug_score, .{ .name = "debug_score" });
        @export(&debug_best, .{ .name = "debug_best" });
        @export(&debug_rewinds_left, .{ .name = "debug_rewinds_left" });
        @export(&debug_crashes, .{ .name = "debug_crashes" });
        @export(&debug_head_x, .{ .name = "debug_head_x" });
        @export(&debug_head_y, .{ .name = "debug_head_y" });
        @export(&debug_head_z, .{ .name = "debug_head_z" });
        @export(&debug_steer_map, .{ .name = "debug_steer_map" });
        @export(&debug_heading, .{ .name = "debug_heading" });
        @export(&debug_occupied, .{ .name = "debug_occupied" });
        @export(&debug_steer_rate, .{ .name = "debug_steer_rate" });
    }
}

fn debug_tick() callconv(.c) u32 {
    return tick;
}
fn debug_state() callconv(.c) u32 {
    return @backingInt(director.state);
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
/// Reseeds and restarts from a cleared screen.
fn debug_set_seed(s: u32) callconv(.c) void {
    reseed(s);
}
/// Scenes started since the last reset (1 after boot).
fn debug_scene() callconv(.c) u32 {
    return director.scene;
}
/// Cells filled this scene.
fn debug_filled() callconv(.c) u32 {
    return director.filled();
}
/// Pipes alive (growing, or drawing their end cell).
fn debug_alive() callconv(.c) u32 {
    return director.alive();
}
/// Pipes started this scene.
fn debug_pipes() callconv(.c) u32 {
    return director.pipes_started;
}
/// View index of the current scene (camera.views).
fn debug_view() callconv(.c) u32 {
    return director.view_index;
}
/// Teapots drawn since boot.
fn debug_teapots() callconv(.c) u32 {
    return director.teapots;
}
/// The next turn of any pipe is a teapot, whatever the joint style and the
/// one-per-scene cap. Returns 1.
fn debug_force_teapot() callconv(.c) u32 {
    director.force_teapot = true;
    return 1;
}
/// 1 while the boot name strip is on screen.
fn debug_name_strip() callconv(.c) u32 {
    return @intFromBool(director.name_strip());
}
/// Commands run on the last tick.
fn debug_cmds() callconv(.c) u32 {
    return cmds_run;
}
/// Camera orbit in eighths of a turn (0..7, Left/Right).
fn debug_orbit() callconv(.c) u32 {
    return @intCast(director.orbit);
}
/// Growth speed: 1, 2, 4 or 8 (Up/Down).
fn debug_speed() callconv(.c) u32 {
    return @as(u32, 1) << director.speed;
}
/// Joint style: 0 mixed, 1 elbow, 2 ball (no longer on a button: always 0).
fn debug_joint_style() callconv(.c) u32 {
    return @backingInt(director.joint_style);
}
/// 1 while paused (Start).
fn debug_paused() callconv(.c) u32 {
    return @intFromBool(director.paused);
}
/// Cells of the current scene in the history ring.
fn debug_history() callconv(.c) u32 {
    return director.history_count();
}

/// 1 while the nametag strip is up (B in the screensaver).
fn debug_nametag() callconv(.c) u32 {
    return @intFromBool(director.nametag);
}
/// Width the strip's Iris mark was last drawn at: 24 at rest, less while
/// it flips like a coin.
fn debug_iris_width() callconv(.c) u32 {
    return overlay.iris_width;
}
/// 1 in steer mode's states (4 steer, 5 rewind, 6 game over).
fn debug_steer() callconv(.c) u32 {
    return @intFromBool(switch (director.state) {
        .steer, .rewind, .game_over => true,
        else => false,
    });
}
/// Player cells this steer run.
fn debug_score() callconv(.c) u32 {
    return director.score();
}
/// Best steer score this session.
fn debug_best() callconv(.c) u32 {
    return director.best;
}
/// Rewinds left this run (1 at the start, 0 after the first crash).
fn debug_rewinds_left() callconv(.c) u32 {
    return director.rewinds_left;
}
/// Crashes this run (2 = game over).
fn debug_crashes() callconv(.c) u32 {
    return director.crashes;
}
/// The player's head cell (grid coordinates).
fn debug_head_x() callconv(.c) u32 {
    return director.head_cell()[0];
}
fn debug_head_y() callconv(.c) u32 {
    return director.head_cell()[1];
}
fn debug_head_z() callconv(.c) u32 {
    return director.head_cell()[2];
}
/// The control mapping, 3 bits per control (up, down, left, right, A into,
/// B out), each a grid.Dir (0 +x, 1 -x, 2 +y, 3 -y, 4 +z, 5 -z).
fn debug_steer_map() callconv(.c) u32 {
    return steer.pack(director.map);
}
/// The player's direction of travel (a grid.Dir).
fn debug_heading() callconv(.c) u32 {
    return @backingInt(director.heading());
}
/// 1 if grid cell (x, y, z) is occupied, walls and outside included.
fn debug_occupied(x: u32, y: u32, z: u32) callconv(.c) u32 {
    return @intFromBool(director.occupied(x, y, z));
}
/// The player's speed in progress units per tick (240 per cell).
fn debug_steer_rate() callconv(.c) u32 {
    return director.player_rate();
}

/// Button state. Upstream's platform_wasm.zig never fills `controls` from
/// the simulator, which writes its button word to linear address 0x04.
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
