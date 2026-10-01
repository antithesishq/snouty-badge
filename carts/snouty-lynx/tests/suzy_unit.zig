//! suzy: sprite engine unit tests (M1 Track B) on synthetic SCBs in a 64 KB
//! RAM. Expected spans are hand-computed in the comments from the rules in
//! docs/SUZY.md (HSIZOFF = VSIZOFF = $007F as games program them).
const std = @import("std");
const core = @import("core");
const Suzy = core.suzy.Suzy;

const vidbas: u16 = 0x2000;
const collbas: u16 = 0x4000;
const scb0: u16 = 0x6000;
const data0: u16 = 0x7000;
const colloff: u16 = 0x20;

const Ram = [0x10000]u8;

const Rig = struct {
    ram: *Ram,
    s: Suzy = .{},

    fn init() !Rig {
        const ram = try std.testing.allocator.create(Ram);
        @memset(ram, 0);
        var r: Rig = .{ .ram = ram };
        r.w16(0x04, 0); // HOFF
        r.w16(0x06, 0); // VOFF
        r.w16(0x08, vidbas);
        r.w16(0x0A, collbas);
        r.w16(0x24, colloff);
        r.w16(0x28, 0x007F); // HSIZOFF
        r.w16(0x2A, 0x007F); // VSIZOFF
        r.s.write(0x90, 1); // SUZYBUSEN
        r.s.write(0x83, 0xF3); // SPRINIT
        return r;
    }

    fn deinit(r: *Rig) void {
        std.testing.allocator.destroy(r.ram);
    }

    fn w16(r: *Rig, a: u8, v: u16) void {
        r.s.write(a, @truncate(v));
        r.s.write(a + 1, @truncate(v >> 8));
    }

    fn r16(r: *Rig, a: u8) u16 {
        return @as(u16, r.s.read(a)) | (@as(u16, r.s.read(a + 1)) << 8);
    }

    fn go(r: *Rig, first: u16, sprgo: u8) u32 {
        r.w16(0x10, first);
        r.s.write(0x91, sprgo);
        std.debug.assert(r.s.sprites_pending());
        return r.s.run_sprites(r.ram);
    }

    fn pix(r: *const Rig, x: u16, y: u16) u8 {
        return nib(r.ram, vidbas, x, y);
    }

    fn coll(r: *const Rig, x: u16, y: u16) u8 {
        return nib(r.ram, collbas, x, y);
    }

    fn fill_video(r: *Rig, v: u8) void {
        @memset(r.ram[vidbas .. vidbas + 8160], v * 0x11);
    }

    fn fill_coll(r: *Rig, v: u8) void {
        @memset(r.ram[collbas .. collbas + 8160], v * 0x11);
    }

    /// Pixels x0..x0+n-1 of row y.
    fn row(r: *const Rig, x0: u16, y: u16, comptime n: usize) [n]u8 {
        var out: [n]u8 = undefined;
        for (0..n) |i| out[i] = r.pix(x0 + @as(u16, @intCast(i)), y);
        return out;
    }

    /// Number of non-zero pixels in the whole video buffer.
    fn count_pixels(r: *const Rig) u32 {
        var n: u32 = 0;
        for (r.ram[vidbas .. vidbas + 8160]) |b| {
            if (b >> 4 != 0) n += 1;
            if (b & 15 != 0) n += 1;
        }
        return n;
    }
};

fn nib(ram: *const Ram, base: u16, x: u16, y: u16) u8 {
    const b = ram[base + y * 80 + x / 2];
    return if (x & 1 == 0) b >> 4 else b & 0x0F;
}

/// An SCB builder.
const Scb = struct {
    sprctl0: u8,
    sprctl1: u8 = 0x10, // reload HSIZ/VSIZ, palette reloaded, SE start
    sprcoll: u8 = 0,
    next: u16 = 0,
    data: u16 = data0,
    hpos: u16 = 10,
    vpos: u16 = 5,
    hsiz: u16 = 0x100,
    vsiz: u16 = 0x100,
    stretch: u16 = 0,
    tilt: u16 = 0,
    palette: [8]u8 = .{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF },

    fn put(c: Scb, ram: *Ram, at: u16) void {
        var p = at;
        const b = struct {
            fn byte(rm: *Ram, q: *u16, v: u8) void {
                rm[q.*] = v;
                q.* +%= 1;
            }
            fn word(rm: *Ram, q: *u16, v: u16) void {
                byte(rm, q, @truncate(v));
                byte(rm, q, @truncate(v >> 8));
            }
        };
        b.byte(ram, &p, c.sprctl0);
        b.byte(ram, &p, c.sprctl1);
        b.byte(ram, &p, c.sprcoll);
        b.word(ram, &p, c.next);
        b.word(ram, &p, c.data);
        b.word(ram, &p, c.hpos);
        b.word(ram, &p, c.vpos);
        const depth = (c.sprctl1 >> 4) & 3;
        if (depth >= 1) {
            b.word(ram, &p, c.hsiz);
            b.word(ram, &p, c.vsiz);
        }
        if (depth >= 2) b.word(ram, &p, c.stretch);
        if (depth >= 3) b.word(ram, &p, c.tilt);
        if (c.sprctl1 & 0x08 == 0) {
            for (c.palette) |v| b.byte(ram, &p, v);
        }
    }
};

fn ctl0(bpp: u8, kind: u8) u8 {
    return ((bpp - 1) << 6) | kind;
}

/// MSB-first bit writer for sprite line data.
const Bits = struct {
    bytes: [64]u8 = @splat(0),
    nbits: usize = 0,

    fn put(b: *Bits, v: u32, n: u5) void {
        var i: u5 = n;
        while (i > 0) {
            i -= 1;
            if ((v >> i) & 1 != 0) b.bytes[b.nbits / 8] |= @as(u8, 0x80) >> @intCast(b.nbits % 8);
            b.nbits += 1;
        }
    }

    fn len(b: *const Bits) usize {
        return (b.nbits + 7) / 8;
    }
};

