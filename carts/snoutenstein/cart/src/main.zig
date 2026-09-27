//! Snoutenstein 3D: entry point, top-level state machine, wasm shims.
//! SPEC.md is the design, PLAN.md the current milestone, CLAUDE.md the
//! toolchain. Modes: title -> playing -> (dead: time frozen, hold B) /
//! intermission -> next level -> victory. Rewind wiring is M4.
const std = @import("std");
const cart = @import("cart-api");
const fixed = @import("fixed.zig");
const state = @import("state.zig");
const levels = @import("levels.zig");
const sim = @import("sim.zig");
const view = @import("render/view.zig");
const sprites = @import("render/sprites.zig");
const weapon = @import("render/weapon.zig");
const hud = @import("render/hud.zig");
const blit = @import("render/blit.zig");

comptime {
    cart.export_start_code();
}

pub const Mode = enum(u32) { title = 0, playing = 1, paused = 2, intermission = 3, victory = 4, dead = 5 };

// Level indices come from levels.zig once the campaign levels land (M3
// track C); until then everything maps onto the levels that exist.
const campaign_len: u8 = if (@hasDecl(levels, "campaign_len")) levels.campaign_len else 1;
const test_index: u8 = if (@hasDecl(levels, "test_index")) levels.test_index else 0;
const e1m1_index: u8 = if (@hasDecl(levels, "e1m1_index")) levels.e1m1_index else 1;
/// Death freeze placeholder (M3): holding B this long restarts the level.
/// M4 replaces it with the real rewind (SPEC.md 9.1).
const dead_hold: u32 = 60;

/// Intermission card: skippable with A after `card_min`, auto-advances at `card_max`.
const card_min: u32 = 60;
const card_max: u32 = 300;
const victory_max: u32 = 600;
/// M1 gate readout stays on screen until Adrian has photographed it.
const show_render_us = true;

var mode: Mode = .title;
var tick_total: u32 = 0;
var card_ticks: u32 = 0;
var game: state.GameState = undefined;
var level: *const levels.Level = &levels.all[0];
var level_index: u8 = 0;
var prev_buttons: state.Buttons = .{};
var render_us: u32 = 0;
var held_b: u32 = 0;
var sound_on: bool = false;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    view.init();
}

pub fn update() void {
    const b: state.Buttons = @bitCast(@as(u16, @bitCast(read_controls())));
    defer prev_buttons = b;
    tick_total += 1;

    switch (mode) {
        .title => {
            // A: campaign. B: the imported E1M1. Start: the test level (the
            // scripted runs use it). Select: sound and LEDs (SPEC.md section 3).
            if (pressed(b, .a)) new_game(0);
            if (pressed(b, .b)) new_game(e1m1_index);
            if (pressed(b, .start)) new_game(test_index);
            if (pressed(b, .select)) sound_on = !sound_on;
        },
        .playing => {
            if (pressed(b, .start)) {
                mode = .paused;
            } else {
                sim.step(&game, level, b);
                hud.tick(&game);
                if (game.player.hp <= 0) {
                    mode = .dead;
                    held_b = 0;
                } else if (game.finished) {
                    mode = .intermission;
                    card_ticks = 0;
                }
            }
        },
        .dead => {
            // Time is frozen; only B does anything.
            held_b = if (b.b) held_b + 1 else 0;
            if (held_b >= dead_hold) new_game(level_index);
        },
        .paused => {
            if (pressed(b, .start)) mode = .playing;
        },
        .intermission => {
            card_ticks += 1;
            if (card_ticks >= card_max or (card_ticks >= card_min and (pressed(b, .a) or pressed(b, .start)))) {
                if (next_level(level_index)) |next| {
                    new_game(next);
                } else {
                    mode = .victory;
                    card_ticks = 0;
                }
            }
        },
        .victory => {
            card_ticks += 1;
            if (card_ticks >= victory_max or (card_ticks >= card_min and (pressed(b, .a) or pressed(b, .start)))) mode = .title;
        },
    }

    switch (mode) {
        .title => hud.draw_title(tick_total, sound_on),
        .playing, .paused, .dead => {
            const moving = mode == .playing and (b.up or b.down);
            const t0 = cart.micros_since_boot();
            view.shade_override = if (mode == .dead or game.hurt > 0) 5 else null;
            view.draw(&game, level);
            weapon.draw(&game, moving);
            hud.draw_bar(&game);
            render_us = @intCast(cart.micros_since_boot() - t0);
            if (show_render_us) hud.draw_render_us(render_us);
            if (mode == .paused) hud.draw_pause();
            if (mode == .dead) hud.draw_dead(held_b, dead_hold);
        },
        .intermission => hud.draw_intermission(&game, level.name, @intCast(level.enemies.len), card_ticks),
        .victory => hud.draw_victory(&game, card_ticks),
    }

    if (cart.is_wasm) present_wasm();
}

