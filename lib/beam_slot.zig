//! The received-cart slot, format v1: the contract between Snouty Beam
//! (carts/snouty-beam) and the fork firmware's `feature/cart-transfer`
//! (fork/CART_TRANSFER.md in adrian-computering/sycl-badge, which is the
//! spec; this file follows it to the byte).
//!
//! The slot is the external flash's cart-writable area (the last 256 KB of
//! the badge's second chip, fork/EXT_FLASH.md):
//!
//!   area + 0x0000  4 KB sector: the 96-byte header, the rest erased (0xFF)
//!   area + 0x1000  the image: cart RAM bytes from `load_addr` up
//!
//! The image is the cart's UF2 flattened the way the OS's UF2 loader would
//! lay it out in RAM (sycl-badge src/os/loader/loader.zig,
//! `loadUF2FromStorage`): each block's payload at `target_addr - load_addr`,
//! later blocks over earlier ones, gaps zero, `load_addr` the lowest target.
//! Blocks that lie wholly below the end of the IPC block (`ipc_end`,
//! 0x20035100) are dropped: the cart linker loads the ELF and program
//! headers at 0x20030000, inside a framebuffer, and they are no part of
//! the cart. A block straddling `ipc_end` makes the UF2 non-transferable.
//! `Uf2(File)` does that on demand, 4 KB at a time, without holding the
//! image: one pass checks the UF2 exactly as the loader does and builds a
//! small index (for each 4 KB of image, the first and last UF2 block that
//! touches it: 4 bytes per 4 KB, 384 bytes for the largest image cart RAM
//! can hold), then `read` fills any range from the blocks in that window.
//!
//! Plain code over byte slices: no cart API, no allocator, no floats,
//! nothing heavy at comptime. Host tests below and in carts/snouty-beam.
const std = @import("std");

// ---- the contract (fork/CART_TRANSFER.md, "Slot format v1") -------------------

/// "BEAM" in memory.
pub const magic: u32 = 0x4D414542;
pub const format_version: u16 = 1;
pub const header_size: u16 = 96;
/// The header's sector; the image starts right after it.
pub const sector_size: u32 = 4096;
pub const image_offset: u32 = sector_size;
/// Longest name (`name_len` 1..47), the field is 48 bytes zero-padded.
pub const name_max: u8 = 47;
const name_field_len = 48;
/// The cart area's size when the firmware doesn't say (stock firmware, the
/// simulator): what `0x200350F8` gives on the fork with a 2 MB chip. Only
/// used to grey out carts on a badge that cannot receive anyway.
pub const default_area_size: u32 = 256 * 1024;

// Header field offsets.
const off_magic = 0;
const off_version = 4;
const off_header_size = 6;
const off_load_addr = 8;
const off_image_len = 12;
const off_image_crc32 = 16;
const off_descriptor_offset = 20;
const off_source_size = 24;
const off_sender_id = 28;
const off_name_len = 32;
const off_name = 36;
const off_header_crc32 = 92;

/// An address range [start, end).
pub const Region = struct {
    start: u32,
    end: u32,
};

/// Process RAM as the OS links it (`__process_ram_start__`..`_end__`,
/// src/os/linker.ld: 0x20020000, 384 KB): the range the UF2 loader accepts
/// RAM blocks in, and so the slot's `load_addr`..`load_addr + image_len`.
pub const cart_ram: Region = .{ .start = 0x20020000, .end = 0x20080000 };
/// End of the OS's IPC block (`CartIPCData` at 0x20020000, 0x15100 bytes):
/// the image starts at or above it (slot rule: `load_addr >= ipc_end`).
pub const ipc_end: u32 = 0x20035100;
/// Where a slot image may lie: cart RAM above the IPC block.
pub const image_region: Region = .{ .start = ipc_end, .end = cart_ram.end };
/// The cart XIP flash window (`cart_xip`, 256 KB at 0x101C0000). A UF2 with
/// any block here is an XIP cart and cannot be beamed.
pub const cart_xip: Region = .{ .start = 0x101C0000, .end = 0x10200000 };

/// The cart descriptor (sycl-badge os_abi.zig `CartDescriptorTable_v1`):
/// magic, version, bss_start, bss_end, entry_point; 20 bytes on the badge.
pub const cart_magic: u32 = 0x54C1_CA41;
pub const cart_version_v1: u32 = 0x54C126_01;
pub const descriptor_v1_size: u32 = 20;

/// CRC-32 (IEEE 802.3, zlib's `crc32`), for the header and the image.
pub fn crc32(bytes: []const u8) u32 {
    return std.hash.Crc32.hash(bytes);
}

fn rd16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn wr16(b: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, b[off..][0..2], v, .little);
}

fn wr32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}

// ---- the header -----------------------------------------------------------------

