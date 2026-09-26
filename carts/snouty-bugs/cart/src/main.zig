//! Snouty vs. the Bugs: M1 "Flying". Title card, then a playable flight
//! with parallax, the zapper, gnat strings, collisions, score and lives.
//! See SPEC.md for the game, PLAN.md for the M1 contract and CLAUDE.md for
//! the toolchain.
const cart = @import("cart-api");
const draw = @import("draw.zig");
const input = @import("input.zig");
const rng = @import("rng.zig");
const player = @import("player.zig");
const bullets = @import("bullets.zig");
const enemies = @import("enemies.zig");
const waves = @import("waves.zig");
const collide = @import("collide.zig");
const fx = @import("fx.zig");
const hud = @import("hud.zig");

comptime {
    cart.export_start_code();
}

pub const State = enum(u32) { title = 0, playing = 1, paused = 2 };

var state: State = .title;
/// Ticks since boot (drives title blink).
var tick_total: u32 = 0;
/// Ticks of simulated play (frozen while paused; drives animations).
var game_tick: u32 = 0;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    draw.init_bg();
}

pub fn update() void {
    input.update(read_controls());

    switch (state) {
        .title => {
            if (input.pressed(.a) or input.pressed(.b) or input.pressed(.start)) {
                new_game();
            } else {
                draw.tick_bg();
            }
        },
        .playing => {
            if (input.pressed(.start)) {
                state = .paused;
            } else {
                simulate();
            }
        },
        .paused => {
            if (input.pressed(.start)) state = .playing;
        },
    }

    switch (state) {
        .title => {
            draw.draw_bg();
            hud.draw_title(tick_total);
        },
        .playing => draw_scene(),
        .paused => {
            draw_scene();
            hud.draw_pause();
        },
    }

    tick_total +%= 1;
    if (cart.is_wasm) present_wasm();
}

fn new_game() void {
    const t: u32 = @truncate(cart.micros_since_boot());
    rng.seed(if (t == 0) 0x5EED else t);
    player.reset();
    bullets.reset();
    enemies.reset();
    waves.reset();
    fx.reset();
    game_tick = 0;
    state = .playing;
}

/// One tick of play, in the PLAN.md update order.
fn simulate() void {
    waves.update();
    player.update();
    enemies.update();
    bullets.update();
    const dead = collide.run();
    fx.update();
    draw.tick_bg();
    game_tick +%= 1;
    if (dead) state = .title;
}

fn draw_scene() void {
    draw.draw_bg();
    enemies.draw_enemies();
    player.draw_ship(game_tick);
    bullets.draw_bolts(game_tick);
    fx.draw_fx();
    hud.draw_hud();
}

// Debug exports for the headless harness (wasm only).
comptime {
    if (cart.is_wasm) {
        @export(&debug_state, .{ .name = "debug_state" });
        @export(&debug_score, .{ .name = "debug_score" });
        @export(&debug_lives, .{ .name = "debug_lives" });
        @export(&debug_enemies, .{ .name = "debug_enemies" });
        @export(&debug_bolts, .{ .name = "debug_bolts" });
    }
}

fn debug_state() callconv(.c) u32 {
    return @backingInt(state);
}
fn debug_score() callconv(.c) u32 {
    return player.score;
}
fn debug_lives() callconv(.c) u32 {
    return player.lives;
}
fn debug_enemies() callconv(.c) u32 {
    return enemies.live_count();
}
fn debug_bolts() callconv(.c) u32 {
    return bullets.live_bolts();
}

/// Button state. Upstream's platform_wasm.zig exposes `controls` but never
/// fills it from the simulator, which writes its button word (same bit
/// layout as cart.Controls) to linear address 0x04; read that directly on
/// wasm. Hardware gets the OS-maintained cart.controls.
pub fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// Simulator shim, copied from snouty-badge (see its CLAUDE.md for the full
/// story): upstream's wasm platform never presents, and the web simulator
/// reads a legacy framebuffer at 0x20 with red and blue swapped relative to
/// DisplayColor. Hardware builds compile none of this.
const sim_swap_rb = true;

fn present_wasm() void {
    const sim_framebuffer: *cart.Framebuffer = @ptrFromInt(0x20);
    if (sim_swap_rb) {
        for (cart.framebuffer, sim_framebuffer) |*src_column, *dst_column| {
            for (src_column, dst_column) |src, *dst| {
                const c = src.to_color();
                dst.* = .from_color(.{ .r = c.b, .g = c.g, .b = c.r });
            }
        }
    } else {
        sim_framebuffer.* = cart.framebuffer.*;
    }
}
