//! Snouty Gear: Game Gear emulator cart. Runs the core one frame per badge
//! frame and shows its lines through frontend/video.zig, with the debug
//! overlay (frontend/debug.zig) on top and, while the overlay is on, the
//! ROM report line (frontend/romsrc.zig) at the bottom.
//!
//! States: splash (frontend/splash.zig) -> running -> menu
//! (frontend/menu.zig, opened by a 500 ms Select hold, frontend/input.zig)
//! -> running; or, in the badge drive build when the drive has no usable
//! ROM, no_rom (frontend/splash.zig `draw_no_rom`) for good: there is no
//! embedded ROM to fall back on. The core is stepped only while running.
//! Sound (frontend/audio.zig): on the badge the core renders the PSG and
//! the samples stream to the OS; in the simulator one `tone` voice. The time scrubber
//! (frontend/rewind.zig, SPEC.md 10) records a keyframe every 30 game frames
//! and the pad of every frame; the menu's Left/Right scrub through them.
//! Control hints (lib/hint.zig): "Hold Select: menu" on the splash and in
//! a strip at the bottom for the first 3 s of play (gone at the first
//! fresh press); the menu has its own.
//! See SPEC.md (design), PLAN.md (milestone contract), CLAUDE.md (toolchain).
const cart = @import("cart-api");
const core = @import("core");
const video = @import("frontend/video.zig");
const input = @import("frontend/input.zig");
const debug = @import("frontend/debug.zig");
const romsrc = @import("frontend/romsrc.zig");
const text = @import("frontend/text.zig");
const menu = @import("frontend/menu.zig");
const splash = @import("frontend/splash.zig");
const audio = @import("frontend/audio.zig");
const rewind = @import("frontend/rewind.zig");
const hint = @import("hint");

comptime {
    cart.export_start_code();
}

/// The console (~33 KB), a static initialised in place: never build it on
/// the stack (32 KB on the badge, 14.7 KB in wasm).
var gg: core.Gg = undefined;

pub const State = enum(u32) { splash = 0, running = 1, menu = 2, no_rom = 3 };
var state: State = .splash;
var controls_state: input.State = .{};

/// Menu opens since boot.
var menu_opens: u32 = 0;
/// "Hold Select: menu" over the first seconds of play (lib/hint.zig).
var play_hint: hint.Overlay = .{};

/// Badge frames since boot; paces the second chime note.
var frames_seen: u32 = 0;
var chime_second_at: u32 = 0;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    text.init();
    video.init();
    // No ROM on the drive: `gg` stays uninitialised and is never touched.
    const r = romsrc.select() orelse {
        state = .no_rom;
        return;
    };
    gg.init_in_place(r);
    gg.line_sink = video.sink();
    // False when the arena has no room for two keyframes: the scrubber
    // stays off ("Scrub: no memory"), the game runs as before.
    _ = rewind.init();
    rewind.reset(&gg);
}

pub fn update() void {
    controls_state.poll(read_controls());
    // Timestamp every badge frame (paused or not) so the FPS counter sees
    // real frame intervals; `debug.record` below only measures step_frame.
    const t0 = cart.micros_since_boot();
    debug.frame_tick(t0);

    // Sound follows the menu toggle. While the core is paused the badge
    // ramps out (audio.idle); the simulator's tone holds and stops at once
    // when sound is switched off.
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
            audio.idle(&gg);
            if (splash.update(controls_state.edge.any_pressed())) {
                controls_state.suppress_held();
                state = .running;
                play_hint.start(hint.play_seconds * 60);
                run_frame(t0);
            }
        },
        .running => run_frame(t0),
        .menu => {
            // Scrub steps replay frames: no sound to render for them.
            gg.audio_render = false;
            audio.idle(&gg);
            if (menu.update(&gg, controls_state.live_edge()) == .resume_game) {
                menu.close();
                controls_state.suppress_held();
                state = .running;
                run_frame(cart.micros_since_boot());
            }
        },
        .no_rom => {
            audio.idle(&gg);
            splash.draw_no_rom(romsrc.failure orelse "");
        },
    }

    frames_seen +%= 1;
    if (cart.is_wasm) present_wasm();
}

