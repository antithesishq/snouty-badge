//! Snouty Boy: Game Boy emulator cart. Runs the core one frame per badge
//! frame and shows its lines through frontend/video.zig, with the debug
//! overlay (frontend/debug.zig) on top.
//!
//! States: splash (frontend/splash.zig) -> running -> menu
//! (frontend/menu.zig, opened by a 500 ms Select hold, frontend/input.zig)
//! -> running. The core is stepped only while running.
//! See SPEC.md (design), PLAN.md (milestone contract), CLAUDE.md (toolchain).
const cart = @import("cart-api");
const core = @import("core");
const rom = @import("rom");
const video = @import("frontend/video.zig");
const input = @import("frontend/input.zig");
const debug = @import("frontend/debug.zig");
const menu = @import("frontend/menu.zig");
const splash = @import("frontend/splash.zig");

comptime {
    cart.export_start_code();
}

var gb: core.Gb = undefined;

pub const State = enum(u32) { splash = 0, running = 1, menu = 2 };
var state: State = .splash;
var controls_state: input.State = .{};

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    video.init();
    gb = core.Gb.init(rom.data);
    gb.line_sink = video.sink();
}

pub fn update() void {
    controls_state.poll(read_controls());
    // Timestamp every badge frame (paused or not) so the FPS counter sees
    // real frame intervals; `debug.record` below only measures step_frame.
    const t0 = cart.micros_since_boot();
    debug.frame_tick(t0);

    switch (state) {
        .splash => {
            if (splash.update(controls_state.edge.any_pressed())) {
                controls_state.suppress_held();
                state = .running;
                run_frame(t0);
            }
        },
        .running => run_frame(t0),
        .menu => {
            if (menu.update(&gb, controls_state.edge) == .resume_game) {
                menu.close();
                controls_state.suppress_held();
                state = .running;
                run_frame(cart.micros_since_boot());
            }
        },
    }

    if (cart.is_wasm) present_wasm();
}

/// One game frame, or opening the menu instead of stepping. `t1` is a fresh
/// `micros_since_boot` reading taken just before.
fn run_frame(t1: u64) void {
    const in = controls_state.game_frame();
    if (in.open_menu) {
        state = .menu;
        menu.open();
        _ = menu.update(&gb, controls_state.edge);
        return;
    }

    gb.step_frame(in.pad);
    const t2 = cart.micros_since_boot();

    // TODO(M3 integrator): audio.update(&gb); // frontend/audio.zig, gated on menu.sound_enabled; also consume splash.request_chime

    video.finish_frame();
    debug.record(@truncate(t2 -% t1));
    debug.draw();
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

// Zero-argument exports for `tools/preview.mjs --dump-exports` (wasm only).
// In wasm micros_since_boot is a stub that adds 1000 per call, so
// debug_step_us reads 1000 there and means nothing.
comptime {
    if (cart.is_wasm) {
        @export(&debug_frame_count, .{ .name = "debug_frame_count" });
        @export(&debug_step_us, .{ .name = "debug_step_us" });
        @export(&debug_lines, .{ .name = "debug_lines" });
        @export(&debug_palette, .{ .name = "debug_palette" });
        @export(&debug_state, .{ .name = "debug_state" });
        @export(&debug_pad, .{ .name = "debug_pad" });
    }
}

/// Frames stepped since reset (`gb.frame_count`).
fn debug_frame_count() callconv(.c) u32 {
    return gb.frame_count;
}
/// Microseconds the last `step_frame` took.
fn debug_step_us() callconv(.c) u32 {
    return debug.last_step_us;
}
/// Lines the core emitted during the last frame (144 with the LCD on).
fn debug_lines() callconv(.c) u32 {
    return video.last_frame_lines;
}
/// Current palette index into `video.palettes`.
fn debug_palette() callconv(.c) u32 {
    return @intCast(video.palette_index);
}
/// Frontend state: 0 splash, 1 running, 2 menu.
fn debug_state() callconv(.c) u32 {
    return @backingInt(state);
}
/// Pad byte the game was last stepped with (`core.Pad` bits; Select = 64).
fn debug_pad() callconv(.c) u32 {
    return gb.pad;
}