pub const Header = struct {
    load_addr: u32,
    image_len: u32,
    image_crc32: u32,
    descriptor_offset: u32,
    source_size: u32,
    sender_id: u32 = 0,
    name_len: u8,
    /// Zero after `name_len`.
    name_buf: [name_field_len]u8,

    pub fn name(h: *const Header) []const u8 {
        return h.name_buf[0..@min(h.name_len, name_max)];
    }

    /// The 96 header bytes, `header_crc32` included.
    pub fn encode(h: *const Header) [header_size]u8 {
        var b: [header_size]u8 = @splat(0);
        wr32(&b, off_magic, magic);
        wr16(&b, off_version, format_version);
        wr16(&b, off_header_size, header_size);
        wr32(&b, off_load_addr, h.load_addr);
        wr32(&b, off_image_len, h.image_len);
        wr32(&b, off_image_crc32, h.image_crc32);
        wr32(&b, off_descriptor_offset, h.descriptor_offset);
        wr32(&b, off_source_size, h.source_size);
        wr32(&b, off_sender_id, h.sender_id);
        b[off_name_len] = h.name_len;
        @memcpy(b[off_name..][0..h.name_len], h.name_buf[0..h.name_len]);
        wr32(&b, off_header_crc32, crc32(b[0..off_header_crc32]));
        return b;
    }
};

/// Why a header is not a valid slot.
pub const HeaderError = error{
    BadMagic,
    BadVersion,
    BadHeaderSize,
    BadHeaderCrc,
    BadName,
    ImageTooLong,
    OutsideCartRam,
    BadDescriptorOffset,
};

/// The "valid slot" rule, all the firmware's menu checks: magic, version,
/// header_size and header_crc32 match; the name is 1..47 printable bytes;
/// `image_len` fits an area of `area_size` bytes after the header sector;
/// the image lies in cart RAM; the 20-byte descriptor lies inside the
/// image, 4-aligned. "In cart RAM" is `image_region`: at or above
/// `ipc_end`.
pub fn parse(bytes: *const [header_size]u8, area_size: u32) HeaderError!Header {
    if (rd32(bytes, off_magic) != magic) return error.BadMagic;
    if (rd16(bytes, off_version) != format_version) return error.BadVersion;
    if (rd16(bytes, off_header_size) != header_size) return error.BadHeaderSize;
    if (rd32(bytes, off_header_crc32) != crc32(bytes[0..off_header_crc32])) return error.BadHeaderCrc;
    var h: Header = .{
        .load_addr = rd32(bytes, off_load_addr),
        .image_len = rd32(bytes, off_image_len),
        .image_crc32 = rd32(bytes, off_image_crc32),
        .descriptor_offset = rd32(bytes, off_descriptor_offset),
        .source_size = rd32(bytes, off_source_size),
        .sender_id = rd32(bytes, off_sender_id),
        .name_len = bytes[off_name_len],
        .name_buf = bytes[off_name..][0..name_field_len].*,
    };
    if (h.name_len == 0 or h.name_len > name_max) return error.BadName;
    for (h.name()) |c| if (c < 0x20 or c > 0x7E) return error.BadName;
    @memset(h.name_buf[h.name_len..], 0);
    try check_fields(&h, area_size);
    return h;
}

/// The range and descriptor rules of `parse`, for a header built here.
pub fn check_fields(h: *const Header, area_size: u32) HeaderError!void {
    if (area_size < image_offset or h.image_len > area_size - image_offset) return error.ImageTooLong;
    if (h.load_addr < image_region.start or @as(u64, h.load_addr) + h.image_len > image_region.end) return error.OutsideCartRam;
    if (h.descriptor_offset % 4 != 0 or @as(u64, h.descriptor_offset) + descriptor_v1_size > h.image_len)
        return error.BadDescriptorOffset;
}

/// Bytes an area of `area_size` can hold as an image.
pub fn capacity(area_size: u32) u32 {
    return area_size -| image_offset;
}

/// A slot name from a file name: the extension cut off, bytes outside
/// 0x20..0x7E as '?', at most 47 bytes, "CART" when nothing is left.
pub fn name_from_file(file_name: []const u8, out: *[name_field_len]u8) u8 {
    var stem = file_name;
    if (std.mem.lastIndexOfScalar(u8, stem, '.')) |dot| {
        if (dot > 0) stem = stem[0..dot];
    }
    out.* = @splat(0);
    if (stem.len == 0) stem = "CART";
    const n: u8 = @intCast(@min(stem.len, name_max));
    for (stem[0..n], out[0..n]) |c, *o| o.* = if (c >= 0x20 and c <= 0x7E) c else '?';
    return n;
}

/// The cart descriptor rule the UF2 loader applies before launching a RAM
/// cart (v1: BSS inside cart RAM, entry in cart RAM or cart XIP, thumb bit),
/// over the descriptor's 20 image bytes.
pub fn descriptor_ok(desc: *const [descriptor_v1_size]u8) bool {
    if (rd32(desc, 0) != cart_magic) return false;
    if (rd32(desc, 4) != cart_version_v1) return false;
    const bss_start = rd32(desc, 8);
    const bss_end = rd32(desc, 12);
    const entry = rd32(desc, 16);
    const r = cart_ram;
    const x = cart_xip;
    if (bss_start < r.start or bss_start > r.end or bss_end < r.start or bss_end > r.end or bss_start > bss_end)
        return false;
    if (!(entry >= r.start and entry < r.end or entry >= x.start and entry < x.end)) return false;
    return entry & 1 == 1;
}

