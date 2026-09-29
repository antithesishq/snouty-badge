//! Snouty Genesis: Sega Genesis emulator cart (XIP only, SPEC.md section
//! 13). Each update runs `tunables.render_every` Genesis frames (two: the
//! "60/30" of SPEC.md section 8) and renders only the last, which reaches
//! the framebuffer through frontend/video.zig; the debug overlay
//! (frontend/debug.zig) goes on top and the ROM report line
//! (frontend/romsrc.zig) at the bottom. The neopixels are never written
//! (docs/NEOPIXELS.md at the repository root).
//!
//! M0 scaffold: the core is a stub whose rendered frame is a test pattern
//! (core/md.zig `test_pattern`); no splash, menu or rewind yet (M2, M3). A
//! Select hold is counted and does nothing. See SPEC.md (design), PLAN.md
//! (milestone contract), CLAUDE.md (toolchain).
const cart = @import("cart-api");
const core = @import("core");
const video = @import("frontend/video.zig");
const input = @import("frontend/input.zig");
const audio = @import("frontend/audio.zig");
const debug = @import("frontend/debug.zig");
const romsrc = @import("frontend/romsrc.zig");
const text = @import("frontend/text.zig");

comptime {
    cart.export_start_code();
}

/// The console (~137 KB), a static initialised in place: never build it on
/// the stack (32 KB on the badge, 14.7 KB in wasm).
var md: core.Md = undefined;

/// Genesis frames per update; only the last is rendered.
const frames_per_update = core.tunables.render_every;

pub const State = enum(u32) { running = 1 };
var state: State = .running;
var controls_state: input.State = .{};

/// Select holds seen (the M2 menu will open there).
var menu_requests: u32 = 0;

pub fn start() void {
    // Presents at 60 / render_every Hz (30 by default).
    cart.set_vsync_enabled(1000.0 * @as(f32, frames_per_update) / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    text.init();
    video.init();
    debug.frames_per_update = frames_per_update;
    md.init_in_place(romsrc.select());
    md.line_sink = video.sink();
}

pub fn update() void {
    controls_state.poll(read_controls());
    const t0 = cart.micros_since_boot();
    debug.frame_tick(t0);
    switch (state) {
        .running => run_update(t0),
    }
    if (cart.is_wasm) present_wasm();
}

fn run_update(t1: u64) void {
    const in = controls_state.game_frame();
    if (in.open_menu) menu_requests += 1;

    var f: u8 = 1;
    while (f <= frames_per_update) : (f += 1) md.step_frame(in.pad, f == frames_per_update);
    const t2 = cart.micros_since_boot();

    audio.update(&md);
    video.finish_frame();
    debug.record(@truncate(t2 -% t1));
    romsrc.draw_report();
    debug.draw();
}

pub fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// Simulator shim, copied from Snouty Gear: upstream's wasm platform never
/// presents, and the web simulator reads a legacy framebuffer at 0x20 with
/// red and blue swapped relative to DisplayColor. Hardware builds compile
/// none of this.
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
// In wasm micros_since_boot adds 1000 per call, so debug_step_us means nothing.
comptime {
    if (cart.is_wasm) {
        @export(&debug_frame_count, .{ .name = "debug_frame_count" });
        @export(&debug_step_us, .{ .name = "debug_step_us" });
        @export(&debug_lines, .{ .name = "debug_lines" });
        @export(&debug_state, .{ .name = "debug_state" });
        @export(&debug_pad, .{ .name = "debug_pad" });
        @export(&debug_rom_source, .{ .name = "debug_rom_source" });
        @export(&debug_rom_size, .{ .name = "debug_rom_size" });
        @export(&debug_rom_crc, .{ .name = "debug_rom_crc" });
        @export(&debug_cram_rebuilds, .{ .name = "debug_cram_rebuilds" });
        @export(&debug_menu_requests, .{ .name = "debug_menu_requests" });
        @export(&debug_tone_calls, .{ .name = "debug_tone_calls" });
        @export(&debug_pc, .{ .name = "debug_pc" });
        @export(&debug_sp, .{ .name = "debug_sp" });
        @export(&debug_sr, .{ .name = "debug_sr" });
        @export(&debug_vdp_line, .{ .name = "debug_vdp_line" });
        @export(&debug_z80_pc, .{ .name = "debug_z80_pc" });
    }
}

/// Genesis frames stepped since reset (`md.frame_count`; two per update).
fn debug_frame_count() callconv(.c) u32 {
    return md.frame_count;
}
/// Microseconds the last update's frames took.
fn debug_step_us() callconv(.c) u32 {
    return debug.last_step_us;
}
/// Rows the core emitted for the last presented frame (128).
fn debug_lines() callconv(.c) u32 {
    return video.last_frame_lines;
}
/// Frontend state: 1 running (splash 0 and menu 2 arrive in M2).
fn debug_state() callconv(.c) u32 {
    return @backingInt(state);
}
/// Pad word the core was last stepped with (`core.Pad` bits).
fn debug_pad() callconv(.c) u32 {
    return md.pad;
}
/// 0 none, 1 embedded, 2 drive contiguous, 3 drive fragmented.
fn debug_rom_source() callconv(.c) u32 {
    return @backingInt(romsrc.origin);
}
/// ROM size in bytes.
fn debug_rom_size() callconv(.c) u32 {
    return md.rom.size;
}
/// CRC32 of the drive ROM (0 for the embedded one).
fn debug_rom_crc() callconv(.c) u32 {
    return romsrc.crc;
}
/// CRAM -> Pixel cache rebuilds since boot.
fn debug_cram_rebuilds() callconv(.c) u32 {
    return video.cram_rebuilds;
}
/// Select holds that would have opened the menu.
fn debug_menu_requests() callconv(.c) u32 {
    return menu_requests;
}
/// `tone2` calls since boot (0 in M0: `Md.tone()` is a stub).
fn debug_tone_calls() callconv(.c) u32 {
    return audio.tone_calls;
}
/// 68000 program counter after the last frame.
fn debug_pc() callconv(.c) u32 {
    return md.cpu.pc;
}
/// 68000 active stack pointer (A7).
fn debug_sp() callconv(.c) u32 {
    return md.cpu.a[7];
}
/// 68000 status register.
fn debug_sr() callconv(.c) u32 {
    return md.cpu.sr;
}
/// VDP line (0..261) the frame ended on.
fn debug_vdp_line() callconv(.c) u32 {
    return md.vdp.line;
}
/// Z80 program counter.
fn debug_z80_pc() callconv(.c) u32 {
    return md.z80.pc;
}
