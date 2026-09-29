//! ROM image access for the core. The Game Boy sees its cartridge as 16 KB
//! banks, so the image is a table of bank pointers: an embedded ROM is one
//! contiguous slice (every bank a plain pointer into it), a ROM file read in
//! place from the badge drive (docs/ROM_DRIVE.md) is usually contiguous too,
//! and when it is fragmented across the drive's 512-byte clusters the banks
//! that are not contiguous go through a per-sector pointer table instead.
//! Read-only, built once at start by the frontend, never part of a keyframe.
//! The MMU caches the two mapped banks' pointers (`Gb.rom0`, `Gb.romn`) so the
//! hot path is one load, exactly as with the old contiguous slice.
const std = @import("std");

pub const bank_bytes: u32 = 0x4000;
pub const sector_bytes: u32 = 512;
/// 1 MB: 64 banks, all an MBC5 can address once `Mbc.rom_bank_mask` applies
/// (SPEC.md section 11). Bigger images are cut off.
pub const max_bytes: u32 = 1024 * 1024;
pub const max_banks: usize = max_bytes / bank_bytes;
pub const max_sectors: usize = max_bytes / sector_bytes;

pub const Rom = struct {
    /// Bytes in the image, at most `max_bytes`. Reads at or past it give 0xFF
    /// (open bus), which is also what a bank past the end of a small ROM
    /// reads once `Mbc.rom_bank_mask` has folded the bank number.
    len: u32 = 0,
    /// One pointer per 16 KB bank when the whole bank is contiguous in
    /// memory; null past `len`, for a partial last bank, and for a bank of a
    /// fragmented drive file. Null banks are read through `sectors` or `tail`.
    banks: [max_banks]?[*]const u8 = @splat(null),
    /// Drive files: a pointer to each 512-byte sector of the image, in file
    /// order, `ceil(len / 512)` of them. Empty for an embedded ROM.
    sectors: []const [*]const u8 = &.{},
    /// Embedded ROM whose length is not a multiple of 16 KB (test images):
    /// the start of the partial last bank.
    tail: ?[*]const u8 = null,

    /// A contiguous image (embedded ROM, host test buffer).
    pub fn from_slice(bytes: []const u8) Rom {
        var r: Rom = .{ .len = @intCast(@min(bytes.len, max_bytes)) };
        var bank: usize = 0;
        while ((bank + 1) * bank_bytes <= r.len) : (bank += 1) r.banks[bank] = bytes.ptr + bank * bank_bytes;
        if (bank * bank_bytes < r.len) r.tail = bytes.ptr + bank * bank_bytes;
        return r;
    }

    /// An image of `len` bytes made of 512-byte sectors that may lie anywhere
    /// (a file on the badge drive). Banks whose 32 sectors are consecutive in
    /// memory get a direct pointer; the rest read through the table. The
    /// slice must outlive the Rom.
    pub fn from_sectors(len: u32, sectors: []const [*]const u8) Rom {
        var r: Rom = .{ .len = @min(len, max_bytes), .sectors = sectors };
        const per_bank = bank_bytes / sector_bytes;
        var bank: usize = 0;
        while ((bank + 1) * bank_bytes <= r.len) : (bank += 1) {
            const first = bank * per_bank;
            if (first + per_bank > sectors.len) break;
            const base = sectors[first];
            var contiguous = true;
            for (sectors[first..][0..per_bank], 0..) |p, i| {
                if (p != base + i * sector_bytes) {
                    contiguous = false;
                    break;
                }
            }
            if (contiguous) r.banks[bank] = base;
        }
        return r;
    }

    /// Any byte of the image, fast bank or slow path. The MMU uses the cached
    /// bank pointers instead; this serves the header and the slow path.
    pub fn read(r: *const Rom, off: u32) u8 {
        if (off >= r.len) return 0xFF;
        if (r.banks[off / bank_bytes]) |p| return p[off % bank_bytes];
        if (r.sectors.len != 0) return r.sectors[off / sector_bytes][off % sector_bytes];
        if (r.tail) |t| return t[off % bank_bytes];
        return 0xFF;
    }

    /// Pointer to a contiguous bank, or null when it must go through `read`.
    /// `bank` may be any value the MBC produces; past the table it is null.
    pub inline fn bank_ptr(r: *const Rom, bank: u32) ?[*]const u8 {
        return if (bank < max_banks) r.banks[bank] else null;
    }

    /// Banks the drive file could not map directly (0 for an embedded ROM);
    /// the frontend shows a hint when this is not zero.
    pub fn fragmented_banks(r: *const Rom) u32 {
        var n: u32 = 0;
        var bank: usize = 0;
        while ((bank + 1) * bank_bytes <= r.len) : (bank += 1) {
            if (r.banks[bank] == null) n += 1;
        }
        return n;
    }

    /// IEEE CRC32 over the whole image, for the About screen and the bench.
    pub fn crc32(r: *const Rom) u32 {
        var h = std.hash.Crc32.init();
        var off: u32 = 0;
        while (off < r.len) {
            if (r.banks[off / bank_bytes]) |p| {
                const n = @min(bank_bytes, r.len - off);
                h.update(p[0..n]);
                off += n;
            } else {
                var buf: [sector_bytes]u8 = undefined;
                const n = @min(sector_bytes, r.len - off);
                for (buf[0..n], 0..) |*b, i| b.* = r.read(off + @as(u32, @intCast(i)));
                h.update(buf[0..n]);
                off += n;
            }
        }
        return h.final();
    }
};

