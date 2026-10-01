//! Line sink: rendered badge rows (tagged 6-bit CRAM indices, SPEC.md
//! section 6) into the column-major RGB565 framebuffer, through a `Pixel`
//! cache of the 9-bit CRAM with its shadow and highlight variants. Copied
//! from Snouty Gear's video.zig and adapted: the core already applies the
//! line table (it emits badge rows 0..127, 160 pixels each), so there is no
//! line map here.
//!
//! The hot path is `on_line`, called once per rendered row (128 per
//! presented frame). The framebuffer is `[160][128]Pixel`, column-major:
//! one row is 160 halfword stores 256 bytes apart. A 320-wide row (an H40
//! line under the menu's Smooth H40, `Vdp.h_mode`) stores the average of
//! each column pair (`avg`).
const cart = @import("cart-api");
const core = @import("core");

const out_w = core.out_w;
const fb_h = cart.screen_height;
const fb_w = cart.screen_width;

comptime {
    if (out_w != fb_w) @compileError("the core renders exactly one badge row width");
    if (core.out_h != fb_h) @compileError("the core renders exactly the badge's rows");
}

// ---- CRAM -> Pixel cache ----

/// The CRAM the cache was built from, and its `Pixel`s: entries 0-63
/// normal, 64-127 shadow, 128-191 highlight (the tag in bits 6-7 of a
/// rendered pixel indexes straight in), 192-255 normal again (tag 3 is
/// never emitted; filled so an index is always in range). Rebuilt when a
/// row arrives with a different CRAM (a 128-byte compare per row; H-int
/// palette changes land between lines and are seen).
var cram_seen: [64]u16 = @splat(0xFFFF);
var pixels: [256]cart.Pixel = @splat(.{ .bits = 0 });
/// Cache rebuilds since boot (a `debug_*` export).
pub var cram_rebuilds: u32 = 0;

/// One 3-bit CRAM component at an intensity: normal 2c, shadow c,
/// highlight c + 7, on a 0..14 scale, to 8 bits.
fn level(c: u32, tag: u2) u32 {
    const l: u32 = switch (tag) {
        1 => c,
        2 => c + 7,
        else => 2 * c,
    };
    return (l * 255 + 7) / 14;
}

/// 9-bit ----BBB-GGG-RRR- CRAM word with a shadow/highlight tag to a
/// DisplayColor.
pub fn cram_color(w: u16, tag: u2) cart.DisplayColor {
    const r = level((w >> 1) & 7, tag);
    const g = level((w >> 5) & 7, tag);
    const b = level((w >> 9) & 7, tag);
    return .rgb(r << 16 | g << 8 | b);
}

fn rebuild(cram: *const [64]u16) void {
    for (0..4) |t| {
        const tag: u2 = if (t == 3) 0 else @intCast(t);
        for (pixels[t * 64 ..][0..64], cram) |*px, c| px.* = .from_color(cram_color(c, tag));
    }
    cram_seen = cram.*;
    cram_rebuilds +%= 1;
}

/// Compared as 32 words, no early exit (branches cost more than the
/// loads). The CRAM is only halfword aligned, hence align(1).
inline fn cram_changed(cram: *const [64]u16) bool {
    const a: *align(1) const [32]u32 = @ptrCast(cram);
    const b: *align(1) const [32]u32 = @ptrCast(&cram_seen);
    var diff: u32 = 0;
    inline for (0..32) |i| diff |= a[i] ^ b[i];
    return diff != 0;
}

/// Rows the core emitted since the last `finish_frame`.
var rows_this_frame: u32 = 0;
/// Rows emitted for the last presented frame (128).
pub var last_frame_lines: u32 = 0;

pub fn init() void {
    cram_seen = @splat(0xFFFF);
}

pub fn sink() core.LineSink {
    return .{ .ctx = @ptrFromInt(@alignOf(usize)), .func = &on_line };
}

fn on_line(_: *anyopaque, row: u8, line: [*]const u8, width: u16, cram: *const [64]u16) void {
    rows_this_frame += 1;
    if (row >= fb_h) return;
    if (cram_changed(cram)) rebuild(cram);
    if (width == out_w) store_line(row, line) else store_pairs(row, line);
}

/// One row to framebuffer row `row`: 160 halfword stores with a stride of
/// `fb_h` pixels, unrolled by 8 so the stores use immediate offsets. Every
/// byte value indexes `pixels` in range, so no mask.
inline fn store_line(row: u8, src: [*]const u8) void {
    var dst: [*]cart.Pixel = @as([*]cart.Pixel, @ptrCast(cart.framebuffer)) + row;
    const pix: [*]const cart.Pixel = &pixels;
    var x: usize = 0;
    while (x < out_w) : (x += 8) {
        inline for (0..8) |k| {
            dst[k * fb_h] = pix[src[x + k]];
        }
        dst += 8 * fb_h;
    }
}

