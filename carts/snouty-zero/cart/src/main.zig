//! Snouty Zero: an F-Zero style Mode 7 hover racer on a planet-sized AI
//! datacenter. SPEC.md is the design, PLAN.md the milestone contract.
//! M0: the floor renderer with a free camera.
const cart = @import("cart-api");
const build_options = @import("build_options");
const input = @import("input.zig");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const camera = @import("camera.zig");
const render = @import("render.zig");
const track = @import("track.zig");

comptime {
    cart.export_start_code();
}

/// Frames since start(); one frame is one update() at 60 Hz.
var frame: u32 = 0;
/// Microseconds spent in the last frame's render (hardware timer; 0 on wasm).
var render_us: u32 = 0;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    render.set_track(&track.cold_aisle);
    // Start on the start line, looking along the track.
    const s0 = track.cold_aisle.sample(0);
    camera.init(@as(i32, s0.x) << fixed.Q, @as(i32, s0.y) << fixed.Q, s0.tangent);
}

pub fn update() void {
    input.update(read_controls());
    camera.free_fly();

    const t0 = cart.micros_since_boot();
    render.draw();
    render_us = @truncate(cart.micros_since_boot() - t0);
    if (build_options.debug_overlay) draw_overlay();

    frame +%= 1;
    if (cart.is_wasm) present_wasm();
}

/// -Ddebug_overlay=true: "uuuuuus" top-right plus the camera height.
fn draw_overlay() void {
    var buf: [12]u8 = "      us h  ".*;
    put_uint(buf[0..6], @min(render_us, 999_999));
    put_uint(buf[9..12], @intCast(camera.cam.height));
    cart.text(.{
        .str = &buf,
        .x = 160 - 8 * @as(i32, buf.len),
        .y = 0,
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
/// Attribute of the tile under the camera.
fn debug_tile_under() callconv(.c) u32 {
    return @backingInt(track.cold_aisle.attr_at(camera.cam.x >> fixed.Q, camera.cam.y >> fixed.Q));
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