/// Lines builder: each line is an offset byte plus its data bytes.
const Lines = struct {
    ram: *Ram,
    p: u16 = data0,

    fn line(l: *Lines, data: []const u8) void {
        l.ram[l.p] = @intCast(data.len + 1);
        @memcpy(l.ram[l.p + 1 .. l.p + 1 + data.len], data);
        l.p += @intCast(data.len + 1);
    }

    fn bits(l: *Lines, b: *const Bits) void {
        l.line(b.bytes[0..b.len()]);
    }

    fn next_quadrant(l: *Lines) void {
        l.ram[l.p] = 1;
        l.p += 1;
    }

    fn end(l: *Lines) void {
        l.ram[l.p] = 0;
        l.p += 1;
    }
};

const literal: u8 = 0x80;

test "suzy: literal lines at each bpp" {
    var r = try Rig.init();
    defer r.deinit();
    // Pens 1,2,3,1 (1 bpp: 1,0,1,1); a pad byte keeps the last pixel (the
    // strict "more bits than a pen" rule). Normal sprite: pen 0 transparent.
    const cases = [_]struct { bpp: u8, pens: [4]u8 }{
        .{ .bpp = 1, .pens = .{ 1, 0, 1, 1 } },
        .{ .bpp = 2, .pens = .{ 1, 2, 3, 1 } },
        .{ .bpp = 3, .pens = .{ 7, 2, 5, 1 } },
        .{ .bpp = 4, .pens = .{ 15, 2, 9, 1 } },
    };
    for (cases) |c| {
        @memset(r.ram, 0);
        var b: Bits = .{};
        for (c.pens) |p| b.put(p, @intCast(c.bpp));
        b.put(0, 8); // pad
        var l: Lines = .{ .ram = r.ram };
        l.bits(&b);
        l.end();
        (Scb{ .sprctl0 = ctl0(c.bpp, 4), .sprctl1 = 0x10 | literal }).put(r.ram, scb0);
        _ = r.go(scb0, 1);
        try std.testing.expectEqual(c.pens, r.row(10, 5, 4));
        try std.testing.expectEqual(@as(u8, 0), r.pix(9, 5));
        try std.testing.expectEqual(@as(u8, 0), r.pix(14, 5));
        try std.testing.expectEqual([_]u8{ 0, 0, 0, 0 }, r.row(10, 4, 4));
        try std.testing.expectEqual([_]u8{ 0, 0, 0, 0 }, r.row(10, 6, 4));
    }
}

test "suzy: literal line without pad loses the last pixel" {
    var r = try Rig.init();
    defer r.deinit();
    // 4 bpp, 2 data bytes = 16 bits: pens are taken while > 4 bits remain,
    // so 3 of the 4 pixels.
    var l: Lines = .{ .ram = r.ram };
    l.line(&.{ 0x12, 0x34 });
    l.end();
    (Scb{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal }).put(r.ram, scb0);
    _ = r.go(scb0, 1);
    try std.testing.expectEqual([_]u8{ 1, 2, 3, 0 }, r.row(10, 5, 4));
}

test "suzy: totally literal ignores the 00000 header" {
    var r = try Rig.init();
    defer r.deinit();
    var l: Lines = .{ .ram = r.ram };
    l.line(&.{ 0x10, 0x00, 0x02, 0x00 });
    l.end();
    (Scb{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal }).put(r.ram, scb0);
    _ = r.go(scb0, 1);
    try std.testing.expectEqual([_]u8{ 1, 0, 0, 0, 0, 2, 0 }, r.row(10, 5, 7));
}

test "suzy: packed lines at each bpp" {
    var r = try Rig.init();
    defer r.deinit();
    for (1..5) |bpp_us| {
        const bpp: u8 = @intCast(bpp_us);
        @memset(r.ram, 0);
        const top: u32 = (@as(u32, 1) << @intCast(bpp)) - 1;
        // packed 4 x pen `top`, literal (top-0 alternating) 2 pens, packed 2 x 1
        var b: Bits = .{};
        b.put(0b0_0011, 5);
        b.put(top, @intCast(bpp));
        b.put(0b1_0001, 5);
        b.put(1, @intCast(bpp));
        b.put(top, @intCast(bpp));
        b.put(0b0_0001, 5);
        b.put(1, @intCast(bpp));
        b.put(0, 5); // end of line
        b.put(0, 8); // pad
        var l: Lines = .{ .ram = r.ram };
        l.bits(&b);
        l.end();
        (Scb{ .sprctl0 = ctl0(bpp, 4) }).put(r.ram, scb0);
        _ = r.go(scb0, 1);
        const t: u8 = @intCast(top);
        try std.testing.expectEqual([_]u8{ t, t, t, t, 1, t, 1, 1, 0 }, r.row(10, 5, 9));
    }
}

test "suzy: packed header 00000 ends the line" {
    var r = try Rig.init();
    defer r.deinit();
    var b: Bits = .{};
    b.put(0b0_0001, 5);
    b.put(3, 4); // 2 x pen 3
    b.put(0, 5); // end
    b.put(0b0_0011, 5);
    b.put(5, 4); // never drawn
    b.put(0, 8);
    var l: Lines = .{ .ram = r.ram };
    l.bits(&b);
    l.end();
    (Scb{ .sprctl0 = ctl0(4, 4) }).put(r.ram, scb0);
    _ = r.go(scb0, 1);
    try std.testing.expectEqual([_]u8{ 3, 3, 0, 0, 0, 0 }, r.row(10, 5, 6));
}

