//! Snouty Cycles: a top-down light-cycle arena (Tron). You ride a cycle
//! that leaves a wall; so do the programs. The screen is a function of the
//! grid, drawn incrementally into the OS's copy-forward framebuffer.
//! SPEC.md is the design, PLAN.md the current milestone, CLAUDE.md the
//! module map and interfaces.
const std = @import("std");
const cart = @import("cart-api");
const build_options = @import("build_options");
const sim = @import("sim.zig");
const game = @import("game.zig");
const render = @import("render.zig");

comptime {
    cart.export_start_code();
}

/// Pixel sink for the renderer: the cart framebuffer plus the OS dirty rect.
const Screen = struct {
    pub inline fn put(x: u32, y: u32, c: u16) void {
        cart.framebuffer[x][y] = .from_color(@bitCast(c));
    }
    pub fn mark_dirty(r: render.Rect) void {
        if (r.is_empty()) return;
        cart.mark_dirty_rect(r.x0, r.y0, @as(i32, r.x1) - r.x0, @as(i32, r.y1) - r.y0);
    }
};
const R = render.Renderer(Screen);

/// 38 KB of World inside: a static, never on the stack.
var g: game.Game = undefined;
var renderer: R = .{};

var tick: u32 = 0;
var render_us: u32 = 0;
var seed: u32 = 0;
var autopilot: u8 = 0;

/// -Ddebug_overlay builds show the render time in the HUD.
const debug_build = build_options.debug_overlay;

var prev: game.Buttons = .{};

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.copy_forward);
    autopilot = @intCast(@min(bench_autopilot, 2));
    if (bench_seed != 0) return reseed(bench_seed);
    reseed(if (clock_seeded) cart.rand() ^ clock_mix() else cart.rand());
}

/// badge-bench hooks (firmware only, 0 on the badge): `--poke
/// snouty_cycles_seed=N` starts from seed N (the seed the wasm build gets
/// when cart.rand() first returns N), `--poke snouty_cycles_autopilot=2`
/// lets T1 drive the player, with slips (badge-bench/carts/snouty-cycles.toml).
var bench_seed: u32 = 0;
var bench_autopilot: u32 = 0;
comptime {
    if (!cart.is_wasm) {
        @export(&bench_seed, .{ .name = "snouty_cycles_seed" });
        @export(&bench_autopilot, .{ .name = "snouty_cycles_autopilot" });
    }
}

/// Badge builds only: cart.rand() reads 0 on the RP2350, so the badge mixes
/// in the microsecond clock (as snouty-maze and snouty-pipes do). Wasm keeps
/// cart.rand() alone so preview.mjs --seed reproduces runs.
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
    g.init(s);
    g.autopilot = autopilot;
    renderer.invalidate();
}

fn buttons(c: cart.Controls) game.Buttons {
    return .{
        .up = c.up,
        .right = c.right,
        .down = c.down,
        .left = c.left,
        .a = c.a,
        .b = c.b,
        .start = c.start,
        .select = c.select,
    };
}

pub fn update() void {
    const held = buttons(read_controls());
    const pressed: game.Buttons = @bitCast(@as(u8, @bitCast(held)) & ~@as(u8, @bitCast(prev)));
    prev = held;
    g.update(held, pressed);

    const t0 = cart.micros_since_boot();
    if (g.repaint) {
        renderer.invalidate();
        g.repaint = false;
    }
    var v = g.view();
    if (debug_build) {
        var buf: [20]u8 = undefined;
        const n = game.decimal(&buf, render_us, 4);
        @memcpy(buf[n..][0..2], "us");
        v.hud.right = .of(buf[0 .. n + 2], 1, game.colors.warn);
    }
    renderer.frame(&g.world, v);
    render_us = @truncate(cart.micros_since_boot() - t0);

    tick +%= 1;
    if (cart.is_wasm) present_wasm();
}

// Debug exports for the headless harness (wasm only). docs/RUNNING.md
// section 6 lists them; tools/check.sh depends on their names.
comptime {
    if (cart.is_wasm) {
        @export(&debug_tick, .{ .name = "debug_tick" });
        @export(&debug_state, .{ .name = "debug_state" });
        @export(&debug_round, .{ .name = "debug_round" });
        @export(&debug_alive_mask, .{ .name = "debug_alive_mask" });
        @export(&debug_player_x, .{ .name = "debug_player_x" });
        @export(&debug_player_y, .{ .name = "debug_player_y" });
        @export(&debug_player_dir, .{ .name = "debug_player_dir" });
        @export(&debug_render_us, .{ .name = "debug_render_us" });
        @export(&debug_pixel_checksum, .{ .name = "debug_pixel_checksum" });
        @export(&debug_set_seed, .{ .name = "debug_set_seed" });
        @export(&debug_autopilot, .{ .name = "debug_autopilot" });
        @export(&debug_score, .{ .name = "debug_score" });
        @export(&debug_wins, .{ .name = "debug_wins" });
        @export(&debug_losses, .{ .name = "debug_losses" });
        @export(&debug_world_tick, .{ .name = "debug_world_tick" });
        @export(&debug_world_hash, .{ .name = "debug_world_hash" });
    }
}

fn debug_tick() callconv(.c) u32 {
    return tick;
}
/// game.State: 0 title, 1 countdown, 2 play, 3 round over, 4 paused.
fn debug_state() callconv(.c) u32 {
    return @backingInt(g.state);
}
/// Round of the current match (0 on the title).
fn debug_round() callconv(.c) u32 {
    return g.round;
}
/// Bit i set while cycle i is alive (cycle 0 is the player).
fn debug_alive_mask() callconv(.c) u32 {
    return g.world.alive_mask();
}
fn debug_player_x() callconv(.c) u32 {
    return g.world.cycles[0].x;
}
fn debug_player_y() callconv(.c) u32 {
    return g.world.cycles[0].y;
}
/// sim.Dir: 0 up, 1 right, 2 down, 3 left.
fn debug_player_dir() callconv(.c) u32 {
    return @backingInt(g.world.cycles[0].dir);
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
/// Reseeds and restarts on the title.
fn debug_set_seed(s: u32) callconv(.c) void {
    reseed(s);
}
/// 1: T1 drives the player, 2: T1 with random slips (rounds end sooner);
/// 0 off. Kept through reseeds. Returns the new value.
fn debug_autopilot(level: u32) callconv(.c) u32 {
    autopilot = @intCast(@min(level, 2));
    g.autopilot = autopilot;
    return autopilot;
}
fn debug_score() callconv(.c) u32 {
    return g.score;
}
fn debug_wins() callconv(.c) u32 {
    return g.wins;
}
fn debug_losses() callconv(.c) u32 {
    return g.losses;
}
/// Ticks into the current World (round or attract round).
fn debug_world_tick() callconv(.c) u32 {
    return g.world.tick;
}
/// sim.World.hash of the current World (determinism checks).
fn debug_world_hash() callconv(.c) u32 {
    return g.world.hash();
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
