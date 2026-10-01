//! Snouty Genesis: Sega Genesis emulator cart (XIP only, SPEC.md section
//! 13). Each update runs `tunables.render_every` Genesis frames (two: the
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
//! known (`have_md`).
const cart = @import("cart-api");
const core = @import("core");
const video = @import("frontend/video.zig");
const input = @import("frontend/input.zig");
const audio = @import("frontend/audio.zig");
const debug = @import("frontend/debug.zig");
const romsrc = @import("frontend/romsrc.zig");
const text = @import("frontend/text.zig");
const menu = @import("frontend/menu.zig");
const splash = @import("frontend/splash.zig");
const picker = @import("frontend/picker.zig");
const help = @import("frontend/help.zig");
const rewind = @import("frontend/rewind.zig");

comptime {
    cart.export_start_code();
}

/// The console (~137 KB), a static initialised in place: never build it on
/// the stack (32 KB on the badge, 14.7 KB in wasm).
var md: core.Md = undefined;

/// Genesis frames per update; only the last is rendered.
const frames_per_update = core.tunables.render_every;

/// 0 splash, 1 running, 2 menu, 3 pick (drive picker), 4 help (no ROM on
/// the drive). `pick` and `help` only happen in drive builds.
pub const State = enum(u32) { splash = 0, running = 1, menu = 2, pick = 3, help = 4 };
var state: State = .splash;
/// Where the splash leads: `running` (the ROM was chosen in `start`),
/// `pick` or `help`.
var after_splash: State = .running;
/// `md` has been initialised by `begin`; nothing reads it before.
var have_md = false;
var controls_state: input.State = .{};

/// Menu opens since boot.
var menu_opens: u32 = 0;

pub fn start() void {
    // Presents at 60 / render_every Hz (30 by default).
    cart.set_vsync_enabled(1000.0 * @as(f32, frames_per_update) / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    text.init();
    video.init();
    debug.frames_per_update = frames_per_update;
    // False when the arena has no room: the game runs untracked and the
    // menu reads "Scrub: no memory".
    _ = rewind.init();
    romsrc.scan();
    choose_rom();
}

/// The ROM decision of PLAN.md "Frontend states": the embedded ROM when the
/// drive is not used or has no volume, the one playable drive file, the
/// picker for several, the help screen for none.
fn choose_rom() void {
    if (!romsrc.use_drive) return begin(romsrc.embedded(null));
    const s = &romsrc.scan_result;
    if (s.err) |e| return begin(romsrc.embedded(@errorName(e)));
    if (s.playable_count == 1) return begin(romsrc.select(s.first_playable().?));
    if (s.playable_count > 1) {
        picker.reset();
        after_splash = .pick;
    } else {
        after_splash = .help;
    }
}

/// Create the console for `src`. Called once the ROM is known: in `start`,
/// or when the picker or the help screen is left.
fn begin(src: core.RomSource) void {
    md.init_in_place(src);
    md.line_sink = video.sink();
    video.apply(&md);
    have_md = true;
    rewind.reset(&md);
}

pub fn update() void {
    controls_state.poll(read_controls());
    const t0 = cart.micros_since_boot();
    debug.frame_tick(t0);
    switch (state) {
        .splash => splash_update(t0),
        .running => run_update(t0),
        .menu => menu_update(),
        // Only a drive build gets here; the check keeps the picker and the
        // help screen out of the wasm and embed builds.
        .pick => if (romsrc.use_drive) pick_update(t0),
        .help => if (romsrc.use_drive) help_update(t0),
    }
    if (cart.is_wasm) present_wasm();
}

/// One splash update (frontend/splash.zig); any button skips it. When it
/// ends, `after_splash` starts in the same update.
fn splash_update(t0: u64) void {
    if (splash.update(controls_state.edge.any_pressed())) leave_splash(t0);
}

/// Enter `after_splash` and run its first update now, with the buttons that
/// skipped the splash ignored until released.
fn leave_splash(t0: u64) void {
    controls_state.suppress_held();
    state = after_splash;
    switch (state) {
        .running => run_update(t0),
        .pick => if (romsrc.use_drive) pick_update(t0),
        .help => if (romsrc.use_drive) help_update(t0),
        else => {},
    }
}

/// The edge with suppressed (held-over) buttons masked out, so a button
/// that left the previous state does not act in the next.
fn live_edge() input.Edge {
    const e = controls_state.edge;
    return .{ .prev = e.prev, .cur = e.cur & ~controls_state.suppress };
}

/// One picker update (drive builds). On a choice start that ROM (or the
/// embedded one for B) and run its first frames in the same update.
fn pick_update(t0: u64) void {
    const choice = picker.update(live_edge()) orelse return;
    begin(if (choice) |i| romsrc.select(i) else romsrc.embedded("skipped"));
    start_running(t0);
}

/// One help-screen update (drive builds); A or B runs the embedded ROM.
fn help_update(t0: u64) void {
    if (!help.update(live_edge())) return;
    begin(romsrc.embedded("no ROM on the drive"));
    start_running(t0);
}

fn start_running(t0: u64) void {
    controls_state.suppress_held();
    state = .running;
    run_update(t0);
}

fn run_update(t1: u64) void {
    const in = controls_state.game_frame();
    if (in.open_menu) {
        menu_opens += 1;
        state = .menu;
        audio.silence();
        // A Left/Right held over from the game must not scrub.
        controls_state.suppress_held();
        menu.open();
        _ = menu.update(&md, live_edge());
        return;
    }

    // After a scrub the console is parked on a record boundary: playing on
    // drops the records ahead.
    rewind.resume_if_parked(&md);
    var f: u8 = 1;
    while (f <= frames_per_update) : (f += 1) {
        md.step_frame(in.pad, f == frames_per_update);
        rewind.record_frame(&md);
    }
    // The drive ROM's CRC32, 8 KB per update (a no-op once known).
    romsrc.crc_tick();
    const t2 = cart.micros_since_boot();

    audio.update(&md);
    video.finish_frame();
    debug.record(@truncate(t2 -% t1));
    if (debug.enabled) romsrc.draw_report();
    debug.z80_state = debug.z80_label(&md);
    debug.draw();
}

/// One menu update over the frozen frame; the core is not stepped.
fn menu_update() void {
    audio.silence();
    switch (menu.update(&md, live_edge())) {
        .stay => {},
        .resume_game => {
            menu.close();
            controls_state.suppress_held();
            video.apply(&md); // a Scale change, Reset's squeeze, a scrub
            state = .running;
            run_update(cart.micros_since_boot());
        },
        .pick_rom => {
            menu.close();
            controls_state.suppress_held();
            audio.silence();
            picker.reset();
            state = .pick;
        },
    }
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
    }
}

