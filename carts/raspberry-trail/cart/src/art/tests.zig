//! Host tests of the art module (track A): sizes, decoding against the
//! generator's expected results, transparency, clipping and the lookups.
//! `zig test carts/raspberry-trail/cart/src/art/tests.zig`
const std = @import("std");
const art = @import("art.zig");
const data = @import("gen/art_data.zig");
const check = @import("gen/art_check.zig");

const Pic = art.Pic;
const n_pics = @typeInfo(Pic).@"enum".field_names.len;

/// A 256x256 framebuffer sink that records every write.
const Buf = struct {
    const clear: u32 = 0xFFFF_FFFF;
    px: [256 * 256]u32 = @splat(clear),
    writes: u32 = 0,
    out_of_bounds: u32 = 0,

    pub fn put(self: *Buf, x: i32, y: i32, c: art.Color) void {
        self.writes += 1;
        if (x < 0 or y < 0 or x >= 256 or y >= 256) {
            self.out_of_bounds += 1;
            return;
        }
        self.px[@intCast(y * 256 + x)] = @as(u16, @bitCast(c));
    }

    fn at(self: *const Buf, x: i32, y: i32) u32 {
        return self.px[@intCast(y * 256 + x)];
    }
};

/// Same, but takes runs through `span`.
const SpanBuf = struct {
    inner: Buf = .{},
    spans: u32 = 0,

    pub fn put(self: *SpanBuf, x: i32, y: i32, c: art.Color) void {
        self.inner.put(x, y, c);
    }

    pub fn span(self: *SpanBuf, x0: i32, x1: i32, y: i32, c: art.Color) void {
        self.spans += 1;
        var x = x0;
        while (x < x1) : (x += 1) self.inner.put(x, y, c);
    }
};

const everywhere: art.Rect = .{ .x = 0, .y = 0, .w = 256, .h = 256 };

fn checksum(b: *const Buf, w: u32, h: u32) struct { n: u32, sum: u32 } {
    var n: u32 = 0;
    var sum: u32 = 0;
    for (0..h) |y| {
        for (0..w) |x| {
            const v = b.px[y * 256 + x];
            if (v == Buf.clear) continue;
            n += 1;
            sum +%= @as(u32, @intCast(y * w + x + 1)) *% (v + 1);
        }
    }
    return .{ .n = n, .sum = sum };
}

test "art: sizes and frame counts" {
    try std.testing.expectEqual(art.Size{ .w = 160, .h = 128 }, art.size(.title_bg));
    try std.testing.expectEqual(@as(u8, 2), art.frames(.strip_wagon));
    try std.testing.expectEqual(@as(u8, 3), art.frames(.btn_a));
    for (0..n_pics) |k| {
        const p: Pic = @fromBackingInt(@intCast(k));
        const name = @tagName(p);
        const sz = art.size(p);
        try std.testing.expect(sz.w > 0 and sz.w <= 160 and sz.h > 0 and sz.h <= 128);
        try std.testing.expect(art.frames(p) >= 1);
        try std.testing.expect(data.infos[k].colors <= 16);
        if (std.mem.startsWith(u8, name, "v_")) {
            try std.testing.expect(sz.w <= 64 and sz.h <= 40);
        }
        if (std.mem.startsWith(u8, name, "btn_")) {
            try std.testing.expectEqual(art.Size{ .w = 14, .h = 14 }, sz);
        }
    }
    try std.testing.expectEqual(data.frames.len, check.checks.len);
}

test "art: every frame decodes to the generator's pixels" {
    var used_raw = false;
    var used_rle = false;
    for (0..n_pics) |k| {
        const p: Pic = @fromBackingInt(@intCast(k));
        const inf = data.infos[k];
        for (0..inf.frames) |f| {
            const fr = data.frames[inf.frame + f];
            if (fr.rle) used_rle = true else used_raw = true;
            var b: Buf = .{};
            art.drawClipped(p, 0, 0, @intCast(f), everywhere, &b);
            const want = check.checks[inf.frame + f];
            const got = checksum(&b, inf.w, inf.h);
            try std.testing.expectEqual(want.opaque_px, got.n);
            try std.testing.expectEqual(want.sum, got.sum);
            try std.testing.expectEqual(want.opaque_px, b.writes);
            try std.testing.expectEqual(@as(u32, 0), b.out_of_bounds);
        }
    }
    try std.testing.expect(used_raw and used_rle);
}

