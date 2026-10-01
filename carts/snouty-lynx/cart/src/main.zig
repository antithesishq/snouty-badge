//! Snouty Lynx: Atari Lynx emulator cart (M1: the real core). The Iris-mark
//! splash (frontend/splash.zig), then the game: the core steps 1/60 s of
//! Lynx time per update and its last completed frame goes to rows 0..101,
//! the 26-row status strip below it (SPEC.md section 6) has the title and
//! the ROM source line (frontend/romsrc.zig), or with the debug overlay on
//! (frontend/debug.zig, on in M1) fps, mean/worst step microseconds,
//! instructions and Suzy pixels per frame. A drive with no playable
//! `.lnx`/`.lyx` file gets the add-a-ROM help over the picture.
//!
//! No sound (the badge speaker is unused, docs/SOUND.md at the repository
//! root) and the neopixels are never written (docs/NEOPIXELS.md). SPEC.md
//! is the design, PLAN.md the milestone contract, CLAUDE.md the conventions.
const cart = @import("cart-api");
const core = @import("core");
const video = @import("frontend/video.zig");
const input = @import("frontend/input.zig");
const debug = @import("frontend/debug.zig");
const romsrc = @import("frontend/romsrc.zig");
const text = @import("frontend/text.zig");
const menu = @import("frontend/menu.zig");
const splash = @import("frontend/splash.zig");

comptime {
    cart.export_start_code();
}

/// The console (~66 KB), a static initialised in place: never build it on
/// the stack (32 KB on the badge, 14.7 KB in wasm).
var lynx: core.Lynx = undefined;

pub const State = enum(u32) { splash = 0, running = 1 };
var state: State = .splash;
var controls_state: input.State = .{};

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    text.init();
    // The boot (core/boot.zig, no boot ROM) runs inside `init_in_place`:
    // the ROM is only known here, after the drive scan.
    lynx.init_in_place(romsrc.select());
}

pub fn update() void {
    controls_state.poll(read_controls());
    const t0 = cart.micros_since_boot();
    debug.frame_tick(t0);

    switch (state) {
        .splash => if (splash.update(controls_state.edge.any_pressed())) {
            controls_state.suppress_held();
            state = .running;
            run_frame(t0);
        },
        .running => run_frame(t0),
    }

    if (cart.is_wasm) present_wasm();
}

fn run_frame(t1: u64) void {
    const in = controls_state.game_frame();
    // No menu until M2 (frontend/menu.zig); a Select hold does nothing.
    _ = in.open_menu;
    lynx.step_frame(in.pad);
    const t2 = cart.micros_since_boot();
    debug.record(@truncate(t2 -% t1));
    debug.record_core(lynx.instr_count(), lynx.pixels_drawn());

    video.show(lynx.frame());
    if (romsrc.no_rom_on_drive) draw_help();
    draw_strip();
}

const strip_bg: cart.DisplayColor = .rgb(0x101828);
const strip_ink: cart.DisplayColor = .rgb(0xF0F0E8);
const strip_accent: cart.DisplayColor = .rgb(0xFFC020);
const strip_dim: cart.DisplayColor = .rgb(0x98A8C8);
const cols = cart.screen_width / 8;

/// Rows 102..127: "SNOUTY LYNX" and the ROM's origin ("drive" or
/// "embedded") on the first line, the rest of the ROM report word-wrapped
/// over the next two; with the debug overlay on, the two debug lines
/// instead of the title line and the report's first line.
fn draw_strip() void {
    video.fill_rows(video.strip_y, video.strip_h, strip_bg);
    const y0: i32 = video.strip_y + 1;
    var lines: [2][]const u8 = undefined;
    const n = wrap(romsrc.detail(), &lines);
    if (debug.enabled) {
        var buf: [32]u8 = undefined;
        text.draw(debug.line(&buf), 0, y0, strip_ink, strip_bg);
        var buf2: [32]u8 = undefined;
        text.draw(debug.line2(&buf2), 0, y0 + 8, strip_accent, strip_bg);
        if (n > 0) text.draw(lines[0], 0, y0 + 16, strip_dim, strip_bg);
        return;
    }
    text.draw(menu.title, 0, y0, strip_accent, strip_bg);
    text.draw(romsrc.origin_word(), (menu.title.len + 1) * 8, y0, strip_dim, strip_bg);
    for (lines[0..n], 0..) |l, k| text.draw(l, 0, y0 + 8 * @as(i32, @intCast(k + 1)), strip_ink, strip_bg);
}

/// The drive has a volume but no playable Lynx ROM (Snouty Genesis's M2
/// help, in a band over the picture; the embedded ROM runs underneath).
/// The last line names the first refused file and why, if there is one.
fn draw_help() void {
    const lines = [_][]const u8{ "No Lynx ROM found.", "Copy a .lnx file to", "SYCLBADGE, eject and", "restart the cart." };
    const black: cart.DisplayColor = .rgb(0x000000);
    const y0 = 24;
    video.fill_rows(y0 - 3, lines.len * 10 + 16, black);
    for (lines, 0..) |l, k| text.draw(l, 0, y0 + @as(i32, @intCast(k)) * 10, if (k == 0) strip_accent else strip_ink, black);
    const found = romsrc.candidates();
    if (found.len == 0) return;
    var buf: [cols]u8 = undefined;
    var n: usize = 0;
    n += debug.put(buf[n..], found[0].file_name());
    n += debug.put(buf[n..], ": ");
    n += debug.put(buf[n..], found[0].note());
    text.draw(buf[0..n], 0, y0 + lines.len * 10 + 2, strip_dim, black);
}

/// Split `s` at spaces into at most `out.len` lines of `cols` characters.
fn wrap(s: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < out.len) {
        while (i < s.len and s[i] == ' ') i += 1;
        const start_i = i;
        var end = @min(s.len, start_i + cols);
        if (end < s.len and s[end] != ' ') {
            var j = end;
            while (j > start_i and s[j - 1] != ' ') j -= 1;
            if (j > start_i) end = j;
        }
        var trimmed = end;
        while (trimmed > start_i and s[trimmed - 1] == ' ') trimmed -= 1;
        if (trimmed > start_i) {
            out[n] = s[start_i..trimmed];
            n += 1;
        }
        i = end;
    }
    return n;
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
    }
}

/// Frames stepped since reset.
fn debug_frame_count() callconv(.c) u32 {
    return lynx.frame_count;
}
/// Frontend state: 0 splash, 1 running.
fn debug_state() callconv(.c) u32 {
    return @backingInt(state);
}
/// Pad word the core was last stepped with (`core.Pad` bits).
fn debug_pad() callconv(.c) u32 {
    return lynx.pad;
}
/// 0 embedded ROM, 1 drive file.
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
