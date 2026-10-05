//! Snouty Lynx: Atari Lynx emulator cart (M5: sound). The Iris-mark
//! splash (frontend/splash.zig), then the game: the core steps 1/60 s of
//! Lynx time per update and its last completed frame goes to rows 0..101,
//! the 26-row status strip below it (SPEC.md section 6) has the title and
//! the ROM name, then the ROM origin or, with the debug overlay on
//! (frontend/debug.zig, a menu row, off at boot), fps, mean/worst step
//! microseconds, instructions and Suzy pixels per frame.
//!
//! States (PLAN.md "M2 Frontend"): splash -> running | pick | help,
//! running <-> menu, menu -> pick -> running | help. After the splash the
//! embedded ROM (wasm, `-Dlynx-rom-source=embed`) or the one playable drive
//! file runs at once; several playable files open the picker
//! (frontend/picker.zig; B keeps the first); a drive build (it embeds no
//! ROM) without a usable one (no volume, no playable file, a file that no
//! longer maps) shows the no-ROM screen and stays there (help; the OS menu
//! leaves the cart). A 500 ms Select hold opens the menu (frontend/menu.zig)
//! over the frozen frame; the core is not stepped while the menu or the
//! picker is up. Choosing a file in the picker restarts the core on it
//! (`romsrc.open`, `Lynx.init_in_place`).
//!
//! Time scrubber (M3, SPEC.md section 10, PLAN.md "M3 Scrub"):
//! frontend/rewind.zig over core/undo.zig keeps an undo record every 30
//! frames in the RAM the linker leaves free; in the menu Left/Right swap
//! through them, and playing on from a scrubbed position drops the future.
//! Every boot (start, a picker choice, the menu's Reset) forgets the
//! history.
//!
//! Fast forward (docs/FAST_FORWARD.md at the root): while the second
//! press of a Select double tap is held (frontend/input.zig), each update
//! spans `tuning.ff_periods` badge frames (a Lynx frame is too dear for
//! two in one) and steps up to `tuning.ff_max_frames` game frames per
//! period within `tuning.ff_budget_us`, only the last one shown (the
//! others skip the display conversion, `video.show`, and the strip), none
//! with sound (`audio_render` off, the stream ramps out as in the menu),
//! every one recorded for the scrubber; the speed (`>>2x`, `>>1.5x`) sits
//! in the picture's top right corner meanwhile. Left during that hold
//! turns it into the chorded rewind (`input.Rewind`): the game freezes
//! under the menu's scrub bar (`menu.draw_scrub_bar`), Left/Right step
//! time through `rewind.step` as in the menu, and letting go of Select
//! resumes from there as the menu's resume does.
//!
//! Control hints (lib/hint.zig): "Hold Select: menu" on the splash and
//! over the status strip's last line for the first 3 s of play after the
//! splash or the picker, then "2x Sel+hold: fast" and "then Left: rewind"
//! for 3 s each (gone at the first fresh press); the menu has its own.
//!
//! Sound (M5, PLAN.md "M5 Sound: contract"): every stepped frame's
//! `audio_out` goes to the new firmware's streaming ring
//! (frontend/audio.zig over lib/stream_audio.zig); an update that steps
//! nothing (splash, menu, scrub, picker) ramps it out. The menu's Sound
//! row (off at boot as in every cart, `-Dsound=true` starts it on; not in
//! the wasm build, the simulator has no streaming audio) toggles it. The neopixels are never written
//! (docs/NEOPIXELS.md). SPEC.md is the design, PLAN.md the milestone
//! contract, CLAUDE.md the conventions.
const cart = @import("cart-api");
const core = @import("core");
const video = @import("frontend/video.zig");
const input = @import("frontend/input.zig");
const debug = @import("frontend/debug.zig");
const romsrc = @import("frontend/romsrc.zig");
const text = @import("frontend/text.zig");
const menu = @import("frontend/menu.zig");
const splash = @import("frontend/splash.zig");
const picker = @import("frontend/picker.zig");
const strip = @import("frontend/strip.zig");
const rewind = @import("frontend/rewind.zig");
const cable = @import("frontend/cable.zig");
const cable_screen = @import("frontend/cable_screen.zig");
const audio = @import("frontend/audio.zig");
const tuning = @import("frontend/tuning.zig");
const hint = @import("hint");

comptime {
    cart.export_start_code();
}