/// The level after `i`: through the campaign, then victory; the test level
/// hands over to E1M1 so the scripted exit run exercises the transition.
fn next_level(i: u8) ?u8 {
    if (i + 1 < campaign_len) return i + 1;
    if (i == test_index and e1m1_index != test_index) return e1m1_index;
    return null;
}

fn new_game(index: u8) void {
    level_index = index;
    level = &levels.all[level_index];
    sim.init(&game, level, level_index, @truncate(cart.micros_since_boot()));
    hud.tick(&game);
    mode = .playing;
}

const Button = enum { start, select, a, b, up, down, left, right };
fn pressed(b: state.Buttons, comptime btn: Button) bool {
    return @field(b, @tagName(btn)) and !@field(prev_buttons, @tagName(btn));
}

// Debug exports for the headless harness (wasm only).
comptime {
    if (cart.is_wasm) {
        @export(&debug_mode, .{ .name = "debug_mode" });
        @export(&debug_tick, .{ .name = "debug_tick" });
        @export(&debug_px, .{ .name = "debug_px" });
        @export(&debug_py, .{ .name = "debug_py" });
        @export(&debug_angle, .{ .name = "debug_angle" });
        @export(&debug_render_us, .{ .name = "debug_render_us" });
        @export(&debug_state_size, .{ .name = "debug_state_size" });
        @export(&debug_hp, .{ .name = "debug_hp" });
        @export(&debug_kills, .{ .name = "debug_kills" });
        @export(&debug_weapon, .{ .name = "debug_weapon" });
        @export(&debug_ammo, .{ .name = "debug_ammo" });
        @export(&debug_level, .{ .name = "debug_level" });
        @export(&debug_sprites, .{ .name = "debug_sprites" });
        @export(&debug_state_hash, .{ .name = "debug_state_hash" });
        @export(&debug_nibble_ok, .{ .name = "debug_nibble_ok" });
        @export(&debug_frozen, .{ .name = "debug_frozen" });
        @export(&debug_projectiles, .{ .name = "debug_projectiles" });
    }
}
fn debug_mode() callconv(.c) u32 {
    return @backingInt(mode);
}
fn debug_tick() callconv(.c) u32 {
    return game.tick;
}
/// Player x in 16.16 fixed point (cells).
fn debug_px() callconv(.c) u32 {
    return @bitCast(game.player.x);
}
fn debug_py() callconv(.c) u32 {
    return @bitCast(game.player.y);
}
fn debug_angle() callconv(.c) u32 {
    return game.player.angle;
}
fn debug_render_us() callconv(.c) u32 {
    return render_us;
}
fn debug_state_size() callconv(.c) u32 {
    return @sizeOf(state.GameState);
}
fn debug_hp() callconv(.c) u32 {
    return @bitCast(@as(i32, game.player.hp));
}
fn debug_kills() callconv(.c) u32 {
    return game.kills;
}
fn debug_weapon() callconv(.c) u32 {
    return @backingInt(game.player.weapon);
}
/// Ammo of the current weapon (swatter: 0).
fn debug_ammo() callconv(.c) u32 {
    return switch (game.player.weapon) {
        .swatter => 0,
        .zapper => game.player.ammo_zapper,
        .spray => game.player.ammo_spray,
    };
}
fn debug_level() callconv(.c) u32 {
    return level_index;
}
fn debug_sprites() callconv(.c) u32 {
    return sprites.drawn;
}
fn debug_state_hash() callconv(.c) u32 {
    return sim.hash(&game);
}
fn debug_frozen() callconv(.c) u32 {
    return game.player.frozen;
}
/// Live projectiles.
fn debug_projectiles() callconv(.c) u32 {
    var n: u32 = 0;
    for (game.projectiles) |pr| n += @intFromBool(pr.kind != 0);
    return n;
}
/// 1 when the sprite/blit nibble reads agree with PackedIntSlice.get.
fn debug_nibble_ok() callconv(.c) u32 {
    return @intFromBool(blit.nibble_order_ok());
}

/// Button state. Upstream's platform_wasm.zig exposes `controls` but never
/// fills it from the simulator, which writes its button word (same bit
/// layout as cart.Controls) to linear address 0x04; read that directly on
/// wasm. Hardware gets the OS-maintained cart.controls.
pub fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// Simulator shim (see snouty-badge/CLAUDE.md): upstream's wasm platform
/// never presents, and the web simulator reads a legacy framebuffer at
/// 0x20 with red and blue swapped relative to DisplayColor.
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