/// "Launchable": a valid header whose image (the bytes after the header
/// sector) matches `image_crc32` and whose descriptor passes the loader's
/// v1 checks. `area` is the whole cart area.
pub fn launchable(area: []const u8) bool {
    if (area.len < image_offset) return false;
    const h = parse(area[0..header_size], @intCast(@min(area.len, std.math.maxInt(u32)))) catch return false;
    const image = area[image_offset..][0..h.image_len];
    if (crc32(image) != h.image_crc32) return false;
    return descriptor_ok(image[h.descriptor_offset..][0..descriptor_v1_size]);
}

// ---- UF2 -> image ----------------------------------------------------------------

pub const uf2_block_size: u32 = 512;
const uf2_magic0: u32 = 0x0A324655;
const uf2_magic1: u32 = 0x9E5D5157;
const uf2_magic_end: u32 = 0x0AB16F30;
const uf2_max_payload: u32 = 476;
const uf2_flag_family: u32 = 0x00002000;
const uf2_families = [_]u32{ 0xE48BFF59, 0xE48BFF5A, 0xE48BFF5B };

/// Why a UF2 cannot be beamed. The first group is what the OS's UF2 loader
/// would refuse too; `Xip` is an XIP cart (it runs from the cart flash
/// window, which a slot cannot hold); `NoDescriptor`/`BadDescriptor` a UF2
/// without a RAM cart descriptor the loader would launch.
pub const Uf2Error = error{
    /// Empty, not a multiple of 512 bytes, or a block without the UF2 magics.
    NotUf2,
    /// A payload over 476 bytes or of 0 bytes, a block number past the count.
    BadBlock,
    /// A family other than RP2350's.
    WrongFamily,
    /// Fewer or more blocks than the first block's count.
    Incomplete,
    /// A block in the cart XIP window.
    Xip,
    /// A block outside both cart RAM and the XIP window.
    OutsideCartRam,
    /// A block that starts below `ipc_end` and ends above it.
    StraddlesIpc,
    NoDescriptor,
    BadDescriptor,
};

/// What one pass over a UF2 finds.
pub const Info = struct {
    load_addr: u32,
    image_len: u32,
    descriptor_offset: u32,
    blocks: u32,
};

/// Image chunks the index covers: cart RAM / 4 KB.
pub const max_chunks: u32 = (image_region.end - image_region.start + sector_size - 1) / sector_size;

/// A block wholly below `ipc_end`, which the image leaves out.
fn dropped(target: u32) bool {
    return target < ipc_end;
}

/// A UF2 file held as bytes (host tools, tests, a contiguous drive file).
pub const SliceFile = struct {
    bytes: []const u8,
    pub fn size(f: *const SliceFile) u32 {
        return @intCast(f.bytes.len);
    }
    pub fn block(f: *const SliceFile, index: u32) *const [uf2_block_size]u8 {
        return f.bytes[index * uf2_block_size ..][0..uf2_block_size];
    }
};