/// The console (~66 KB), a static initialised in place: never build it on
/// the stack (32 KB on the badge, 14.7 KB in wasm).
var lynx: core.Lynx = undefined;

/// 0 splash, 1 running, 2 menu, 3 pick (drive picker), 4 help (no usable
/// ROM on the drive: the no-ROM screen, the core is never stepped), 5 the
/// LINK screen (frontend/cable_screen.zig, from the menu). `pick` and
/// `help` only happen in drive builds.
pub const State = enum(u32) { splash = 0, running = 1, menu = 2, pick = 3, help = 4, cable = 5 };
var state: State = .splash;
/// Where the splash leads (`romsrc.select`'s choice).
var after_splash: State = .running;
var controls_state: input.State = .{};

/// Menu opens since boot.
var menu_opens: u32 = 0;
/// "Hold Select: menu", then `menu.fast_hint` and `menu.rewind_hint`, over
/// the status strip's last line for the first seconds of play
/// (lib/hint.zig): `hint.play_seconds` each.
var play_hint: hint.Overlay = .{};
const play_hint_updates = hint.play_seconds * 60;
/// The core stepped in this update with sound (else the sound ramps out).
var stepped: bool = false;
/// Game frames the last update stepped: 1 at 1x, up to `ff_cap` while
/// fast forwarding (the `>>2x` indicator and the `debug_ff_frames` export).
var frames_stepped: u32 = 0;
/// Microseconds the last shown game frame took (step and record): the
/// first estimate of a frame's cost in the next fast-forward update.
var last_frame_us: u64 = 0;
/// Badge frames a fast-forward update spans: `tuning.ff_periods` on the
/// badge; 1 in the simulator, which has no clock to fill them by (it runs
/// `tuning.ff_max_frames` every update, 4x).
const ff_periods = if (cart.is_wasm) 1 else tuning.ff_periods;
/// Game frames at most in one fast-forward update.
const ff_cap = tuning.ff_max_frames * ff_periods;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    text.init();
    // The arena does not depend on the ROM; false = "Scrub: no memory".
    _ = rewind.init();
    // The boot (core/boot.zig, no boot ROM) runs inside `init_in_place`:
    // the ROM is only known here, after the drive scan. With several drive
    // files the first playable one boots now and the picker may replace it.
    const sel = romsrc.select();
    boot(sel.cart);
    after_splash = switch (sel.next) {
        .run => .running,
        .pick => .pick,
        .help => .help,
    };
}

pub fn update() void {
    controls_state.poll(read_controls());
    const t0 = cart.micros_since_boot();
    debug.frame_tick(t0);
    stepped = false;

    switch (state) {
        .splash => if (splash.update(controls_state.edge.any_pressed())) {
            if (after_splash == .pick) picker.reset() else play_hint.start(3 * play_hint_updates);
            picker.from_menu = false;
            enter(after_splash, t0);
        },
        .running => run_frame(t0),
        .help => draw_help(),
        .menu => menu_frame(),
        .cable => cable_frame(t0),
        // Only a drive build gets here; the check keeps the picker out of
        // the wasm and embed builds.
        .pick => if (romsrc.use_drive) pick_frame(t0),
    }
    // The game stopped (menu, scrub, picker): one ramp to silence.
    if (!stepped) audio.stop();
    // Linked: answer the cable until late in the update (frontend/cable.zig).
    cable.pump(&lynx, t0);

    if (cart.is_wasm) present_wasm();
}

/// Switch to `next` with every held button ignored until released, and run
/// its first frame in this update.
fn enter(next: State, t0: u64) void {
    controls_state.suppress_held();
    state = next;
    switch (next) {
        .running => run_frame(t0),
        .help => draw_help(),
        .pick => if (romsrc.use_drive) pick_frame(t0),
        .splash, .menu, .cable => {},
    }
}

/// The edge with suppressed (held-over) buttons masked out, so a button
/// that left the previous state does not act in the next.
fn live_edge() input.Edge {
    return controls_state.live_edge();
}

/// (Re)start the core on `c` (start and the picker; the menu's Reset makes
/// the same call) and forget the scrub history: the boot writes RAM past
/// the undo hooks. The boot is one out-of-line call for every site so the
/// boot code (core/boot.zig, ~2 KB once inlined) is not copied into each.
pub fn boot(c: core.Cart) void {
    @call(.never_inline, core.Lynx.init_in_place, .{ &lynx, c });
    rewind.reset(&lynx);
    cable.after_boot(&lynx);
}

