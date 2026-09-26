//! Snoutenstein 3D: entry point, top-level state machine, wasm shims.
//! SPEC.md is the design, PLAN.md the current milestone, CLAUDE.md the
//! toolchain. M0: title card and a walkable stub view.
const std = @import("std");
const cart = @import("cart-api");
const fixed = @import("fixed.zig");
const state = @import("state.zig");
const levels = @import("levels.zig");
const sim = @import("sim.zig");
const view = @import("render/view.zig");
const hud = @import("render/hud.zig");

comptime {
    cart.export_start_code();
}

pub const Mode = enum(u32) { title = 0, playing = 1, paused = 2 };

var mode: Mode = .title;
var tick_total: u32 = 0;
var game: state.GameState = undefined;
var level: *const levels.Level = &levels.all[0];
var level_index: u8 = 0;
var prev_buttons: state.Buttons = .{};
var render_us: u32 = 0;

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
            if (pressed(b, .a) or pressed(b, .b) or pressed(b, .start)) new_game();
        },
        .playing => {
            if (pressed(b, .start)) {
                mode = .paused;
            } else {
                sim.step(&game, level, b);
            }
        },
        .paused => {
            if (pressed(b, .start)) mode = .playing;
        },
    }

    switch (mode) {
        .title => hud.draw_title(tick_total),
        .playing, .paused => {
            const t0 = cart.micros_since_boot();
            view.draw(&game, level);
            render_us = @intCast(cart.micros_since_boot() - t0);
            hud.draw_debug_bar(&game, render_us);
            if (mode == .paused) cart.text(.{ .str = "PAUSED", .x = 56, .y = 48, .text_color = hud.anti_white });
        },
    }

    if (cart.is_wasm) present_wasm();
}

fn new_game() void {
    level_index = 0;
    level = &levels.all[level_index];
    sim.init(&game, level, level_index, @truncate(cart.micros_since_boot()));
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