/// The flattener over a UF2 `File`: `size(f) u32` and `block(f, i)` giving
/// the i-th 512-byte block (on the badge: a drive file through
/// lib/romfs.zig, where a block is exactly one cluster). State: the file,
/// `info` and the index, about 400 bytes.
pub fn Uf2(comptime File: type) type {
    return struct {
        const Self = @This();

        file: File,
        info: Info,
        /// For each 4 KB image chunk, the first and last UF2 block touching it
        /// (first > last: none, the chunk is zero).
        first: [max_chunks]u16,
        last: [max_chunks]u16,

        /// One pass with the UF2 loader's checks, in its order; then the
        /// index; then the descriptor read back from the flattened image
        /// and checked as the loader would before launching.
        pub fn open(file: File) Uf2Error!Self {
            var self: Self = .{ .file = file, .info = undefined, .first = undefined, .last = undefined };
            const fsize = self.file.size();
            if (fsize == 0 or fsize % uf2_block_size != 0) return error.NotUf2;
            const count = fsize / uf2_block_size;
            if (count > std.math.maxInt(u16)) return error.NotUf2;
            var expected: u32 = 0;
            var lo: u32 = std.math.maxInt(u32);
            var hi: u32 = 0;
            var desc_addr: ?u32 = null;
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const b = self.file.block(i);
                if (rd32(b, 0) != uf2_magic0 or rd32(b, 4) != uf2_magic1 or rd32(b, 508) != uf2_magic_end) return error.NotUf2;
                const flags = rd32(b, 8);
                const target = rd32(b, 12);
                const len = rd32(b, 16);
                if (len > uf2_max_payload) return error.BadBlock;
                if (i == 0) {
                    expected = rd32(b, 24);
                    if (flags & uf2_flag_family != 0 and std.mem.indexOfScalar(u32, &uf2_families, rd32(b, 28)) == null)
                        return error.WrongFamily;
                }
                if (rd32(b, 20) >= rd32(b, 24)) return error.BadBlock;
                if (len == 0) return error.BadBlock;
                const end = @as(u64, target) + len;
                // The loader's order: the XIP test first, then RAM.
                if (target >= cart_xip.start and end < cart_xip.end) return error.Xip;
                if (!(target >= cart_ram.start and end <= cart_ram.end)) return error.OutsideCartRam;
                if (target < ipc_end and end > ipc_end) return error.StraddlesIpc;
                if (dropped(target)) continue;
                lo = @min(lo, target);
                hi = @max(hi, @as(u32, @intCast(end)));
                if (desc_addr == null) {
                    const words = len / 4;
                    var w: u32 = 0;
                    while (w < words) : (w += 1) {
                        if (rd32(b, 32 + w * 4) == cart_magic) {
                            desc_addr = target + w * 4;
                            break;
                        }
                    }
                }
            }
            if (count != expected) return error.Incomplete;
            const da = desc_addr orelse return error.NoDescriptor;
            if (lo > hi) return error.NoDescriptor;
            self.info = .{
                .load_addr = lo,
                .image_len = hi - lo,
                .descriptor_offset = da - lo,
                .blocks = count,
            };
            // The index.
            const chunks = self.chunk_count();
            @memset(self.first[0..chunks], std.math.maxInt(u16));
            @memset(self.last[0..chunks], 0);
            i = 0;
            while (i < count) : (i += 1) {
                const b = self.file.block(i);
                if (dropped(rd32(b, 12))) continue;
                const off = rd32(b, 12) - lo;
                const len = rd32(b, 16);
                var c = off / sector_size;
                const c_end = (off + len - 1) / sector_size;
                while (c <= c_end) : (c += 1) {
                    self.first[c] = @min(self.first[c], @as(u16, @intCast(i)));
                    self.last[c] = @max(self.last[c], @as(u16, @intCast(i)));
                }
            }
            // The descriptor as the loader will find it after every block
            // is in place (a later block could cover it).
            if (self.info.descriptor_offset % 4 != 0 or
                @as(u64, self.info.descriptor_offset) + descriptor_v1_size > self.info.image_len)
                return error.BadDescriptor;
            var desc: [descriptor_v1_size]u8 = undefined;
            self.read(self.info.descriptor_offset, &desc);
            if (!descriptor_ok(&desc)) return error.BadDescriptor;
            return self;
        }

        /// 4 KB chunks in the image (the last one may be short).
        pub fn chunk_count(self: *const Self) u32 {
            return (self.info.image_len + sector_size - 1) / sector_size;
        }

        /// Image bytes `offset .. offset + dst.len` (within the image).
        pub fn read(self: *const Self, offset: u32, dst: []u8) void {
            @memset(dst, 0);
            if (dst.len == 0) return;
            const end: u32 = offset + @as(u32, @intCast(dst.len));
            var c = offset / sector_size;
            while (c * sector_size < end) : (c += 1) {
                // This chunk's share of the range.
                const lo = @max(offset, c * sector_size);
                const hi = @min(end, (c + 1) * sector_size);
                if (self.first[c] > self.last[c]) continue;
                var i: u32 = self.first[c];
                while (i <= self.last[c]) : (i += 1) {
                    const b = self.file.block(i);
                    if (dropped(rd32(b, 12))) continue;
                    const boff = rd32(b, 12) - self.info.load_addr;
                    const blen = rd32(b, 16);
                    const s = @max(lo, boff);
                    const e = @min(hi, boff + blen);
                    if (s >= e) continue;
                    @memcpy(dst[s - offset .. e - offset], b[32 + (s - boff) ..][0 .. e - s]);
                }
            }
        }

        /// CRC-32 of the whole image, a chunk per call: `crc_step` until it
        /// returns true, `scratch` holds one chunk.
        pub fn crc_step(self: *const Self, state: *CrcState, scratch: *[sector_size]u8) bool {
            if (state.at >= self.info.image_len) return true;
            const n = @min(sector_size, self.info.image_len - state.at);
            self.read(state.at, scratch[0..n]);
            state.h.update(scratch[0..n]);
            state.at += n;
            return state.at >= self.info.image_len;
        }

        /// The header for this image: `image_crc` from `crc_step`.
        pub fn header(self: *const Self, image_crc: u32, file_name: []const u8) Header {
            var h: Header = .{
                .load_addr = self.info.load_addr,
                .image_len = self.info.image_len,
                .image_crc32 = image_crc,
                .descriptor_offset = self.info.descriptor_offset,
                .source_size = self.file.size(),
                .name_len = 0,
                .name_buf = undefined,
            };
            h.name_len = name_from_file(file_name, &h.name_buf);
            return h;
        }
    };
}

pub const CrcState = struct {
    h: std.hash.Crc32 = .init(),
    at: u32 = 0,
    pub fn final(s: *const CrcState) u32 {
        return s.h.final();
    }
};

/// The slot area for a UF2: the header sector (header, then 0xFF) and the
/// image, `image_offset + image_len` bytes into `out` (host tools). Returns
/// the bytes written.
pub fn write_area(u: *const Uf2(SliceFile), file_name: []const u8, out: []u8) error{NoSpace}!usize {
    const total = image_offset + u.info.image_len;
    if (out.len < total) return error.NoSpace;
    @memset(out[0..image_offset], 0xFF);
    const image = out[image_offset..total];
    u.read(0, image);
    const h = u.header(crc32(image), file_name);
    out[0..header_size].* = h.encode();
    return total;
}