/// One picker update (drive builds). A choice restarts the core on that
/// file; B keeps the cart that runs.
fn pick_frame(t0: u64) void {
    const choice = picker.update(live_edge()) orelse return;
    if (choice) |i| boot(romsrc.open(i) orelse return enter(.help, t0));
    play_hint.start(3 * play_hint_updates);
    enter(.running, t0);
}

/// One menu update over the frozen frame; the core is not stepped.
fn menu_frame() void {
    switch (menu.update(&lynx, live_edge())) {
        .stay => {},
        .resume_game => {
            menu.close();
            enter(.running, cart.micros_since_boot());
        },
        .pick_rom => {
            // Another ROM is another game: off the link first.
            cable.close(&lynx);
            menu.close();
            picker.reset();
            picker.from_menu = true;
            enter(.pick, cart.micros_since_boot());
        },
        .link_cable => {
            cable_screen.enter();
            menu.close();
            enter(.cable, cart.micros_since_boot());
        },
    }
    // Linked, the game runs on behind the menu (the other console does
    // not wait).
    if (state == .menu and cable.linked) linked_background_frame();
}

/// The LINK screen: B goes back to the menu; GO restarts the game linked.
noinline fn cable_frame(t0: u64) void {
    switch (cable_screen.update(&lynx, live_edge())) {
        .stay => {},
        .back => {
            state = .menu;
            menu.open();
            _ = menu.update(&lynx, live_edge());
        },
        .started => enter(.running, t0),
    }
}

/// One game frame behind the menu while linked (no input, not shown).
noinline fn linked_background_frame() void {
    _ = cable.before_frame(&lynx);
    step(0);
    cable.after_frame(&lynx);
}

fn run_frame(t1: u64) void {
    frames_stepped = 0;
    const in = controls_state.game_frame();
    if (in.open_menu) {
        play_hint.stop();
        menu_opens +%= 1;
        // Held buttons (the d-pad, A) must not act in the menu.
        controls_state.suppress_held();
        state = .menu;
        menu.open();
        _ = menu.update(&lynx, live_edge());
        return;
    }

    // Chorded rewind (Left during fast forward): the game stays frozen
    // under the menu's scrub bar and Left/Right step time as in the menu;
    // letting go of Select resumes as the menu does (input.zig suppressed
    // the held buttons) and steps this frame. Nothing is stepped
    // meanwhile, so `update` ramps the sound out (`stepped` stays false).
    // Linked (ComLynx on the link cable, frontend/cable.zig): no fast
    // forward and no chorded rewind, the other console would fall behind.
    const fast = in.fast and !cable.linked;
    const rewind_phase: input.Rewind = if (cable.linked) .off else in.rewind;

    switch (rewind_phase) {
        .enter, .on => {
            if (rewind_phase == .enter) {
                play_hint.stop();
                menu.freeze_frame();
                // The last presented frame carries the `>>` indicator:
                // redraw the picture and the strip without it.
                video.show(lynx.frame());
                strip.draw(&lynx);
                cart.mark_dirty_rect(0, 0, cart.screen_width, cart.screen_height);
            }
            rewinding = true;
            if (in.scrub != 0) _ = rewind.step(&lynx, in.scrub);
            menu.draw_scrub_bar(true);
            return;
        },
        .exit => {
            rewinding = false;
            menu.close();
        },
        .off => {},
    }

    // After a scrub the console is parked on a record boundary: playing on
    // from there drops the future.
    rewind.resume_if_parked(&lynx);

    // Fast forward: the frames before the last one are not shown (no
    // display conversion, no strip) and none renders sound; the console
    // steps exactly as at 1x (tests/ff_determinism.zig).
    var n: u32 = 1;
    _ = cable.before_frame(&lynx);
    if (fast) {
        lynx.audio_render = false;
        var slowest: u64 = last_frame_us;
        var t = t1;
        while (n < ff_cap) : (n += 1) {
            if (!cart.is_wasm and t -% t1 + 2 * slowest > tuning.ff_budget_us) break;
            step(in.pad);
            const now = cart.micros_since_boot();
            slowest = @max(slowest, now -% t);
            t = now;
        }
    } else {
        // Sound off (or wasm): the core may skip filling `audio_out`. Set
        // every frame: a boot (`init_in_place`) turns it back on.
        lynx.audio_render = audio.enabled;
    }
    frames_stepped = n;

    const t_last = cart.micros_since_boot();
    step(in.pad);
    cable.after_frame(&lynx);
    const t2 = cart.micros_since_boot();
    last_frame_us = t2 -% t_last;
    debug.record(@truncate(t2 -% t1));
    // While fast the stream ramps out (as in the menu) and resumes, primed,
    // on the first 1x frame.
    if (!fast) {
        audio.frame(&lynx);
        stepped = true;
    }

    video.show(lynx.frame());
    strip.draw(&lynx);
    if (fast) draw_fast(n);
    // Over the strip's last line (the ROM detail), so no picture is hidden.
    // A press held over from the splash or picker is suppressed, not fresh.
    if (play_hint.tick(live_edge().any_pressed())) {
        const s = if (play_hint.left >= 2 * play_hint_updates) hint.hold_select else if (play_hint.left >= play_hint_updates) menu.fast_hint else menu.rewind_hint;
        hint.draw_strip(cart, text.draw, s, cart.screen_height - hint.strip_h, strip.accent, strip.bg);
    } else if (cable.note_left > 0) {
        // "Link cable: linked", "Partner left link", "Link cable out".
        cable.note_left -= 1;
        hint.draw_strip(cart, text.draw, cable.note, cart.screen_height - hint.strip_h, strip.accent, strip.bg);
    }
}

