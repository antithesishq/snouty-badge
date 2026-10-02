//! core/cart.zig: the `.lnx` header / headerless parser and the block
//! table, on synthetic data (SPEC.md sections 7 and 11, 18.3).
const std = @import("std");
const core = @import("core");
const cart = core.cart;
const testing = std.testing;

/// A 64-byte header: bank 0 page size `bank0`, bank 1 `bank1`, the name
/// "Test Cart", maker "Snouty", then `rotation` and `eeprom`.
fn header(bank0: u16, bank1: u16, rotation: u8, eeprom: u8) [64]u8 {
    var h: [64]u8 = @splat(0);
    @memcpy(h[0..4], "LYNX");
    std.mem.writeInt(u16, h[4..6], bank0, .little);
    std.mem.writeInt(u16, h[6..8], bank1, .little);
    std.mem.writeInt(u16, h[8..10], 1, .little);
    @memcpy(h[10..19], "Test Cart");
    @memcpy(h[42..48], "Snouty");
    h[58] = rotation;
    h[60] = eeprom;
    return h;
}

var buf: [64 + 4096]u8 = undefined;

fn file_with(h: [64]u8, data_len: usize) []const u8 {
    @memcpy(buf[0..64], &h);
    for (buf[64..][0..data_len], 0..) |*b, i| b.* = @truncate(i * 3 + i / 512);
    return buf[0 .. 64 + data_len];
}

test "cart: headered 128 KB bank, short file" {
    const f = file_with(header(512, 0, 0, 0), 1024 + 100);
    const l = cart.parse(f, @intCast(f.len));
    try testing.expectEqual(cart.Refusal.ok, l.verdict);
    try testing.expect(l.headered);
    try testing.expectEqual(@as(u32, 64), l.data_offset);
    try testing.expectEqual(@as(u32, 512), l.block_size);
    try testing.expectEqual(@as(u32, 128 * 1024), l.bank_size());
    try testing.expectEqual(@as(u32, 1124), l.data_size);
    try testing.expectEqualStrings("Test Cart", l.title());
    try testing.expectEqualStrings("Snouty", cart.trim(&l.manufacturer));
    try testing.expectEqual(@as(u16, 1), l.version);
    try testing.expect(!l.warn_eeprom());

    const c = cart.Cart.from_slice(&l, f);
    // Two whole blocks by pointer, the partial third through the slice.
    try testing.expectEqual(@as(u32, 2), c.direct_blocks());
    try testing.expectEqual(f[64], c.read(0, 0));
    try testing.expectEqual(f[64 + 511], c.read(0, 511));
    try testing.expectEqual(f[64 + 512 + 7], c.read(1, 7));
    try testing.expectEqual(f[64 + 1024 + 99], c.read(2, 99));
    // Past the file, and a block beyond it: open bus.
    try testing.expectEqual(@as(u8, 0xFF), c.read(2, 100));
    try testing.expectEqual(@as(u8, 0xFF), c.read(200, 0));
    // The offset wraps at the block size (the ripple counter).
    try testing.expectEqual(c.read(1, 3), c.read(1, 512 + 3));
}

test "cart: header block sizes 256, 1024, 2048" {
    const cases = [_][2]u32{ .{ 256, 8 }, .{ 1024, 10 }, .{ 2048, 11 } };
    for (cases) |cs| {
        const f = file_with(header(@intCast(cs[0]), 0, 0, 0), 4096);
        const l = cart.parse(f, @intCast(f.len));
        try testing.expectEqual(cart.Refusal.ok, l.verdict);
        try testing.expectEqual(cs[0], l.block_size);
        try testing.expectEqual(@as(u5, @intCast(cs[1])), l.block_shift);
        const c = cart.Cart.from_slice(&l, f);
        try testing.expectEqual(4096 / cs[0], c.direct_blocks());
        try testing.expectEqual(f[64 + cs[0] + 5], c.read(1, 5));
    }
}

test "cart: headered refusals and the EEPROM warning" {
    var f = file_with(header(512, 512, 0, 0), 512);
    try testing.expectEqual(cart.Refusal.bank1, cart.parse(f, @intCast(f.len)).verdict);
    f = file_with(header(512, 0, 1, 0), 512);
    try testing.expectEqual(cart.Refusal.rotation, cart.parse(f, @intCast(f.len)).verdict);
    f = file_with(header(512, 0, 2, 0), 512);
    try testing.expectEqual(cart.Refusal.rotation, cart.parse(f, @intCast(f.len)).verdict);
    f = file_with(header(768, 0, 0, 0), 512);
    try testing.expectEqual(cart.Refusal.bad_bank0, cart.parse(f, @intCast(f.len)).verdict);
    f = file_with(header(0, 0, 0, 0), 512);
    try testing.expectEqual(cart.Refusal.bad_bank0, cart.parse(f, @intCast(f.len)).verdict);
    // A header and nothing after it.
    f = file_with(header(512, 0, 0, 0), 0);
    try testing.expectEqual(cart.Refusal.empty, cart.parse(f, @intCast(f.len)).verdict);
    // EEPROM (93C46 = 1): accepted, flagged.
    f = file_with(header(512, 0, 0, 1), 512);
    const l = cart.parse(f, @intCast(f.len));
    try testing.expectEqual(cart.Refusal.ok, l.verdict);
    try testing.expect(l.warn_eeprom());
}

