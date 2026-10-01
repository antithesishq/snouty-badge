//! Host tests for cart/src/frontend/drive.zig (PLAN.md M2 Track B): the
//! drive scan, the verdicts the picker and the help screen show, and the
//! RomSource built for a contiguous and a fragmented file, against FAT12
//! images written by tools/make_romfs.py (tests/fixtures/, see README.md
//! there; regenerate with `python3 make_fixtures.py` in that directory).
//!
//! m2_drive.img, root in this order: a deleted OLD.GEN, a .fseventsd
//! directory, TEST.GEN (roms/snouty-test.bin, contiguous), FRAG.MD (the
//! same bytes, stored back to front: 32 one-cluster runs), NOHDR.BIN (16 KB
//! byte pattern, no header), BAD.BIN (SMD-interleaved copy of the test ROM),
//! README.TXT. m2_none.img: README.TXT and JUNK.BIN (the NOHDR pattern).
const std = @import("std");
const core = @import("core");
const romfs = @import("romfs");
const drive = @import("drive");
const testing = std.testing;

const drive_img = @embedFile("fixtures/m2_drive.img");
const none_img = @embedFile("fixtures/m2_none.img");

/// zlib.crc32 of roms/snouty-test.bin.
const test_rom_crc: u32 = 0xe5d1c6bf;
const test_rom_size: u32 = 16384;

var clusters: [romfs.max_clusters]u16 = undefined;

const prefixes = [_][]const u8{ "", "carts/snouty-genesis/", "../", "../../" };
var rom_buf: [test_rom_size]u8 = undefined;

/// roms/snouty-test.bin (the build's working directory varies).
fn test_rom() ![]const u8 {
    for (prefixes) |pre| {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}roms/snouty-test.bin", .{pre}) catch continue;
        return std.Io.Dir.cwd().readFile(testing.io, path, &rom_buf) catch continue;
    }
    return error.SkipZigTest;
}

fn find(s: *const drive.Scan, name: []const u8) !*const drive.Candidate {
    for (s.candidates[0..s.count]) |*c| {
        if (std.mem.eql(u8, c.file_name(), name)) return c;
    }
    return error.NotFound;
}

test "drive: scan lists the four ROM files in directory order with their verdicts" {
    const s = drive.scan(drive_img, &clusters);
    try testing.expect(s.err == null);
    try testing.expectEqual(@as(u32, 4), s.count);
    try testing.expectEqual(@as(u32, 2), s.playable_count);

    const names = [_][]const u8{ "TEST.GEN", "FRAG.MD", "NOHDR.BIN", "BAD.BIN" };
    const verdicts = [_]core.rom.Refusal{ .ok, .ok, .no_header, .smd_interleaved };
    const sizes = [_]u32{ test_rom_size, test_rom_size, 16384, test_rom_size + 512 };
    for (s.candidates[0..4], names, verdicts, sizes) |*c, n, v, z| {
        try testing.expectEqualStrings(n, c.file_name());
        try testing.expectEqual(v, c.verdict);
        try testing.expectEqual(z, c.size);
        try testing.expect(c.map_err == null);
        try testing.expectEqual(v == .ok, c.playable());
    }
    try testing.expectEqual(@as(?usize, 0), s.first_playable());
}

test "drive: header names come from the header, refused files have none" {
    const s = drive.scan(drive_img, &clusters);
    // roms/snouty-test.bin: domestic and overseas name "SNOUTY TEST" at
    // 0x120 / 0x150, space padded.
    try testing.expectEqualStrings("SNOUTY TEST", (try find(&s, "TEST.GEN")).name());
    try testing.expectEqualStrings("SNOUTY TEST", (try find(&s, "FRAG.MD")).name());
    const nohdr = try find(&s, "NOHDR.BIN");
    try testing.expectEqualStrings("", nohdr.name());
    try testing.expectEqualStrings("no SEGA header", nohdr.note());
    const bad = try find(&s, "BAD.BIN");
    try testing.expectEqualStrings("", bad.name());
    try testing.expectEqualStrings(core.rom.Refusal.smd_interleaved.text(), bad.note());
    try testing.expectEqualStrings("SNOUTY TEST", (try find(&s, "TEST.GEN")).note());
}

fn check_reads(src: *const core.RomSource, want: []const u8) !void {
    try testing.expectEqual(@as(u32, @intCast(want.len)), src.size);
    try testing.expect(src.valid());
    for (want, 0..) |b, i| try testing.expectEqual(b, core.rom.read8(src, @intCast(i)));
    var a: u32 = 0;
    while (a < want.len) : (a += 2) {
        try testing.expectEqual(@as(u16, want[a]) << 8 | want[a + 1], core.rom.read16(src, a));
    }
    try testing.expectEqual(@as(u8, 0xFF), core.rom.read8(src, src.size));
    try testing.expectEqual(core.rom.Refusal.ok, core.rom.check(src));
}

