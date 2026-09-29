//! Snouty Gear: Game Gear emulator cart. Runs the core one frame per badge
//! frame and shows its lines through frontend/video.zig, with the debug
//! overlay (frontend/debug.zig) on top and, while the overlay is on, the
//! ROM report line (frontend/romsrc.zig) at the bottom.
//!
//! States: splash (frontend/splash.zig) -> running -> menu
//! (frontend/menu.zig, opened by a 500 ms Select hold, frontend/input.zig)
//! -> running. The core is stepped only while running. Sound is one tone2
//! voice from the PSG (frontend/audio.zig). The time scrubber is M3.
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

comptime {
    cart.export_start_code();
}

/// The console (~33 KB), a static initialised in place: never build it on
/// the stack (32 KB on the badge, 14.7 KB in wasm).
var gg: core.Gg = undefined;

pub const State = enum(u32) { splash = 0, running = 1, menu = 2 };
var state: State = .splash;
var controls_state: input.State = .{};

/// Menu opens since boot.
var menu_opens: u32 = 0;

/// Badge frames since boot; paces the second chime note.
var frames_seen: u32 = 0;
var chime_second_at: u32 = 0;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    text.init();
    video.init();
    gg.init_in_place(romsrc.select());
    gg.line_sink = video.sink();
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
            audio.update(&gg);
            if (menu.update(&gg, controls_state.edge) == .resume_game) {
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

/// One game frame, or opening the menu instead of stepping. `t1` is a fresh
/// `micros_since_boot` reading taken just before.
fn run_frame(t1: u64) void {
    const in = controls_state.game_frame();
    if (in.open_menu) {
        menu_opens += 1;
        state = .menu;
        menu.open();
        _ = menu.update(&gg, controls_state.edge);
        return;
    }

    gg.step_frame(in.pad);
    const t2 = cart.micros_since_boot();

    audio.update(&gg);

    video.finish_frame();
    debug.record(@truncate(t2 -% t1));
    if (debug.enabled) romsrc.draw_report();
    debug.draw();
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
/// Frontend state: 0 splash, 1 running, 2 menu.
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
