//! Snouty on the Water: real-time ray-traced sunset lake (trace.zig). See
//! SPEC.md for the design, PLAN.md for the M1 contract, CLAUDE.md for the
//! toolchain.
const cart = @import("cart-api");
const input = @import("input.zig");
const math = @import("math.zig");
const dither = @import("dither.zig");
const overlay = @import("overlay.zig");
const trace = @import("trace.zig");
const camera = @import("camera.zig");
const scene = @import("scene.zig");
const variant = @import("variant.zig");
const build_options = @import("build_options");

comptime {
    cart.export_start_code();
}

/// Preset of the stand-in view (Track A's branch only): badge-bench sets it
/// with --poke reflections_bench_preset=N, the wasm with debug_set_preset.
export var reflections_bench_preset: u32 = 0;
/// Offset added to the frame counter for the stand-in view (badge-bench
/// --poke reflections_bench_frame0=N starts the orbit at frame N).
export var reflections_bench_frame0: u32 = 0;
/// Fixed eye height in mm for badge-bench (--poke reflections_bench_height_mm=3000); 0: default.
export var reflections_bench_height_mm: u32 = 0;

/// -Dreflections_bench=height: the eye height sweeps min to max and back
/// once per orbit, so every frame rebuilds the primary water tables.
fn bench_height(f: u32) f32 {
    const half = camera.orbit_frames / 2;
    const i = f % camera.orbit_frames;
    const k: f32 = @floatFromInt(if (i < half) i else camera.orbit_frames - i);
    return camera.min_height + (camera.max_height - camera.min_height) * k / @as(f32, half);
}

/// A view fixed by debug_set_view (wasm harness), drawn every frame.
var debug_view: ?trace.View = null;

/// Frames since start().
var frame: u32 = 0;
/// Microseconds spent in the last render (hardware timer; 0 on wasm).
var render_us: u32 = 0;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / @as(comptime_float, variant.fps));
    cart.set_double_buffer_mode(.no_copy_full_frame);
    trace.init();
}

pub fn update() void {
    input.update(read_controls());

    if (input.pressed(.b)) dither.next_mode();

    const t0 = cart.micros_since_boot();
    dither.begin_frame(frame);
    // Track B's app.zig replaces this with the attract / free camera state.
    const f = frame +% reflections_bench_frame0;
    trace.render_frame(debug_view orelse .{
        .preset = @fromBackingInt(@intCast(reflections_bench_preset % scene.preset_count)),
        .t = f,
        .orbit = f % camera.orbit_frames,
        .height = if (build_options.reflections_bench == .height)
            bench_height(f)
        else if (reflections_bench_height_mm != 0)
            @as(f32, @floatFromInt(reflections_bench_height_mm)) / 1000.0
        else
            camera.default_height,
        .fade = 1.0,
    });
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
        @export(&debug_set_preset, .{ .name = "debug_set_preset" });
        @export(&debug_set_view, .{ .name = "debug_set_view" });
        @export(&debug_set_dither_mode, .{ .name = "debug_set_dither_mode" });
        @export(&debug_preset, .{ .name = "debug_preset" });
    }
}

fn debug_frame() callconv(.c) u32 {
    return frame;
}
fn debug_render_us() callconv(.c) u32 {
    return render_us;
}
fn debug_set_preset(p: u32) callconv(.c) void {
    reflections_bench_preset = p;
}
fn debug_set_view(preset: u32, t: u32, orbit: u32, height_mm: u32) callconv(.c) void {
    debug_view = .{
        .preset = @fromBackingInt(@intCast(preset % scene.preset_count)),
        .t = t,
        .orbit = orbit % camera.orbit_frames,
        .height = @as(f32, @floatFromInt(height_mm)) / 1000.0,
        .fade = 1.0,
    };
}
fn debug_set_dither_mode(m: u32) callconv(.c) void {
    dither.mode = @fromBackingInt(@intCast(m & 1));
}
fn debug_preset() callconv(.c) u32 {
    return if (debug_view) |v| @backingInt(v.preset) else reflections_bench_preset % scene.preset_count;
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