test "cart: a headered file over 512 KB of data is refused, not clipped (EM-05)" {
    // parse() sees the first 64 bytes and the file size, as the drive scan
    // and the embedded path give it.
    const h = header(512, 0, 0, 0);
    // The review's case: a 128 KB bank declared, 600 KB on the drive.
    try testing.expectEqual(cart.Refusal.too_big, cart.parse(&h, 600 * 1024).verdict);
    // The bound is the headerless one plus the header, for every bank size.
    for ([_]u16{ 256, 512, 1024, 2048 }) |bank0| {
        const hb = header(bank0, 0, 0, 0);
        try testing.expectEqual(cart.Refusal.too_big, cart.parse(&hb, cart.max_size + 64 + 1).verdict);
        const l = cart.parse(&hb, cart.max_size + 64);
        try testing.expectEqual(cart.Refusal.ok, l.verdict);
        try testing.expectEqual(l.bank_size(), l.data_size);
    }
    // A whole 128 KB bank plus its header: ok, every byte used.
    const full = cart.parse(&h, 128 * 1024 + 64);
    try testing.expectEqual(cart.Refusal.ok, full.verdict);
    try testing.expectEqual(@as(u32, 128 * 1024), full.data_size);
    // Short homebrew still runs.
    try testing.expectEqual(cart.Refusal.ok, cart.parse(&h, 64 + 3000).verdict);
    try testing.expectEqualStrings("over 512 KB", cart.Refusal.too_big.text());
}

test "cart: headerless block size from the file size" {
    // Only the size matters for a headerless file; `head` is its first bytes.
    var head: [64]u8 = @splat(0);
    head[0] = 0x80;
    head[1] = 0x08;
    const cases = [_][2]u32{
        .{ 128 * 1024, 512 },
        .{ 4096, 512 },
        .{ 128 * 1024 + 1, 1024 },
        .{ 256 * 1024, 1024 },
        .{ 512 * 1024, 2048 },
    };
    for (cases) |cs| {
        const l = cart.parse(&head, cs[0]);
        try testing.expectEqual(cart.Refusal.ok, l.verdict);
        try testing.expect(!l.headered);
        try testing.expectEqual(@as(u32, 0), l.data_offset);
        try testing.expectEqual(cs[1], l.block_size);
        try testing.expectEqual(cs[0], l.data_size);
    }
    try testing.expectEqual(cart.Refusal.too_big, cart.parse(&head, 512 * 1024 + 1).verdict);
    try testing.expectEqual(cart.Refusal.empty, cart.parse(&.{}, 0).verdict);
    // Shorter than a header, not "LYNX": headerless.
    const l = cart.parse("LYN", 3);
    try testing.expectEqual(cart.Refusal.ok, l.verdict);
    try testing.expect(!l.headered);
}

test "cart: headerless 128 KB dump maps every block" {
    const S = struct {
        var dump: [128 * 1024]u8 = undefined;
    };
    for (&S.dump, 0..) |*b, i| b.* = @truncate(i ^ (i >> 9));
    const l = cart.parse(&S.dump, S.dump.len);
    const c = cart.Cart.from_slice(&l, &S.dump);
    try testing.expectEqual(@as(u32, 256), c.direct_blocks());
    for ([_]u8{ 0, 1, 127, 255 }) |blk| {
        for ([_]u32{ 0, 1, 300, 511 }) |off| {
            try testing.expectEqual(S.dump[@as(u32, blk) * 512 + off], c.read(blk, off));
        }
    }
}

test "cart: the fallback reader serves null blocks" {
    const Ctx = struct {
        fn read(_: *const anyopaque, offset: u32) u8 {
            return @truncate(offset * 5);
        }
    };
    const head: [64]u8 = @splat(0);
    const l = cart.parse(&head, 64 * 1024);
    var c = cart.Cart.empty(&l);
    c.read_fallback = .{ .ctx = @ptrFromInt(@alignOf(usize)), .func = &Ctx.read };
    try testing.expectEqual(@as(u8, @truncate((3 * 512 + 9) * 5)), c.read(3, 9));
    try testing.expectEqual(@as(u8, 0xFF), c.read(200, 0)); // past 64 KB
}