test "suzy: packet ending on bit 0 of the last byte is lost (pad-byte bug)" {
    var r = try Rig.init();
    defer r.deinit();
    // 1 bpp, one byte: literal header 1 0010 (3 pens) + pens 1,0,1 = 8 bits.
    // Without a pad byte the third pen ends on bit 0 and is not drawn.
    var l: Lines = .{ .ram = r.ram };
    l.line(&.{0b1001_0101});
    l.end();
    (Scb{ .sprctl0 = ctl0(1, 4) }).put(r.ram, scb0);
    _ = r.go(scb0, 1);
    try std.testing.expectEqual([_]u8{ 1, 0, 0 }, r.row(10, 5, 3));
    // With the pad byte all three are drawn.
    @memset(r.ram, 0);
    l = .{ .ram = r.ram };
    l.line(&.{ 0b1001_0101, 0 });
    l.end();
    (Scb{ .sprctl0 = ctl0(1, 4) }).put(r.ram, scb0);
    _ = r.go(scb0, 1);
    try std.testing.expectEqual([_]u8{ 1, 0, 1 }, r.row(10, 5, 3));
}

test "suzy: pen map and palette reuse" {
    var r = try Rig.init();
    defer r.deinit();
    var l: Lines = .{ .ram = r.ram };
    l.line(&.{ 0x12, 0x30, 0 }); // pen indices 1,2,3,0,0,0 (literal 4 bpp)
    l.end();
    // Index 1 -> 9, 2 -> A, 3 -> 0 (transparent in a normal sprite), 0 -> 4.
    (Scb{
        .sprctl0 = ctl0(4, 4),
        .sprctl1 = 0x10 | literal,
        .next = scb0 + 0x40,
        .palette = .{ 0x49, 0xA0, 0, 0, 0, 0, 0, 0 },
    }).put(r.ram, scb0);
    // Second sprite, palette bit 3 set: same map, one row lower.
    (Scb{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x18 | literal, .vpos = 6 }).put(r.ram, scb0 + 0x40);
    _ = r.go(scb0, 1);
    try std.testing.expectEqual([_]u8{ 9, 0xA, 0, 4, 4 }, r.row(10, 5, 5));
    try std.testing.expectEqual([_]u8{ 9, 0xA, 0, 4, 4 }, r.row(10, 6, 5));
}

const TypeCase = struct {
    kind: u8,
    video: [4]u8,
    coll: [4]u8,
    dep: ?u8,
};

test "suzy: the eight sprite types: pixels, collision buffer, depository" {
    // Literal pens 0, 1, E, F at x = 10..13 over video 8 and collision 3;
    // the sprite's collision number is 5. Depository preset to $EE.
    const cases = [_]TypeCase{
        .{ .kind = 0, .video = .{ 0, 1, 0xE, 0xF }, .coll = .{ 5, 5, 3, 5 }, .dep = null },
        .{ .kind = 1, .video = .{ 0, 1, 0xE, 0xF }, .coll = .{ 3, 3, 3, 3 }, .dep = null },
        .{ .kind = 2, .video = .{ 8, 1, 0xE, 8 }, .coll = .{ 3, 5, 3, 5 }, .dep = 3 },
        .{ .kind = 3, .video = .{ 8, 1, 0xE, 8 }, .coll = .{ 3, 5, 5, 5 }, .dep = 3 },
        .{ .kind = 4, .video = .{ 8, 1, 0xE, 0xF }, .coll = .{ 3, 5, 5, 5 }, .dep = 3 },
        .{ .kind = 5, .video = .{ 8, 1, 0xE, 0xF }, .coll = .{ 3, 3, 3, 3 }, .dep = null },
        .{ .kind = 6, .video = .{ 8, 9, 6, 7 }, .coll = .{ 3, 5, 3, 5 }, .dep = 3 },
        .{ .kind = 7, .video = .{ 8, 1, 0xE, 0xF }, .coll = .{ 3, 5, 3, 5 }, .dep = 3 },
    };
    var r = try Rig.init();
    defer r.deinit();
    for (cases) |c| {
        @memset(r.ram, 0);
        r.fill_video(8);
        r.fill_coll(3);
        var l: Lines = .{ .ram = r.ram };
        l.line(&.{ 0x01, 0xEF, 0 });
        l.end();
        r.ram[scb0 + colloff] = 0xEE;
        (Scb{ .sprctl0 = ctl0(4, c.kind), .sprctl1 = 0x10 | literal, .sprcoll = 5 }).put(r.ram, scb0);
        _ = r.go(scb0, 1);
        errdefer std.debug.print("type {d}\n", .{c.kind});
        // Background types also paint the pad pens (0) after F.
        try std.testing.expectEqual(c.video, r.row(10, 5, 4));
        var coll: [4]u8 = undefined;
        for (0..4) |i| coll[i] = r.coll(10 + @as(u16, @intCast(i)), 5);
        try std.testing.expectEqual(c.coll, coll);
        try std.testing.expectEqual(c.dep orelse 0xEE, r.ram[scb0 + colloff]);
        // Nothing outside the row's sprite pixels moved (background types
        // paint the pad pens too: x = 14, 15).
        try std.testing.expectEqual(@as(u8, 8), r.pix(9, 5));
        try std.testing.expectEqual(@as(u8, 3), r.coll(9, 5));
        try std.testing.expectEqual(@as(u8, 8), r.pix(10, 6));
    }
}

test "suzy: no-collide bits disable collision and the depository" {
    var r = try Rig.init();
    defer r.deinit();
    for ([_]bool{ true, false }) |via_sprsys| {
        @memset(r.ram, 0);
        r.fill_coll(3);
        var l: Lines = .{ .ram = r.ram };
        l.line(&.{ 0x11, 0x11, 0 });
        l.end();
        r.ram[scb0 + colloff] = 0xEE;
        r.s.write(0x92, if (via_sprsys) 0x20 else 0x00);
        (Scb{
            .sprctl0 = ctl0(4, 4),
            .sprctl1 = 0x10 | literal,
            .sprcoll = if (via_sprsys) 5 else 0x25,
        }).put(r.ram, scb0);
        _ = r.go(scb0, 1);
        try std.testing.expectEqual([_]u8{ 1, 1, 1, 1 }, r.row(10, 5, 4));
        try std.testing.expectEqual(@as(u8, 3), r.coll(10, 5));
        try std.testing.expectEqual(@as(u8, 0xEE), r.ram[scb0 + colloff]);
    }
    r.s.write(0x92, 0);
}

