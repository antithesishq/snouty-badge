//! Siwoo: a name badge cart for Siwoo Yoon's Supabase Select badge (a
//! Pimoroni Tufty 2350 running the Snouty Tufty OS; it runs on the SYCL
//! Badge V2 too). Demosnout's floating Snouty head tumbles in space over
//! the starfield, and "SIWOO YOON" sits under it in chrome capitals that
//! drop in, wave, shine, hop, spin and sparkle. See SPEC.md.
//!
//! update(): input, then the head with its background, then the name over
//! it and a button toast, and the clock advances one frame. Runs forever;
//! nothing to win. Buttons (the Tufty's five map 1:1, C = Select):
//!   A       spin the letters, flick the tongue
//!   B       next colours, and keep them (a toast names them)
//!   UP      colours change on their own again (the default)
//!   DOWN    the letters hop
//!   Select  a shine sweeps across
//! Nothing reacts while Start and Select are held together (the SYCL OS's
//! exit chord).
const cart = @import("cart-api");
const input = @import("input.zig");
const head = @import("head.zig");
const name = @import("name.zig");
const text = @import("text.zig");

comptime {
    cart.export_start_code();
}

/// Frames since start(), 60 a second: the head's and the name's clock.
var frame: u32 = 0;
var render_us: u32 = 0;
/// The toast: what the last B or UP did, for toast_frames.
var toast: []const u8 = "";
var toast_left: u32 = 0;
const toast_frames = 90;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    head.init();
    head.enter();
    name.init();
    name.enter();
}

pub fn update() void {
    input.update(read_controls());
    if (input.held(.start) and input.held(.select)) {
        // Start+Select is the OS's exit chord: react to neither button.
    } else {
        if (input.pressed(.a)) {
            name.flip(frame, null);
            head.flick(frame);
        }
        if (input.pressed(.b)) {
            name.pick_theme(frame);
            show_toast(name.themes[name.pending_theme()].name);
        }
        if (input.pressed(.up)) {
            name.auto();
            show_toast("AUTO COLORS");
        }
        if (input.pressed(.down)) name.hop(frame);
        if (input.pressed(.select)) name.shine(frame);
    }

    const fb = cart.framebuffer;
    const t0 = cart.micros_since_boot();
    head.render(frame, fb, name.glow(frame));
    name.render(frame, fb);
    if (toast_left > 0) {
        toast_left -= 1;
        text.toast(toast, toast_left);
    }
    render_us = @truncate(cart.micros_since_boot() - t0);
    frame +%= 1;

    if (cart.is_wasm) present_wasm();
}

fn show_toast(str: []const u8) void {
    if (frame < name.show_at) return;
    toast = str;
    toast_left = toast_frames;
}

// Debug exports for the headless harness (wasm only).
comptime {
    if (cart.is_wasm) {
        @export(&debug_frame, .{ .name = "debug_frame" });
        @export(&debug_theme, .{ .name = "debug_theme" });
        @export(&debug_pixel_checksum, .{ .name = "debug_pixel_checksum" });
        @export(&debug_render_us, .{ .name = "debug_render_us" });
    }
}

fn debug_frame() callconv(.c) u32 {
    return frame;
}
fn debug_theme() callconv(.c) u32 {
    return @intCast(name.theme);
}
/// Sum of all framebuffer words of the last frame, for regression tests.
fn debug_pixel_checksum() callconv(.c) u32 {
    var sum: u32 = 0;
    for (cart.framebuffer) |*column| {
        for (column) |px| sum +%= @as(u16, @bitCast(px));
    }
    return sum;
}
fn debug_render_us() callconv(.c) u32 {
    return render_us;
}

/// Button state. Upstream's platform_wasm.zig exposes `controls` but never
/// fills it from the simulator, which writes its button word (same bit
/// layout as cart.Controls) to linear address 0x04; read that directly on
/// wasm. Hardware gets the OS-maintained cart.controls. (From demosnout.)
fn read_controls() cart.Controls {
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
