//! Host tests for lib/romfs.zig against images written by tools/make_romfs.py.
//! The fixtures are truncated at the last used sector (--truncate), so these
//! tests also show the reader touches nothing past the file data it needs.
//!
//! Fixtures (regenerate from lib/tests/fixtures/, see README.md there):
//!
//!   python3 ../../../tools/make_romfs.py waternet.img \
//!       ../../../carts/snouty-gear/roms/waternet.gg --truncate
//!   python3 ../../../tools/make_romfs.py drive.img --truncate --fragment 1 \
//!       --delete "src_c.bin=Old Game.gg" --dir .fseventsd --dir Games.gg \
//!       "src_a.bin=Sonic The Hedgehog (World).gg" \
//!       "src_c.bin=._Sonic The Hedgehog (World).gg" src_c.bin=TETRIS.GG \
//!       src_c.bin=readme.txt "src_b.bin=Second Game.SMS" \
//!       "src_c.bin=An extremely long file name that runs past the sixty-four byte limit.gg"
const std = @import("std");
const romfs = @import("../romfs.zig");
const testing = std.testing;

const waternet_img = @embedFile("fixtures/waternet.img");
const drive_img = @embedFile("fixtures/drive.img");
const src_a = @embedFile("fixtures/src_a.bin");
const src_b = @embedFile("fixtures/src_b.bin");
const src_c = @embedFile("fixtures/src_c.bin");

/// zlib.crc32 of carts/snouty-gear/roms/waternet.gg (md5 44d92c49...).
const waternet_crc: u32 = 0x6bb36dfc;
/// Sector 19 in the OS geometry: 1 reserved + 2 x 8 FAT + 2 root sectors.
const data_start = 19 * romfs.sector_size;

fn find_one(v: *const romfs.Volume, name: []const u8) !romfs.Entry {
    var out: [16]romfs.Entry = undefined;
    const n = v.find(&.{ "gg", "sms", "txt" }, &out);
    for (out[0..n]) |e| {
        if (std.mem.eql(u8, e.slice(), name)) return e;
    }
    return error.NotFound;
}

fn check_bytes(m: *const romfs.Mapped, src: []const u8) !void {
    try testing.expectEqual(@as(u32, @intCast(src.len)), m.size);
    for (src, 0..) |b, i| try testing.expectEqual(b, m.read(@intCast(i)));
    try testing.expectEqual(@as(u8, 0xFF), m.read(m.size));
    try testing.expectEqual(std.hash.Crc32.hash(src), m.crc32());
}

