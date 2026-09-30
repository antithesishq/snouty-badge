//! cart/src/frontend/drive.zig: the drive scan and the Cart built from a
//! drive file, against FAT12 images from tools/make_romfs.py
//! (tests/fixtures/make_fixtures.py writes them; its docstring lists the
//! files). No commercial ROMs.
const std = @import("std");
const core = @import("core");
const romfs = @import("romfs");
const drive = @import("drive");
const testing = std.testing;

const drive_img = @embedFile("fixtures/m0_drive.img");
const none_img = @embedFile("fixtures/m0_none.img");

var clusters: [romfs.max_clusters]u16 = undefined;
var src: drive.Source = undefined;

/// The fixture's byte pattern (make_fixtures.py raw_pattern).
fn pattern(i: u32) u8 {
    return @truncate(i * 7 + i / 512);
}

fn find(s: *const drive.Scan, name: []const u8) !*const drive.Candidate {
    for (s.candidates[0..s.count]) |*c| {
        if (std.mem.eql(u8, c.file_name(), name)) return c;
    }
    return error.TestUnexpectedResult;
}

test "drive: scan lists every Lynx file and checks it" {
    const s = drive.scan(drive_img.ptr, &clusters);
    try testing.expect(s.err == null);
    try testing.expectEqual(@as(u32, 4), s.count);
    try testing.expectEqual(@as(u32, 3), s.playable_count);
    try testing.expectEqualStrings("ROT.LNX", s.candidates[0].file_name());
    try testing.expectEqualStrings("rotated", s.candidates[0].note());
    // The first playable one is what M0 runs.
    try testing.expectEqual(@as(?usize, 1), s.first_playable());
    const game = try find(&s, "GAME.LNX");
    try testing.expect(game.layout.headered);
    try testing.expectEqualStrings("Snouty Lynx placeholder", game.layout.title());
    const raw = try find(&s, "RAW.LYX");
    try testing.expect(!raw.layout.headered);
    try testing.expectEqual(@as(u32, 512), raw.layout.block_size);
}

test "drive: contiguous headered file maps by pointer" {
    const s = drive.scan(drive_img.ptr, &clusters);
    const c = try drive.open(drive_img.ptr, try find(&s, "GAME.LNX"), &clusters, &src);
    try testing.expectEqual(@as(u32, 1), c.direct_blocks());
    // Placeholder block 0 starts with its stripe rows: 0x00 0x00 0x00 0x00 0x00 0x11.
    try testing.expectEqual(@as(u8, 0x00), c.read(0, 0));
    try testing.expectEqual(@as(u8, 0x11), c.read(0, 5));
    try testing.expectEqual(@as(u8, 0xFF), c.read(1, 0));
}

test "drive: fragmented files read the same through pointers and the cluster table" {
    const s = drive.scan(drive_img.ptr, &clusters);
    // RAW.LYX: runs of two clusters, blocks are whole clusters: all direct.
    var c = try drive.open(drive_img.ptr, try find(&s, "RAW.LYX"), &clusters, &src);
    try testing.expectEqual(@as(u32, 8), c.direct_blocks());
    var i: u32 = 0;
    while (i < 4096) : (i += 1) try testing.expectEqual(pattern(i), c.read(@intCast(i / 512), i % 512));
    // FRAG.LNX: blocks 1 and 3 straddle a run boundary.
    c = try drive.open(drive_img.ptr, try find(&s, "FRAG.LNX"), &clusters, &src);
    try testing.expectEqual(@as(u32, 2), c.direct_blocks());
    try testing.expect(c.blocks[0] != null and c.blocks[1] == null and c.blocks[2] != null and c.blocks[3] == null);
    i = 0;
    while (i < 2048) : (i += 1) try testing.expectEqual(pattern(i), c.read(@intCast(i / 512), i % 512));
    try testing.expectEqual(@as(u8, 0xFF), c.read(4, 0));
}

test "drive: no playable file, no volume" {
    const s = drive.scan(none_img.ptr, &clusters);
    try testing.expectEqual(@as(u32, 1), s.count);
    try testing.expectEqual(@as(?usize, null), s.first_playable());
    const blank: [1024]u8 = @splat(0);
    const n = drive.scan(&blank, &clusters);
    try testing.expectEqual(@as(?romfs.Error, error.NoVolume), n.err);
    try testing.expectEqual(@as(u32, 0), n.count);
}