/// One game frame, or opening the menu instead of stepping. `t1` is a fresh
/// `micros_since_boot` reading taken just before.
fn run_frame(t1: u64) void {
    const in = controls_state.game_frame();
    if (in.open_menu) {
        play_hint.stop();
        menu_opens += 1;
        state = .menu;
        // The held Select, and an A/B pressed with it, wait for a release.
        controls_state.suppress_held();
        menu.open();
        _ = menu.update(&gg, controls_state.live_edge());
        return;
    }

    gg.audio_render = audio.renders();
    gg.step_frame(in.pad);
    rewind.record_frame(&gg, in.pad);
    const t2 = cart.micros_since_boot();

    audio.update(&gg);

    video.finish_frame();
    debug.record(@truncate(t2 -% t1));
    if (debug.enabled) romsrc.draw_report();
    debug.draw();
    // A press held over from the splash is suppressed, not fresh.
    const e = controls_state.edge;
    const fresh = (input.Edge{ .prev = e.prev, .cur = e.cur & ~controls_state.suppress }).any_pressed();
    play_hint.update_and_draw(cart, text.draw, fresh, cart.screen_height - hint.strip_h, menu.title_color, menu.band_color);
}

pub fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// Simulator shim, copied from Snouty Boy: upstream's wasm platform never
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
        @export(&debug_rom_banks, .{ .name = "debug_rom_banks" });
        @export(&debug_rom_crc, .{ .name = "debug_rom_crc" });
        @export(&debug_cram_rebuilds, .{ .name = "debug_cram_rebuilds" });
        @export(&debug_menu_opens, .{ .name = "debug_menu_opens" });
        @export(&debug_tone_hz, .{ .name = "debug_tone_hz" });
        @export(&debug_settings, .{ .name = "debug_settings" });
        @export(&debug_pc, .{ .name = "debug_pc" });
        @export(&debug_sp, .{ .name = "debug_sp" });
        @export(&debug_iff1, .{ .name = "debug_iff1" });
        @export(&debug_halted, .{ .name = "debug_halted" });
        @export(&debug_mapper, .{ .name = "debug_mapper" });
        @export(&debug_vdp_regs01, .{ .name = "debug_vdp_regs01" });
        @export(&debug_vdp_status, .{ .name = "debug_vdp_status" });
        @export(&debug_vdp_line, .{ .name = "debug_vdp_line" });
        @export(&debug_irq_frame, .{ .name = "debug_irq_frame" });
        @export(&debug_irq_line, .{ .name = "debug_irq_line" });
        @export(&debug_frame_t, .{ .name = "debug_frame_t" });
        @export(&debug_psg_voice, .{ .name = "debug_psg_voice" });
        @export(&debug_psg_atten, .{ .name = "debug_psg_atten" });
        @export(&debug_psg_tones, .{ .name = "debug_psg_tones" });
        @export(&debug_scrub_depth, .{ .name = "debug_scrub_depth" });
        @export(&debug_history, .{ .name = "debug_history" });
        @export(&debug_keyframes, .{ .name = "debug_keyframes" });
        @export(&debug_keyframe_cap, .{ .name = "debug_keyframe_cap" });
        @export(&debug_pool_bytes, .{ .name = "debug_pool_bytes" });
        @export(&debug_arena_bytes, .{ .name = "debug_arena_bytes" });
    }
}

/// Frames stepped since reset (`gg.frame_count`).
fn debug_frame_count() callconv(.c) u32 {
    return gg.frame_count;
}
/// Microseconds the last `step_frame` took.
fn debug_step_us() callconv(.c) u32 {
    return debug.last_step_us;
}
/// Lines the core emitted during the last frame (144).
fn debug_lines() callconv(.c) u32 {
    return video.last_frame_lines;
}
/// Frontend state: 0 splash, 1 running, 2 menu, 3 no ROM.
fn debug_state() callconv(.c) u32 {
    return @backingInt(state);
}
/// Pad byte the core was last stepped with (`core.Pad` bits).
fn debug_pad() callconv(.c) u32 {
    return gg.pad;
}
/// 0 embedded ROM, 1 drive file.
fn debug_rom_source() callconv(.c) u32 {
    return @backingInt(romsrc.origin);
}
/// ROM size in bytes.
fn debug_rom_size() callconv(.c) u32 {
    return gg.rom.size;
}
/// 16 KB banks in the ROM.
fn debug_rom_banks() callconv(.c) u32 {
    return gg.rom.bank_count;
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
    return menu_opens;
}
/// Frequency the buzzer was last told to play, 0 when stopped.
fn debug_tone_hz() callconv(.c) u32 {
    return if (audio.playing) audio.last_hz else 0;
}
/// Menu settings: bit 0 sound on, bit 1 crop scale, bit 2 A/B swapped,
/// bit 3 debug overlay on.
fn debug_settings() callconv(.c) u32 {
    var v: u32 = 0;
    if (menu.sound_enabled) v |= 1;
    if (video.scale == .crop) v |= 2;
    if (input.swap_ab) v |= 4;
    if (debug.enabled) v |= 8;
    return v;
}