/// Genesis frames stepped since reset (`md.frame_count`; two per update).
fn debug_frame_count() callconv(.c) u32 {
    if (!have_md) return 0;
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
/// Frontend state: 0 splash, 1 running, 2 menu, 3 picker, 4 no-ROM help.
fn debug_state() callconv(.c) u32 {
    return @backingInt(state);
}
/// Pad word the core was last stepped with (`core.Pad` bits).
fn debug_pad() callconv(.c) u32 {
    if (!have_md) return 0;
    return md.pad;
}
/// 0 none, 1 embedded, 2 drive contiguous, 3 drive fragmented.
fn debug_rom_source() callconv(.c) u32 {
    return @backingInt(romsrc.origin);
}
/// ROM size in bytes.
fn debug_rom_size() callconv(.c) u32 {
    if (!have_md) return 0;
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
/// Times the menu opened since boot.
fn debug_menu_opens() callconv(.c) u32 {
    return menu_opens;
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
    if (!have_md) return 0;
    return md.cpu.pc;
}
/// 68000 active stack pointer (A7).
fn debug_sp() callconv(.c) u32 {
    if (!have_md) return 0;
    return md.cpu.a[7];
}
/// 68000 status register.
fn debug_sr() callconv(.c) u32 {
    if (!have_md) return 0;
    return md.cpu.get_sr();
}
/// VDP line (0..261) the frame ended on.
fn debug_vdp_line() callconv(.c) u32 {
    if (!have_md) return 0;
    return md.vdp.line;
}
/// Z80 program counter.
fn debug_z80_pc() callconv(.c) u32 {
    if (!have_md) return 0;
    return md.z80.pc;
}
/// Frequency the buzzer plays (0 when silent).
fn debug_tone_hz() callconv(.c) u32 {
    return audio.playing_hz();
}
/// Z80 arbiter: bit 0 BUSREQ held by the 68000, bit 1 Z80 in reset, bit 2
/// Z80 switched off (`tunables.z80_enabled` false).
fn debug_z80_state() callconv(.c) u32 {
    if (!have_md) return 0;
    var v: u32 = 0;
    if (md.arbiter.busreq) v |= 1;
    if (md.arbiter.z80_reset) v |= 2;
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
