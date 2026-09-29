//! Page store unit tests (SPEC.md 19.3, core/kstore.zig): zero page,
//! sharing, tail pages, eviction order, PoolFull, truncation, reference
//! accounting over many cycles, and exact restore of a whole console.
const std = @import("std");
const core = @import("core");
const kstore = core.kstore;
const Gb = core.Gb;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

// Small synthetic layout: page 64, regions of 100 (two pages, the second a
// 36-byte tail), 256, 128 and 0 bytes: 2 + 4 + 2 + 0 = 8 pages.
const page = 64;
const lens = [4]usize{ 100, 256, 128, 0 };
const n_pages = kstore.pages_for(page, lens);

const Bufs = struct {
    a: [100]u8 = @splat(0),
    b: [256]u8 = @splat(0),
    c: [128]u8 = @splat(0),

    fn regions(x: *Bufs) [4][]u8 {
        return .{ &x.a, &x.b, &x.c, &.{} };
    }
    fn const_regions(x: *Bufs) [4][]const u8 {
        return .{ &x.a, &x.b, &x.c, &.{} };
    }
    /// Page-distinct content: page i gets marker bytes derived from `tag`.
    fn fill(x: *Bufs, tag: u8) void {
        for (&x.a, 0..) |*v, i| v.* = tag +% @as(u8, @intCast(i / page)) +% 1;
        for (&x.b, 0..) |*v, i| v.* = tag +% @as(u8, @intCast(i / page)) +% 3;
        for (&x.c, 0..) |*v, i| v.* = tag +% @as(u8, @intCast(i / page)) +% 7;
    }
};

fn expect_same(x: *const Bufs, y: *const Bufs) !void {
    try expect(std.mem.eql(u8, &x.a, &y.a));
    try expect(std.mem.eql(u8, &x.b, &y.b));
    try expect(std.mem.eql(u8, &x.c, &y.c));
}

test "kstore: page count with tail and empty regions" {
    try expectEqual(@as(usize, 8), n_pages);
    try expectEqual(@as(usize, 0), kstore.pages_for(512, .{ 0, 0, 0, 0 }));
    try expectEqual(@as(usize, 1 + 32 + 64), kstore.pages_for(512, .{ 1, 0x4000, 0x8000, 0 }));
}

test "kstore: all-zero state costs no pool pages" {
    const S = kstore.Store(page, 16, 4, n_pages);
    var s: S = undefined;
    s.reset();
    var x: Bufs = .{};
    try s.put(x.const_regions());
    try expectEqual(@as(usize, 0), s.pages_in_use());
    try expectEqual(@as(usize, n_pages), s.last_zero);
    try expectEqual(@as(usize, 0), s.last_copied);
    x.fill(9);
    var y: Bufs = undefined;
    s.get(0, y.regions());
    try expect(std.mem.allEqual(u8, &y.a, 0) and std.mem.allEqual(u8, &y.b, 0) and std.mem.allEqual(u8, &y.c, 0));
    try expect(s.check());
}

test "kstore: unchanged pages are shared, changed ones copied" {
    const S = kstore.Store(page, 32, 4, n_pages);
    var s: S = undefined;
    s.reset();
    var x: Bufs = .{};
    x.fill(1);
    try s.put(x.const_regions());
    try expectEqual(@as(usize, n_pages), s.last_copied);
    try expectEqual(@as(usize, n_pages), s.pages_in_use());

    try s.put(x.const_regions());
    try expectEqual(@as(usize, 0), s.last_copied);
    try expectEqual(@as(usize, n_pages), s.last_shared);
    try expectEqual(@as(usize, n_pages), s.pages_in_use());

    // One byte in the tail page of region 0, one in the middle of region 1,
    // and one page of region 2 zeroed.
    x.a[99] ^= 0xFF;
    x.b[130] ^= 0x01;
    @memset(x.c[64..128], 0);
    try s.put(x.const_regions());
    try expectEqual(@as(usize, 2), s.last_copied);
    try expectEqual(@as(usize, 1), s.last_zero);
    try expectEqual(@as(usize, n_pages - 3), s.last_shared);
    try expectEqual(@as(usize, n_pages + 2), s.pages_in_use());
    try expect(s.check());

    var y: Bufs = undefined;
    s.get(0, y.regions());
    try expect_same(&x, &y);
    x.a[99] ^= 0xFF;
    x.b[130] ^= 0x01;
    x.fill(1);
    s.get(2, y.regions());
    try expect_same(&x, &y);
    // Only the pages the newest changed are its own.
    try expectEqual(@as(usize, 2), s.pages_owned(0));
}

