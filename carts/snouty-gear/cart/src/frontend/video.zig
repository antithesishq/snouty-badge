//! Line sink: Game Gear lines (CRAM indices 0..31) into the column-major
//! RGB565 framebuffer, with the squeeze/crop line map and a 32-entry
//! `Pixel` cache of the 12-bit CRAM. SPEC.md section 6. Copied from Snouty
//! Boy's video.zig and adapted.
//!
//! The hot path is `on_line`, called once per visible line (144 per frame).
//! The framebuffer is `[160][128]Pixel`, column-major: one Game Gear line
//! is 160 halfword stores 256 bytes apart, the row's first pixel address
//! computed once per line and the loop only adding the column stride.
const cart = @import("cart-api");
const core = @import("core");

pub const Scale = enum { squeeze, crop };

pub var scale: Scale = .squeeze;

const gg_h = core.screen_h;
const gg_w = core.screen_w;
const fb_h = cart.screen_height;
const fb_w = cart.screen_width;

comptime {
    if (gg_w != fb_w) @compileError("horizontal mapping is 1:1");
    if (fb_h > 0xFF) @compileError("rows must fit in u8");
}

/// Line map entry meaning "this Game Gear line is not drawn".
const skip: u8 = 0xFF;

/// Row in the badge framebuffer for each Game Gear line, or `skip`. Built at
/// runtime by `set_scale` (144 bytes; no comptime tables, see CLAUDE.md).
var line_map: [gg_h]u8 = @splat(skip);

fn build_line_map(s: Scale) void {
    for (&line_map, 0..) |*row, y| {
        row.* = switch (s) {
            // Drop every ninth line (y % 9 == 8): 144 - 16 = 128 rows.
            .squeeze => if (y % 9 == 8) skip else @intCast(y - y / 9),
            // Lines 8..135 to rows 0..127.
            .crop => if (y < 8 or y >= 8 + fb_h) skip else @intCast(y - 8),
        };
    }
}

// ---- CRAM -> Pixel cache ----

/// The CRAM the cache was built from, and its `Pixel`s. Rebuilt when a line
/// arrives with a different CRAM (a 64-byte compare per line; mid-frame
/// palette changes land between lines and are seen).
var cram_seen: [32]u16 = @splat(0xFFFF);
var pixels: [32]cart.Pixel = @splat(.{ .bits = 0 });
/// Cache rebuilds since boot (a `debug_*` export).
pub var cram_rebuilds: u32 = 0;

/// 12-bit ----BBBBGGGGRRRR to a DisplayColor (each 4-bit level times 17).
pub fn cram_color(c: u16) cart.DisplayColor {
    const r: u32 = c & 0xF;
    const g: u32 = (c >> 4) & 0xF;
    const b: u32 = (c >> 8) & 0xF;
    return .rgb((r * 17) << 16 | (g * 17) << 8 | b * 17);
}

fn rebuild(cram: *const [32]u16) void {
    for (&pixels, cram) |*px, c| px.* = .from_color(cram_color(c));
    cram_seen = cram.*;
    cram_rebuilds +%= 1;
}

/// Compared as 16 words, no early exit (branches cost more than the
/// loads). The CRAM is only halfword aligned, hence align(1).
inline fn cram_changed(cram: *const [32]u16) bool {
    const a: *align(1) const [16]u32 = @ptrCast(cram);
    const b: *align(1) const [16]u32 = @ptrCast(&cram_seen);
    var diff: u32 = 0;
    inline for (0..16) |i| diff |= a[i] ^ b[i];
    return diff != 0;
}

/// Lines the core emitted since the last `finish_frame` (drawn or skipped).
var lines_this_frame: u32 = 0;
/// Lines emitted during the last completed frame (144).
pub var last_frame_lines: u32 = 0;

pub fn init() void {
    set_scale(scale);
}

pub fn set_scale(s: Scale) void {
    scale = s;
    build_line_map(s);
}

pub fn sink() core.LineSink {
    return .{ .ctx = @ptrFromInt(@alignOf(usize)), .func = &on_line };
}

fn on_line(_: *anyopaque, y: u8, line: *const [gg_w]u5, cram: *const [32]u16) void {
    lines_this_frame += 1;
    if (y >= gg_h) return;
    const row = line_map[y];
    if (row == skip) return;
    if (cram_changed(cram)) rebuild(cram);
    store_line(row, line);
}

/// One Game Gear line to framebuffer row `row`: 160 halfword stores with a
/// stride of `fb_h` pixels, unrolled by 8 so the stores use immediate offsets.
/// The indices are read as bytes (a u5 load would mask every one) and used
/// unchecked: the core only emits 0..31.
inline fn store_line(row: u8, line: *const [gg_w]u5) void {
    var dst: [*]cart.Pixel = @as([*]cart.Pixel, @ptrCast(cart.framebuffer)) + row;
    const src: [*]const u8 = @ptrCast(line);
    const pix: [*]const cart.Pixel = &pixels;
    var x: usize = 0;
    while (x < gg_w) : (x += 8) {
        inline for (0..8) |k| {
            dst[k * fb_h] = pix[src[x + k]];
        }
        dst += 8 * fb_h;
    }
}

/// Fill the whole screen with one 12-bit color.
pub fn blank(c: u16) void {
    const px: u16 = cart.Pixel.from_color(cram_color(c)).bits;
    const fb: *[fb_w * fb_h / 2]u32 = @ptrCast(cart.framebuffer);
    @memset(fb, @as(u32, px) << 16 | px);
}

/// Called once per badge frame after `step_frame`. With no lines emitted
/// the back buffer still holds an old frame, so blank it.
pub fn finish_frame() void {
    if (lines_this_frame == 0) blank(0);
    last_frame_lines = lines_this_frame;
    lines_this_frame = 0;
}
