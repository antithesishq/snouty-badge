//! The marquee's art (frontend/marquee_art.zig, M8): title clean-up,
//! lettering that stays inside the band, schemes, the glint, and the drive
//! BMP check. The font is the OS font from the SDK's source, the same
//! glyphs the cart captures from the screen.
const std = @import("std");
const art = @import("marquee_art");
const os_font = @import("os_font");

/// The glyphs, converted at run time (comptime stays light: CLAUDE.md).
var glyphs: art.Glyphs = undefined;
var glyphs_ready = false;

fn font() *const art.Glyphs {
    if (!glyphs_ready) {
        glyphs = art.glyphs_from_rows(os_font.font[0..art.glyph_count]);
        glyphs_ready = true;
    }
    return &glyphs;
}

fn clean(src: []const u8, from_file: bool) []const u8 {
    const S = struct {
        var buf: [art.max_title]u8 = undefined;
    };
    return art.clean_title(src, from_file, &S.buf);
}

test "marquee: title clean-up" {
    try std.testing.expectEqualStrings("HARD DRIVIN'", clean("Hard Drivin' (USA, Europe).lnx", true));
    try std.testing.expectEqualStrings("HARD DRIVIN", clean("hard_drivin.lnx", true));
    try std.testing.expectEqualStrings("CHECKERED FLAG", clean("checkered-flag.LYX", true));
    try std.testing.expectEqualStrings("X-MEN", clean("X-Men", false));
    try std.testing.expectEqualStrings("KLAX", clean("  Klax [!] (1990) ", false));
    try std.testing.expectEqualStrings("RAYCAST", clean("RAYCAST", false));
    try std.testing.expectEqualStrings("", clean("(Proto)", false));
    // Cut at max_title.
    try std.testing.expectEqual(art.max_title, clean("abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz", false).len);
}

test "marquee: font from the SDK source" {
    // '!' is a centred stroke with a gap above the dot (rows 0..4, 6).
    const g = font()['!' - art.first_glyph];
    try std.testing.expectEqual(@as(u8, 0), g[0]);
    try std.testing.expectEqual(@as(u8, 0b0101_1111), g[3]);
    try std.testing.expectEqual(@as(u8, 0), font()[0][0]); // space
}

const titles = [_][]const u8{
    "A",                                 "KLAX",                             "RAYCAST",
    "HARD DRIVIN'",                      "BLUE LIGHTNING",                   "CHIP'S CHALLENGE",
    "S.T.U.N. RUNNER",                   "BATTLEZONE 2000",                  "CALIFORNIA GAMES",
    "GAUNTLET: THE THIRD ENCOUNTER",     "TODD'S ADVENTURES IN SLIME WORLD", "SUPER ASTEROIDS & MISSILE COMMAND",
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456", "WWWWWWWWWWWWWWWWWWWW",             "@@@@@@@@@@@@@@@@@@@@ @@@@@@@@@@@@@@@@@@@",
};

test "marquee: lettering stays inside the band" {
    for (titles) |t| {
        errdefer std.debug.print("title \"{s}\"\n", .{t});
        const l = art.layout(t, font());
        try std.testing.expect(l.lines >= 1);
        const c = art.colors(art.schemes[art.scheme_index(t)], &l);
        var img: [art.h][art.w]u32 = undefined;
        // Mid-glint, so the glint is checked too.
        art.render_rgb(&l, &c, 12, &img);
        // Trim and its highlight untouched; the ends are background.
        for (0..art.w) |x| {
            const g = art.glow_level(@intCast(x));
            for ([_]usize{ 0, 1, art.h - 2, art.h - 1 }) |y| {
                errdefer std.debug.print("x {d} y {d}\n", .{ x, y });
                try std.testing.expectEqual(c.bg[g][y], img[y][x]);
            }
        }
        for (0..art.h) |y| {
            for ([_]usize{ 0, 1, 2, 3, art.w - 4, art.w - 3, art.w - 2, art.w - 1 }) |x| {
                errdefer std.debug.print("x {d} y {d}\n", .{ x, y });
                try std.testing.expectEqual(c.bg[art.glow_level(@intCast(x))][y], img[y][x]);
            }
        }
        // Some ink.
        var ink: u32 = 0;
        for (l.mask) |m| ink += @popCount(m);
        try std.testing.expect(ink > 0);
    }
}

test "marquee: short titles get one tall line, long ones two" {
    try std.testing.expectEqual(@as(u8, 1), art.layout("KLAX", font()).lines);
    try std.testing.expectEqual(@as(u8, 14), art.layout("KLAX", font()).rows[0]);
    try std.testing.expectEqual(@as(u8, 1), art.layout("CHIP'S CHALLENGE", font()).lines);
    try std.testing.expectEqual(@as(u8, 2), art.layout("GAUNTLET: THE THIRD ENCOUNTER", font()).lines);
    try std.testing.expectEqual(@as(u8, 0), art.layout("", font()).lines);
}

