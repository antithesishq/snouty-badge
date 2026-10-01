//! boot: known-answer tests from public sources (no ROM files needed).
const std = @import("std");
const boot = @import("core").boot;

/// cc65 libsrc/lynx/bootldr.s (Karri Kaksonen, 2011; cc65 is zlib
/// licensed): the one-block encrypted loader cc65's `lynx` target puts in
/// front of every cart, and its plaintext as listed in that file's comments.
/// https://github.com/cc65/cc65/blob/master/libsrc/lynx/bootldr.s
const cc65_encrypted = [_]u8{
    0xff, 0xb6, 0xbb, 0x82, 0xd5, 0x9f, 0x48, 0xcf,
    0x23, 0x37, 0x8e, 0x07, 0x38, 0xf5, 0xb6, 0x30,
    0xd6, 0x2f, 0x12, 0x29, 0x9f, 0x43, 0x5b, 0x2e,
    0xf5, 0x66, 0x5c, 0xdb, 0x93, 0x1a, 0x78, 0x55,
    0x5e, 0xc9, 0x0d, 0x72, 0x1b, 0xe9, 0xd8, 0x4d,
    0x2f, 0xe4, 0x95, 0xc0, 0x4f, 0x7f, 0x1b, 0x66,
    0x8b, 0xa7, 0xfc, 0x21,
};
const cc65_plain = [_]u8{
    0x9C, 0xF9, 0xFF, // stz MAPCTL
    0xA0, 0x1F, 0xA9, 0x00, 0x99, 0xA0, 0xFD, 0x88, 0x10, 0xFA, // clear palette
    0xA9, 0x04, 0x8D, 0x8C, 0xFD, // SERCTL = 4
    0xA9, 0x1A, 0x8D, 0x8A, 0xFD, // IODIR = $1A
    0xA9, 0x0B, 0x85, 0x1A, 0x8D, 0x8B, 0xFD, // IODAT = $0B
    0xA2, 0x00, 0xA0, 0x97, 0xAD, 0xB2, 0xFC, 0x9D, 0x68, 0xFB, 0xE8, 0x88, 0xD0, 0xF6, // read 151 bytes to $FB68
    0x4C, 0x68, 0xFB, // jmp $FB68
    0x00, 0x00, 0x00, // spares
};

/// lynx-encryption-tools loaders.h (David Huseby, zlib licence): Wookie's
/// micro loader, encrypted and plaintext.
/// https://github.com/dhuseby/lynx-encryption-tools/blob/master/loaders.h
const wookie_encrypted = [_]u8{
    0xff, 0x88, 0x6c, 0x24, 0xd0, 0xf5, 0x9a, 0x62,
    0x8c, 0xa1, 0x08, 0x7e, 0xda, 0x87, 0x3f, 0x1b,
    0xeb, 0x48, 0x50, 0xba, 0x0d, 0xc9, 0xcb, 0x7b,
    0x3e, 0x10, 0x7c, 0xfd, 0x7e, 0xde, 0x8c, 0x06,
    0x3a, 0x12, 0x35, 0x1a, 0x8c, 0x74, 0x07, 0xdb,
    0xd1, 0x60, 0x7e, 0xe5, 0x88, 0x90, 0x60, 0x5b,
    0x2e, 0x4b, 0xa2, 0x25,
};
const wookie_plain = [_]u8{
    0x9c, 0xf9, 0xff, 0xa9, 0x03, 0x8d, 0x8a, 0xfd,
    0xa9, 0x04, 0x8d, 0x8c, 0xfd, 0xa9, 0x08, 0x8d,
    0x8b, 0xfd, 0xa2, 0x00, 0xad, 0xb2, 0xfc, 0x9d,
    0x00, 0x03, 0xe8, 0xd0, 0xf7, 0x4c, 0x00, 0x03,
} ++ @as([18]u8, @splat(0));

const Cart = boot.cart.Cart;

/// A 128 KB headerless cart image whose block 0 starts with `loader`.
fn cart_with(buf: *[128 * 1024]u8, loader: []const u8) Cart {
    @memset(buf, 0xFF);
    @memcpy(buf[0..loader.len], loader);
    const lay = boot.cart.parse(buf, buf.len);
    std.debug.assert(lay.verdict == .ok);
    return Cart.from_slice(&lay, buf);
}

/// post_boot over a fresh reader at block 0, counter 0.
fn boot_cart(c: *const Cart) boot.BootError!boot.BootState {
    var r: boot.CartReader = .{ .cart = c };
    const st = try boot.post_boot(&r, &ram);
    std.debug.assert(r.counter == st.cart_counter);
    return st;
}

var cart_buf: [128 * 1024]u8 = undefined;
var ram: [65536]u8 = undefined;

