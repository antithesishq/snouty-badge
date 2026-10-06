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
/// `pal.bg` as words: rows 2k and 2k + 1 of a column in one u32 store (the
/// upper row in the low half, as the framebuffer lays them out).
var bg_words: [art.glow_levels][h / 2]u32 = undefined;
/// Glow level per column (`art.glow_level`).
var level: [w]u8 = undefined;
/// Frames drawn since `load`, for the glint.
var frame: u32 = 0;

/// The drive BMP, when there is a usable one.
var bmp: ?art.Bmp = null;
/// What About says.
var status: []const u8 = drawn_text;
var status_buf: [24]u8 = undefined;
const drawn_text = "Marquee: drawn";

/// Pick the title, colour scheme and drive BMP for the ROM that just
/// booted. Call after every boot (start, picker, Reset).
pub fn load() void {
    var tb: [art.max_title]u8 = undefined;
    const from_file = romsrc.layout.title().len == 0;
    const title = art.clean_title(romsrc.title_name(), from_file, &tb);
    const l = art.layout(title, text.glyphs());
    mask = l.mask;
    const c = art.colors(art.schemes[art.scheme_index(title)], &l);
    for (0..art.glow_levels) |g| {
        for (&pal.bg[g], c.bg[g]) |*p, rgb| p.* = px(rgb);
        for (&bg_words[g], 0..) |*word, k| word.* = @as(u32, pal.bg[g][2 * k].bits) | @as(u32, pal.bg[g][2 * k + 1].bits) << 16;
    }
    for (&pal.shadow, c.shadow) |*p, rgb| p.* = px(rgb);
    for (&pal.fill, c.fill) |*p, rgb| p.* = px(rgb);
    for (&pal.shine, c.fill) |*p, rgb| p.* = px(art.shine(rgb));
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
        status = name_line(e.slice());
        return;
    }
}

/// "Marquee: HD.BMP", the name cut to the About panel's 18 columns.
fn name_line(name: []const u8) []const u8 {
    const prefix = "Marquee: ";
    const cols = 18;
    @memcpy(status_buf[0..prefix.len], prefix);
    const room = cols - prefix.len;
    var n = @min(name.len, room);
    @memcpy(status_buf[prefix.len..][0..n], name[0..n]);
    if (name.len > room) status_buf[prefix.len + n - 1] = '~';
    n += prefix.len;
    return status_buf[0..n];
}

/// The About page's line: "Marquee: drawn", "Marquee: HD.BMP",
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