test "art: sample pixels, through draw and through pixel()" {
    for (check.samples) |s| {
        const p: Pic = @fromBackingInt(@intCast(s.pic));
        const got = art.pixel(p, s.frame, s.x, s.y);
        if (s.c) |c| {
            try std.testing.expect(got != null);
            try std.testing.expectEqual(c, @as(u16, @bitCast(got.?)));
        } else {
            try std.testing.expect(got == null);
        }
    }
    try std.testing.expect(art.pixel(.title_bg, 0, -1, 0) == null);
    try std.testing.expect(art.pixel(.title_bg, 0, 160, 0) == null);
}

test "art: transparency leaves the background alone" {
    // Vignette corners are clipped (transparent); glyph corners too.
    var b: Buf = .{};
    art.drawClipped(.v_fire, 10, 10, 0, everywhere, &b);
    try std.testing.expectEqual(Buf.clear, b.at(10, 10));
    try std.testing.expect(b.at(10 + 32, 10 + 20) != Buf.clear);
    var g: Buf = .{};
    art.drawClipped(.btn_up, 0, 0, 0, everywhere, &g);
    try std.testing.expectEqual(Buf.clear, g.at(0, 0));
    try std.testing.expectEqual(Buf.clear, g.at(13, 13));
    try std.testing.expect(g.writes < 14 * 14);
}

test "art: clipping to the screen and to a rectangle" {
    // title_bg is fully opaque.
    try std.testing.expectEqual(@as(u32, 160 * 128), check.checks[data.infos[@backingInt(Pic.title_bg)].frame].opaque_px);
    var b: Buf = .{};
    art.draw(.title_bg, -10, -5, 0, &b);
    try std.testing.expectEqual(@as(u32, 150 * 123), b.writes);
    try std.testing.expectEqual(@as(u32, 0), b.out_of_bounds);
    // the pixel at screen (0, 0) is the picture's (10, 5)
    try std.testing.expectEqual(@as(u32, @as(u16, @bitCast(art.pixel(.title_bg, 0, 10, 5).?))), b.at(0, 0));

    var c: Buf = .{};
    art.draw(.title_bg, 150, 120, 0, &c);
    try std.testing.expectEqual(@as(u32, 10 * 8), c.writes);
    for (0..256) |y| for (0..256) |x| {
        if (c.px[y * 256 + x] != Buf.clear) {
            try std.testing.expect(x >= 150 and x < 160 and y >= 120 and y < 128);
        }
    };

    var d: Buf = .{};
    art.draw(.title_bg, 200, 0, 0, &d);
    art.draw(.title_bg, 0, -128, 0, &d);
    art.draw(.v_fog, -64, 0, 0, &d);
    try std.testing.expectEqual(@as(u32, 0), d.writes);

    var e: Buf = .{};
    art.drawClipped(.shoot_hunt, 0, 0, 0, .{ .x = 20, .y = 30, .w = 7, .h = 3 }, &e);
    try std.testing.expectEqual(@as(u32, 21), e.writes);

    // a raw-encoded frame clips too
    var raw_pic: ?Pic = null;
    for (0..n_pics) |k| {
        if (!data.frames[data.infos[k].frame].rle) raw_pic = @fromBackingInt(@intCast(k));
    }
    const rp = raw_pic.?;
    var f: Buf = .{};
    const sz = art.size(rp);
    art.drawClipped(rp, -1, -1, 0, .{ .x = 0, .y = 0, .w = @intCast(sz.w), .h = @intCast(sz.h) }, &f);
    for (0..256) |y| for (0..256) |x| {
        if (f.px[y * 256 + x] != Buf.clear) try std.testing.expect(x < sz.w - 1 and y < sz.h - 1);
    };
}