// ---- Boot diagnostics: what a game that does not start is doing ----

/// Z80 program counter after the last frame.
fn debug_pc() callconv(.c) u32 {
    return gg.cpu.pc;
}
/// Z80 stack pointer.
fn debug_sp() callconv(.c) u32 {
    return gg.cpu.sp;
}
/// 1 when interrupts are enabled (IFF1).
fn debug_iff1() callconv(.c) u32 {
    return @intFromBool(gg.cpu.iff1);
}
/// 1 when the CPU sits in HALT.
fn debug_halted() callconv(.c) u32 {
    return @intFromBool(gg.cpu.halted);
}
/// Mapper as written: slot 0 | slot 1 << 8 | slot 2 << 16 | FFFC << 24.
fn debug_mapper() callconv(.c) u32 {
    const m = gg.mapper;
    return @as(u32, m.slot[0]) | @as(u32, m.slot[1]) << 8 | @as(u32, m.slot[2]) << 16 | @as(u32, m.control) << 24;
}
/// VDP register 0 | register 1 << 8 (register 1 bit 6 display on, bit 5
/// frame IRQ enable; register 0 bit 4 line IRQ enable).
fn debug_vdp_regs01() callconv(.c) u32 {
    return @as(u32, gg.vdp.regs[0]) | @as(u32, gg.vdp.regs[1]) << 8;
}
/// VDP status flags (bit 7 frame IRQ, 6 overflow, 5 collision) as they
/// stand, without the read side effects.
fn debug_vdp_status() callconv(.c) u32 {
    return gg.vdp.status;
}
/// VDP line (0..261) the frame ended on.
fn debug_vdp_line() callconv(.c) u32 {
    return gg.vdp.line;
}
/// Frame interrupts the CPU accepted since reset.
fn debug_irq_frame() callconv(.c) u32 {
    return gg.irq_frame_count;
}
/// Line interrupts the CPU accepted since reset.
fn debug_irq_line() callconv(.c) u32 {
    return gg.irq_line_count;
}
/// T-states the last frame ran (about 59,736).
fn debug_frame_t() callconv(.c) u32 {
    return gg.frame_t;
}
/// The PSG voice audio plays: hz | atten << 24 | channel << 28, 0 when
/// silent.
fn debug_psg_voice() callconv(.c) u32 {
    const v = gg.psg.voice() orelse return 0;
    return (v.hz & 0xFFFFFF) | @as(u32, v.atten) << 24 | @as(u32, v.channel) << 28;
}
/// PSG attenuations as written: ch0 | ch1 << 4 | ch2 << 8 | noise << 12
/// (15 = silent), then the noise control << 16 and the latch << 20.
fn debug_psg_atten() callconv(.c) u32 {
    const p = gg.psg;
    return @as(u32, p.atten[0]) | @as(u32, p.atten[1]) << 4 | @as(u32, p.atten[2]) << 8 | @as(u32, p.atten[3]) << 12 | @as(u32, p.noise) << 16 | @as(u32, p.latch) << 20;
}
/// PSG 10-bit tone periods: ch0 | ch1 << 10 | ch2 << 20.
fn debug_psg_tones() callconv(.c) u32 {
    const p = gg.psg;
    return @as(u32, p.tone[0]) | @as(u32, p.tone[1]) << 10 | @as(u32, p.tone[2]) << 20;
}

// ---- Time scrubber (frontend/rewind.zig) ----

/// Frames the game is parked behind live, 0 at live.
fn debug_scrub_depth() callconv(.c) u32 {
    return rewind.depth_frames();
}
/// Frames of history reachable from live.
fn debug_history() callconv(.c) u32 {
    return rewind.history_frames();
}
/// Keyframes held in the page store.
fn debug_keyframes() callconv(.c) u32 {
    return @intCast(rewind.keyframe_count());
}
/// Keyframes the store can hold at most (0: no room, scrubber off).
fn debug_keyframe_cap() callconv(.c) u32 {
    return @intCast(rewind.keyframe_capacity());
}
/// Pool bytes holding keyframe pages.
fn debug_pool_bytes() callconv(.c) u32 {
    return @intCast(rewind.pool_bytes());
}
/// Arena bytes the store was laid out in (72 KB static in wasm).
fn debug_arena_bytes() callconv(.c) u32 {
    return @intCast(rewind.arena_bytes());
}
