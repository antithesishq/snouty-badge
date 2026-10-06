//! The arcade marquee over the picture, badge rows 0..25 (PLAN.md "M8
//! Marquee: contract"). No Lynx ROM carries marquee art, so it is drawn
//! from the title (frontend/marquee_art.zig: the lettering as column masks,
//! the colour scheme the title picks), or comes from `NAME.BMP` beside
//! `NAME.LNX` on the same drive (160x26, 24 or 32 bit, read in place from
//! flash). `load` prepares it after every boot; `draw` paints the rows
//! every frame (the game presents full frames without a copy, so the back
//! buffer holds the frame before last).
//!
//! Drawn look: black trim, a backlit background brightest behind the
//! middle, letters with a two-tone chrome fill, a dark outline and a
//! shadow down and right, and a glint that sweeps across the letters every
//! `art.glint_period` frames.
const cart = @import("cart-api");
const romfs = @import("romfs");
const art = @import("marquee_art.zig");
const romsrc = @import("romsrc.zig");
const text = @import("text.zig");

/// Rows the marquee fills, 0..h-1 (the picture starts at `video.top`).
pub const h = art.h;
const w = art.w;

comptime {
    if (w != cart.screen_width) @compileError("the marquee spans the screen");
    if (h % 2 != 0) @compileError("word stores: an even number of rows");
}

/// The lettering (bit y of `mask[x]` = ink at column x, row y).
var mask: [w]u32 = @splat(0);
var pal: art.Palette(cart.Pixel) = undefined;
/// The background per glow level as words: rows 2k and 2k + 1 of a column
/// in one u32 store (the upper row in the low half, as the framebuffer
/// lays them out).
var bg_words: [art.glow_levels][h / 2]u32 = undefined;
/// Glow level per column (`art.glow_level`).
var level: [w]u8 = undefined;
/// Frames drawn since `load`, for the glint.
var frame: u32 = 0;

/// The drive BMP, when there is a usable one.
var bmp: ?art.Bmp = null;
/// What About says.
var status: []const u8 = drawn_text;
const drawn_text = "Marquee: drawn";

/// Pick the title, colour scheme and drive BMP for the ROM that just
/// booted. Call after every boot (start, picker, Reset).
pub noinline fn load() void {
    var tb: [art.max_title]u8 = undefined;
    const from_file = romsrc.layout.title().len == 0;
    const title = art.clean_title(romsrc.title_name(), from_file, &tb);
    const l = art.layout(title, text.glyphs());
    mask = l.mask;
    const c = art.colors(art.schemes[art.scheme_index(title)], &l);
    for (&bg_words, &c.bg) |*words, *col| to_words(words, col);
    to_pixels(&pal.shadow, &c.shadow, false);
    to_pixels(&pal.fill, &c.fill, false);
    to_pixels(&pal.shine, &c.fill, true);
    pal.outline = px(c.outline);
    pal.glint = px(0xFFFFFF);
    for (&level, 0..) |*v, x| v.* = @intCast(art.glow_level(@intCast(x)));
    // The first glint a second after boot.
    frame = art.glint_period - 60;
    bmp = null;
    status = drawn_text;
    if (romsrc.use_drive) find_bmp();
}

fn px(rgb: u32) cart.Pixel {
    return .from_color(.rgb(rgb));
}

/// 0xRRGGBB colours to pixels (`shine`: half way to white first). Out of
/// line over slices so the one-off set-up stays small (marquee_art.zig
/// `bg_column`).
noinline fn to_pixels(dst: []cart.Pixel, src: []const u32, shine: bool) void {
    for (dst, src) |*p, rgb| p.* = px(if (shine) art.shine(rgb) else rgb);
}

/// A background column as row-pair words (the upper row in the low half).
noinline fn to_words(dst: []u32, src: []const u32) void {
    for (dst, 0..) |*word, k| word.* = @as(u32, px(src[2 * k]).bits) | @as(u32, px(src[2 * k + 1]).bits) << 16;
}

/// `NAME.BMP` beside the running `NAME.LNX`, on the same drive. Only a
/// file in one run on the drive is used (a fresh copy always is): it is
/// read in place every frame.
noinline fn find_bmp() void {
    const i = romsrc.chosen_index() orelse return;
    const cand = &romsrc.candidates()[i];
    const image = romfs.Image.drive(cand.entry.drive) orelse return;
    const vol = romfs.Volume.open(image) catch return;
    var entries: [8]romfs.Entry = undefined;
    const n = vol.find(&.{"bmp"}, &entries);
    for (entries[0..n]) |*e| {
        if (!art.sidecar_matches(cand.file_name(), e.slice())) continue;
        // 33 clusters hold a 32-bit 160x26 BMP with a V5 header.
        var clusters: [40]u16 = undefined;
        const m = vol.map(e.*, &clusters) catch |err| {
            status = if (err == error.TooManyClusters) art.bmp_error_text(error.Not160x26) else "BMP: bad FAT chain";
            return;
        };
        const p = m.contiguous() orelse {
            status = "BMP: fragmented";
            return;
        };
        bmp = art.parse_bmp(p[0..m.size]) catch |err| {
            status = art.bmp_error_text(err);
            return;
        };
        status = "Marquee: from BMP";
        return;
    }
}

/// The About page's line: "Marquee: drawn", "Marquee: from BMP",
/// "BMP: not 160x26".
pub fn about_line(buf: *[24]u8) []const u8 {
    @memcpy(buf[0..status.len], status);
    return buf[0..status.len];
}

/// Paint rows 0..h-1 completely. Marks no dirty rect (the game presents
/// the full frame).
pub fn draw() void {
    frame +%= 1;
    if (bmp) |*b| return draw_bmp(b);
    const glint = art.glint_at(frame);
    var left_d: u32 = 0;
    for (0..w) |x| {
        const column: *[h]cart.Pixel = cart.framebuffer[x][0..h];
        const words: *align(4) [h / 2]u32 = @ptrCast(@alignCast(column));
        words.* = bg_words[level[x]];
        art.letter_column(cart.Pixel, &pal, &mask, x, &left_d, glint, column);
    }
}

/// The drive BMP, converted pixel by pixel from flash.
noinline fn draw_bmp(b: *const art.Bmp) void {
    var rows: [h][*]const u8 = undefined;
    for (&rows, 0..) |*r, y| r.* = b.row(@intCast(y));
    const bpp = b.bytes_pp;
    for (0..w) |x| {
        const column = &cart.framebuffer[x];
        const off = x * bpp;
        for (&rows, 0..) |r, y| {
            const p = r + off;
            column[y] = .from_color(.{ .r = @intCast(p[2] >> 3), .g = @intCast(p[1] >> 2), .b = @intCast(p[0] >> 3) });
        }
    }
}