test "drive: open maps TEST.GEN contiguous, reads back the test ROM" {
    const want = try test_rom();
    const s = drive.scan(drive_img, &clusters);
    const m = try drive.open(drive_img, try find(&s, "TEST.GEN"), &clusters);
    const p = m.contiguous() orelse return error.NotContiguous;
    const src = drive.source_of(&m);
    try testing.expectEqual(@as(?[*]const u8, p), src.base);
    try check_reads(&src, want);
    try testing.expectEqual(test_rom_crc, m.crc32());
    try testing.expectEqual(std.hash.Crc32.hash(want), m.crc32());
}

test "drive: open maps FRAG.MD through the cluster table, same bytes" {
    const want = try test_rom();
    const s = drive.scan(drive_img, &clusters);
    const m = try drive.open(drive_img, try find(&s, "FRAG.MD"), &clusters);
    try testing.expect(m.contiguous() == null);
    try testing.expectEqual(@as(usize, 32), m.clusters.len);
    // Stored back to front (tests/fixtures/make_fixtures.py).
    try testing.expectEqual(m.clusters[31] + 31, m.clusters[0]);
    const src = drive.source_of(&m);
    try testing.expect(src.base == null);
    try check_reads(&src, want);
    try testing.expectEqual(test_rom_crc, m.crc32());
}

test "drive: a volume with no Genesis ROM lists the refused file, nothing playable" {
    const s = drive.scan(none_img, &clusters);
    try testing.expect(s.err == null);
    try testing.expectEqual(@as(u32, 1), s.count);
    try testing.expectEqual(@as(u32, 0), s.playable_count);
    try testing.expectEqualStrings("JUNK.BIN", s.candidates[0].file_name());
    try testing.expectEqual(core.rom.Refusal.no_header, s.candidates[0].verdict);
    try testing.expectEqual(@as(?usize, null), s.first_playable());
}

test "drive: a boot sector without the signature is NoVolume" {
    var img: [2048]u8 = @splat(0);
    const s = drive.scan(&img, &clusters);
    try testing.expectEqual(@as(?romfs.Error, error.NoVolume), s.err);
    try testing.expectEqual(@as(u32, 0), s.count);
    try testing.expectEqual(@as(u32, 0), s.playable_count);
    // The real image with its signature broken.
    var broken: [drive_img.len]u8 = drive_img.*;
    broken[510] = 0;
    try testing.expectEqual(@as(?romfs.Error, error.NoVolume), drive.scan(&broken, &clusters).err);
}

test "drive: header_name collapses padding and falls back to the overseas name" {
    var rom: [0x200]u8 = @splat(' ');
    @memcpy(rom[0x100..0x104], "SEGA");
    const overseas = "SONIC THE          HEDGEHOG";
    @memcpy(rom[0x150..][0..overseas.len], overseas);
    var out: [drive.name_max]u8 = undefined;
    const src = core.RomSource.from_slice(&rom);
    const n = drive.header_name(&src, &out);
    try testing.expectEqualStrings("SONIC THE HEDGEHOG", out[0..n]);
    @memcpy(rom[0x120..0x126], "  ABC\x01");
    const k = drive.header_name(&src, &out);
    try testing.expectEqualStrings("ABC?", out[0..k]);
}

/// `Mapped.Crc` over `m` in steps of `chunk` bytes; the step count.
fn crc_in_steps(m: *const romfs.Mapped, chunk: u32, steps: *u32) u32 {
    var c = romfs.Mapped.Crc.init();
    steps.* = 0;
    while (true) {
        steps.* += 1;
        if (c.step(m, chunk)) break;
    }
    // Further steps change nothing.
    std.debug.assert(c.step(m, chunk));
    return c.final();
}

test "drive: the incremental CRC of the fragmented and contiguous files matches crc32" {
    const s = drive.scan(drive_img, &clusters);
    for ([_][]const u8{ "FRAG.MD", "TEST.GEN" }) |name| {
        const m = try drive.open(drive_img, try find(&s, name), &clusters);
        try testing.expectEqual(test_rom_crc, m.crc32());
        // 8 KB (the cart's chunk), odd sizes that cut clusters, one byte.
        for ([_]u32{ 8 * 1024, 1000, 512, 3, 1, 1 << 20 }) |chunk| {
            var steps: u32 = 0;
            try testing.expectEqual(test_rom_crc, crc_in_steps(&m, chunk, &steps));
            try testing.expectEqual((test_rom_size + chunk - 1) / chunk, steps);
        }
    }
    // An empty file is done at once (CRC of nothing is 0).
    const empty: romfs.Mapped = .{ .size = 0, .clusters = &.{}, .data_base = drive_img };
    var steps: u32 = 0;
    try testing.expectEqual(@as(u32, 0), crc_in_steps(&empty, 8192, &steps));
    try testing.expectEqual(@as(u32, 1), steps);
}
