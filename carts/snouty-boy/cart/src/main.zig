//! Snouty Boy: Game Boy emulator cart. M0 scaffold: runs the core one frame
//! per badge frame and shows its lines through frontend/video.zig.
//! See SPEC.md (design), PLAN.md (M1 contract), CLAUDE.md (toolchain).
const cart = @import("cart-api");
const core = @import("core");
const rom = @import("rom");
const video = @import("frontend/video.zig");
const input = @import("frontend/input.zig");
const debug = @import("frontend/debug.zig");

comptime {
    cart.export_start_code();
}

var gb: core.Gb = undefined;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    video.init();
    gb = core.Gb.init(rom.data);
    gb.line_sink = video.sink();
}

pub fn update() void {
    const controls = read_controls();
    const pad = input.pad_from_controls(controls);

    const t0 = cart.micros_since_boot();
    gb.step_frame(pad);
    const t1 = cart.micros_since_boot();

    video.finish_frame();
    debug.record(@intCast(t1 - t0));
    debug.draw();

    if (cart.is_wasm) present_wasm();
}

pub fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// Simulator shim, copied from snouty-bugs (see its CLAUDE.md): upstream's
/// wasm platform never presents, and the web simulator reads a legacy
/// framebuffer at 0x20 with red and blue swapped relative to DisplayColor.
/// Hardware builds compile none of this.
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
