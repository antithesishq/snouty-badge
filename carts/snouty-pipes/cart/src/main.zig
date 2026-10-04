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

var tick: u32 = 0;
var render_us: u32 = 0;
var seed: u32 = 0;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.copy_forward);
    reseed(if (clock_seeded) cart.rand() ^ clock_mix() else cart.rand());
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
        .up = input.pressed(.up),
        .down = input.pressed(.down),
        .left = input.pressed(.left),
        .right = input.pressed(.right),
    };
    director.step(held, pressed);

    const t0 = cart.micros_since_boot();
    for (director.commands()) |c| switch (c) {
        .cell => |cell| R.draw_cell(&director.cam, cell.p, cell.s0, cell.s1),
        .clear_all => {
            Screen.fill(0);
            R.clear_all();
        },
        .clear_blocks => |b| R.clear_blocks(b.from, b.to),
    };
    director.commands_done();
    render_us = @truncate(cart.micros_since_boot() - t0);

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
    }
}

fn debug_tick() callconv(.c) u32 {
    return tick;
}
fn debug_state() callconv(.c) u32 {
    return @intFromEnum(director.state);
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
