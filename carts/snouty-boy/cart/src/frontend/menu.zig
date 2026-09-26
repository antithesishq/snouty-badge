//! Emulator menu (SPEC.md sections 5 and 12): opened by holding Select for
//! 500 ms (frontend/input.zig), drawn with cart.text/cart.rect over the
//! frozen game frame. The core is not stepped while it is open.
//!
//! Frozen frame. The cart runs in `.no_copy_full_frame` mode: after every
//! present the buffers swap and nothing is copied, so the new back buffer
//! holds the frame from two presents ago, not the frozen one. `open` copies
//! the last presented frame (`cart.frontbuffer`) into the back buffer once
//! (40 KB memcpy, no extra RAM) and switches to `.copy_forward`, in which the
//! OS copies each presented frame into the next back buffer (about 0.1 ms,
//! only while the menu is open). The panel is opaque and redrawn every
//! frame, so nothing compounds. `close` switches back before the next game
//! frame is presented. In wasm nothing is ever presented and `framebuffer`
//! never changes, so the frozen frame is simply still there.
//!
//! A palette change while paused recolors the frozen frame in place
//! (`video.remap_palette`), so the preview matches what resuming will show.
//! A scale change takes effect on the first frame after resuming.
const std = @import("std");
const cart = @import("cart-api");
const core = @import("core");
const video = @import("video.zig");
const debug = @import("debug.zig");
const input = @import("input.zig");

pub const version = "0.3.0-m3";

/// Sound approximation on/off (SPEC.md 18 item 6). Read by frontend/audio.zig
/// through the integrator; keep the name.
pub var sound_enabled: bool = true;

pub const Result = enum { stay, resume_game };

const Item = enum { resume_game, palette, scale, sound, debug, reset, about };
const item_count = @typeInfo(Item).@"enum".field_names.len;

var cursor: Item = .resume_game;
var showing_about: bool = false;
/// A Select press began inside the menu; its release resumes. The release
/// of the hold that opened the menu does not count.
var select_armed: bool = false;

/// Enter the menu. Call in the frame the hold threshold is reached, before
/// drawing anything.
pub fn open() void {
    showing_about = false;
    select_armed = false;
    cursor = .resume_game;
    if (!cart.is_wasm) {
        const n = cart.screen_width * cart.screen_height / 2;
        const src: *const [n]u32 = @ptrCast(cart.frontbuffer);
        const dst: *[n]u32 = @ptrCast(cart.framebuffer);
        @memcpy(dst, src);
    }
    cart.set_double_buffer_mode(.copy_forward);
}

/// Leave the menu; the caller steps the game in the same frame.
pub fn close() void {
    cart.set_double_buffer_mode(.no_copy_full_frame);
}

/// M4 time scrubber hook (SPEC.md section 10): Left = back 0.5 s, Right =
/// forward. Does nothing yet.
fn on_scrub(dir: i2) void {
    // TODO(M4): step the keyframe ring by `dir` half-seconds and re-render.
    _ = dir;
}

/// One menu frame: handle input, then draw. Returns `.resume_game` when the
/// game should run again (the caller calls `close`).
pub fn update(gb: *core.Gb, e: input.Edge) Result {
    if (e.pressed(.select)) select_armed = true;
    const select_tap = select_armed and e.released(.select);
    if (select_tap) select_armed = false;

    if (showing_about) {
        if (e.pressed(.a) or e.pressed(.b) or select_tap) showing_about = false;
    } else {
        if (e.pressed(.b) or select_tap) return .resume_game;
        if (e.pressed(.up)) move(-1);
        if (e.pressed(.down)) move(1);
        if (e.pressed(.left)) adjust(-1);
        if (e.pressed(.right)) adjust(1);
        if (e.pressed(.a)) {
            switch (cursor) {
                .resume_game => return .resume_game,
                .reset => {
                    gb.reset();
                    return .resume_game;
                },
                .about => showing_about = true,
                else => adjust(1),
            }
        }
    }
    draw(gb);
    return .stay;
}

fn move(d: i2) void {
    const i: usize = @backingInt(cursor);
    const n: usize = if (d < 0) (i + item_count - 1) % item_count else (i + 1) % item_count;
    cursor = @fromBackingInt(@intCast(n));
}

/// Left/Right (or A) on a setting cycles it; elsewhere Left/Right are the
/// scrubber's (M4).
fn adjust(d: i2) void {
    switch (cursor) {
        .palette => {
            const old = video.palette_index;
            const new = if (d < 0) old + video.palettes.len - 1 else old + 1;
            video.set_palette_index(new);
            video.remap_palette(old, video.palette_index);
        },
        .scale => video.set_scale(if (video.scale == .squeeze) .crop else .squeeze),
        .sound => sound_enabled = !sound_enabled,
        .debug => debug.enabled = !debug.enabled,
        .resume_game, .reset, .about => on_scrub(d),
    }
}