test "romfs: waternet.gg image is one contiguous file, every 16 KB bank maps" {
    const v = try romfs.Volume.open(waternet_img);
    var out: [4]romfs.Entry = undefined;
    const n = v.find(&.{ "gg", "sms" }, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("waternet.gg", out[0].slice());
    try testing.expectEqual(@as(u32, 65536), out[0].size);
    try testing.expectEqual(@as(u16, 2), out[0].first_cluster);

    var table: [romfs.max_clusters]u16 = undefined;
    const m = try v.map(out[0], &table);
    try testing.expectEqual(@as(usize, 128), m.clusters.len);
    const whole = m.contiguous() orelse return error.NotContiguous;
    try testing.expectEqual(@intFromPtr(waternet_img) + data_start, @intFromPtr(whole));
    var bank: u32 = 0;
    while (bank < 4) : (bank += 1) {
        const p = m.chunk(bank * 16384, 16384) orelse return error.BankNotMapped;
        try testing.expectEqual(@intFromPtr(whole) + bank * 16384, @intFromPtr(p));
    }
    try testing.expect(m.chunk(3 * 16384, 16385) == null); // runs past the end
    try testing.expect(m.chunk(65536, 1) == null);
    try testing.expect(m.chunk(0, 0) == null);
    // Game Gear header, and the ROM's CRC against Python's zlib.crc32.
    try testing.expectEqualStrings("TMR SEGA", whole[0x7FF0..0x7FF8]);
    try testing.expectEqual(waternet_crc, m.crc32());
    try testing.expectEqual(std.hash.Crc32.hash(whole[0..65536]), m.crc32());
    try testing.expectEqual(whole[12345], m.read(12345));
}

test "romfs: long, 8.3 and case-flag names; deleted, directories, AppleDouble skipped" {
    const v = try romfs.Volume.open(drive_img);
    var out: [16]romfs.Entry = undefined;
    const n = v.find(&.{ "gg", "SMS" }, &out);
    const want = [_][]const u8{
        "Sonic The Hedgehog (World).gg",
        "TETRIS.GG",
        "Second Game.SMS",
        "An extremely long file name that runs past the sixty-four byte l",
    };
    try testing.expectEqual(want.len, n);
    for (want, out[0..n]) |w, e| try testing.expectEqualStrings(w, e.slice());
    try testing.expectEqual(@as(u8, 64), out[3].name_len);
    try testing.expectEqual(@as(u32, 1500), out[0].size);
    try testing.expectEqual(@as(u32, 1100), out[2].size);

    // Only .txt: the lower-case long name of README.TXT.
    const t = v.find(&.{"txt"}, &out);
    try testing.expectEqual(@as(usize, 1), t);
    try testing.expectEqualStrings("readme.txt", out[0].slice());

    // A short output slice keeps the first matches in directory order.
    var two: [2]romfs.Entry = undefined;
    try testing.expectEqual(@as(usize, 2), v.find(&.{"gg"}, &two));
    try testing.expectEqualStrings("Sonic The Hedgehog (World).gg", two[0].slice());
    try testing.expectEqualStrings("TETRIS.GG", two[1].slice());

    // No match, and no extensions at all.
    try testing.expectEqual(@as(usize, 0), v.find(&.{"lnx"}, &out));
    try testing.expectEqual(@as(usize, 0), v.find(&.{}, &out));
}

test "romfs: NT case bits and an LFN group whose checksum does not match" {
    var img: [drive_img.len]u8 = drive_img.*;
    const root = 17 * 512;
    // Entry 15 is TETRIS.GG (8.3 only): Windows' lower-case base+ext bits.
    try testing.expectEqualStrings("TETRIS  GG ", img[root + 15 * 32 ..][0..11]);
    img[root + 15 * 32 + 12] = 0x18;
    // Entry 10 is SONICT~1.GG after its 3 LFN entries: rename the 8.3 alias
    // so the checksum no longer pairs them (a host that renamed it without
    // LFN support); the reader must fall back to the 8.3 name.
    try testing.expectEqualStrings("SONICT~1GG ", img[root + 10 * 32 ..][0..11]);
    img[root + 10 * 32 + 5] = 'X';
    const v = try romfs.Volume.open(&img);
    var out: [8]romfs.Entry = undefined;
    const n = v.find(&.{"gg"}, &out);
    try testing.expect(n >= 2);
    try testing.expectEqualStrings("SONICX~1.GG", out[0].slice());
    try testing.expectEqualStrings("tetris.gg", out[1].slice());
}

test "romfs: fragmented files map, chunk() only across consecutive clusters, read() exact" {
    const v = try romfs.Volume.open(drive_img);
    var table: [romfs.max_clusters]u16 = undefined;
    for ([_]struct { []const u8, []const u8 }{
        .{ "Sonic The Hedgehog (World).gg", src_a },
        .{ "Second Game.SMS", src_b },
        .{ "TETRIS.GG", src_c },
    }) |case| {
        const e = try find_one(&v, case[0]);
        const m = try v.map(e, &table);
        try testing.expectEqual((case[1].len + 511) / 512, m.clusters.len);
        try check_bytes(&m, case[1]);
        var runs: usize = 1;
        for (1..m.clusters.len) |i| {
            const joined = m.clusters[i] == m.clusters[i - 1] + 1;
            if (!joined) runs += 1;
            // Two bytes straddling the cluster boundary i-1 | i.
            const off: u32 = @intCast(i * 512 - 1);
            const p = m.chunk(off, 2);
            try testing.expectEqual(joined, p != null);
            if (p) |q| try testing.expectEqualSlices(u8, case[1][off .. off + 2], q[0..2]);
        }
        // Within one cluster a chunk always maps and points at the right bytes.
        for (0..m.clusters.len) |i| {
            const off: u32 = @intCast(i * 512);
            const len: u32 = @intCast(@min(512, case[1].len - off));
            const q = m.chunk(off, len) orelse return error.ClusterNotMapped;
            try testing.expectEqualSlices(u8, case[1][off .. off + len], q[0..len]);
        }
        try testing.expectEqual(runs == 1, m.contiguous() != null);
    }
    // --fragment 1 interleaves the two multi-cluster files.
    const sonic = try v.map(try find_one(&v, "Sonic The Hedgehog (World).gg"), &table);
    try testing.expect(sonic.contiguous() == null);
}

test "romfs: map errors: short table, bad chains" {
    const v = try romfs.Volume.open(drive_img);
    const e = try find_one(&v, "Sonic The Hedgehog (World).gg");
    var small: [2]u16 = undefined;
    try testing.expectError(error.TooManyClusters, v.map(e, &small));

    var table: [romfs.max_clusters]u16 = undefined;
    var bad = e;
    bad.first_cluster = 0; // free / reserved
    try testing.expectError(error.BadChain, v.map(bad, &table));
    bad.first_cluster = 4000; // beyond the volume
    try testing.expectError(error.BadChain, v.map(bad, &table));
    bad = try find_one(&v, "TETRIS.GG");
    bad.size = 2000; // chain (1 cluster) shorter than the size claims
    try testing.expectError(error.BadChain, v.map(bad, &table));

    // A loop: point cluster 5's FAT entry back at itself in a copy.
    var img: [drive_img.len]u8 = drive_img.*;
    const fat = img[512..];
    const off = 5 + 5 / 2; // odd cluster: high 12 bits of the pair
    fat[off] = (fat[off] & 0x0F) | 0x50;
    fat[off + 1] = 0x00;
    const lv = try romfs.Volume.open(&img);
    try testing.expectError(error.BadChain, lv.map(e, &table));

    // An empty file maps to nothing.
    var empty = e;
    empty.size = 0;
    empty.first_cluster = 0;
    const m = try v.map(empty, &table);
    try testing.expectEqual(@as(usize, 0), m.clusters.len);
    try testing.expect(m.contiguous() == null);
    try testing.expectEqual(@as(u8, 0xFF), m.read(0));
    try testing.expectEqual(@as(u32, 0), m.crc32());
}

test "romfs: no volume and bad geometry" {
    const zeros = std.mem.zeroes([512]u8);
    try testing.expectError(error.NoVolume, romfs.Volume.open(&zeros));
    var erased: [512]u8 = undefined;
    @memset(&erased, 0xFF);
    try testing.expectError(error.NoVolume, romfs.Volume.open(&erased));

    const good: [512]u8 = waternet_img[0..512].*;
    _ = try romfs.Volume.open(&good);
    const Patch = struct { off: usize, val: u8 };
    for ([_]Patch{
        .{ .off = 12, .val = 0x04 }, // 1024-byte sectors
        .{ .off = 13, .val = 2 }, // 2 sectors per cluster
        .{ .off = 17, .val = 64 }, // 64 root entries
        .{ .off = 58, .val = '6' }, // "FAT16   "
        .{ .off = 16, .val = 0 }, // no FATs
    }) |p| {
        var bs = good;
        bs[p.off] = p.val;
        try testing.expectError(error.BadGeometry, romfs.Volume.open(&bs));
    }
    // find on a non-volume finds nothing.
    const nv = romfs.Volume{ .base = &zeros };
    var out: [2]romfs.Entry = undefined;
    try testing.expectEqual(@as(usize, 0), nv.find(&.{"gg"}, &out));
}

test "romfs: constants match the OS layout" {
    try testing.expectEqual(@as(usize, 0x10080000), romfs.base_addr);
    try testing.expectEqual(@as(usize, 2560), romfs.max_clusters);
    // The fixture boot sector says 2560 sectors, as the OS formats 1280 KB.
    try testing.expectEqual(@as(u16, 2560), std.mem.readInt(u16, waternet_img[19..21], .little));
}