fn expect_loader(encrypted: []const u8, plain: []const u8) !void {
    const cart = cart_with(&cart_buf, encrypted);
    try std.testing.expectEqual(@as(u32, 512), cart.block_size);
    const st = try boot_cart(&cart);
    try std.testing.expectEqual(@as(u8, 1), st.frame.blocks);
    try std.testing.expectEqual(@as(u16, 50), st.frame.len);
    try std.testing.expectEqualSlices(u8, plain, ram[0x200..0x232]);
    try std.testing.expectEqual(@as(u16, 0x0200), st.regs.pc);
    try std.testing.expectEqual(@as(u8, 0), st.regs.a);
    try std.testing.expectEqual(@as(u8, 0), st.regs.x);
    try std.testing.expectEqual(@as(u8, 2), st.regs.y);
    try std.testing.expect(st.regs.p & boot.flag_z != 0);
    try std.testing.expect(st.regs.p & boot.flag_i != 0);
    try std.testing.expectEqual(@as(u8, 0), st.mapctl);
    try std.testing.expectEqual(@as(u32, 52), st.cart_counter);
    try std.testing.expectEqual(@as(u8, 0x32), ram[boot.zp_dest_lo]);
    try std.testing.expectEqual(@as(u8, 0x02), ram[boot.zp_dest_hi]);
    try std.testing.expectEqual(@as(u8, 0), ram[boot.zp_count]);
    // Nothing else written.
    for (ram, 0..) |b, i| {
        if (i >= 0x200 and i < 0x232) continue;
        if (i == boot.zp_dest_lo or i == boot.zp_dest_hi) continue;
        try std.testing.expectEqual(@as(u8, 0), b);
    }
}

test "boot: cc65 bootldr.s decrypts to its published plaintext" {
    try expect_loader(&cc65_encrypted, &cc65_plain);
}

test "boot: Wookie's micro loader decrypts to its published plaintext" {
    try expect_loader(&wookie_encrypted, &wookie_plain);
}

test "boot: cube of 1 and 2 (arithmetic sanity)" {
    var one: [boot.block_len]u8 = @splat(0);
    one[0] = 1; // least significant byte first, as on the cart
    const r1 = boot.cube(&one);
    for (r1[0..50]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try std.testing.expectEqual(@as(u8, 1), r1[50]);
    one[0] = 2;
    try std.testing.expectEqual(@as(u8, 8), boot.cube(&one)[50]);
    // (N - 1)^3 = -1 = N - 1 mod N.
    var nm1: [boot.block_len]u8 = undefined;
    for (0..boot.block_len) |i| nm1[i] = boot.modulus_be[boot.block_len - 1 - i];
    nm1[0] -= 1;
    var want = boot.modulus_be;
    want[50] -= 1;
    try std.testing.expectEqualSlices(u8, &want, &boot.cube(&nm1));
}

test "boot: rejected loaders" {
    // Count byte below $FB.
    var enc = cc65_encrypted;
    enc[0] = 0xFA;
    var cart = cart_with(&cart_buf, &enc);
    try std.testing.expectError(error.BadCount, boot_cart(&cart));
    // A flipped ciphertext byte fails the $15 check (or, rarely, the range check).
    enc = cc65_encrypted;
    enc[10] ^= 0x40;
    cart = cart_with(&cart_buf, &enc);
    if (boot_cart(&cart)) |_| return error.TestUnexpectedResult else |e| try std.testing.expect(e == error.BadCheckByte or e == error.BadBlock or e == error.BadLastByte);
    // Top three bytes zero.
    enc = cc65_encrypted;
    enc[49] = 0;
    enc[50] = 0;
    enc[51] = 0;
    cart = cart_with(&cart_buf, &enc);
    try std.testing.expectError(error.BadBlock, boot_cart(&cart));
    // Top three bytes equal to the modulus's: not below it.
    enc[51] = boot.modulus_be[0];
    enc[50] = boot.modulus_be[1];
    enc[49] = boot.modulus_be[2];
    cart = cart_with(&cart_buf, &enc);
    try std.testing.expectError(error.BadBlock, boot_cart(&cart));
}

test "boot: the boot reader over core/cart.zig (header, short image, wrap)" {
    var hdr: [64 + 1024]u8 = @splat(0);
    @memcpy(hdr[0..4], "LYNX");
    hdr[4] = 0x00;
    hdr[5] = 0x04; // 1024-byte pages
    hdr[8] = 1;
    @memcpy(hdr[10..17], "RAYCAST");
    for (hdr[64..], 0..) |*b, i| b.* = @truncate(i);
    const lay = boot.cart.parse(&hdr, hdr.len);
    try std.testing.expectEqual(boot.cart.Refusal.ok, lay.verdict);
    try std.testing.expectEqual(@as(u32, 1024), lay.block_size);
    try std.testing.expectEqualStrings("RAYCAST", lay.title());
    const c = Cart.from_slice(&lay, &hdr);
    // Past the end of a short image reads 0xFF.
    var r: boot.CartReader = .{ .cart = &c, .block = 3, .counter = 5 };
    try std.testing.expectEqual(@as(u8, 0xFF), r.read_byte());
    // Block 0 reads the data after the header, and the counter wraps
    // within the block.
    r = .{ .cart = &c, .block = 0, .counter = 1022 };
    try std.testing.expectEqual(@as(u8, 0xFE), r.read_byte());
    try std.testing.expectEqual(@as(u8, 0xFF), r.read_byte());
    try std.testing.expectEqual(@as(u32, 0), r.counter);
    try std.testing.expectEqual(@as(u8, 0x00), r.read_byte());
}
