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
    const v = try romfs.Volume.open(.truncated_test(waternet_img));
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
    const v = try romfs.Volume.open(.truncated_test(drive_img));
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
    const v = try romfs.Volume.open(.truncated_test(&img));
    var out: [8]romfs.Entry = undefined;
    const n = v.find(&.{"gg"}, &out);
    try testing.expect(n >= 2);
    try testing.expectEqualStrings("SONICX~1.GG", out[0].slice());
    try testing.expectEqualStrings("tetris.gg", out[1].slice());
}

test "romfs: fragmented files map, chunk() only across consecutive clusters, read() exact" {
    const v = try romfs.Volume.open(.truncated_test(drive_img));
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
    const v = try romfs.Volume.open(.truncated_test(drive_img));
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
    const lv = try romfs.Volume.open(.truncated_test(&img));
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
    try testing.expectError(error.NoVolume, romfs.Volume.open(.whole(&zeros)));
    var erased: [512]u8 = undefined;
    @memset(&erased, 0xFF);
    try testing.expectError(error.NoVolume, romfs.Volume.open(.whole(&erased)));

    const good: [waternet_img.len]u8 = waternet_img.*;
    _ = try romfs.Volume.open(.truncated_test(&good));
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
        try testing.expectError(error.BadGeometry, romfs.Volume.open(.truncated_test(&bs)));
    }
    // find on a non-volume finds nothing.
    const nv = romfs.Volume{ .image = .whole(&zeros) };
    var out: [2]romfs.Entry = undefined;
    try testing.expectEqual(@as(usize, 0), nv.find(&.{"gg"}, &out));
}

/// The review's INF01 probe boot sector: a valid signature, sector size,
/// root count and FAT marker, but 3000 reserved sectors, 2 FATs of 8 and
/// 4000 sectors in all, so cluster 2 would map 1,545,216 bytes in, past the
/// 1,310,720-byte drive.
fn probe_boot() [512]u8 {
    var boot = std.mem.zeroes([512]u8);
    std.mem.writeInt(u16, boot[510..512], 0xaa55, .little);
    std.mem.writeInt(u16, boot[11..13], 512, .little);
    boot[13] = 1;
    std.mem.writeInt(u16, boot[14..16], 3000, .little);
    boot[16] = 2;
    std.mem.writeInt(u16, boot[17..19], 32, .little);
    std.mem.writeInt(u16, boot[19..21], 4000, .little);
    std.mem.writeInt(u16, boot[22..24], 8, .little);
    @memcpy(boot[54..62], "FAT12   ");
    return boot;
}

/// A drive-sized image (the badge's 1280 KB region).
var drive_sized: [romfs.size]u8 = undefined;

test "romfs: geometry outside the drive is BadGeometry before any directory or data access" {
    const boot = probe_boot();
    try testing.expectError(error.BadGeometry, romfs.Volume.open(.truncated_test(&boot)));
    @memset(&drive_sized, 0);
    @memcpy(drive_sized[0..512], &boot);
    try testing.expectError(error.BadGeometry, romfs.Volume.open(.whole(&drive_sized)));
    // A Volume made without `open` re-checks on every call: nothing found,
    // nothing mapped.
    const v = romfs.Volume{ .image = .whole(&drive_sized) };
    var out: [2]romfs.Entry = undefined;
    try testing.expectEqual(@as(usize, 0), v.find(&.{"gg"}, &out));
    var table: [1]u16 = undefined;
    try testing.expectError(error.BadGeometry, v.map(.{ .size = 512, .first_cluster = 2 }, &table));

    // The OS boot sector (2560 sectors, exactly the drive) opens in a
    // drive-sized image and not in one a sector short of it.
    @memcpy(drive_sized[0..waternet_img.len], waternet_img);
    _ = try romfs.Volume.open(.whole(&drive_sized));
    try testing.expectError(error.BadGeometry, romfs.Volume.open(.whole(drive_sized[0 .. romfs.size - 512])));
    // A truncated image still may not claim more than the drive.
    var big: [waternet_img.len]u8 = waternet_img.*;
    std.mem.writeInt(u16, big[19..21], 2561, .little);
    try testing.expectError(error.BadGeometry, romfs.Volume.open(.truncated_test(&big)));
    // Nor be cut inside its FATs or root directory.
    try testing.expectError(error.BadGeometry, romfs.Volume.open(.truncated_test(waternet_img[0..512])));
    try testing.expectError(error.BadGeometry, romfs.Volume.open(.truncated_test(waternet_img[0 .. data_start - 1])));
    _ = try romfs.Volume.open(.truncated_test(waternet_img[0..data_start]));
    // An image shorter than a boot sector is no volume.
    try testing.expectError(error.NoVolume, romfs.Volume.open(.whole(waternet_img[0..511])));
}