/// The chorded rewind is showing (the `debug_chord_rewind` export).
var rewinding: bool = false;

/// One game frame with `pad` (plus a menu row's held buttons for their
/// frames), recorded for the scrubber and the overlay.
fn step(pad: u16) void {
    var p = pad;
    if (menu.hold_frames_left > 0) {
        menu.hold_frames_left -= 1;
        p |= menu.hold_pad;
    }
    if (cable.linked) cable.step_frame(&lynx, p) else lynx.step_frame(p);
    rewind.record_frame(&lynx);
    debug.record_core(lynx.instr_count(), lynx.pixels_drawn());
}

/// The speed, `n` frames over `ff_periods` badge frames (`>>2x`,
/// `>>1.5x`), in the picture's top right corner, rows 0..7: the debug
/// overlay and the play hint are in the status strip below the picture.
/// The game redraws the whole screen every update (`.no_copy_full_frame`),
/// so it is gone the update fast forward stops; `text.draw` marks its own
/// dirty rect.
fn draw_fast(n: u32) void {
    comptime {
        if (ff_periods > 2 or ff_cap > 9 * ff_periods) @compileError("the indicator shows one digit and halves");
    }
    var buf: [6]u8 = undefined;
    var k = debug.put(&buf, ">>");
    k += debug.put_num(buf[k..3], n / ff_periods);
    if (n % ff_periods != 0) k += debug.put(buf[k..], ".5");
    k += debug.put(buf[k..], "x");
    text.draw(buf[0..k], @intCast(cart.screen_width - 8 * k), video.top, strip.accent, strip.bg);
}

