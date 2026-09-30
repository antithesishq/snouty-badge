//! Page store unit tests (SPEC.md section 10, core/kstore.zig): zero page,
//! sharing, tail pages, eviction order, PoolFull, truncation, reference
//! accounting over many cycles, and exact restore of a whole console.
//! Ported from Snouty Boy's tests/kstore_unit.zig in M3 (the store is copied
//! verbatim, SPEC.md section 7); the synthetic tests are unchanged, the
//! console test uses the Game Gear's four regions.
const std = @import("std");
const core = @import("core");
const kstore = core.kstore;
const Gg = core.Gg;
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

const S = kstore.Store(page);
/// Backing memory for the synthetic stores (the tests run one at a time).
var mem: [8192]u8 align(4) = undefined;

/// A store of `pool_pages` pages and `max_keyframes` tables in `mem`, as the
/// frontend lays one out in its arena.
fn make(pool_pages: usize, max_keyframes: usize) S {
    return S.init(&mem, pool_pages, max_keyframes, n_pages);
}

fn expect_same(x: *const Bufs, y: *const Bufs) !void {
    try expect(std.mem.eql(u8, &x.a, &y.a));
    try expect(std.mem.eql(u8, &x.b, &y.b));
    try expect(std.mem.eql(u8, &x.c, &y.c));
}

test "kstore: layout arithmetic" {
    // 10 pages of 64 B, 3 tables of 8 references, 10 free entries, 10 counts.
    try expectEqual(@as(usize, 640 + 48 + 20 + 10), kstore.bytes_for(page, 10, 3, n_pages));
    try expectEqual(@as(usize, 10), kstore.pages_fitting(page, 718, 3, n_pages));
    try expectEqual(@as(usize, 9), kstore.pages_fitting(page, 717, 3, n_pages));
    try expectEqual(@as(usize, 0), kstore.pages_fitting(page, 48, 3, n_pages));
    // The store stays inside what bytes_for asked for.
    var s = make(10, 3);
    const end = @intFromPtr(&mem) + kstore.bytes_for(page, 10, 3, n_pages);
    try expect(@intFromPtr(s.refs.ptr + s.refs.len) <= end);
    try expectEqual(@as(usize, 10), s.capacity_pages());
    var x: Bufs = .{};
    x.fill(4);
    try s.put(x.const_regions());
    try expect(s.check());
}

test "kstore: page count with tail and empty regions" {
    try expectEqual(@as(usize, 8), n_pages);
    try expectEqual(@as(usize, 0), kstore.pages_for(512, .{ 0, 0, 0, 0 }));
    try expectEqual(@as(usize, 1 + 32 + 64), kstore.pages_for(512, .{ 1, 0x4000, 0x8000, 0 }));
    // The Game Gear at the default 128 B page: Small, RAM, VRAM, cart RAM.
    try expectEqual(@as(usize, (@sizeOf(Gg.Small) + 127) / 128 + 64 + 128 + 64), gg_pages);
}

test "kstore: all-zero state costs no pool pages" {
    var s = make(16, 4);
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
    var s = make(32, 4);
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
    var s = make(20, 8);
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
    var s = make(64, 3);
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
    var s = make(12, 4);
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
    var s = make(64, 8);
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
    var s = make(30, 16);
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

const gg_page = 128;
/// The Game Gear's regions (`Gg.state_regions`): Small, RAM, VRAM, cart RAM.
const gg_lens = [4]usize{ @sizeOf(Gg.Small), 0x2000, 0x4000, core.cart_ram_size };
const gg_pages = kstore.pages_for(gg_page, gg_lens);
const GgStore = kstore.Store(gg_page);

/// Name of the first differing field, or null. VDP fields are named
/// `vdp.<field>` so a VRAM difference reads as such.
fn diff(a: *const Gg.Keyframe, b: *const Gg.Keyframe) ?[]const u8 {
    inline for (@typeInfo(Gg.Keyframe).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "vdp")) {
            inline for (@typeInfo(core.vdp.Vdp).@"struct".field_names) |v| {
                if (!std.meta.eql(@field(a.vdp, v), @field(b.vdp, v))) return "vdp." ++ v;
            }
        } else if (!std.meta.eql(@field(a, name), @field(b, name))) return name;
    }
    return null;
}

test "kstore: a console round-trips exactly (Gg.Keyframe field by field)" {
    const gpa = std.testing.allocator;
    try expectEqual(@as(usize, 0x2000), core.cart_ram_size);
    const store_mem = try gpa.alignedAlloc(u8, .@"4", kstore.bytes_for(gg_page, 600, 8, gg_pages));
    defer gpa.free(store_mem);
    var store_v = GgStore.init(store_mem, 600, 8, gg_pages);
    const store = &store_v;
    const gg = try gpa.create(Gg);
    defer gpa.destroy(gg);
    const want = try gpa.create(Gg.Keyframe);
    defer gpa.destroy(want);
    const got = try gpa.create(Gg.Keyframe);
    defer gpa.destroy(got);
    var small: Gg.Small = undefined;

    // A 32 KB ROM of NOPs.
    const rom: [0x8000]u8 = @splat(0);
    gg.init_in_place(core.Rom.from_slice(&rom));
    for (0..3) |_| gg.step_frame(0);
    gg.ram[0x1FFF] = 0x22;
    gg.vdp.vram[0x2001] = 0x11;
    gg.vdp.cram[5] = 0x0ABC;
    gg.vdp.regs[7] = 0x3C;
    gg.cart_ram[0x1FFF] = 0x33;
    gg.mapper.bank[2] = 1;
    gg.sync_map();
    gg.cpu.a = 0x55;
    gg.snapshot(want);
    gg.save_small(&small);
    try store.put(gg.state_regions(&small));
    // Whatever the console does next, the store brings it back.
    for (0..7) |_| gg.step_frame(0xFF);
    @memset(&gg.vdp.vram, 0xA5);
    @memset(&gg.ram, 0x5A);
    @memset(&gg.cart_ram, 0x77);
    gg.vdp.cram[5] = 0;
    gg.mapper.bank[2] = 0;
    gg.cpu.a = 0;
    store.get(0, gg.state_regions(&small));
    gg.load_small(&small);
    gg.snapshot(got);
    if (diff(want, got)) |field| {
        std.debug.print("field '{s}' differs after restore\n", .{field});
        return error.RestoreDiffers;
    }
    // load_small rebuilt the read map for the restored mapper.
    try expectEqual(gg.rom.banks[1].? + 0x400, gg.read_map[33].?);
    try expect(store.check());
}
