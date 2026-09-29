//! Snouty Boy: Game Boy emulator cart. Runs the core one frame per badge
//! frame and shows its lines through frontend/video.zig, with the debug
//! overlay (frontend/debug.zig) on top.
//!
//! States: splash (frontend/splash.zig) -> [pick] -> running -> menu
//! (frontend/menu.zig, opened by a 500 ms Select hold, frontend/input.zig)
//! -> running. The core is stepped only while running.
//!
//! The ROM (frontend/romsrc.zig, SPEC.md 11.1): on the badge `start()` looks
//! at the drive first. With more than one playable `.gb`/`.gbc` file there
//! the `pick` state (frontend/picker.zig) follows the splash and the console
//! is created only once a file is chosen; otherwise the one drive file or
//! the embedded ROM is chosen at `start()`. The ROM's header picks the
//! model (DMG, or CGB when 0x143 has bit 7, SPEC.md 19) and the cart RAM
//! size; `rewind.layout` then places the console, that cart RAM and the
//! keyframe store in the RAM above `.bss`. `halted` is the refusal to run when fewer than 2
//! keyframes fit there (frontend/rewind.zig).
//! See SPEC.md (design), PLAN.md (milestone contract), CLAUDE.md (toolchain).
const cart = @import("cart-api");
const core = @import("core");
const video = @import("frontend/video.zig");
const input = @import("frontend/input.zig");
const debug = @import("frontend/debug.zig");
const menu = @import("frontend/menu.zig");
const splash = @import("frontend/splash.zig");
const audio = @import("frontend/audio.zig");
const rewind = @import("frontend/rewind.zig");
const romsrc = @import("frontend/romsrc.zig");
const picker = @import("frontend/picker.zig");

comptime {
    cart.export_start_code();
}

/// The console, placed in the arena above `.bss` by `rewind.layout` (50 KB
/// that would otherwise ship as zeros in the UF2).
var gb: *core.Gb = undefined;
/// `gb` has been created (false while the picker is up).
var have_gb = false;

pub const State = enum(u32) { splash = 0, running = 1, menu = 2, pick = 3, halted = 4 };
var state: State = .splash;
var controls_state: input.State = .{};
/// Leave the splash for the picker instead of the game.
var pick_after_splash = false;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    // DMG look for the splash and the picker; `begin` switches to the
    // chosen ROM's model.
    video.init(.dmg);
    romsrc.scan();
    if (romsrc.use_drive and romsrc.playable_count > 1) {
        pick_after_splash = true;
    } else {
        begin(romsrc.choose_default());
    }
}

/// Lay out cart RAM and the keyframe store for `r`, then create the
/// console in the model its header asks for.
fn begin(r: core.Rom) void {
    debug.source_letter = if (romsrc.info.source == .drive) 'D' else 'E';
    const model = core.default_model(&r);
    video.init(model);
    const l = rewind.layout(&r) orelse {
        state = .halted;
        return;
    };
    gb = l.gb;
    gb.* = core.Gb.init(r, model, l.cart_ram);
    gb.line_sink = video.sink(gb);
    have_gb = true;
    rewind.reset(gb);
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
                if (romsrc.use_drive and pick_after_splash) {
                    state = .pick;
                    pick_frame();
                } else {
                    state = .running;
                    run_frame(t0);
                }
            }
        },
        // Only a drive build can get here; the check keeps the picker and
        // the drive code out of the wasm build.
        .pick => if (romsrc.use_drive) pick_frame(),
        .halted => draw_halted(),
        .running => run_frame(t0),
        .menu => {
            audio.update(gb);
            if (menu.update(gb, controls_state.edge) == .resume_game) {
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

/// One picker frame; on a choice, create the console and start the game in
/// the same frame.
fn pick_frame() void {
    const choice = picker.update(controls_state.edge) orelse return;
    begin(if (choice) |i| romsrc.select(i) else romsrc.embedded("skipped"));
    controls_state.suppress_held();
    if (state == .halted) return;
    state = .running;
    run_frame(cart.micros_since_boot());
}

/// Fewer than 2 keyframes fit next to this ROM: say so instead of running a
/// game the scrubber cannot rewind (PLAN.md M5, M8). Only a ROM embedded
/// in a RAM build can get here (build it with -Dcart-mode=xip).
fn draw_halted() void {
    video.blank(0);
    const ink = video.shade_color(3);
    const lines = [_][]const u8{ "SNOUTY BOY", "", "Not enough RAM for", "the time scrubber", "with this ROM.", "", "Start+Select: exit" };
    for (lines, 0..) |l, i| cart.text(.{ .str = l, .x = 4, .y = 24 + @as(i32, @intCast(i)) * 10, .text_color = ink });
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
        _ = menu.update(gb, controls_state.edge);
        return;
    }

    gb.step_frame(in.pad);
    const t2 = cart.micros_since_boot();
    rewind.record_frame(gb, in.pad);

    audio.update(gb);

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
// debug_step_us reads 1000 there and means nothing. Exports that read `gb`
// return 0 until it exists (the picker is up).
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
        @export(&debug_rom_source, .{ .name = "debug_rom_source" });
        @export(&debug_rom_size, .{ .name = "debug_rom_size" });
        @export(&debug_rom_crc, .{ .name = "debug_rom_crc" });
        @export(&debug_slots, .{ .name = "debug_slots" });
        @export(&debug_arena_bytes, .{ .name = "debug_arena_bytes" });
    }
}

/// Frames stepped since reset (`gb.frame_count`).
fn debug_frame_count() callconv(.c) u32 {
    return if (have_gb) gb.frame_count else 0;
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
/// Frontend state: 0 splash, 1 running, 2 menu, 3 pick, 4 halted.
fn debug_state() callconv(.c) u32 {
    return @backingInt(state);
}
/// Pad byte the game was last stepped with (`core.Pad` bits; Select = 64).
fn debug_pad() callconv(.c) u32 {
    return if (have_gb) gb.pad else 0;
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
/// 1 when the console runs in CGB mode (0 while picking).
fn debug_cgb() callconv(.c) u32 {
    return @intFromBool(have_gb and gb.is_cgb());
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
/// Where the running ROM came from: 0 embedded, 1 drive.
fn debug_rom_source() callconv(.c) u32 {
    return @backingInt(romsrc.info.source);
}
/// Bytes in the running ROM image (0 while picking).
fn debug_rom_size() callconv(.c) u32 {
    return romsrc.info.size;
}
/// CRC32 of the running ROM image (as on the About screen).
fn debug_rom_crc() callconv(.c) u32 {
    return romsrc.info.crc;
}
/// Keyframes the store can hold at most for this ROM (0 while picking).
fn debug_slots() callconv(.c) u32 {
    return @intCast(rewind.keyframe_capacity());
}
/// Bytes of the arena holding cart RAM and the keyframe store.
fn debug_arena_bytes() callconv(.c) u32 {
    return @intCast(rewind.arena_bytes());
}