// ---- tests ------------------------------------------------------------------------

const testing = std.testing;

fn test_header() Header {
    var h: Header = .{
        .load_addr = 0x20035100,
        .image_len = 0x5D00,
        .image_crc32 = 0x12345678,
        .descriptor_offset = 0x0100,
        .source_size = 48640,
        .sender_id = 0xBEEF,
        .name_len = 0,
        .name_buf = undefined,
    };
    h.name_len = name_from_file("snouty-pong.uf2", &h.name_buf);
    return h;
}

test "beam_slot: golden header bytes" {
    const h = test_header();
    const b = h.encode();
    // Hand-written from fork/CART_TRANSFER.md's table.
    const want_prefix = [_]u8{
        0x42, 0x45, 0x41, 0x4D, // "BEAM"
        0x01, 0x00, 0x60, 0x00, // version 1, header_size 96
        0x00, 0x51, 0x03, 0x20, // load_addr
        0x00, 0x5D, 0x00, 0x00, // image_len
        0x78, 0x56, 0x34, 0x12, // image_crc32
        0x00, 0x01, 0x00, 0x00, // descriptor_offset
        0x00, 0xBE, 0x00, 0x00, // source_size 48640
        0xEF, 0xBE, 0x00, 0x00, // sender_id
        11, 0, 0, 0, // name_len, reserved
    };
    try testing.expectEqualSlices(u8, &want_prefix, b[0..36]);
    try testing.expectEqualSlices(u8, "snouty-pong", b[36..47]);
    for (b[47..92]) |z| try testing.expectEqual(@as(u8, 0), z);
    try testing.expectEqual(crc32(b[0..92]), rd32(&b, 92));
    // zlib.crc32 of these 92 bytes, computed outside Zig (python3 -c).
    try testing.expectEqual(@as(u32, 0x2874B509), rd32(&b, 92));
    const back = try parse(&b, default_area_size);
    try testing.expectEqualDeep(h, back);
}

test "beam_slot: crc32 is zlib's" {
    try testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));
}

test "beam_slot: every validity rule" {
    const good = test_header().encode();
    _ = try parse(&good, default_area_size);

    const Case = struct { off: usize, val: u8, err: HeaderError };
    // One byte broken at a time, header CRC left stale (it is checked after
    // magic, version and size).
    const raw_cases = [_]Case{
        .{ .off = 0, .val = 0x41, .err = error.BadMagic },
        .{ .off = 4, .val = 2, .err = error.BadVersion },
        .{ .off = 6, .val = 95, .err = error.BadHeaderSize },
        .{ .off = 40, .val = 0x58, .err = error.BadHeaderCrc },
        .{ .off = 92, .val = 0, .err = error.BadHeaderCrc },
    };
    for (raw_cases) |c| {
        var b = good;
        b[c.off] = c.val;
        try testing.expectError(c.err, parse(&b, default_area_size));
    }

    // Field rules, each with a fresh header CRC.
    const Mut = struct {
        fn apply(f: *const fn (*Header) void) [header_size]u8 {
            var h = test_header();
            f(&h);
            return h.encode();
        }
    };
    const fields = struct {
        fn name0(h: *Header) void {
            h.name_len = 0;
        }
        fn name48(h: *Header) void {
            h.name_len = 48;
            @memset(&h.name_buf, 'a');
        }
        fn name_ctrl(h: *Header) void {
            h.name_buf[2] = 0x07;
        }
        fn name_hi(h: *Header) void {
            h.name_buf[0] = 0x80;
        }
        fn too_long(h: *Header) void {
            h.image_len = default_area_size - image_offset + 1;
        }
        fn below_ram(h: *Header) void {
            h.load_addr = ipc_end - 4;
        }
        fn past_ram(h: *Header) void {
            h.load_addr = cart_ram.end - h.image_len + 4;
        }
        fn wraps(h: *Header) void {
            h.load_addr = 0xFFFF_F000;
        }
        fn desc_misaligned(h: *Header) void {
            h.descriptor_offset = 0x0102;
        }
        fn desc_outside(h: *Header) void {
            h.descriptor_offset = h.image_len - 16;
        }
        fn desc_huge(h: *Header) void {
            h.descriptor_offset = 0xFFFF_FFFC;
        }
    };
    const want = [_]struct { f: *const fn (*Header) void, err: HeaderError }{
        .{ .f = fields.name0, .err = error.BadName },
        .{ .f = fields.name48, .err = error.BadName },
        .{ .f = fields.name_ctrl, .err = error.BadName },
        .{ .f = fields.name_hi, .err = error.BadName },
        .{ .f = fields.too_long, .err = error.ImageTooLong },
        .{ .f = fields.below_ram, .err = error.OutsideCartRam },
        .{ .f = fields.past_ram, .err = error.OutsideCartRam },
        .{ .f = fields.wraps, .err = error.OutsideCartRam },
        .{ .f = fields.desc_misaligned, .err = error.BadDescriptorOffset },
        .{ .f = fields.desc_outside, .err = error.BadDescriptorOffset },
        .{ .f = fields.desc_huge, .err = error.BadDescriptorOffset },
    };
    for (want) |w| {
        const b = Mut.apply(w.f);
        try testing.expectError(w.err, parse(&b, default_area_size));
    }
    // Edges that are valid: the image filling the area, ending at RAM's end,
    // the descriptor as the image's last 20 bytes, a 47-byte name.
    const edges = struct {
        fn full(h: *Header) void {
            h.image_len = default_area_size - image_offset;
            h.load_addr = cart_ram.end - h.image_len;
        }
        fn desc_last(h: *Header) void {
            h.descriptor_offset = h.image_len - descriptor_v1_size;
        }
        fn name47(h: *Header) void {
            h.name_len = 47;
            @memset(h.name_buf[0..47], '~');
            h.name_buf[47] = 0;
        }
    };
    for ([_]*const fn (*Header) void{ edges.full, edges.desc_last, edges.name47 }) |f| {
        const b = Mut.apply(f);
        _ = try parse(&b, default_area_size);
    }
    // A smaller area (another chip size) shrinks the limit.
    try testing.expectError(error.ImageTooLong, parse(&good, image_offset + 0x5D00 - 1));
    _ = try parse(&good, image_offset + 0x5D00);
    try testing.expectError(error.ImageTooLong, parse(&good, 100));
}