test "marquee: words stay apart" {
    // Between "BLUE" and "LIGHTNING" at least two columns without fill.
    const l = art.layout("BLUE LIGHTNING", font());
    var x: usize = 0;
    while (l.mask[x] == 0) x += 1;
    var runs: u32 = 0;
    var gap: u32 = 0;
    var widest: u32 = 0;
    while (x < art.w) : (x += 1) {
        if (l.mask[x] == 0) gap += 1 else {
            if (gap > 0) runs += 1;
            widest = @max(widest, gap);
            gap = 0;
        }
    }
    try std.testing.expect(widest >= 3);
}

test "marquee: schemes and glint" {
    try std.testing.expectEqual(art.scheme_index("HARD DRIVIN'"), art.scheme_index("HARD DRIVIN'"));
    for (titles) |t| try std.testing.expect(art.scheme_index(t) < art.schemes.len);
    try std.testing.expect(art.glint_at(0) < 0);
    try std.testing.expect(art.glint_at(art.glint_frames / 2) > 0);
    try std.testing.expectEqual(@as(i32, -1000), art.glint_at(art.glint_frames));
    try std.testing.expectEqual(art.glint_at(5), art.glint_at(5 + art.glint_period));
}

/// A 160x26 BMP: `bpp` 24 or 32, rows bottom-up unless `top_down`, pixel
/// (x, y) = (x, y, x ^ y) as (R, G, B).
fn make_bmp(buf: []u8, bpp: u16, top_down: bool) []u8 {
    const stride: u32 = (art.w * bpp / 8 + 3) & ~@as(u32, 3);
    const size: u32 = 54 + stride * art.h;
    @memset(buf[0..size], 0);
    buf[0] = 'B';
    buf[1] = 'M';
    std.mem.writeInt(u32, buf[2..6], size, .little);
    std.mem.writeInt(u32, buf[10..14], 54, .little);
    std.mem.writeInt(u32, buf[14..18], 40, .little);
    std.mem.writeInt(i32, buf[18..22], art.w, .little);
    std.mem.writeInt(i32, buf[22..26], if (top_down) -art.h else art.h, .little);
    std.mem.writeInt(u16, buf[26..28], 1, .little);
    std.mem.writeInt(u16, buf[28..30], bpp, .little);
    for (0..art.h) |y| {
        const row = if (top_down) y else art.h - 1 - y;
        for (0..art.w) |x| {
            const p = buf[54 + row * stride + x * bpp / 8 ..];
            p[0] = @intCast(x ^ y);
            p[1] = @intCast(y);
            p[2] = @intCast(x);
        }
    }
    return buf[0..size];
}

test "marquee: drive BMP" {
    var buf: [54 + 640 * 26]u8 = undefined;
    for ([_]u16{ 24, 32 }) |bpp| for ([_]bool{ false, true }) |td| {
        const b = try art.parse_bmp(make_bmp(&buf, bpp, td));
        try std.testing.expectEqual(@as(u8, @intCast(bpp / 8)), b.bytes_pp);
        for ([_][2]u32{ .{ 0, 0 }, .{ 159, 25 }, .{ 37, 11 } }) |xy| {
            const p = b.row(xy[1]) + xy[0] * b.bytes_pp;
            try std.testing.expectEqual(@as(u8, @intCast(xy[0])), p[2]);
            try std.testing.expectEqual(@as(u8, @intCast(xy[1])), p[1]);
        }
    };

    var bmp = make_bmp(&buf, 24, false);
    bmp[0] = 'X';
    try std.testing.expectError(error.NotBmp, art.parse_bmp(bmp));
    bmp = make_bmp(&buf, 24, false);
    std.mem.writeInt(u32, bmp[30..34], 1, .little); // RLE8
    try std.testing.expectError(error.Compressed, art.parse_bmp(bmp));
    bmp = make_bmp(&buf, 24, false);
    std.mem.writeInt(u16, bmp[28..30], 16, .little);
    try std.testing.expectError(error.NotTrueColour, art.parse_bmp(bmp));
    bmp = make_bmp(&buf, 24, false);
    std.mem.writeInt(i32, bmp[22..26], 27, .little);
    try std.testing.expectError(error.Not160x26, art.parse_bmp(bmp));
    bmp = make_bmp(&buf, 24, false);
    try std.testing.expectError(error.Truncated, art.parse_bmp(bmp[0 .. bmp.len - 1]));
    // 32-bit with BI_BITFIELDS (what many editors write) is fine.
    bmp = make_bmp(&buf, 32, false);
    std.mem.writeInt(u32, bmp[30..34], 3, .little);
    _ = try art.parse_bmp(bmp);
}

test "marquee: BMP beside the ROM" {
    try std.testing.expect(art.sidecar_matches("HARDDRIV.LNX", "harddriv.bmp"));
    try std.testing.expect(art.sidecar_matches("Hard Drivin' (USA).lnx", "Hard Drivin' (USA).BMP"));
    try std.testing.expect(!art.sidecar_matches("A.LNX", "AB.BMP"));
    try std.testing.expect(!art.sidecar_matches("KLAX.LNX", "KLAX.LNX.BMP"));
}