/// A 320-pixel row to framebuffer row `row`: badge column x shows the
/// average of Genesis columns 2x and 2x + 1, unrolled as `store_line`.
inline fn store_pairs(row: u8, src: [*]const u8) void {
    var dst: [*]cart.Pixel = @as([*]cart.Pixel, @ptrCast(cart.framebuffer)) + row;
    const pix: [*]const cart.Pixel = &pixels;
    var x: usize = 0;
    while (x < out_w) : (x += 8) {
        inline for (0..8) |k| {
            const a = pix[src[2 * (x + k)]].bits;
            const b = pix[src[2 * (x + k) + 1]].bits;
            dst[k * fb_h] = .{ .bits = avg(a, b) };
        }
        dst += 8 * fb_h;
    }
}

// ---- Column-pair average (Smooth H40) ----

/// The low bit of each RGB565 field in `DisplayColor` order (r bits 0-4,
/// g 5-10, b 11-15); `half_mask` clears them so `(a ^ b) & half_mask >> 1`
/// halves every field without a bit crossing into its neighbour.
const low_bits: u16 = @bitCast(cart.DisplayColor{ .r = 1, .g = 1, .b = 1 });
const half_mask: u16 = ~low_bits;
/// `Pixel.from_color` byte-swaps on the simulator (wasm) and stores the
/// `DisplayColor` as is on the badge. In swapped order the green field is
/// split across the bytes, so no mask works there: swap, average, swap.
const fb_swapped = cart.Pixel.from_color(.{ .r = 1, .g = 0, .b = 0 }).bits != @as(u16, @bitCast(cart.DisplayColor{ .r = 1, .g = 0, .b = 0 }));

/// Per-field floor average of two RGB565 values in `DisplayColor` order,
/// carry-free: the common bits plus half the differing ones.
inline fn avg565(a: u16, b: u16) u16 {
    return (a & b) + (((a ^ b) & half_mask) >> 1);
}

/// Average of two framebuffer pixels (`Pixel.bits`), per field.
pub inline fn avg(a: u16, b: u16) u16 {
    if (fb_swapped) return @byteSwap(avg565(@byteSwap(a), @byteSwap(b)));
    return avg565(a, b);
}

comptime {
    const px = cart.Pixel.from_color;
    // Red and blue average to the purple `from_color` gives for (15, 0, 15).
    if (avg(px(.{ .r = 31, .g = 0, .b = 0 }).bits, px(.{ .r = 0, .g = 0, .b = 31 }).bits) != px(.{ .r = 15, .g = 0, .b = 15 }).bits)
        @compileError("avg(red, blue) is not purple");
    // White and black: every field halves, nothing carries.
    if (avg(px(.{ .r = 31, .g = 63, .b = 31 }).bits, px(.{ .r = 0, .g = 0, .b = 0 }).bits) != px(.{ .r = 15, .g = 31, .b = 15 }).bits)
        @compileError("avg(white, black) is not grey");
    // Odd fields on both sides: (31, 1, 17) and (1, 63, 3) -> (16, 32, 10).
    if (avg(px(.{ .r = 31, .g = 1, .b = 17 }).bits, px(.{ .r = 1, .g = 63, .b = 3 }).bits) != px(.{ .r = 16, .g = 32, .b = 10 }).bits)
        @compileError("avg mixes fields");
}

/// Fill the whole screen with one 9-bit color.
pub fn blank(c: u16) void {
    const px: u16 = cart.Pixel.from_color(cram_color(c, 0)).bits;
    const fb: *[fb_w * fb_h / 2]u32 = @ptrCast(cart.framebuffer);
    @memset(fb, @as(u32, px) << 16 | px);
}

/// Called once per update after the rendered frame. With no rows emitted
/// the back buffer still holds an old frame, so blank it.
pub fn finish_frame() void {
    if (rows_this_frame == 0) blank(0);
    last_frame_lines = rows_this_frame;
    rows_this_frame = 0;
}

// ---- Scale (the menu's Scale row, SPEC.md section 6) ----

/// Which of the 224 Genesis lines reach the 128 badge rows: `.squeeze`
/// shows every line through the line table, `.crop` a 1:1 middle band.
/// The VDP holds the mode (`Vdp.line_mode`); this is the setting, applied
/// by `apply`.
pub var scale: core.vdp.LineMode = .squeeze;

/// The menu's Smooth H40 row: H40 lines composed at 320 columns and each
/// column pair averaged (`Vdp.h_mode`), applied by `apply` with `scale`.
pub var smooth: bool = true;

/// Put `scale` and `smooth` into the console. main.zig calls it after `init_in_place`,
/// after a Reset (`Vdp.reset` puts the mode back to squeeze) and when the
/// menu closes. (M3: a `Keyframe` restore brings back the recorded `Vdp`,
/// so it must re-apply too.)
pub fn apply(md: *core.Md) void {
    md.vdp.line_mode = scale;
    md.vdp.h_mode = if (smooth) .smooth else .sharp;
}