test "romfs: a FAT too small for the volume's clusters is BadGeometry, not capped" {
    // 1 reserved + 2 FATs of 1 sector (341 entries) + 2 root sectors, 2560
    // sectors: 2555 clusters the FAT cannot describe.
    var bs: [waternet_img.len]u8 = waternet_img.*;
    std.mem.writeInt(u16, bs[22..24], 1, .little);
    try testing.expectError(error.BadGeometry, romfs.Volume.open(.truncated_test(&bs)));
    // Total cut to fit the 1-sector FAT exactly (339 clusters + 2): opens.
    std.mem.writeInt(u16, bs[19..21], 5 + 339, .little);
    _ = try romfs.Volume.open(.truncated_test(&bs));
    std.mem.writeInt(u16, bs[19..21], 5 + 340, .little);
    try testing.expectError(error.BadGeometry, romfs.Volume.open(.truncated_test(&bs)));
}

test "romfs: a truncated image maps no cluster past its bytes" {
    // drive.img cut two clusters into the data area: Sonic (3 clusters,
    // fragmented) reaches beyond it, the 1-cluster TETRIS.GG is inside only
    // when its cluster is.
    const v = try romfs.Volume.open(.truncated_test(drive_img));
    const sonic = try find_one(&v, "Sonic The Hedgehog (World).gg");
    var table: [romfs.max_clusters]u16 = undefined;
    const full = try v.map(sonic, &table);
    var last: u16 = 0;
    for (full.clusters) |c| last = @max(last, c);
    // Cut just before the highest of Sonic's clusters.
    const cut = drive_img[0 .. 17 * 512 + 2 * 512 + (@as(usize, last) - 2) * 512];
    const short = try romfs.Volume.open(.truncated_test(cut));
    try testing.expectError(error.BadChain, short.map(sonic, &table));
    // One sector more and it maps again.
    const cut2 = drive_img[0 .. cut.len + 512];
    _ = try (try romfs.Volume.open(.truncated_test(cut2))).map(sonic, &table);
}

test "romfs: constants match the OS layout" {
    try testing.expectEqual(@as(usize, 0x10080000), romfs.base_addr);
    try testing.expectEqual(@as(usize, 2560), romfs.max_clusters);
    // The fixture boot sector says 2560 sectors, as the OS formats 1280 KB.
    try testing.expectEqual(@as(u16, 2560), std.mem.readInt(u16, waternet_img[19..21], .little));
}

/// An extra-drive-sized image (the ext-flash OS's "SYCLEXTRA" volume).
var extra_sized: [romfs.extra_size]u8 = undefined;

test "romfs: the extra drive geometry (128 root entries, 3584 sectors) opens and maps high clusters" {
    // The boot sector storage.zig formats for the extra drive: 1 reserved
    // sector, 2 FATs of 11 sectors, 128 root entries (8 sectors).
    @memset(&extra_sized, 0);
    const bs = extra_sized[0..512];
    std.mem.writeInt(u16, bs[510..512], 0xaa55, .little);
    std.mem.writeInt(u16, bs[11..13], 512, .little);
    bs[13] = 1;
    std.mem.writeInt(u16, bs[14..16], 1, .little);
    bs[16] = 2;
    std.mem.writeInt(u16, bs[17..19], 128, .little);
    std.mem.writeInt(u16, bs[19..21], 3584, .little);
    bs[21] = 0xF8;
    std.mem.writeInt(u16, bs[22..24], 11, .little);
    @memcpy(bs[54..62], "FAT12   ");

    // One 1000-byte file in clusters 3000 -> 3001, past the badge drive's
    // 2560 sectors.
    const fat = extra_sized[512..];
    const setFat = struct {
        fn f(t: []u8, cluster: u32, val: u16) void {
            const off = cluster + cluster / 2;
            if (cluster & 1 == 0) {
                t[off] = @truncate(val);
                t[off + 1] = (t[off + 1] & 0xF0) | @as(u8, @truncate(val >> 8));
            } else {
                t[off] = (t[off] & 0x0F) | @as(u8, @truncate(val << 4));
                t[off + 1] = @truncate(val >> 4);
            }
        }
    }.f;
    setFat(fat, 3000, 3001);
    setFat(fat, 3001, 0xFFF);
    const root = extra_sized[(1 + 2 * 11) * 512 ..];
    @memcpy(root[0..11], "GAME    LNX");
    root[11] = 0x20;
    std.mem.writeInt(u16, root[26..28], 3000, .little);
    std.mem.writeInt(u32, root[28..32], 1000, .little);
    const extra_data: usize = (1 + 2 * 11 + 8) * 512;
    extra_sized[extra_data + (3000 - 2) * 512] = 0x42;
    extra_sized[extra_data + (3001 - 2) * 512 + 487] = 0x43;

    var v = try romfs.Volume.open(.whole(&extra_sized));
    v.drive = 1;
    var out: [2]romfs.Entry = undefined;
    try testing.expectEqual(@as(usize, 1), v.find(&.{"lnx"}, &out));
    try testing.expectEqualStrings("GAME.LNX", out[0].slice());
    try testing.expectEqual(@as(u8, 1), out[0].drive);
    var table: [romfs.max_clusters]u16 = undefined;
    const m = try v.map(out[0], &table);
    try testing.expectEqual(@as(u8, 0x42), m.read(0));
    try testing.expectEqual(@as(u8, 0x43), m.read(999));
    try testing.expect(m.contiguous() != null);
    // Not in a badge-drive-sized image.
    try testing.expectError(error.BadGeometry, romfs.Volume.open(.whole(extra_sized[0..romfs.size])));
}
