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
//! is created only once a file is chosen; otherwise the one drive file (or,
//! in the wasm and `-Drom-source=embed` builds, the embedded ROM) is chosen
//! at `start()`. The ROM's header picks the model (DMG, or CGB when 0x143 has
//! bit 7, SPEC.md 19) and the cart RAM size; `rewind.layout` then places the
//! console, that cart RAM and the keyframe store in the RAM above `.bss`.
//! `halted` is the refusal to run: no ROM on the drive (the badge build
//! embeds none), or fewer than 2 keyframes fit (frontend/rewind.zig).
//!
//! Control hints (lib/hint.zig): "Hold Select: menu" on the splash and in
//! a strip at the bottom for the first 3 s of play after the splash or the
//! picker (gone at the first fresh press); the menu has its own.
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
const flow = @import("frontend/flow.zig");
const hint = @import("hint");

comptime {
    cart.export_start_code();
}

/// The console, placed in the arena above `.bss` by `rewind.layout` (50 KB
/// that would otherwise ship as zeros in the UF2).
var gb: *core.Gb = undefined;
/// `gb` has been created (false while the picker is up).
var have_gb = false;

pub const State = flow.State;
/// Which screen is up and what it may see (frontend/flow.zig).
var fl: flow.Flow(Ctx) = .{};
var ctx: Ctx = .{};
/// "Hold Select: menu" over the first seconds of play (lib/hint.zig).
var play_hint: hint.Overlay = .{};

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    // DMG look for the splash and the picker; `begin` switches to the
    // chosen ROM's model.
    video.init(.dmg);
    romsrc.scan();
    if (romsrc.use_drive and romsrc.playable_count > 1) {
        fl.pick_after_splash = true;
    } else if (!begin(romsrc.choose_default())) {
        fl.state = .halted;
    }
}

/// Lay out cart RAM and the keyframe store for `rom`, then create the
/// console in the model its header asks for. False when there is no ROM
/// (`romsrc.missing`) or fewer than 2 keyframes fit (the halted screen
/// follows).
fn begin(rom: ?core.Rom) bool {
    const r = rom orelse return false;
    debug.source_letter = if (romsrc.info.source == .drive) 'D' else 'E';
    const model = core.default_model(&r);
    video.init(model);
    const l = rewind.layout(&r) orelse return false;
    gb = l.gb;
    gb.* = core.Gb.init(r, model, l.cart_ram);
    gb.line_sink = video.sink(gb);
    have_gb = true;
    rewind.reset(gb);
    return true;
}

pub fn update() void {
    // Timestamp every badge frame (paused or not) so the FPS counter sees
    // real frame intervals; `debug.record` measures only step_frame.
    debug.frame_tick(cart.micros_since_boot());

    // Sound follows the menu toggle; the tone holds while the core is paused
    // and stops at once when sound is switched off (audio.update handles it).
    audio.enabled = menu.sound_enabled;

    fl.update(&ctx, @bitCast(read_controls()));

    frames_seen +%= 1;
    if (cart.is_wasm) present_wasm();
}

/// The badge side of frontend/flow.zig: the splash, picker, console, menu
/// and halted screen it switches between.
const Ctx = struct {
    pub fn splash_frame(_: *Ctx, skip: bool) bool {
        if (splash.request_chime) {
            splash.request_chime = false;
            audio.chime(0);
            chime_second_at = frames_seen + 4;
        }
        if (chime_second_at != 0 and frames_seen == chime_second_at) {
            chime_second_at = 0;
            audio.chime(1);
        }
        return splash.update(skip);
    }

    /// Only a drive build gets a choice; the check keeps the picker and the
    /// drive code out of the wasm build.
    pub fn pick_frame(_: *Ctx, e: input.Edge) ?usize {
        return if (romsrc.use_drive) picker.update(e) else null;
    }

    pub fn begin_choice(_: *Ctx, choice: usize) bool {
        return if (romsrc.use_drive) begin(romsrc.select(choice)) else false;
    }

    /// The game starts after the splash or the picker (not after the menu).
    pub fn play_begin(_: *Ctx) void {
        play_hint.start(hint.play_seconds * 60);
    }

    /// One game frame; `fresh` is a press not held over from the last
    /// screen, which dismisses the play hint.
    pub fn step(_: *Ctx, pad: u8, fresh: bool) void {
        const t1 = cart.micros_since_boot();
        gb.step_frame(pad);
        const t2 = cart.micros_since_boot();
        rewind.record_frame(gb, pad);

        audio.update(gb);

        video.finish_frame();
        debug.record(@truncate(t2 -% t1));
        debug.draw();
        play_hint.update_and_draw(cart, null, fresh, cart.screen_height - hint.strip_h, video.shade_color(0), video.shade_color(3));
    }

    pub fn menu_open(_: *Ctx) void {
        play_hint.stop();
        menu.open();
    }

    pub fn menu_frame(_: *Ctx, e: input.Edge) flow.MenuResult {
        audio.update(gb);
        return switch (menu.update(gb, e)) {
            .stay => .stay,
            .resume_game => .resume_game,
        };
    }

    pub fn menu_close(_: *Ctx) void {
        menu.close();
    }

    pub fn halted_frame(_: *Ctx) void {
        draw_halted();
    }
};

/// No ROM on the drive: say what to do, with the reason dimmed below (the
/// badge build embeds no ROM, so there is nothing else to run). Otherwise
/// fewer than 2 keyframes fit next to this ROM: say so instead of running a
/// game the scrubber cannot rewind (PLAN.md M5, M8). Only a ROM embedded in
/// a RAM build can get there (build it with -Dcart-mode=xip).
fn draw_halted() void {
    video.blank(0);
    const ink = video.shade_color(3);
    if (romsrc.missing) |why| {
        const lines = [_][]const u8{ "SNOUTY BOY", "", "No ROM on the badge", "drive.", "", "Copy a .gb or .gbc", "file to the drive,", "eject, then restart", "this cart.", "", "", "Start+Select: exit" };
        for (lines, 0..) |l, i| cart.text(.{ .str = l, .x = 4, .y = 4 + @as(i32, @intCast(i)) * 10, .text_color = ink });
        const dim = video.shade_color(2);
        cart.text(.{ .str = "Why:", .x = 4, .y = 94, .text_color = dim });
        cart.text(.{ .str = why[0..@min(why.len, 14)], .x = 44, .y = 94, .text_color = dim });
        return;
    }
    const lines = [_][]const u8{ "SNOUTY BOY", "", "Not enough RAM for", "the time scrubber", "with this ROM.", "", "Start+Select: exit" };
    for (lines, 0..) |l, i| cart.text(.{ .str = l, .x = 4, .y = 24 + @as(i32, @intCast(i)) * 10, .text_color = ink });
}

/// Badge frames since boot; paces the second chime note.
var frames_seen: u32 = 0;
var chime_second_at: u32 = 0;

comptime {
    // input.Controls mirrors cart.Controls bit for bit.
    if (@bitSizeOf(input.Controls) != @bitSizeOf(cart.Controls)) @compileError("Controls size");
    for (@typeInfo(cart.Controls).@"struct".field_names) |name| {
        if (@bitOffsetOf(input.Controls, name) != @bitOffsetOf(cart.Controls, name)) @compileError("Controls layout: " ++ name);
    }
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
        @export(&debug_tone_hz, .{ .name = "debug_tone_hz" });
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
    return @backingInt(fl.state);
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
/// What the buzzer was last told to play, in Hz; 0 when stopped.
fn debug_tone_hz() callconv(.c) u32 {
    return if (audio.playing) audio.last_hz else 0;
}
