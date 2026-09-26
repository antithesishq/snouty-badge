//! Snouty vs. the Bugs: M2 "Bullet hell". Title card, then a flight
//! against five enemy kinds and their bullets, with bombs, graze, the
//! rewind stock (a hit spends one; the real rewind is M4) and death.
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
const world = @import("world.zig");

comptime {
    cart.export_start_code();
}

pub const State = enum(u32) { title = 0, playing = 1, paused = 2, dying = 3 };

// Meta-state, outside the World (never rewound). Play state is `world.w`.
var state: State = .title;
/// Ticks since boot (drives title blink).
var tick_total: u32 = 0;
/// Rewind stock (replaces lives; SPEC.md 5.1).
var rewinds: u32 = start_rewinds;
var bombs: u32 = start_bombs;
/// Score at which the next extra bomb / extra rewind is granted.
var next_bomb_score: u32 = first_bomb_score;
var next_rewind_score: u32 = first_rewind_score;
/// Ticks left in DYING before the title.
var dying_ticks: u32 = 0;

const start_rewinds: u32 = 3;
const max_rewinds: u32 = 5;
const first_rewind_score: u32 = 10_000;
const rewind_score_step: u32 = 20_000;
const start_bombs: u32 = 2;
const max_bombs: u32 = 3;
const first_bomb_score: u32 = 5_000;
const bomb_score_step: u32 = 5_000;
const dying_len: u32 = 60;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
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
                simulate(.live);
            }
        },
        .paused => {
            if (input.pressed(.start)) state = .playing;
        },
        .dying => {
            simulate_dying();
            dying_ticks -|= 1;
            if (dying_ticks == 0) state = .title;
        },
    }

    switch (state) {
        .title => {
            draw.draw_bg();
            hud.draw_title(tick_total);
        },
        .playing, .dying => draw_scene(),
        .paused => {
            draw_scene();
            hud.draw_pause();
        },
    }

    tick_total +%= 1;
    if (cart.is_wasm) present_wasm();
}

/// A fresh World, except that the background and the input edge detector
/// carry over so the sky scrolls on from the title and the button that
/// started the game is not seen as a new press.
fn new_game() void {
    const w = &world.w;
    const bg = w.bg;
    const in = w.input;
    w.* = .{};
    w.bg = bg;
    w.input = in;
    const t: u32 = @truncate(cart.micros_since_boot());
    rng.seed(if (t == 0) 0x5EED else t);
    rewinds = start_rewinds;
    bombs = start_bombs;
    next_bomb_score = first_bomb_score;
    next_rewind_score = first_rewind_score;
    state = .playing;
}

/// One tick of play, in the PLAN.md update order. `mode` is `.silent` for
/// rewind catch-up ticks (M4), which must not emit sound or light.
fn simulate(mode: world.Mode) void {
    waves.update();
    player.update();
    enemies.update();
    bullets.update();
    bullets.update_enemy_bullets();
    // After everything moved, so the bomb tick ends with no enemy bullets
    // and its invulnerability covers this tick's collisions.
    _ = player.try_bomb(&bombs);
    const hit = collide.run();
    // audio/neopixel effects check `mode` here (M4)
    _ = mode;
    fx.update();
    draw.tick_bg();
    world.w.game_tick +%= 1;
    award_extras();
    if (hit.by != .none) on_hit(hit);
}

/// The ship was touched. `hit.kind` names the bug for M4's message.
fn on_hit(hit: collide.Hit) void {
    if (rewinds > 0) {
        // M4: rewind sequence starts here (bug report for `hit.kind`,
        // reverse playback, resume); M2 only spends the stock.
        _ = hit;
        rewinds -= 1;
        world.w.player.invuln = player.invuln_ticks;
    } else {
        state = .dying;
        dying_ticks = dying_len;
        const c = player.hitbox_center();
        fx.spawn(.big_explosion, c[0], c[1]);
    }
}

/// Extra bomb every 5,000 points (max 3); extra rewind at 10,000 and every
/// 20,000 after (max 5). A threshold crossed at the cap is still consumed.
fn award_extras() void {
    const score = world.w.player.score;
    while (score >= next_bomb_score) {
        bombs = @min(bombs + 1, max_bombs);
        next_bomb_score += bomb_score_step;
    }
    while (score >= next_rewind_score) {
        rewinds = @min(rewinds + 1, max_rewinds);
        next_rewind_score += rewind_score_step;
    }
}

/// A DYING tick: enemies, enemy bullets and the spawner are frozen (so
/// nothing fires); bolts, fx and the background keep running.
fn simulate_dying() void {
    bullets.update();
    fx.update();
    draw.tick_bg();
    world.w.game_tick +%= 1;
}

/// Draw order: bg (or bomb flash), enemies, ship, bolts, enemy bullets,
/// fx, bomb ring, HUD. The ship is hidden while DYING.
fn draw_scene() void {
    fx.draw_bg_or_flash();
    enemies.draw_enemies();
    if (state != .dying) player.draw_ship(world.w.game_tick);
    bullets.draw_bolts(world.w.game_tick);
    bullets.draw_enemy_bullets();
    fx.draw_fx();
    fx.draw_bomb_ring();
    hud.draw_hud(rewinds, bombs);
}

// Debug exports for the headless harness (wasm only).
comptime {
    if (cart.is_wasm) {
        @export(&debug_state, .{ .name = "debug_state" });
        @export(&debug_score, .{ .name = "debug_score" });
        @export(&debug_lives, .{ .name = "debug_lives" });
        @export(&debug_enemies, .{ .name = "debug_enemies" });
        @export(&debug_bolts, .{ .name = "debug_bolts" });
        @export(&debug_world_size, .{ .name = "debug_world_size" });
        @export(&debug_rewinds, .{ .name = "debug_rewinds" });
        @export(&debug_bombs, .{ .name = "debug_bombs" });
        @export(&debug_bullets, .{ .name = "debug_bullets" });
        @export(&debug_grazes, .{ .name = "debug_grazes" });
        @export(&debug_bomb_timer, .{ .name = "debug_bomb_timer" });
    }
}

fn debug_state() callconv(.c) u32 {
    return @backingInt(state);
}
fn debug_score() callconv(.c) u32 {
    return world.w.player.score;
}
/// Kept from M1; the lives are the rewind stock now.
fn debug_lives() callconv(.c) u32 {
    return rewinds;
}
fn debug_enemies() callconv(.c) u32 {
    return enemies.live_count();
}
fn debug_bolts() callconv(.c) u32 {
    return bullets.live_bolts();
}
fn debug_world_size() callconv(.c) u32 {
    return @sizeOf(world.World);
}
fn debug_rewinds() callconv(.c) u32 {
    return rewinds;
}
fn debug_bombs() callconv(.c) u32 {
    return bombs;
}
fn debug_bullets() callconv(.c) u32 {
    return bullets.live_enemy_bullets();
}
fn debug_grazes() callconv(.c) u32 {
    return world.w.player.grazes;
}
fn debug_bomb_timer() callconv(.c) u32 {
    return world.w.player.bomb_timer;
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