test "kstore: the pool evicts the oldest keyframes first" {
    // Each keyframe is 8 distinct pages; 20 pages hold two plus change.
    const S = kstore.Store(page, 20, 8, n_pages);
    var s: S = undefined;
    s.reset();
    var x: Bufs = .{};
    for (0..5) |k| {
        x.fill(@intCast(k * 16));
        try s.put(x.const_regions());
        try expect(s.check());
        try expect(s.count <= 2);
    }
    try expectEqual(@as(usize, 2), s.count);
    try expectEqual(@as(usize, 1), s.last_evicted);
    // Newest two are 4 and 3.
    var y: Bufs = undefined;
    s.get(0, y.regions());
    x.fill(4 * 16);
    try expect_same(&x, &y);
    s.get(1, y.regions());
    x.fill(3 * 16);
    try expect_same(&x, &y);
}

test "kstore: max_keyframes evicts the oldest" {
    const S = kstore.Store(page, 64, 3, n_pages);
    var s: S = undefined;
    s.reset();
    var x: Bufs = .{};
    for (0..5) |k| {
        x.a[0] = @intCast(k + 1); // one page differs per keyframe
        try s.put(x.const_regions());
    }
    try expectEqual(@as(usize, 3), s.count);
    var y: Bufs = undefined;
    for (0..3) |age| {
        s.get(age, y.regions());
        try expectEqual(@as(u8, @intCast(5 - age)), y.a[0]);
    }
    try expectEqual(@as(usize, 3), s.pages_in_use());
    try expect(s.check());
}

test "kstore: PoolFull keeps the previous keyframe" {
    // 12 pages: one full keyframe (8) fits, two do not.
    const S = kstore.Store(page, 12, 4, n_pages);
    var s: S = undefined;
    s.reset();
    var x: Bufs = .{};
    x.fill(1);
    try s.put(x.const_regions());
    x.fill(50);
    try std.testing.expectError(error.PoolFull, s.put(x.const_regions()));
    try expectEqual(@as(usize, 1), s.count);
    try expect(s.check());
    var y: Bufs = undefined;
    s.get(0, y.regions());
    x.fill(1);
    try expect_same(&x, &y);
    // After a reset one keyframe always fits.
    s.reset();
    x.fill(50);
    try s.put(x.const_regions());
    try expectEqual(@as(usize, 8), s.pages_in_use());
}

test "kstore: drop_newest truncates and later puts share with the new head" {
    const S = kstore.Store(page, 64, 8, n_pages);
    var s: S = undefined;
    s.reset();
    var x: Bufs = .{};
    x.fill(3);
    for (0..5) |k| {
        x.b[0] = @intCast(k);
        try s.put(x.const_regions());
    }
    s.drop_newest(2);
    try expectEqual(@as(usize, 3), s.count);
    try expect(s.check());
    var y: Bufs = undefined;
    s.get(0, y.regions());
    try expectEqual(@as(u8, 2), y.b[0]);
    x.b[0] = 2;
    try s.put(x.const_regions());
    try expectEqual(@as(usize, 0), s.last_copied);
    s.drop_oldest(10);
    try expectEqual(@as(usize, 0), s.count);
    try expectEqual(@as(usize, 0), s.pages_in_use());
    try expect(s.check());
}

