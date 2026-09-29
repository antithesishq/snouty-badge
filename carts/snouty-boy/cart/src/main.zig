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
const audio = @import("frontend/audio.zig");
const rewind = @import("frontend/rewind.zig");

comptime {
    cart.export_start_code();
}

var gb: core.Gb = undefined;
/// Cart RAM, sized from the embedded ROM's header (0 to 32 KB). Word
/// aligned so the page store's word compares and copies are aligned.
var cart_ram: [core.mmu.cart_ram_len(rom.data)]u8 align(4) = undefined;

pub const State = enum(u32) { splash = 0, running = 1, menu = 2 };
var state: State = .splash;
var controls_state: input.State = .{};

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    const model = core.default_model(rom.data);
    video.init(model);
    gb = core.Gb.init(rom.data, model, &cart_ram);
    gb.line_sink = video.sink(&gb);
    rewind.reset(&gb);
}

pub fn update() void {
    controls_state.poll(read_controls());
    // Timestamp every badge frame (paused or not) so the FPS counter sees
    // real frame intervals; `debug.record` below only measures step_frame.
    const t0 = cart.micros_since_boot();
    debug.frame_tick(t0);

    // Sound follows the menu toggle; the tone holds while the core is paused
    // and stops at once when sound is switched off (audio.update handles it).
    audio.enabled = menu.sound_enabled;

    switch (state) {
        .splash => {
            if (splash.request_chime) {
                splash.request_chime = false;
                audio.chime(0);
                chime_second_at = frames_seen + 4;
            }
            if (chime_second_at != 0 and frames_seen == chime_second_at) {
                chime_second_at = 0;
                audio.chime(1);
            }
            if (splash.update(controls_state.edge.any_pressed())) {
                controls_state.suppress_held();
                state = .running;
                run_frame(t0);
            }
        },
        .running => run_frame(t0),
        .menu => {
            audio.update(&gb);
            if (menu.update(&gb, controls_state.edge) == .resume_game) {
                menu.close();
                controls_state.suppress_held();
                state = .running;
                run_frame(cart.micros_since_boot());
            }
        },
    }

    frames_seen +%= 1;
    if (cart.is_wasm) present_wasm();
}

/// Badge frames since boot; paces the second chime note.
var frames_seen: u32 = 0;
var chime_second_at: u32 = 0;

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
    rewind.record_frame(&gb, in.pad);

    audio.update(&gb);

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
        @export(&debug_scrub_depth, .{ .name = "debug_scrub_depth" });
        @export(&debug_history, .{ .name = "debug_history" });
        @export(&debug_keyframes, .{ .name = "debug_keyframes" });
        @export(&debug_pool_bytes, .{ .name = "debug_pool_bytes" });
        @export(&debug_cgb, .{ .name = "debug_cgb" });
        @export(&debug_leds, .{ .name = "debug_leds" });
        @export(&debug_led_max, .{ .name = "debug_led_max" });
        @export(&debug_alarm, .{ .name = "debug_alarm" });
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
/// Lines the core emitted during the last frame (128 with the LCD on).
fn debug_lines() callconv(.c) u32 {
    return video.last_frame_lines;
}
/// Current palette index into `video.palettes` (DMG mode).
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
/// Frames the scrubber is parked behind the live position (0 = live).
fn debug_scrub_depth() callconv(.c) u32 {
    return rewind.depth_frames();
}
/// Frames of history in the keyframe ring.
fn debug_history() callconv(.c) u32 {
    return rewind.history_frames();
}
/// Valid keyframes in the ring.
fn debug_keyframes() callconv(.c) u32 {
    return @intCast(rewind.keyframe_count());
}
/// Page-store pool bytes in use.
fn debug_pool_bytes() callconv(.c) u32 {
    return @intCast(rewind.pool_bytes());
}
/// 1 when the console runs in CGB mode.
fn debug_cgb() callconv(.c) u32 {
    return @intFromBool(gb.is_cgb());
}
/// Neopixels currently lit (any channel non-zero).
fn debug_leds() callconv(.c) u32 {
    var n: u32 = 0;
    for (0..cart.neopixels.len) |i| {
        const c = cart.neopixels[i];
        if (c.r != 0 or c.g != 0 or c.b != 0) n += 1;
    }
    return n;
}
/// Largest neopixel channel value (must stay <= 10).
fn debug_led_max() callconv(.c) u32 {
    var m: u8 = 0;
    for (0..cart.neopixels.len) |i| {
        const c = cart.neopixels[i];
        m = @max(m, c.r, c.g, c.b);
    }
    return m;
}
/// 1 if the rewind self-check found a mismatch.
fn debug_alarm() callconv(.c) u32 {
    return @intFromBool(debug.alarm);
}