test "beam_slot: names from file names" {
    var buf: [name_field_len]u8 = undefined;
    var n = name_from_file("snouty-boy.uf2", &buf);
    try testing.expectEqualSlices(u8, "snouty-boy", buf[0..n]);
    n = name_from_file("a.b.c", &buf);
    try testing.expectEqualSlices(u8, "a.b", buf[0..n]);
    n = name_from_file(".uf2", &buf);
    try testing.expectEqualSlices(u8, ".uf2", buf[0..n]);
    n = name_from_file("", &buf);
    try testing.expectEqualSlices(u8, "CART", buf[0..n]);
    n = name_from_file("caf\xc3\xa9.uf2", &buf);
    try testing.expectEqualSlices(u8, "caf??", buf[0..n]);
    var long: [64]u8 = @splat('x');
    @memcpy(long[60..], ".uf2");
    n = name_from_file(&long, &buf);
    try testing.expectEqual(@as(u8, 47), n);
    try testing.expectEqual(@as(u8, 0), buf[47]);
}

/// A synthetic UF2 for the flattener tests: `blocks` of (target, payload).
const TestBlock = struct { target: u32, len: u32, fill: u8, family: ?u32 = 0xE48BFF59 };

fn make_uf2(out: []u8, blocks: []const TestBlock, count_override: ?u32) []u8 {
    const n: u32 = @intCast(blocks.len);
    for (blocks, 0..) |tb, i| {
        const b = out[i * 512 ..][0..512];
        @memset(b, 0);
        wr32(b, 0, uf2_magic0);
        wr32(b, 4, uf2_magic1);
        wr32(b, 8, if (tb.family != null) uf2_flag_family else 0);
        wr32(b, 12, tb.target);
        wr32(b, 16, tb.len);
        wr32(b, 20, @intCast(i));
        wr32(b, 24, count_override orelse n);
        wr32(b, 28, tb.family orelse 0);
        for (0..@min(tb.len, uf2_max_payload)) |k| b[32 + k] = tb.fill +% @as(u8, @truncate(k));
        wr32(b, 508, uf2_magic_end);
    }
    return out[0 .. blocks.len * 512];
}

/// Put a v1 descriptor into a block's payload at `at` (bytes).
fn put_descriptor(uf2: []u8, block: usize, at: usize) void {
    const p = uf2[block * 512 + 32 + at ..];
    wr32(p, 0, cart_magic);
    wr32(p, 4, cart_version_v1);
    wr32(p, 8, 0x20040000);
    wr32(p, 12, 0x20041000);
    wr32(p, 16, 0x20035121);
}

/// The loader's model: copy every block into a RAM array in file order,
/// leaving out (spec v1) the blocks wholly below the IPC block's end.
fn model_image(uf2: []const u8, ram: []u8) Info {
    @memset(ram, 0);
    var lo: u32 = std.math.maxInt(u32);
    var hi: u32 = 0;
    var i: usize = 0;
    while (i < uf2.len) : (i += 512) {
        const b = uf2[i..][0..512];
        const t = rd32(b, 12);
        const l = rd32(b, 16);
        // Spec v1: blocks wholly below the IPC block's end are not image.
        if (t + l <= ipc_end) continue;
        @memcpy(ram[t - cart_ram.start ..][0..l], b[32..][0..l]);
        lo = @min(lo, t);
        hi = @max(hi, t + l);
    }
    return .{ .load_addr = lo, .image_len = hi - lo, .descriptor_offset = 0, .blocks = @intCast(uf2.len / 512) };
}