test "kstore: accounting never leaks over many put/evict/drop cycles" {
    const S = kstore.Store(page, 30, 16, n_pages);
    var s: S = undefined;
    s.reset();
    var x: Bufs = .{};
    var seed: u32 = 12345;
    for (0..3000) |_| {
        seed = seed *% 1_664_525 +% 1_013_904_223;
        const r = seed >> 8;
        switch (r % 16) {
            0 => s.drop_newest(r >> 4 & 3),
            1 => s.drop_oldest(r >> 4 & 3),
            else => {
                // Mutate a few random bytes, sometimes zero a page.
                const bytes = x.regions();
                for (0..(r >> 4) % 4) |j| {
                    const reg = bytes[(r >> @intCast(8 + j)) % 3];
                    reg[(r >> 12) % reg.len] +%= @intCast(j + 1);
                }
                if ((r >> 20) % 5 == 0) @memset(x.b[64..128], 0);
                s.put(x.const_regions()) catch {
                    try expectEqual(@as(usize, 1), s.count);
                    s.reset();
                    try s.put(x.const_regions());
                };
                var y: Bufs = undefined;
                s.get(0, y.regions());
                try expect_same(&x, &y);
            },
        }
        try expect(s.check());
    }
}

// ---- A whole console ----

const gb_page = 512;
const max_pages = kstore.pages_for(gb_page, .{ @sizeOf(Gb.Small), 0x4000, 0x8000, Gb.max_cart_ram });
const GbStore = kstore.Store(gb_page, 400, 8, max_pages);

fn diff(a: *const Gb.Keyframe, b: *const Gb.Keyframe) ?[]const u8 {
    inline for (@typeInfo(Gb.Small).@"struct".field_names) |name| {
        if (!std.meta.eql(@field(a.small, name), @field(b.small, name))) return name;
    }
    inline for (.{ "vram", "wram", "cart_ram" }) |name| {
        if (!std.meta.eql(@field(a, name), @field(b, name))) return name;
    }
    return null;
}

var ram: [0x2000]u8 = undefined;

test "kstore: a console round-trips exactly (Gb.Keyframe field by field)" {
    const gpa = std.testing.allocator;
    const store = try gpa.create(GbStore);
    defer gpa.destroy(store);
    store.reset();
    const gb = try gpa.create(Gb);
    defer gpa.destroy(gb);
    const want = try gpa.create(Gb.Keyframe);
    defer gpa.destroy(want);
    const got = try gpa.create(Gb.Keyframe);
    defer gpa.destroy(got);
    var small: Gb.Small = undefined;

    // A ROM of NOPs with an MBC5 + 8 KB RAM header, run in both models.
    var rom: [0x8000]u8 = @splat(0);
    rom[0x147] = 0x1A;
    rom[0x149] = 0x02;
    try expectEqual(@as(usize, 0x2000), core.mmu.cart_ram_len(&rom));
    inline for (.{ core.Model.dmg, core.Model.cgb }) |model| {
        store.reset();
        gb.* = Gb.init(&rom, model, &ram);
        for (0..3) |_| gb.step_frame(0);
        gb.vram[0x2001] = 0x11;
        gb.wram[0x7FFF] = 0x22;
        gb.cart_ram[0x1FFF] = 0x33;
        gb.io[0x42] = 0x44;
        gb.cpu.a = 0x55;
        gb.snapshot(want);
        gb.save_small(&small);
        try store.put(gb.state_regions(&small));
        // Whatever the console does next, the store brings it back.
        for (0..7) |_| gb.step_frame(0xFF);
        @memset(&gb.vram, 0xA5);
        @memset(&gb.wram, 0x5A);
        @memset(gb.cart_ram, 0x77);
        gb.cpu.a = 0;
        store.get(0, gb.state_regions(&small));
        gb.load_small(&small);
        gb.snapshot(got);
        if (diff(want, got)) |field| {
            std.debug.print("{s}: field '{s}' differs after restore\n", .{ @tagName(model), field });
            return error.RestoreDiffers;
        }
        try expect(gb.pal_dirty);
        try expect(store.check());
    }
}