/// The no-ROM screen (drive builds): how to add a ROM, then why the drive
/// gave none ("drive: NoVolume", "drive: X.LNX: rotated"), word-wrapped to
/// the screen width, in the status strip's colours on black. Redrawn every
/// update (the buffers swap); no key leaves it.
fn draw_help() void {
    const lines = [_][]const u8{ "No Lynx ROM on the", "badge drive.", "", "Copy a .lnx file to", "SYCLBADGE, eject and", "restart the cart." };
    const black: cart.DisplayColor = .rgb(0x000000);
    const y0 = 16;
    video.fill_rows(0, cart.screen_height, black);
    for (lines, 0..) |l, k| text.draw(l, 0, y0 + @as(i32, @intCast(k)) * 10, if (k < 2) strip.accent else strip.ink, black);
    const why = romsrc.reason orelse return;
    var buf: [64]u8 = undefined;
    var n = debug.put(&buf, "drive: ");
    n += debug.put(buf[n..], why);
    // Wrapped at the last space that fits, else cut at the screen width.
    var rest: []const u8 = buf[0..n];
    var y: i32 = y0 + lines.len * 10 + 10;
    while (rest.len > 0 and y + 8 <= cart.screen_height) : (y += 10) {
        var k = @min(rest.len, strip.cols);
        if (k < rest.len) {
            var sp = k;
            while (sp > 0 and rest[sp] != ' ') sp -= 1;
            if (sp > 0) k = sp;
        }
        text.draw(rest[0..k], 0, y, strip.dim, black);
        rest = rest[k..];
        if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
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
fn present_wasm() void {
    const sim_framebuffer: *cart.Framebuffer = @ptrFromInt(0x20);
    for (cart.framebuffer, sim_framebuffer) |*src_column, *dst_column| {
        for (src_column, dst_column) |src, *dst| {
            const c = src.to_color();
            dst.* = .from_color(.{ .r = c.b, .g = c.g, .b = c.r });
        }
    }
}

// Zero-argument exports for `tools/preview.mjs --dump-exports` (wasm only).
comptime {
    if (cart.is_wasm) {
        @export(&debug_frame_count, .{ .name = "debug_frame_count" });
        @export(&debug_state, .{ .name = "debug_state" });
        @export(&debug_pad, .{ .name = "debug_pad" });
        @export(&debug_rom_source, .{ .name = "debug_rom_source" });
        @export(&debug_rom_size, .{ .name = "debug_rom_size" });
        @export(&debug_rom_block_size, .{ .name = "debug_rom_block_size" });
        @export(&debug_rom_direct_blocks, .{ .name = "debug_rom_direct_blocks" });
        @export(&debug_rom_headered, .{ .name = "debug_rom_headered" });
        @export(&debug_rom_crc, .{ .name = "debug_rom_crc" });
        @export(&debug_palette_rebuilds, .{ .name = "debug_palette_rebuilds" });
        @export(&debug_led_max, .{ .name = "debug_led_max" });
        @export(&debug_ticks_lo, .{ .name = "debug_ticks_lo" });
        @export(&debug_ticks_hi, .{ .name = "debug_ticks_hi" });
        @export(&debug_instr_count, .{ .name = "debug_instr_count" });
        @export(&debug_pixels_drawn, .{ .name = "debug_pixels_drawn" });
        @export(&debug_irq_count, .{ .name = "debug_irq_count" });
        @export(&debug_sleep_ticks, .{ .name = "debug_sleep_ticks" });
        @export(&debug_display_frames, .{ .name = "debug_display_frames" });
        @export(&debug_boot_error, .{ .name = "debug_boot_error" });
        @export(&debug_pc, .{ .name = "debug_pc" });
        @export(&debug_instr_per_frame, .{ .name = "debug_instr_per_frame" });
        @export(&debug_menu_opens, .{ .name = "debug_menu_opens" });
        @export(&debug_settings, .{ .name = "debug_settings" });
        @export(&debug_hold_pad, .{ .name = "debug_hold_pad" });
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

/// Frames stepped since reset.
fn debug_frame_count() callconv(.c) u32 {
    return lynx.frame_count;
}
/// Frontend state: 0 splash, 1 running, 2 menu, 3 picker, 4 no-ROM help,
/// 5 LINK screen.
fn debug_state() callconv(.c) u32 {
    return @backingInt(state);
}
/// Pad word the core was last stepped with (`core.Pad` bits).
fn debug_pad() callconv(.c) u32 {
    return lynx.pad;
}
/// 0 embedded ROM, 1 drive file, 2 none (the no-ROM screen).
fn debug_rom_source() callconv(.c) u32 {
    return @backingInt(romsrc.origin);
}
/// ROM file size in bytes (header included).
fn debug_rom_size() callconv(.c) u32 {
    return romsrc.size;
}
/// Cart block size in bytes (512 for a 128 KB bank).
fn debug_rom_block_size() callconv(.c) u32 {
    return lynx.cart.block_size;
}
/// Blocks with a direct pointer (the rest read through the fallback).
fn debug_rom_direct_blocks() callconv(.c) u32 {
    return lynx.cart.direct_blocks();
}
/// 1 when the ROM has the 64-byte LYNX header.
fn debug_rom_headered() callconv(.c) u32 {
    return @intFromBool(romsrc.layout.headered);
}
/// CRC32 of the drive ROM (0 for the embedded one).
fn debug_rom_crc() callconv(.c) u32 {
    return romsrc.crc;
}
/// Palette cache rebuilds since boot.
fn debug_palette_rebuilds() callconv(.c) u32 {
    return video.palette_rebuilds;
}
/// Largest neopixel channel value: must read 0 (docs/NEOPIXELS.md).
fn debug_led_max() callconv(.c) u32 {
    var m: u8 = 0;
    for (0..cart.neopixels.len) |i| {
        const c = cart.neopixels[i];
        m = @max(m, c.r, c.g, c.b);
    }
    return m;
}
/// Lynx 16 MHz ticks since reset, low and high 32 bits.
fn debug_ticks_lo() callconv(.c) u32 {
    return @truncate(lynx.time());
}
fn debug_ticks_hi() callconv(.c) u32 {
    return @truncate(lynx.time() >> 32);
}
/// CPU instructions executed since reset (wraps).
fn debug_instr_count() callconv(.c) u32 {
    return lynx.instr_count();
}
/// Suzy pixels written since the last boot (wraps).
fn debug_pixels_drawn() callconv(.c) u32 {
    return lynx.pixels_drawn();
}
/// Interrupt sequences taken.
fn debug_irq_count() callconv(.c) u32 {
    return lynx.irq_count;
}
/// Ticks the CPU spent asleep (Suzy drawing), saturated to 32 bits.
fn debug_sleep_ticks() callconv(.c) u32 {
    return @intCast(@min(lynx.sleep_ticks, 0xFFFF_FFFF));
}
/// Lynx frames copied to the display (vertical blanks with video DMA on).
fn debug_display_frames() callconv(.c) u32 {
    return lynx.display_frames;
}
/// 0 booted; else 1 + the core.boot.BootError (count, block, check, last byte).
fn debug_boot_error() callconv(.c) u32 {
    const e = lynx.boot_error orelse return 0;
    return switch (e) {
        error.BadCount => 1,
        error.BadBlock => 2,
        error.BadCheckByte => 3,
        error.BadLastByte => 4,
    };
}
/// The CPU's program counter.
fn debug_pc() callconv(.c) u32 {
    return lynx.cpu.regs.pc;
}
/// Instructions in the last stepped frame.
fn debug_instr_per_frame() callconv(.c) u32 {
    return debug.instr_per_frame;
}
/// Times the menu opened since boot.
fn debug_menu_opens() callconv(.c) u32 {
    return menu_opens;
}
/// Menu settings: bit 0 sound on (never in wasm), bit 2 A/B swapped,
/// bit 3 debug overlay on.
fn debug_settings() callconv(.c) u32 {
    var v: u32 = 0;
    if (audio.enabled) v |= 1;
    if (input.swap_ab) v |= 4;
    if (debug.enabled) v |= 8;
    return v;
}
/// `core.Pad` bits the last held-button menu row asked for (Option 2 = 4,
/// Pause + Option 1 = 264), 0 before any; `debug_pad` shows them reaching
/// the core for `menu.hold_frames_left` frames.
fn debug_hold_pad() callconv(.c) u32 {
    return menu.hold_pad;
}

// ---- Time scrubber (frontend/rewind.zig) ----

/// Frames the console is parked behind live (0 live; 30 per scrub step).
fn debug_scrub_depth() callconv(.c) u32 {
    return rewind.depth_frames();
}
/// Frames reachable back from live.
fn debug_scrub_history() callconv(.c) u32 {
    return rewind.history_frames();
}
/// Closed undo records held.
fn debug_scrub_records() callconv(.c) u32 {
    return @intCast(rewind.record_count());
}
/// 68-byte ring slots in use (closed records and the open one).
fn debug_scrub_slots() callconv(.c) u32 {
    return @intCast(rewind.slots_in_use());
}
/// Ring slots the arena holds (0: no room, scrubber off).
fn debug_scrub_capacity() callconv(.c) u32 {
    return @intCast(rewind.capacity_slots());
}
/// Arena bytes found (in wasm `tuning.wasm_arena_bytes`).
fn debug_scrub_arena() callconv(.c) u32 {
    return @intCast(rewind.arena_bytes());
}

// ---- Fast forward ----

/// 1 while the chorded rewind shows (fast forward turned into rewind).
fn debug_chord_rewind() callconv(.c) u32 {
    return @intFromBool(state == .running and rewinding);
}

/// Game frames the last update stepped (1 at 1x, up to 8 while fast
/// forwarding on the badge, 4 in the simulator; 0 in an update that
/// stepped none).
fn debug_ff_frames() callconv(.c) u32 {
    return if (state == .running) frames_stepped else 0;
}