test "beam_slot: flattening matches the loader model, any order, overlaps, gaps" {
    var buf: [64 * 512]u8 = undefined;
    var ram: [cart_ram.end - cart_ram.start]u8 = undefined;
    var img: [64 * 1024]u8 = undefined;
    const base: u32 = 0x20035100;
    const layouts = [_][]const TestBlock{
        // In order, 256-byte payloads, with a gap and an odd-sized tail.
        &.{
            .{ .target = base, .len = 256, .fill = 1 },
            .{ .target = base + 256, .len = 256, .fill = 2 },
            .{ .target = base + 0x3000, .len = 256, .fill = 3 },
            .{ .target = base + 0x3100, .len = 13, .fill = 4 },
        },
        // Out of order, overlapping (the later block wins), 476-byte
        // payloads straddling 4 KB chunk edges, a block below the rest.
        &.{
            .{ .target = base + 0x0F80, .len = 476, .fill = 10 },
            .{ .target = base, .len = 256, .fill = 11 },
            .{ .target = base + 0x0F00, .len = 256, .fill = 12 },
            .{ .target = 0x20030000, .len = 256, .fill = 13 },
            .{ .target = base + 0x2000, .len = 476, .fill = 14 },
            .{ .target = base + 0x2010, .len = 16, .fill = 15 },
        },
    };
    for (layouts) |layout| {
        const uf2 = make_uf2(&buf, layout, null);
        // The descriptor in the block at `base`.
        for (layout, 0..) |tb, i| if (tb.target == base) put_descriptor(uf2, i, 0);
        const want = model_image(uf2, &ram);
        const u = try Uf2(SliceFile).open(.{ .bytes = uf2 });
        try testing.expectEqual(want.load_addr, u.info.load_addr);
        try testing.expectEqual(want.image_len, u.info.image_len);
        try testing.expectEqual(base - want.load_addr, u.info.descriptor_offset);
        const image = img[0..want.image_len];
        u.read(0, image);
        try testing.expectEqualSlices(u8, ram[want.load_addr - cart_ram.start ..][0..want.image_len], image);
        // Any sub-range reads the same bytes.
        var off: u32 = 0;
        while (off < want.image_len) : (off += 509) {
            var small: [700]u8 = undefined;
            const n = @min(small.len, want.image_len - off);
            u.read(off, small[0..n]);
            try testing.expectEqualSlices(u8, image[off..][0..n], small[0..n]);
        }
        // The chunked CRC is the CRC of the image.
        var st: CrcState = .{};
        var scratch: [sector_size]u8 = undefined;
        while (!u.crc_step(&st, &scratch)) {}
        try testing.expectEqual(crc32(image), st.final());
    }
}