test "suzy: depository holds the highest collision number hit" {
    var r = try Rig.init();
    defer r.deinit();
    var l: Lines = .{ .ram = r.ram };
    l.line(&.{ 0x11, 0x11, 0 });
    l.end();
    // Collision buffer: 2 under x=10, 7 under x=12, 9 elsewhere but outside.
    r.fill_coll(0);
    r.ram[collbas + 5 * 80 + 5] = 0x20; // x=10 -> 2
    r.ram[collbas + 5 * 80 + 6] = 0x70; // x=12 -> 7
    r.ram[collbas + 5 * 80 + 7] = 0x09; // x=15 (not painted) -> 9
    (Scb{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal, .sprcoll = 4 }).put(r.ram, scb0);
    _ = r.go(scb0, 1);
    try std.testing.expectEqual(@as(u8, 7), r.ram[scb0 + colloff]);
    // Its own number is now in the buffer under its pixels.
    try std.testing.expectEqual(@as(u8, 4), r.coll(11, 5));
    // A second sprite over it registers 4; a sprite elsewhere 0.
    (Scb{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal, .sprcoll = 1, .next = scb0 + 0x40 }).put(r.ram, scb0);
    (Scb{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal, .sprcoll = 1, .vpos = 50 }).put(r.ram, scb0 + 0x40);
    _ = r.go(scb0, 1);
    try std.testing.expectEqual(@as(u8, 4), r.ram[scb0 + colloff]);
    try std.testing.expectEqual(@as(u8, 0), r.ram[scb0 + 0x40 + colloff]);
}

/// The four-quadrant test sprite: each quadrant one literal 4 bpp line of
/// two pens (quadrant k uses pens 2k+1, 2k+2), at (50, 50).
fn quad_sprite(r: *Rig, sprctl0: u8, start: u8) void {
    @memset(r.ram, 0);
    var l: Lines = .{ .ram = r.ram };
    l.line(&.{ 0x12, 0 });
    l.next_quadrant();
    l.line(&.{ 0x34, 0 });
    l.next_quadrant();
    l.line(&.{ 0x56, 0 });
    l.next_quadrant();
    l.line(&.{ 0x78, 0 });
    l.end();
    (Scb{ .sprctl0 = sprctl0, .sprctl1 = 0x10 | literal | start, .hpos = 50, .vpos = 50 }).put(r.ram, scb0);
    _ = r.go(scb0, 1);
}

const Px = struct { x: u16, y: u16, pen: u8 };

fn expect_only(r: *const Rig, want: []const Px) !void {
    for (want) |p| {
        errdefer std.debug.print("at ({d},{d})\n", .{ p.x, p.y });
        try std.testing.expectEqual(p.pen, r.pix(p.x, p.y));
    }
    try std.testing.expectEqual(@as(u32, @intCast(want.len)), r.count_pixels());
}

test "suzy: quadrants from each start quadrant" {
    var r = try Rig.init();
    defer r.deinit();
    // Start SE: SE (down, right) row 50 x 50,51; NE (up) row 49 x 50,51;
    // NW row 49 x 49,48; SW row 50 x 49,48.
    quad_sprite(&r, ctl0(4, 4), 0);
    try expect_only(&r, &.{
        .{ .x = 50, .y = 50, .pen = 1 }, .{ .x = 51, .y = 50, .pen = 2 },
        .{ .x = 50, .y = 49, .pen = 3 }, .{ .x = 51, .y = 49, .pen = 4 },
        .{ .x = 49, .y = 49, .pen = 5 }, .{ .x = 48, .y = 49, .pen = 6 },
        .{ .x = 49, .y = 50, .pen = 7 }, .{ .x = 48, .y = 50, .pen = 8 },
    });
    // Start NE (bit 1): NE row 50 x 50,51; NW row 50 x 49,48; SW row 51
    // x 49,48; SE row 51 x 50,51.
    quad_sprite(&r, ctl0(4, 4), 2);
    try expect_only(&r, &.{
        .{ .x = 50, .y = 50, .pen = 1 }, .{ .x = 51, .y = 50, .pen = 2 },
        .{ .x = 49, .y = 50, .pen = 3 }, .{ .x = 48, .y = 50, .pen = 4 },
        .{ .x = 49, .y = 51, .pen = 5 }, .{ .x = 48, .y = 51, .pen = 6 },
        .{ .x = 50, .y = 51, .pen = 7 }, .{ .x = 51, .y = 51, .pen = 8 },
    });
    // Start NW (3): NW row 50 x 50,49; SW row 51 x 50,49; SE row 51 x
    // 51,52; NE row 50 x 51,52.
    quad_sprite(&r, ctl0(4, 4), 3);
    try expect_only(&r, &.{
        .{ .x = 50, .y = 50, .pen = 1 }, .{ .x = 49, .y = 50, .pen = 2 },
        .{ .x = 50, .y = 51, .pen = 3 }, .{ .x = 49, .y = 51, .pen = 4 },
        .{ .x = 51, .y = 51, .pen = 5 }, .{ .x = 52, .y = 51, .pen = 6 },
        .{ .x = 51, .y = 50, .pen = 7 }, .{ .x = 52, .y = 50, .pen = 8 },
    });
    // Start SW (1): SW row 50 x 50,49; SE row 50 x 51,52; NE row 49 x
    // 51,52; NW row 49 x 50,49.
    quad_sprite(&r, ctl0(4, 4), 1);
    try expect_only(&r, &.{
        .{ .x = 50, .y = 50, .pen = 1 }, .{ .x = 49, .y = 50, .pen = 2 },
        .{ .x = 51, .y = 50, .pen = 3 }, .{ .x = 52, .y = 50, .pen = 4 },
        .{ .x = 51, .y = 49, .pen = 5 }, .{ .x = 52, .y = 49, .pen = 6 },
        .{ .x = 50, .y = 49, .pen = 7 }, .{ .x = 49, .y = 49, .pen = 8 },
    });
}

