//! Snouty Lynx: Atari Lynx emulator cart, M0 scaffold. The Iris-mark
//! splash (frontend/splash.zig), then the placeholder screen: the core's
//! 160x102 picture at rows 0..101 (M0: a test pattern, core/lynx.zig) and
//! the 26-row status strip below it (SPEC.md section 6) with the title and
//! the ROM source line (frontend/romsrc.zig). A drive with no playable
//! `.lnx`/`.lyx` file gets the add-a-ROM help over the picture.
//!
//! No sound (M2 adds it, silent at boot per docs/SOUND.md) and the
//! neopixels are never written (docs/NEOPIXELS.md). SPEC.md is the design,
//! PLAN.md the milestone contract, CLAUDE.md the conventions.
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
    lynx.init_in_place(romsrc.select());
    // TODO(M0 Track A): core/boot.zig runs inside `reset` (the ROM is only
    // known here, after the drive scan); nothing else changes in start().
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
    // M0: no menu yet (frontend/menu.zig); a Select hold does nothing.
    _ = in.open_menu;
    lynx.step_frame(in.pad);
    const t2 = cart.micros_since_boot();
    debug.record(@truncate(t2 -% t1));

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
/// "embedded") on the first line (the debug numbers instead when the
/// overlay is on), the rest of the ROM report word-wrapped over the next two.
fn draw_strip() void {
    video.fill_rows(video.strip_y, video.strip_h, strip_bg);
    const y0: i32 = video.strip_y + 1;
    if (debug.enabled) {
        var buf: [32]u8 = undefined;
        text.draw(debug.line(&buf), 0, y0, strip_ink, strip_bg);
    } else {
        text.draw(menu.title, 0, y0, strip_accent, strip_bg);
        text.draw(romsrc.origin_word(), (menu.title.len + 1) * 8, y0, strip_dim, strip_bg);
    }
    var lines: [2][]const u8 = undefined;
    const n = wrap(romsrc.detail(), &lines);
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
