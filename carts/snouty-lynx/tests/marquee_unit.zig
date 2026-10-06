//! The marquee's art (frontend/marquee_art.zig, M8): title clean-up,
//! lettering that stays inside the band, schemes and the glint. The font is the OS font from the SDK's source, the same
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
