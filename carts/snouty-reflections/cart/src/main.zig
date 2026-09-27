//! Snouty on the Water: real-time ray-traced sunset lake (trace.zig). See
//! SPEC.md for the design, PLAN.md for the M1 contract, CLAUDE.md for the
//! toolchain.
const cart = @import("cart-api");
const input = @import("input.zig");
const math = @import("math.zig");
const dither = @import("dither.zig");
const overlay = @import("overlay.zig");
const trace = @import("trace.zig");
const build_options = @import("build_options");

comptime {
    cart.export_start_code();
}

/// Frames since start().
var frame: u32 = 0;
/// Microseconds spent in the last render (hardware timer; 0 on wasm).
var render_us: u32 = 0;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 20.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
}

pub fn update() void {
    input.update(read_controls());

    if (input.pressed(.b)) dither.next_mode();

    const t0 = cart.micros_since_boot();
    dither.begin_frame(frame);
    trace.render_frame(frame);
    render_us = @truncate(cart.micros_since_boot() - t0);
    if (build_options.debug_overlay) overlay.draw(render_us, frame);

    frame +%= 1;
    if (cart.is_wasm) present_wasm();
}

// Debug exports for the headless harness (wasm only).
comptime {
    if (cart.is_wasm) {
        @export(&debug_frame, .{ .name = "debug_frame" });
        @export(&debug_render_us, .{ .name = "debug_render_us" });
        @export(&debug_pixel_checksum, .{ .name = "debug_pixel_checksum" });
        @export(&debug_dither_mode, .{ .name = "debug_dither_mode" });
    }
}

fn debug_frame() callconv(.c) u32 {
    return frame;
}
fn debug_render_us() callconv(.c) u32 {
    return render_us;
}
fn debug_dither_mode() callconv(.c) u32 {
    return @backingInt(dither.mode);
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

/// Simulator shim, copied from snouty-bugs (see its CLAUDE.md for the full
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