test "beam_slot: UF2s the loader refuses, XIP carts, no descriptor" {
    var buf: [8 * 512]u8 = undefined;
    const base: u32 = 0x20035100;
    const F = Uf2(SliceFile);
    // Good baseline.
    {
        const uf2 = make_uf2(&buf, &.{ .{ .target = base, .len = 256, .fill = 0 }, .{ .target = base + 256, .len = 256, .fill = 0 } }, null);
        put_descriptor(uf2, 0, 0);
        _ = try F.open(.{ .bytes = uf2 });
        // Truncated file, wrong magic, wrong end magic.
        try testing.expectError(error.NotUf2, F.open(.{ .bytes = uf2[0..1000] }));
        try testing.expectError(error.NotUf2, F.open(.{ .bytes = uf2[0..0] }));
        uf2[512 + 4] ^= 1;
        try testing.expectError(error.NotUf2, F.open(.{ .bytes = uf2 }));
        uf2[512 + 4] ^= 1;
        uf2[508] ^= 1;
        try testing.expectError(error.NotUf2, F.open(.{ .bytes = uf2 }));
    }
    // Block count says 3, file holds 2.
    {
        const uf2 = make_uf2(&buf, &.{ .{ .target = base, .len = 256, .fill = 0 }, .{ .target = base + 256, .len = 256, .fill = 0 } }, 3);
        put_descriptor(uf2, 0, 0);
        try testing.expectError(error.Incomplete, F.open(.{ .bytes = uf2 }));
    }
    // Block number past the count.
    {
        const uf2 = make_uf2(&buf, &.{ .{ .target = base, .len = 256, .fill = 0 }, .{ .target = base + 256, .len = 256, .fill = 0 } }, 1);
        put_descriptor(uf2, 0, 0);
        try testing.expectError(error.BadBlock, F.open(.{ .bytes = uf2 }));
    }
    // Payload too large, empty payload.
    {
        const uf2 = make_uf2(&buf, &.{ .{ .target = base, .len = 256, .fill = 0 }, .{ .target = base + 256, .len = 477, .fill = 0 } }, null);
        put_descriptor(uf2, 0, 0);
        try testing.expectError(error.BadBlock, F.open(.{ .bytes = uf2 }));
        wr32(uf2[512..], 16, 0);
        try testing.expectError(error.BadBlock, F.open(.{ .bytes = uf2 }));
    }
    // Another family; no family flag is fine.
    {
        const uf2 = make_uf2(&buf, &.{.{ .target = base, .len = 256, .fill = 0, .family = 0xE48BFF56 }}, null);
        put_descriptor(uf2, 0, 0);
        try testing.expectError(error.WrongFamily, F.open(.{ .bytes = uf2 }));
        const uf2b = make_uf2(&buf, &.{.{ .target = base, .len = 256, .fill = 0, .family = null }}, null);
        put_descriptor(uf2b, 0, 0);
        _ = try F.open(.{ .bytes = uf2b });
    }
    // An XIP cart (any block in the cart XIP window), and a block elsewhere.
    {
        const uf2 = make_uf2(&buf, &.{ .{ .target = base, .len = 256, .fill = 0 }, .{ .target = cart_xip.start + 0x100, .len = 256, .fill = 0 } }, null);
        put_descriptor(uf2, 0, 0);
        try testing.expectError(error.Xip, F.open(.{ .bytes = uf2 }));
        const uf2b = make_uf2(&buf, &.{ .{ .target = base, .len = 256, .fill = 0 }, .{ .target = 0x10000000, .len = 256, .fill = 0 } }, null);
        put_descriptor(uf2b, 0, 0);
        try testing.expectError(error.OutsideCartRam, F.open(.{ .bytes = uf2b }));
        const uf2c = make_uf2(&buf, &.{.{ .target = cart_ram.end - 128, .len = 256, .fill = 0 }}, null);
        try testing.expectError(error.OutsideCartRam, F.open(.{ .bytes = uf2c }));
        // A block across the end of the IPC block.
        const uf2d = make_uf2(&buf, &.{ .{ .target = base, .len = 256, .fill = 0 }, .{ .target = ipc_end - 16, .len = 32, .fill = 0 } }, null);
        put_descriptor(uf2d, 0, 0);
        try testing.expectError(error.StraddlesIpc, F.open(.{ .bytes = uf2d }));
        // Only blocks below it: nothing to beam.
        const uf2e = make_uf2(&buf, &.{.{ .target = 0x20030000, .len = 256, .fill = 0 }}, null);
        try testing.expectError(error.NoDescriptor, F.open(.{ .bytes = uf2e }));
        // A block ending exactly at it is dropped, the rest is the image.
        const uf2f = make_uf2(&buf, &.{ .{ .target = ipc_end - 256, .len = 256, .fill = 9 }, .{ .target = base, .len = 256, .fill = 0 } }, null);
        put_descriptor(uf2f, 1, 0);
        const u = try F.open(.{ .bytes = uf2f });
        try testing.expectEqual(ipc_end, u.info.load_addr);
        try testing.expectEqual(@as(u32, 256), u.info.image_len);
    }
    // No descriptor; a descriptor a later block overwrites; a broken one.
    {
        const uf2 = make_uf2(&buf, &.{.{ .target = base, .len = 256, .fill = 0 }}, null);
        try testing.expectError(error.NoDescriptor, F.open(.{ .bytes = uf2 }));
        const uf2b = make_uf2(&buf, &.{ .{ .target = base, .len = 256, .fill = 0 }, .{ .target = base, .len = 16, .fill = 0 } }, null);
        put_descriptor(uf2b, 0, 0);
        try testing.expectError(error.BadDescriptor, F.open(.{ .bytes = uf2b }));
        const uf2c = make_uf2(&buf, &.{.{ .target = base, .len = 256, .fill = 0 }}, null);
        put_descriptor(uf2c, 0, 0);
        wr32(uf2c[32..], 16, 0x20035120); // entry without the thumb bit
        try testing.expectError(error.BadDescriptor, F.open(.{ .bytes = uf2c }));
        // The magic found at a 4-aligned spot of a payload that starts off
        // a word boundary is not 4-aligned in the image.
        const uf2d = make_uf2(&buf, &.{ .{ .target = base + 2, .len = 256, .fill = 0 }, .{ .target = base + 1, .len = 1, .fill = 0 } }, null);
        put_descriptor(uf2d, 0, 4);
        try testing.expectError(error.BadDescriptor, F.open(.{ .bytes = uf2d }));
    }
}

test "beam_slot: write_area gives a valid, launchable slot" {
    var buf: [8 * 512]u8 = undefined;
    const base: u32 = 0x20035100;
    const uf2 = make_uf2(&buf, &.{ .{ .target = base, .len = 256, .fill = 5 }, .{ .target = base + 0x2000, .len = 256, .fill = 6 } }, null);
    put_descriptor(uf2, 0, 0);
    const u = try Uf2(SliceFile).open(.{ .bytes = uf2 });
    var area: [default_area_size]u8 = @splat(0xFF);
    const n = try write_area(&u, "test.uf2", &area);
    try testing.expectEqual(@as(usize, image_offset + 0x2100), n);
    for (area[header_size..image_offset]) |x| try testing.expectEqual(@as(u8, 0xFF), x);
    const h = try parse(area[0..header_size], default_area_size);
    try testing.expectEqualSlices(u8, "test", h.name());
    try testing.expectEqual(@as(u32, @intCast(uf2.len)), h.source_size);
    try testing.expect(launchable(&area));
    area[image_offset + 0x1000] ^= 1;
    try testing.expect(!launchable(&area));
}