test "suzy: H and V flip mirror about the reference point" {
    var r = try Rig.init();
    defer r.deinit();
    // H flip, start SE: SE draws left from 50; NE row 49 left from 50; NW
    // (now right) row 49 x 51,52; SW row 50 x 51,52.
    quad_sprite(&r, ctl0(4, 4) | 0x20, 0);
    try expect_only(&r, &.{
        .{ .x = 50, .y = 50, .pen = 1 }, .{ .x = 49, .y = 50, .pen = 2 },
        .{ .x = 50, .y = 49, .pen = 3 }, .{ .x = 49, .y = 49, .pen = 4 },
        .{ .x = 51, .y = 49, .pen = 5 }, .{ .x = 52, .y = 49, .pen = 6 },
        .{ .x = 51, .y = 50, .pen = 7 }, .{ .x = 52, .y = 50, .pen = 8 },
    });
    // V flip: SE draws up from row 50; NE (now down) row 51.
    quad_sprite(&r, ctl0(4, 4) | 0x10, 0);
    try expect_only(&r, &.{
        .{ .x = 50, .y = 50, .pen = 1 }, .{ .x = 51, .y = 50, .pen = 2 },
        .{ .x = 50, .y = 51, .pen = 3 }, .{ .x = 51, .y = 51, .pen = 4 },
        .{ .x = 49, .y = 51, .pen = 5 }, .{ .x = 48, .y = 51, .pen = 6 },
        .{ .x = 49, .y = 50, .pen = 7 }, .{ .x = 48, .y = 50, .pen = 8 },
    });
    // Both.
    quad_sprite(&r, ctl0(4, 4) | 0x30, 0);
    try expect_only(&r, &.{
        .{ .x = 50, .y = 50, .pen = 1 }, .{ .x = 49, .y = 50, .pen = 2 },
        .{ .x = 50, .y = 51, .pen = 3 }, .{ .x = 49, .y = 51, .pen = 4 },
        .{ .x = 51, .y = 51, .pen = 5 }, .{ .x = 52, .y = 51, .pen = 6 },
        .{ .x = 51, .y = 50, .pen = 7 }, .{ .x = 52, .y = 50, .pen = 8 },
    });
}

test "suzy: a multi-line quadrant goes down, its partner up" {
    var r = try Rig.init();
    defer r.deinit();
    var l: Lines = .{ .ram = r.ram };
    l.line(&.{ 0x10, 0 }); // SE row 20
    l.line(&.{ 0x20, 0 }); // SE row 21
    l.next_quadrant();
    l.line(&.{ 0x30, 0 }); // NE row 19
    l.line(&.{ 0x40, 0 }); // NE row 18
    l.end(); // ends the sprite inside NE
    (Scb{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal, .hpos = 30, .vpos = 20 }).put(r.ram, scb0);
    _ = r.go(scb0, 1);
    try expect_only(&r, &.{
        .{ .x = 30, .y = 20, .pen = 1 }, .{ .x = 30, .y = 21, .pen = 2 },
        .{ .x = 30, .y = 19, .pen = 3 }, .{ .x = 30, .y = 18, .pen = 4 },
    });
}

/// One sprite of 4 literal pens 1,2,3,4 on two source lines (pens 5..8 on
/// the second), at (10, 5), with the given sizes.
fn sized_sprite(r: *Rig, c: Scb) void {
    @memset(r.ram, 0);
    var l: Lines = .{ .ram = r.ram };
    l.line(&.{ 0x12, 0x34, 0 });
    l.line(&.{ 0x56, 0x78, 0 });
    l.end();
    c.put(r.ram, scb0);
    _ = r.go(scb0, 1);
}

test "suzy: scaling 1x, 2x and 0.5x" {
    var r = try Rig.init();
    defer r.deinit();
    sized_sprite(&r, .{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal });
    try std.testing.expectEqual([_]u8{ 1, 2, 3, 4, 0 }, r.row(10, 5, 5));
    try std.testing.expectEqual([_]u8{ 5, 6, 7, 8, 0 }, r.row(10, 6, 5));
    try std.testing.expectEqual(@as(u32, 8), r.count_pixels());

    // 2x: $7F + $200 = $27F -> 2 pixels, remainder $7F each time; rows too.
    sized_sprite(&r, .{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal, .hsiz = 0x200, .vsiz = 0x200 });
    for ([_]u16{ 5, 6 }) |y| try std.testing.expectEqual([_]u8{ 1, 1, 2, 2, 3, 3, 4, 4, 0 }, r.row(10, y, 9));
    for ([_]u16{ 7, 8 }) |y| try std.testing.expectEqual([_]u8{ 5, 5, 6, 6, 7, 7, 8, 8, 0 }, r.row(10, y, 9));
    try std.testing.expectEqual(@as(u32, 32), r.count_pixels());

    // 0.5x: $7F + $80 = $FF -> 0, $FF + $80 -> 1 (rem $7F): odd source
    // pixels and the second source line only.
    sized_sprite(&r, .{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal, .hsiz = 0x80, .vsiz = 0x80 });
    try std.testing.expectEqual([_]u8{ 6, 8, 0 }, r.row(10, 5, 3));
    try std.testing.expectEqual(@as(u32, 2), r.count_pixels());

    // HSIZOFF 0: $100 still gives 1 pixel each; 0.5x now shows even pixels
    // ($80 -> 0, $100 -> 1).
    r.w16(0x28, 0);
    sized_sprite(&r, .{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal, .hsiz = 0x80, .vsiz = 0x100 });
    try std.testing.expectEqual([_]u8{ 2, 4, 0 }, r.row(10, 5, 3));
    r.w16(0x28, 0x7F);
}