// ---- Drawing ----

const band_h = 36;
const panel_x = 4;
const panel_y = 40;
const panel_w = cart.screen_width - 2 * panel_x;
const panel_h = 86;
const row_h = 10;
const text_x = panel_x + 4;
const first_row_y = panel_y + 3;

/// ROM title from the cartridge header (0x134..0x143): up to the first
/// non-printable byte, trailing spaces trimmed.
pub fn rom_title(rom: []const u8) []const u8 {
    if (rom.len < 0x144) return "?";
    const raw = rom[0x134..0x144];
    var n: usize = 0;
    while (n < raw.len and raw[n] >= 0x20 and raw[n] < 0x7F) n += 1;
    while (n > 0 and raw[n - 1] == ' ') n -= 1;
    return if (n == 0) "?" else raw[0..n];
}

fn centered(s: []const u8, y: i32, color: cart.DisplayColor) void {
    const w: i32 = @intCast(@as(usize, @min(s.len, 20)) * 8); // @min(usize, 20) is a u5
    cart.text(.{ .str = s, .x = @divTrunc(@as(i32, cart.screen_width) - w, 2), .y = y, .text_color = color });
}

fn draw(gb: *const core.Gb) void {
    const bg = video.shade_color(0);
    const fg = video.shade_color(3);
    const dim = video.shade_color(2);

    // Title band: SPEC.md 12 and 18 item 9.
    cart.rect(.{ .x = 0, .y = 0, .width = cart.screen_width, .height = band_h, .fill_color = fg });
    centered("SNOUTY BOY", 1, bg);
    centered(rom_title(gb.rom), 10, video.shade_color(1));
    centered("verified by", 19, bg);
    centered("deterministic replay", 27, bg);

    cart.rect(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h, .fill_color = bg, .stroke_color = fg });

    var buf: [24]u8 = undefined;
    if (showing_about) {
        const lines = [_][]const u8{
            cat(&buf, "Version ", version),
            "ROM:",
            rom_title(gb.rom),
            mbc_name(gb.mbc.kind),
            "Built for",
            "Antithesis",
        };
        var y: i32 = first_row_y;
        for (lines, 0..) |l, i| {
            cart.text(.{ .str = l, .x = if (i == 2) text_x + 16 else text_x, .y = y, .text_color = fg });
            y += row_h;
        }
        cart.text(.{ .str = "B: back", .x = text_x, .y = first_row_y + 7 * row_h, .text_color = dim });
        return;
    }

    for (0..item_count) |i| {
        const item: Item = @fromBackingInt(@intCast(i));
        const y: i32 = first_row_y + @as(i32, @intCast(i)) * row_h;
        const label: []const u8 = switch (item) {
            .resume_game => "Resume",
            .palette => cat(&buf, "Palette: ", video.palette_name()),
            .scale => if (video.scale == .squeeze) "Scale: Squeeze" else "Scale: Crop",
            .sound => if (sound_enabled) "Sound: On" else "Sound: Off",
            .debug => if (debug.enabled) "Debug overlay: On" else "Debug overlay: Off",
            .reset => "Reset",
            .about => "About",
        };
        var color = fg;
        if (item == cursor) {
            cart.rect(.{ .x = panel_x + 2, .y = y - 1, .width = panel_w - 4, .height = row_h, .fill_color = fg });
            color = bg;
        }
        cart.text(.{ .str = label, .x = text_x, .y = y, .text_color = color });
    }
    cart.text(.{ .str = "Scrub: (M4)", .x = text_x, .y = first_row_y + item_count * row_h, .text_color = dim });
}

fn cat(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    const n = @min(a.len + b.len, buf.len);
    const na = @min(a.len, n);
    @memcpy(buf[0..na], a[0..na]);
    @memcpy(buf[na..n], b[0 .. n - na]);
    return buf[0..n];
}

fn mbc_name(k: core.mmu.MbcKind) []const u8 {
    return switch (k) {
        .none => "MBC: none",
        .mbc1 => "MBC: MBC1",
        .mbc3 => "MBC: MBC3",
        .mbc5 => "MBC: MBC5",
    };
}

comptime {
    const hdr = "2048-gb    XXXX\x00";
    var rom: [0x150]u8 = @splat(0);
    @memcpy(rom[0x134..0x144], hdr);
    if (!std.mem.eql(u8, rom_title(&rom), "2048-gb    XXXX")) @compileError("rom_title");
    @memcpy(rom[0x134..0x144], "TETRIS\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00");
    if (!std.mem.eql(u8, rom_title(&rom), "TETRIS")) @compileError("rom_title nul");
}
