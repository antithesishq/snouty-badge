//! The cartridge ROM as the core sees it: `RomSource` (SPEC.md section 11,
//! PLAN.md "Frozen for M1"). Where the bytes live (embedded in the cart
//! image, a file on the badge drive) is the frontend's business, so this
//! file has no romfs, cart-api or allocator import.
//!
//! Byte order: the ROM is kept exactly as the file (big-endian 68000
//! words), so the embedded and the streamed source are the same bytes.
//! `read16` assembles the big-endian word; reads at or past `size` return
//! open bus (FF, FFFF).
//!
//! M0 scaffold: the interface and the header parse. M1 Track C adds SMD
//! detection and whatever speed the frame loop needs (the fast path must
//! stay one pointer add; the cluster path one table lookup).

/// Cluster size of the streamed source (romfs sectors, docs/ROM_STREAMING.md).
pub const cluster_size: u32 = 512;
pub const cluster_shift = 9;

/// Largest ROM the 68000 map decodes without a mapper (000000-3FFFFF).
pub const max_size: u32 = 0x400000;

/// Stand-in `data_base` for a source with no cluster table: never read.
const no_data = [1]u8{0xFF};

pub const RomSource = struct {
    /// ROM size in bytes.
    size: u32 = 0,
    /// The whole ROM as one run (embedded, or a contiguous drive file): the
    /// fast path, `base[addr]`.
    base: ?[*]const u8 = null,
    /// Otherwise: the romfs cluster number of each 512-byte piece of the
    /// file, in file order, over `data_base` (cluster 2 is `data_base`,
    /// as in lib/romfs.zig). Owned by the frontend; must outlive the source.
    clusters: []const u16 = &.{},
    /// Address of romfs cluster 2 (the first data sector).
    data_base: [*]const u8 = &no_data,

    /// A ROM held in memory (the embedded source, host tests).
    pub fn from_slice(data: []const u8) RomSource {
        return .{ .size = @intCast(@min(data.len, max_size)), .base = data.ptr };
    }

    /// True when `size` is covered by `base` or by `clusters`.
    pub fn valid(src: *const RomSource) bool {
        if (src.base != null) return true;
        return @as(u64, src.clusters.len) * cluster_size >= src.size;
    }
};

/// One ROM byte at `addr` (a byte offset into the ROM).
pub inline fn read8(src: *const RomSource, addr: u32) u8 {
    if (addr >= src.size) return 0xFF;
    if (src.base) |p| return p[addr];
    const cl: u32 = src.clusters[addr >> cluster_shift];
    return src.data_base[(cl - 2) * cluster_size + (addr & (cluster_size - 1))];
}

/// The big-endian word at `addr` (even; the 68000 never reads a word at an
/// odd address and address errors are not emulated, SPEC.md section 4).
/// A word never straddles two 512-byte clusters when `addr` is even.
pub inline fn read16(src: *const RomSource, addr: u32) u16 {
    if (addr +| 1 >= src.size) return if (addr < src.size) @as(u16, read8(src, addr)) << 8 | 0xFF else 0xFFFF;
    if (src.base) |p| return @as(u16, p[addr]) << 8 | p[addr + 1];
    const cl: u32 = src.clusters[addr >> cluster_shift];
    const q = src.data_base + (cl - 2) * cluster_size + (addr & (cluster_size - 1));
    return @as(u16, q[0]) << 8 | q[1];
}

/// Two words, big-endian (vectors, header fields).
pub fn read32(src: *const RomSource, addr: u32) u32 {
    return @as(u32, read16(src, addr)) << 16 | read16(src, addr +% 2);
}

/// The fields of the header at 0x100 the cart uses. Text fields are the
/// raw bytes (space padded); `trim` gives the visible part.
pub const Header = struct {
    /// 0x100: "SEGA GENESIS    " or "SEGA MEGA DRIVE ".
    system: [16]u8,
    /// 0x120: domestic (Japanese market) name.
    domestic: [48]u8,
    /// 0x150: overseas name.
    overseas: [48]u8,
    /// 0x18E: the header checksum (sum of the words from 0x200 on).
    checksum: u16,
    /// 0x1A0 / 0x1A4: ROM start and end address as the header states them.
    rom_start: u32,
    rom_end: u32,
    /// 0x1B0: "RA" when the cartridge declares SRAM (section 11).
    has_sram: bool,
    /// 0x1F0: region letters (J, U, E or the newer hex digit).
    region: [3]u8,

    /// Bytes the header says the ROM has (end - start + 1), 0 if nonsense.
    pub fn declared_size(h: *const Header) u32 {
        if (h.rom_end < h.rom_start) return 0;
        return h.rom_end - h.rom_start + 1;
    }
};

/// Header offset and the smallest ROM that holds a whole header.
pub const header_at: u32 = 0x100;
pub const header_end: u32 = 0x200;

/// True when the word at 0x100 reads "SEGA": the check the drive picker
/// and the cart apply before running a file (section 11).
pub fn is_genesis(src: *const RomSource) bool {
    return src.size >= header_end and read32(src, header_at) == 0x53454741; // "SEGA"
}

pub fn parse_header(src: *const RomSource) Header {
    var h: Header = undefined;
    copy(src, 0x100, &h.system);
    copy(src, 0x120, &h.domestic);
    copy(src, 0x150, &h.overseas);
    h.checksum = read16(src, 0x18E);
    h.rom_start = read32(src, 0x1A0);
    h.rom_end = read32(src, 0x1A4);
    h.has_sram = read8(src, 0x1B0) == 'R' and read8(src, 0x1B1) == 'A';
    copy(src, 0x1F0, &h.region);
    return h;
}

fn copy(src: *const RomSource, at: u32, out: []u8) void {
    for (out, 0..) |*c, i| c.* = read8(src, at + @as(u32, @intCast(i)));
}

/// `s` without trailing spaces and NULs (header text fields).
pub fn trim(s: []const u8) []const u8 {
    var n = s.len;
    while (n > 0 and (s[n - 1] == ' ' or s[n - 1] == 0)) n -= 1;
    return s[0..n];
}