test "from_slice: full banks direct, partial tail through read" {
    var img: [0x4000 + 0x150]u8 = undefined;
    for (&img, 0..) |*b, i| b.* = @truncate(i * 7);
    const r = Rom.from_slice(&img);
    try std.testing.expectEqual(@as(u32, img.len), r.len);
    try std.testing.expect(r.banks[0] != null);
    try std.testing.expect(r.banks[1] == null);
    try std.testing.expectEqual(img[0x3FFF], r.read(0x3FFF));
    try std.testing.expectEqual(img[0x4000], r.read(0x4000));
    try std.testing.expectEqual(img[0x414F], r.read(0x414F));
    try std.testing.expectEqual(@as(u8, 0xFF), r.read(0x4150));
    try std.testing.expectEqual(@as(u8, 0xFF), r.read(0x7FFF));
    try std.testing.expectEqual(@as(u8, 0xFF), r.read(max_bytes));
    try std.testing.expectEqual(@as(u32, 0), r.fragmented_banks());
    try std.testing.expectEqual(std.hash.Crc32.hash(&img), r.crc32());
}

test "from_sectors: contiguous banks direct, shuffled ones through the table" {
    // A 32 KB image whose second bank is stored with two sectors swapped.
    var img: [0x8000]u8 = undefined;
    for (&img, 0..) |*b, i| b.* = @truncate(i ^ (i >> 8));
    var storage: [0x8000]u8 = img;
    std.mem.swap([512]u8, storage[0x4000..][0..512], storage[0x4200..][0..512]);
    var sectors: [64][*]const u8 = undefined;
    for (&sectors, 0..) |*s, i| s.* = storage[i * 512 ..].ptr;
    std.mem.swap([*]const u8, &sectors[32], &sectors[33]);
    const r = Rom.from_sectors(img.len, &sectors);
    try std.testing.expect(r.banks[0] != null);
    try std.testing.expect(r.banks[1] == null);
    try std.testing.expectEqual(@as(u32, 1), r.fragmented_banks());
    for (img, 0..) |want, i| try std.testing.expectEqual(want, r.read(@intCast(i)));
    try std.testing.expectEqual(std.hash.Crc32.hash(&img), r.crc32());
}
