//! Snouty Genesis: Sega Genesis emulator cart, built twice (SPEC.md
//! section 13, PLAN.md M5): the RAM cart without the Z80 (a stub, so no
//! sound) and without the scrubber, and the XIP cart and the simulator
//! with both (`build_options`). Each update runs `tunables.render_every` Genesis frames (two: the
//! "60/30" of SPEC.md section 8) and renders only the last, which reaches
//! the framebuffer through frontend/video.zig; the debug overlay
//! (frontend/debug.zig) goes on top and the ROM report line
//! (frontend/romsrc.zig) at the bottom. The neopixels are never written
//! (docs/NEOPIXELS.md at the repository root).
//!
//! States (PLAN.md M2 "Frontend states"): splash (frontend/splash.zig) ->
//! running -> menu (frontend/menu.zig, opened by a 500 ms Select hold,
//! frontend/input.zig) -> running; a drive build with several ROMs goes to
//! the picker (pick) after the splash, one with none to the help screen
//! (help). The core is stepped only while running. Sound is the one tone
//! voice (frontend/audio.zig), off at boot unless built with -Dsound=true
//! (docs/SOUND.md); the menu's Sound row flips it. The time scrubber
//! (frontend/rewind.zig over core/undo.zig, SPEC.md 10) keeps an undo record
//! per 30 Genesis frames in the RAM the linker leaves free; the menu's
//! Left/Right swap through them, and playing on from a scrubbed position
//! drops the future. See SPEC.md (design), PLAN.md (milestone contract),
//! CLAUDE.md (toolchain). The console is created by `begin` once the ROM is
//! known (`have_md`). Fast forward (docs/FAST_FORWARD.md at the root):
//! while the second press of a Select double tap is held, each update steps
//! up to `tuning.ff_max_frames` Genesis frames (4x) within
//! `tuning.ff_budget_us`, only the last rendered and none with sound, every
//! one recorded for the scrubber; `>>4x` sits in the bottom right corner
//! meanwhile. Where the scrubber exists, Left during that hold turns it
//! into the chorded rewind: the game freezes under the menu's scrub bar,
//! Left/Right step time, letting go of Select resumes from there
//! (`input.Rewind`). A single Select tap (a Genesis button) waits out the 200 ms
//! in which a second press would make it the double tap. Control hints
//! (lib/hint.zig): "Hold Select: menu" on the splash and in a strip at the
//! bottom for the first 3 s of play after the splash, picker or help
//! screen, then "2x Sel+hold: fast" for 3 s more (gone at the first fresh
//! press); the menu has its own.
//!
//! This file is the root module: the cart exports, the simulator shims
//! and the `debug_*` exports. The state machine is frontend/app.zig, a
//! module of its own (ReleaseSmall in the RAM cart); `start` and `update`
//! call it.
const cart = @import("cart-api");
const core = @import("core");
const video = @import("video");
const app = @import("app");
const input = app.input;
const audio = app.audio;
const debug = app.debug;
const romsrc = app.romsrc;
const rewind = app.rewind;

comptime {
    cart.export_start_code();
}

pub fn start() void {
    app.start();
}

pub fn update() void {
    app.update();
    if (cart.is_wasm) present_wasm();
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
// Those that read `md` return 0 until `begin` has created it (`have_md`).
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
        @export(&debug_menu_opens, .{ .name = "debug_menu_opens" });
        @export(&debug_settings, .{ .name = "debug_settings" });
        @export(&debug_tone_calls, .{ .name = "debug_tone_calls" });
        @export(&debug_sound_on, .{ .name = "debug_sound_on" });
        @export(&debug_pc, .{ .name = "debug_pc" });
        @export(&debug_sp, .{ .name = "debug_sp" });
        @export(&debug_sr, .{ .name = "debug_sr" });
        @export(&debug_vdp_line, .{ .name = "debug_vdp_line" });
        @export(&debug_z80_pc, .{ .name = "debug_z80_pc" });
        @export(&debug_tone_hz, .{ .name = "debug_tone_hz" });
        @export(&debug_z80_state, .{ .name = "debug_z80_state" });
        @export(&debug_scrub_depth, .{ .name = "debug_scrub_depth" });
        @export(&debug_scrub_history, .{ .name = "debug_scrub_history" });
        @export(&debug_scrub_records, .{ .name = "debug_scrub_records" });
        @export(&debug_scrub_slots, .{ .name = "debug_scrub_slots" });
        @export(&debug_scrub_capacity, .{ .name = "debug_scrub_capacity" });
        @export(&debug_scrub_arena, .{ .name = "debug_scrub_arena" });
        @export(&debug_ff_frames, .{ .name = "debug_ff_frames" });
        @export(&debug_chord_rewind, .{ .name = "debug_chord_rewind" });
    }
}