test "art: span sinks draw the same pixels" {
    inline for (.{ Pic.title_bg, Pic.v_river, Pic.btn_b, Pic.tombstone }) |p| {
        var a: Buf = .{};
        var s: SpanBuf = .{};
        art.draw(p, 3, 2, 1, &a);
        art.draw(p, 3, 2, 1, &s);
        try std.testing.expect(std.mem.eql(u32, &a.px, &s.inner.px));
        try std.testing.expect(s.spans > 0);
    }
}

test "art: frames wrap" {
    var a: Buf = .{};
    var b: Buf = .{};
    art.draw(.strip_wagon, 0, 0, 1, &a);
    art.draw(.strip_wagon, 0, 0, 3, &b);
    try std.testing.expect(std.mem.eql(u32, &a.px, &b.px));
}

test "art: lookups by the game's tag names" {
    // A stand-in for the game's enums (this module must not import it).
    const Tag = enum { plain, warning, wagon_breaks, fire, helpful_food, south_pass, death, blizzard };
    try std.testing.expectEqual(@as(?Pic, .v_wagon_breaks), art.vignette(Tag.wagon_breaks));
    try std.testing.expectEqual(@as(?Pic, .v_helpful_food), art.vignette(Tag.helpful_food));
    try std.testing.expectEqual(@as(?Pic, .v_south_pass), art.vignette(Tag.south_pass));
    try std.testing.expectEqual(@as(?Pic, null), art.vignette(Tag.plain));
    try std.testing.expectEqual(@as(?Pic, null), art.vignette(Tag.death));
    try std.testing.expectEqual(@as(?Pic, .v_doctor), art.vignetteForLine(Tag.warning, "DOCTOR'S BILL IS $20"));
    try std.testing.expectEqual(@as(?Pic, null), art.vignetteForLine(Tag.warning, "YOU'D BETTER DO SOME HUNTING"));
    var t: Tag = .blizzard; // runtime value
    _ = &t;
    try std.testing.expectEqual(@as(?Pic, .v_blizzard), art.vignette(t));

    const ShotReason = enum { hunt, riders, bandits, animals };
    try std.testing.expectEqual(Pic.shoot_hunt, art.shootScene(ShotReason.hunt));
    try std.testing.expectEqual(Pic.shoot_animals, art.shootScene(ShotReason.animals));
    const Outcome = enum { none, arrived, starved, snakebite };
    try std.testing.expectEqual(@as(?Pic, null), art.endScene(Outcome.none));
    try std.testing.expectEqual(@as(?Pic, .arrival), art.endScene(Outcome.arrived));
    try std.testing.expectEqual(@as(?Pic, .tombstone), art.endScene(Outcome.snakebite));
    try std.testing.expectEqual(Pic.btn_left, art.button(art.Button.left));
    try std.testing.expectEqual(@as(u8, 3), art.frames(art.button(art.Button.b)));
}

test "art: Color matches the DisplayColor layout" {
    // raspberry #E30B5C -> r 28, g 2, b 11
    const c: art.Color = .{ .r = 0xE3 >> 3, .g = 0x0B >> 2, .b = 0x5C >> 3 };
    try std.testing.expectEqual(@as(u16, 28 | 2 << 5 | 11 << 11), @as(u16, @bitCast(c)));
    try std.testing.expectEqual(@as(u32, 0xE7085A), c.rgb888());
    try std.testing.expectEqual(c, art.color("rasp"));
    try std.testing.expectEqual(@as(u32, 0xF7EBD6), art.color("paper").rgb888());
}

test "art: layout rects sit on the screen" {
    inline for (.{ art.layout.title_logo, art.layout.title_menu, art.layout.title_wagon }) |r| {
        try std.testing.expect(r.x >= 0 and r.y >= 0 and r.x + r.w <= 160 and r.y + r.h <= 128);
    }
    const t = art.layout.tomb_text;
    const ts = art.size(.tombstone);
    try std.testing.expect(t.x + t.w <= ts.w and t.y + t.h <= ts.h);
    try std.testing.expect(t.w >= 60 and t.h >= 24); // 10 columns, 3 rows of the 6x8 font
}