test "suzy: stretch widens each row" {
    var r = try Rig.init();
    defer r.deinit();
    // One source line of pens 1,2, three rows (VSIZ $300), STRETCH $100:
    // HSIZ $100, $200, $300 on rows 5, 6, 7.
    var l: Lines = .{ .ram = r.ram };
    l.line(&.{ 0x12, 0 });
    l.end();
    (Scb{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x20 | literal, .vsiz = 0x300, .stretch = 0x100 }).put(r.ram, scb0);
    _ = r.go(scb0, 1);
    try std.testing.expectEqual([_]u8{ 1, 2, 0, 0, 0, 0, 0 }, r.row(10, 5, 7));
    try std.testing.expectEqual([_]u8{ 1, 1, 2, 2, 0, 0, 0 }, r.row(10, 6, 7));
    try std.testing.expectEqual([_]u8{ 1, 1, 1, 2, 2, 2, 0 }, r.row(10, 7, 7));
    try std.testing.expectEqual(@as(u32, 12), r.count_pixels());
    // HSIZ is left stretched in the register.
    try std.testing.expectEqual(@as(u16, 0x400), r.r16(0x18));

    // Reload depth 1 (no stretch loaded): STRETCH has no effect.
    @memset(r.ram, 0);
    l = .{ .ram = r.ram };
    l.line(&.{ 0x12, 0 });
    l.end();
    (Scb{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal, .vsiz = 0x300 }).put(r.ram, scb0);
    _ = r.go(scb0, 1);
    try std.testing.expectEqual(@as(u32, 6), r.count_pixels());
}

test "suzy: vertical stretch (SPRSYS bit 4)" {
    var r = try Rig.init();
    defer r.deinit();
    r.s.write(0x92, 0x10);
    defer r.s.write(0x92, 0);
    // Two source lines, VSIZ $100, STRETCH $100. Line 0: 1 row (row 5,
    // HSIZ $100); VSIZ += $100 * 1. Line 1: $7F + $200 -> 2 rows (rows 6, 7
    // with HSIZ $200, $300).
    var l: Lines = .{ .ram = r.ram };
    l.line(&.{0x10});
    l.line(&.{0x20});
    l.end();
    (Scb{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x20 | literal, .stretch = 0x100 }).put(r.ram, scb0);
    _ = r.go(scb0, 1);
    try std.testing.expectEqual([_]u8{ 1, 0, 0, 0 }, r.row(10, 5, 4));
    try std.testing.expectEqual([_]u8{ 2, 2, 0, 0 }, r.row(10, 6, 4));
    try std.testing.expectEqual([_]u8{ 2, 2, 2, 0 }, r.row(10, 7, 4));
    try std.testing.expectEqual(@as(u32, 6), r.count_pixels());
}

test "suzy: tilt shifts each row" {
    var r = try Rig.init();
    defer r.deinit();
    // TILT $0080 (half a pixel per row), 4 rows of one pixel from x=10:
    // tilt acc 0, $80, $100 -> +1, $80: x = 10, 10, 11, 11.
    var l: Lines = .{ .ram = r.ram };
    l.line(&.{0x10});
    l.end();
    (Scb{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x30 | literal, .vsiz = 0x400, .tilt = 0x0080 }).put(r.ram, scb0);
    _ = r.go(scb0, 1);
    try expect_only(&r, &.{
        .{ .x = 10, .y = 5, .pen = 1 }, .{ .x = 10, .y = 6, .pen = 1 },
        .{ .x = 11, .y = 7, .pen = 1 }, .{ .x = 11, .y = 8, .pen = 1 },
    });
    // HPOSSTRT is left tilted: 10 + 1.
    try std.testing.expectEqual(@as(u16, 11), r.r16(0x14));

    // TILT -1.0: x = 10, 9, 8, 7.
    @memset(r.ram, 0);
    l = .{ .ram = r.ram };
    l.line(&.{0x10});
    l.end();
    (Scb{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x30 | literal, .vsiz = 0x400, .tilt = 0xFF00 }).put(r.ram, scb0);
    _ = r.go(scb0, 1);
    try expect_only(&r, &.{
        .{ .x = 10, .y = 5, .pen = 1 }, .{ .x = 9, .y = 6, .pen = 1 },
        .{ .x = 8, .y = 7, .pen = 1 },  .{ .x = 7, .y = 8, .pen = 1 },
    });
}

test "suzy: stretch and tilt together draw a triangle" {
    var r = try Rig.init();
    defer r.deinit();
    // A one-pixel source line of pen 3, HSIZ $100 growing by $200 per row
    // and moving left by 1 per row, 4 rows from x=20: spans
    // [20,21) [19,22) [18,23) [17,24).
    var l: Lines = .{ .ram = r.ram };
    l.line(&.{0x30});
    l.end();
    (Scb{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x30 | literal, .hpos = 20, .vsiz = 0x400, .stretch = 0x200, .tilt = 0xFF00 }).put(r.ram, scb0);
    _ = r.go(scb0, 1);
    for (0..4) |k| {
        const y: u16 = 5 + @as(u16, @intCast(k));
        const x0: u16 = 20 - @as(u16, @intCast(k));
        const w: u16 = 1 + 2 * @as(u16, @intCast(k));
        try std.testing.expectEqual(@as(u8, 0), r.pix(x0 - 1, y));
        for (0..w) |i| try std.testing.expectEqual(@as(u8, 3), r.pix(x0 + @as(u16, @intCast(i)), y));
        try std.testing.expectEqual(@as(u8, 0), r.pix(x0 + w, y));
    }
    try std.testing.expectEqual(@as(u32, 16), r.count_pixels());
}