/// Genesis frames stepped since reset (`md.frame_count`; two per update).
fn debug_frame_count() callconv(.c) u32 {
    if (!app.have_md) return 0;
    return app.md.frame_count;
}
/// Microseconds the last update's frames took.
fn debug_step_us() callconv(.c) u32 {
    return debug.last_step_us;
}
/// Rows the core emitted for the last presented frame (128).
fn debug_lines() callconv(.c) u32 {
    return video.last_frame_lines;
}
/// Frontend state: 0 splash, 1 running, 2 menu, 3 picker, 4 no-ROM help.
fn debug_state() callconv(.c) u32 {
    return @backingInt(app.state);
}
/// Pad word the core was last stepped with (`core.Pad` bits).
fn debug_pad() callconv(.c) u32 {
    if (!app.have_md) return 0;
    return app.md.pad;
}
/// 0 none, 1 embedded, 2 drive contiguous, 3 drive fragmented.
fn debug_rom_source() callconv(.c) u32 {
    return @backingInt(romsrc.origin);
}
/// ROM size in bytes.
fn debug_rom_size() callconv(.c) u32 {
    if (!app.have_md) return 0;
    return app.md.rom.size;
}
/// CRC32 of the drive ROM (0 for the embedded one).
fn debug_rom_crc() callconv(.c) u32 {
    return romsrc.crc;
}
/// CRAM -> Pixel cache rebuilds since boot.
fn debug_cram_rebuilds() callconv(.c) u32 {
    return video.cram_rebuilds;
}
/// Times the menu opened since boot.
fn debug_menu_opens() callconv(.c) u32 {
    return app.menu_opens;
}
/// Menu settings: bit 0 sound on, bit 1 crop scale, bits 2-4 the button
/// layout (`input.Layout`, 0 = B=B A=C S=A), bit 5 debug overlay on,
/// bit 6 Smooth H40 on.
fn debug_settings() callconv(.c) u32 {
    var v: u32 = 0;
    if (audio.enabled) v |= 1;
    if (video.scale == .crop) v |= 2;
    v |= @as(u32, @intCast(input.layout.index())) << 2;
    if (debug.enabled) v |= 32;
    if (video.smooth) v |= 64;
    return v;
}
/// `tone2` calls since boot.
fn debug_tone_calls() callconv(.c) u32 {
    return audio.tone_calls;
}
/// 1 when sound is on (`-Dsound` at boot, the menu's Sound row flips it).
fn debug_sound_on() callconv(.c) u32 {
    return @intFromBool(audio.enabled);
}
/// 68000 program counter after the last frame.
fn debug_pc() callconv(.c) u32 {
    if (!app.have_md) return 0;
    return app.md.cpu.pc;
}
/// 68000 active stack pointer (A7).
fn debug_sp() callconv(.c) u32 {
    if (!app.have_md) return 0;
    return app.md.cpu.a[7];
}
/// 68000 status register.
fn debug_sr() callconv(.c) u32 {
    if (!app.have_md) return 0;
    return app.md.cpu.get_sr();
}
/// VDP line (0..261) the frame ended on.
fn debug_vdp_line() callconv(.c) u32 {
    if (!app.have_md) return 0;
    return app.md.vdp.line;
}
/// Z80 program counter.
fn debug_z80_pc() callconv(.c) u32 {
    if (!app.have_md) return 0;
    return app.md.z80.pc;
}
/// Frequency the buzzer plays (0 when silent).
fn debug_tone_hz() callconv(.c) u32 {
    return audio.playing_hz();
}
/// Z80 arbiter: bit 0 BUSREQ held by the 68000, bit 1 Z80 in reset, bit 2
/// Z80 switched off (`tunables.z80_enabled` false).
fn debug_z80_state() callconv(.c) u32 {
    if (!app.have_md) return 0;
    var v: u32 = 0;
    if (app.md.arbiter.busreq) v |= 1;
    if (app.md.arbiter.z80_reset) v |= 2;
    if (!core.tunables.z80_enabled) v |= 4;
    return v;
}

// ---- Time scrubber (frontend/rewind.zig) ----

/// Frames the console is parked behind live (0 live; 30 per scrub step).
fn debug_scrub_depth() callconv(.c) u32 {
    return rewind.depth_frames();
}
/// Frames of history reachable back from live.
fn debug_scrub_history() callconv(.c) u32 {
    return rewind.history_frames();
}
/// Closed undo records held.
fn debug_scrub_records() callconv(.c) u32 {
    return @intCast(rewind.record_count());
}
/// Ring slots (68 B each) in use, closed records and the open one.
fn debug_scrub_slots() callconv(.c) u32 {
    return @intCast(rewind.slots_in_use());
}
/// Ring slots the arena holds (0: no room, scrubber off).
fn debug_scrub_capacity() callconv(.c) u32 {
    return @intCast(rewind.capacity_slots());
}
/// Arena bytes found (`tuning.wasm_arena_bytes` in wasm).
fn debug_scrub_arena() callconv(.c) u32 {
    return @intCast(rewind.arena_bytes());
}

// ---- Fast forward ----

/// 1 while the chorded rewind shows (fast forward turned into rewind).
fn debug_chord_rewind() callconv(.c) u32 {
    return @intFromBool(app.state == .running and app.rewinding);
}

/// Genesis frames the last update stepped (2 at 1x, up to 8 fast; 0 while
/// not running or in the chorded rewind).
fn debug_ff_frames() callconv(.c) u32 {
    return if (app.state == .running) app.frames_stepped else 0;
}
