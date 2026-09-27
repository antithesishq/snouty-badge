//! Bare-metal emulation entry for the bench ELF. Replaces cart/src/main.zig
//! (which needs the OS, input and the overlay): it does exactly what
//! main.update() does around the render, dither.begin_frame then
//! trace.render_frame, with the dither mode taken from `bench_mode`.
//! build.sh copies this file next to the cart modules in build/src/.
const trace = @import("trace.zig");
const dither = @import("dither.zig");

/// 1 = none (reference comparison), 0 = bayer_temporal. Poked by bench.py.
export var bench_mode: u32 = 1;

export fn render_frame(frame: u32) callconv(.c) void {
    dither.mode = @enumFromInt(bench_mode);
    dither.begin_frame(frame);
    trace.render_frame(frame);
}

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ movs r0, #0
        \\ bl render_frame
        \\ bkpt #0
        \\1: b 1b
    );
}