test "suzy: clipping to 160x102 and HOFF/VOFF" {
    var r = try Rig.init();
    defer r.deinit();
    // Left edge: x = -2 with pens 1..4 -> 3, 4 at x 0, 1.
    sized_sprite(&r, .{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal, .hpos = 0xFFFE });
    try std.testing.expectEqual([_]u8{ 3, 4, 0 }, r.row(0, 5, 3));
    try std.testing.expectEqual(@as(u8, 0), r.pix(159, 4)); // previous line's end
    try std.testing.expectEqual(@as(u32, 4), r.count_pixels());
    // Right edge: x = 158 -> 1, 2 at 158, 159; nothing wraps to the next line.
    sized_sprite(&r, .{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal, .hpos = 158 });
    try std.testing.expectEqual([_]u8{ 1, 2 }, r.row(158, 5, 2));
    try std.testing.expectEqual(@as(u8, 0), r.pix(0, 6)); // x = 160 of row 5 would land here
    try std.testing.expectEqual(@as(u32, 4), r.count_pixels());
    // Top: vpos = -1 -> only the second line, at row 0.
    sized_sprite(&r, .{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal, .vpos = 0xFFFF });
    try std.testing.expectEqual([_]u8{ 5, 6, 7, 8 }, r.row(10, 0, 4));
    try std.testing.expectEqual(@as(u32, 4), r.count_pixels());
    // Bottom: vpos = 101 -> only the first line; nothing at row 102.
    sized_sprite(&r, .{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal, .vpos = 101 });
    try std.testing.expectEqual([_]u8{ 1, 2, 3, 4 }, r.row(10, 101, 4));
    try std.testing.expectEqual(@as(u8, 0), r.ram[vidbas + 102 * 80 + 5]);
    try std.testing.expectEqual(@as(u32, 4), r.count_pixels());
    // Left-drawing sprite at x = 1 (H flip): pens at 1, 0; nothing before.
    sized_sprite(&r, .{ .sprctl0 = ctl0(4, 4) | 0x20, .sprctl1 = 0x10 | literal, .hpos = 1 });
    try std.testing.expectEqual([_]u8{ 2, 1 }, r.row(0, 5, 2));
    try std.testing.expectEqual(@as(u8, 0), r.pix(159, 4));
    try std.testing.expectEqual(@as(u32, 4), r.count_pixels());
    // HOFF/VOFF: sprite at (110, 205) with offsets (100, 200) lands at (10, 5).
    r.w16(0x04, 100);
    r.w16(0x06, 200);
    sized_sprite(&r, .{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal, .hpos = 110, .vpos = 205 });
    try std.testing.expectEqual([_]u8{ 1, 2, 3, 4 }, r.row(10, 5, 4));
    try std.testing.expectEqual(@as(u32, 8), r.count_pixels());
    r.w16(0x04, 0);
    r.w16(0x06, 0);
    // Entirely off screen: nothing drawn.
    sized_sprite(&r, .{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal, .hpos = 300 });
    try std.testing.expectEqual(@as(u32, 0), r.count_pixels());
}

test "suzy: everon marks sprites that were never on screen" {
    var r = try Rig.init();
    defer r.deinit();
    const Case = struct { kind: u8, hpos: u16, sprgo: u8, dep: u8 };
    const cases = [_]Case{
        .{ .kind = 4, .hpos = 300, .sprgo = 5, .dep = 0x80 },
        .{ .kind = 4, .hpos = 10, .sprgo = 5, .dep = 0x00 },
        .{ .kind = 4, .hpos = 300, .sprgo = 1, .dep = 0x00 },
        .{ .kind = 5, .hpos = 300, .sprgo = 5, .dep = 0x80 },
        .{ .kind = 5, .hpos = 10, .sprgo = 5, .dep = 0x00 },
        .{ .kind = 5, .hpos = 300, .sprgo = 1, .dep = 0xEE },
    };
    for (cases) |c| {
        @memset(r.ram, 0);
        var l: Lines = .{ .ram = r.ram };
        l.line(&.{ 0x11, 0 });
        l.end();
        r.ram[scb0 + colloff] = 0xEE;
        (Scb{ .sprctl0 = ctl0(4, c.kind), .sprctl1 = 0x10 | literal, .sprcoll = 2, .hpos = c.hpos }).put(r.ram, scb0);
        _ = r.go(scb0, c.sprgo);
        try std.testing.expectEqual(c.dep, r.ram[scb0 + colloff]);
    }
    // A transparent-only sprite on screen still counts as on screen.
    @memset(r.ram, 0);
    var l: Lines = .{ .ram = r.ram };
    l.line(&.{ 0x00, 0 });
    l.end();
    (Scb{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal, .sprcoll = 2 }).put(r.ram, scb0);
    _ = r.go(scb0, 5);
    try std.testing.expectEqual(@as(u8, 0), r.ram[scb0 + colloff]);
}

test "suzy: skip bit, zero link and list order" {
    var r = try Rig.init();
    defer r.deinit();
    var l: Lines = .{ .ram = r.ram };
    l.line(&.{ 0x11, 0 });
    l.end();
    const s1 = scb0 + 0x40;
    const s2 = scb0 + 0x80;
    // First: skipped (only its first 5 bytes are valid: garbage after).
    r.ram[scb0] = ctl0(4, 4);
    r.ram[scb0 + 1] = 0x04;
    r.ram[scb0 + 2] = 1;
    r.ram[scb0 + 3] = @truncate(s1);
    r.ram[scb0 + 4] = @truncate(s1 >> 8);
    @memset(r.ram[scb0 + 5 .. scb0 + 0x20], 0xFF);
    r.ram[scb0 + colloff] = 0xEE;
    // Second: drawn at row 5, links to a third whose link $0080 (high
    // byte 0) ends the list.
    (Scb{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal, .sprcoll = 1, .next = s2 }).put(r.ram, s1);
    (Scb{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal, .sprcoll = 1, .next = 0x0080, .vpos = 7 }).put(r.ram, s2);
    // A sprite at $0080 would draw at row 9 if the link were followed.
    (Scb{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal, .vpos = 9 }).put(r.ram, 0x0080);
    _ = r.go(scb0, 1);
    try std.testing.expectEqual(@as(u8, 0xEE), r.ram[scb0 + colloff]);
    try std.testing.expectEqual([_]u8{ 1, 1 }, r.row(10, 5, 2));
    try std.testing.expectEqual([_]u8{ 1, 1 }, r.row(10, 7, 2));
    try std.testing.expectEqual([_]u8{ 0, 0 }, r.row(10, 9, 2));
    // The engine registers show the last SCB.
    try std.testing.expectEqual(s2, r.r16(0x2C));
    try std.testing.expectEqual(@as(u16, 0x0080), r.r16(0x10));
    // An empty list (SCBNEXT high byte 0) draws nothing and costs nothing.
    try std.testing.expectEqual(@as(u32, 0), r.go(0x00FF, 1));
}

