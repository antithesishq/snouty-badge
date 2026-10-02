//! The header ROM range (core/rom.zig `Header.declared_size`, `check`;
//! review EM-03): a header claiming 00000000-FFFFFFFF overflowed
//! `end - start + 1` in u32 (a panic in safe builds, undefined behaviour in
//! the ReleaseFast cart). Every span must give a stable verdict in both;
//! run with `-Dtest-optimize=safe` (the default) and `-Dtest-optimize=fast`.
const std = @import("std");
const core = @import("core");
const romfs = @import("romfs");
const drive = @import("drive");
const rom = core.rom;
const testing = std.testing;

/// A minimal ROM with a "SEGA" header declaring `start..end`.
fn header_rom(buf: *[0x400]u8, start: u32, end: u32) void {
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], 0x00FFFE00, .big);
    std.mem.writeInt(u32, buf[4..8], 0x00000200, .big);
    @memcpy(buf[0x100..][0..16], "SEGA GENESIS    ");
    std.mem.writeInt(u32, buf[0x1A0..][0..4], start, .big);
    std.mem.writeInt(u32, buf[0x1A4..][0..4], end, .big);
    buf[0x200] = 0x60;
    buf[0x201] = 0xFE;
}

const Case = struct { start: u32, end: u32, size: ?u64, verdict: rom.Refusal };

test "rom: header ROM spans give stable verdicts, no overflow" {
    const max = std.math.maxInt(u32);
    for ([_]Case{
        // One byte at 0 (start == end): a plausible tiny range.
        .{ .start = 0, .end = 0, .size = 1, .verdict = .ok },
        // The whole u32 space: 4 GB, not a wrapped 0.
        .{ .start = 0, .end = max, .size = @as(u64, max) + 1, .verdict = .mapper },
        .{ .start = 1, .end = max, .size = max, .verdict = .mapper },
        .{ .start = max, .end = max, .size = 1, .verdict = .ok },
        // Reversed bounds.
        .{ .start = 0x1000, .end = 0x0FFF, .size = null, .verdict = .bad_range },
        .{ .start = max, .end = 0, .size = null, .verdict = .bad_range },
        // Exactly 4 MB, and one byte over.
        .{ .start = 0, .end = 0x3FFFFF, .size = rom.max_size, .verdict = .ok },
        .{ .start = 0, .end = 0x400000, .size = rom.max_size + 1, .verdict = .mapper },
    }) |c| {
        var buf: [0x400]u8 = undefined;
        header_rom(&buf, c.start, c.end);
        const src = core.RomSource.from_slice(&buf);
        const h = rom.parse_header(&src);
        try testing.expectEqual(c.size, h.declared_size());
        try testing.expectEqual(c.verdict, rom.check(&src));
    }
    try testing.expectEqualStrings("bad header ROM range", rom.Refusal.bad_range.text());
}

const drive_img = @embedFile("fixtures/m2_drive.img");
var clusters: [romfs.max_clusters]u16 = undefined;

fn find(s: *const drive.Scan, name: []const u8) !*const drive.Candidate {
    for (s.candidates[0..s.count]) |*c| {
        if (std.mem.eql(u8, c.file_name(), name)) return c;
    }
    return error.NotFound;
}

test "rom: a drive file whose header claims 00000000-FFFFFFFF is refused beside a valid one" {
    // m2_drive.img with NOHDR.BIN's first 512 bytes turned into a "SEGA"
    // header declaring the whole u32 space (or a reversed range).
    for ([_][2]u32{ .{ 0, 0xFFFF_FFFF }, .{ 0x200, 0x100 } }, [_]rom.Refusal{ .mapper, .bad_range }) |range, want| {
        var img: [drive_img.len]u8 = drive_img.*;
        const s0 = drive.scan(.truncated_test(&img), &clusters);
        const m = try drive.open(.truncated_test(&img), try find(&s0, "NOHDR.BIN"), &clusters);
        const p = m.contiguous() orelse return error.NotContiguous;
        const at = @intFromPtr(p) - @intFromPtr(&img);
        var hdr: [0x400]u8 = undefined;
        header_rom(&hdr, range[0], range[1]);
        @memcpy(img[at..][0..0x200], hdr[0..0x200]);

        const s = drive.scan(.truncated_test(&img), &clusters);
        try testing.expect(s.err == null);
        try testing.expectEqual(@as(u32, 4), s.count);
        try testing.expectEqual(@as(u32, 2), s.playable_count);
        const bad = try find(&s, "NOHDR.BIN");
        try testing.expectEqual(want, bad.verdict);
        try testing.expect(!bad.playable());
        try testing.expectEqualStrings(want.text(), bad.note());
        try testing.expect((try find(&s, "TEST.GEN")).playable());
        try testing.expectEqual(@as(?usize, 0), s.first_playable());
    }
}
