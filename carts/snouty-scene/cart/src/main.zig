//! Snouty Scene: a demoscene production for the SYCL Badge V2. Classic
//! real-time effects on a 120 BPM frame clock, looping, with a part picker.
//! See SPEC.md for the design, PLAN.md for the current milestone and
//! CLAUDE.md for the toolchain.
//!
//! update(): input (A/Start skip, Select opens the picker, B toggles the
//! timing overlay in -Ddebug_overlay=true builds; nothing while Start and
//! Select are held together, the OS's exit chord), then the timeline
//! renders the current part and its veil, the picker and the overlay draw
//! on top, and the clock advances one frame.
const cart = @import("cart-api");
const build_options = @import("build_options");
const input = @import("input.zig");
const math = @import("math.zig");
const timeline = @import("timeline.zig");
const picker = @import("picker.zig");
const overlay = @import("overlay.zig");

comptime {
    cart.export_start_code();
}

/// Part the show starts on. Exported on the badge build so badge-bench can
/// `--poke scene_part=N` before start() (unexported, the compiler would
/// fold it to 0); the wasm build has debug_goto for the same.
var scene_part: u8 = 0;

var render_us: u32 = 0;
var show_overlay: bool = build_options.debug_overlay;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    math.init_tables();
    timeline.init_all();
    timeline.start(scene_part);
}

pub fn update() void {
    input.update(read_controls());
    if (input.held(.start) and input.held(.select)) {
        // Start+Select is the OS's exit chord: react to neither button.
    } else if (picker.open) {
        picker.handle();
    } else if (input.pressed(.select)) {
        picker.show();
    } else if (input.pressed(.a) or input.pressed(.start)) {
        timeline.skip();
    } else if (build_options.debug_overlay and input.pressed(.b)) {
        show_overlay = !show_overlay;
    }

    const fb = cart.framebuffer;
    const t0 = cart.micros_since_boot();
    timeline.render(fb);
    if (picker.open) picker.draw();
    render_us = @truncate(cart.micros_since_boot() - t0);
    if (show_overlay) overlay.draw(render_us, timeline.current(), timeline.part_frame());
    timeline.step();

    if (cart.is_wasm) present_wasm();
}

// Debug exports for the headless harness (wasm), scene_part for badge-bench.
comptime {
    if (cart.is_wasm) {
        @export(&debug_frame, .{ .name = "debug_frame" });
        @export(&debug_part, .{ .name = "debug_part" });
        @export(&debug_part_frame, .{ .name = "debug_part_frame" });
        @export(&debug_pixel_checksum, .{ .name = "debug_pixel_checksum" });
        @export(&debug_render_us, .{ .name = "debug_render_us" });
        @export(&debug_goto, .{ .name = "debug_goto" });
        @export(&debug_picker, .{ .name = "debug_picker" });
    } else {
        @export(&scene_part, .{ .name = "scene_part" });
    }
}

/// Frames since start() (every update, across parts and loops).
fn debug_frame() callconv(.c) u32 {
    return timeline.global_frame;
}
/// Index of the part the next update() renders.
fn debug_part() callconv(.c) u32 {
    return timeline.current();
}
/// Frame within that part (0 = the frame after enter()).
fn debug_part_frame() callconv(.c) u32 {
    return timeline.part_frame();
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
/// Cut to frame 0 of part `part` (clamped to the last part), as the picker does.
fn debug_goto(part: u32) callconv(.c) void {
    timeline.goto(part);
}
/// 1 while the picker is open.
fn debug_picker() callconv(.c) u32 {
    return @intFromBool(picker.open);
}

/// Button state. Upstream's platform_wasm.zig exposes `controls` but never
/// fills it from the simulator, which writes its button word (same bit
/// layout as cart.Controls) to linear address 0x04; read that directly on
/// wasm. Hardware gets the OS-maintained cart.controls. (From snouty-maze.)
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