test "suzy: reload depth 0 reuses the previous sizes" {
    var r = try Rig.init();
    defer r.deinit();
    var l: Lines = .{ .ram = r.ram };
    l.line(&.{ 0x11, 0 });
    l.end();
    // First sprite 2x, second reloads nothing: also 2x.
    (Scb{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal, .hsiz = 0x200, .vsiz = 0x100, .next = scb0 + 0x40 }).put(r.ram, scb0);
    (Scb{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x00 | literal, .vpos = 20 }).put(r.ram, scb0 + 0x40);
    _ = r.go(scb0, 1);
    try std.testing.expectEqual([_]u8{ 1, 1, 1, 1, 0 }, r.row(10, 5, 5));
    try std.testing.expectEqual([_]u8{ 1, 1, 1, 1, 0 }, r.row(10, 20, 5));
}

test "suzy: background sprite clears a buffer region" {
    var r = try Rig.init();
    defer r.deinit();
    r.fill_video(7);
    r.fill_coll(9);
    // Packed 1 bpp, pen index 0 -> pen 0: 16 + 16 pixels of 0 (two packets
    // of count 15), 4 rows at 2x vertical. Type 0 writes video 0 and
    // collision 0 (the sprite's number).
    var b: Bits = .{};
    b.put(0b0_1111, 5);
    b.put(0, 1);
    b.put(0b0_1111, 5);
    b.put(0, 1);
    b.put(0, 5);
    b.put(0, 8);
    var l: Lines = .{ .ram = r.ram };
    l.bits(&b);
    l.bits(&b);
    l.end();
    (Scb{ .sprctl0 = ctl0(1, 0), .hpos = 3, .vsiz = 0x200, .palette = .{ 0, 0, 0, 0, 0, 0, 0, 0 } }).put(r.ram, scb0);
    _ = r.go(scb0, 1);
    for (5..9) |y_us| {
        const y: u16 = @intCast(y_us);
        try std.testing.expectEqual(@as(u8, 7), r.pix(2, y));
        for (3..35) |x| try std.testing.expectEqual(@as(u8, 0), r.pix(@intCast(x), y));
        try std.testing.expectEqual(@as(u8, 0), r.coll(20, y));
        try std.testing.expectEqual(@as(u8, 7), r.pix(35, y));
        try std.testing.expectEqual(@as(u8, 9), r.coll(35, y));
    }
    try std.testing.expectEqual(@as(u8, 7), r.pix(3, 4));
    try std.testing.expectEqual(@as(u8, 7), r.pix(3, 9));
}

test "suzy: tick estimate and pixel counter" {
    var r = try Rig.init();
    defer r.deinit();
    var l: Lines = .{ .ram = r.ram };
    l.line(&.{ 0x12, 0x34, 0 });
    l.end();
    (Scb{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal, .sprcoll = 1 }).put(r.ram, scb0);
    const before = r.s.pixels_drawn;
    const t = r.go(scb0, 1);
    // Header 50; bytes: 2 offset bytes + 3 data bytes = 5 x 5; 4 pixels
    // x 5; 4 collision pixels x 5.
    try std.testing.expectEqual(@as(u32, 50 + 25 + 20 + 20), t);
    try std.testing.expectEqual(@as(u32, 4), r.s.pixels_drawn - before);
}

test "suzy: SPRSYS, SPRGO and register reads" {
    var r = try Rig.init();
    defer r.deinit();
    // A low-byte write zeroes the high byte; the high byte alone keeps the low.
    r.w16(0x04, 0x1234);
    try std.testing.expectEqual(@as(u16, 0x1234), r.r16(0x04));
    r.s.write(0x04, 0x56);
    try std.testing.expectEqual(@as(u16, 0x0056), r.r16(0x04));
    r.s.write(0x05, 0x78);
    try std.testing.expectEqual(@as(u16, 0x7856), r.r16(0x04));
    try std.testing.expectEqual(@as(u8, 0x01), r.s.read(0x88));
    // SPRSYS: bit 0 while a list is pending, lefthand and vstretch echo.
    r.s.write(0x92, 0x18);
    try std.testing.expect(r.s.lefthand());
    r.ram[scb0 + 1] = 0;
    r.ram[scb0 + 3] = 0;
    r.ram[scb0 + 4] = 0; // a skip-free sprite with next = 0 and data = 0
    r.ram[0] = 0;
    r.w16(0x10, scb0);
    r.s.write(0x91, 1);
    try std.testing.expectEqual(@as(u8, 0x19), r.s.read(0x92));
    _ = r.s.run_sprites(r.ram);
    try std.testing.expectEqual(@as(u8, 0x18), r.s.read(0x92));
    try std.testing.expect(!r.s.sprites_pending());
    // Without SUZYBUSEN nothing is pending.
    r.s.write(0x90, 0);
    r.s.write(0x91, 1);
    try std.testing.expect(!r.s.sprites_pending());
    r.s.reset();
    try std.testing.expectEqual(@as(u8, 0), r.s.read(0x92));
}

test "suzy: a list that never ends is capped" {
    var r = try Rig.init();
    defer r.deinit();
    // A sprite linking to itself whose lines are all offset 2 (never 0).
    @memset(r.ram[0x8000..0xF000], 0x02);
    (Scb{ .sprctl0 = ctl0(4, 4), .sprctl1 = 0x10 | literal, .next = scb0, .data = 0x8000, .vpos = 300 }).put(r.ram, scb0);
    const t = r.go(scb0, 1);
    try std.testing.expect(t >= core.suzy.tick_cost.run_cap);
    try std.testing.expect(t < core.suzy.tick_cost.run_cap + 1_000_000);
}
