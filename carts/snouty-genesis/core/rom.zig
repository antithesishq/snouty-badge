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
//! Reads: the fast path (`base`) is one bounds compare and one pointer
//! add; the cluster path one table lookup more. Open bus: a read at or past
//! `size` returns FF (FFFF for a word), the value most emulators give for
//! an unconnected cartridge line (the real bus floats; SPEC.md section 4
//! does not model it).
//!
//! Load-time refusals (`check`): no "SEGA" header, SMD interleave, over
//! 4 MB (file or header range) or a bank-switching mapper (SSF2), the SVP
//! chip, a header ROM range whose end lies before its start. The frontend
//! prints the `Refusal`'s `text()` and falls back to the embedded ROM.

const std = @import("std");

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

/// A stretch of the ROM held in one piece of memory: bytes
/// `base .. base + len` of the ROM are `ptr[0 .. len]`.
pub const Run = struct { ptr: [*]const u8, base: u32, len: u32 };

/// Clusters `run_at` scans in each direction from the cluster of `addr`
/// (so a fetch-window or DMA miss on a fragmented ROM costs a bounded
/// loop; a 64-cluster cap is 32 KB either side).
pub const run_cap: u32 = 64;

/// The run of the ROM that holds `addr`, null at or past `size`. A `base`
/// source is one run (the whole ROM). A clustered source gives the maximal
/// stretch of consecutive volume clusters around the cluster of `addr`
/// (at most `run_cap` clusters back and `run_cap` forward), clipped to
/// `size`. The 68000's fetch window and the VDP's DMA spans come from here
/// (core/bus.zig), so a fragmented drive file is read by pointer inside
/// each run and the bus asks again only at a run boundary.
pub fn run_at(src: *const RomSource, addr: u32) ?Run {
    if (addr >= src.size) return null;
    if (src.base) |p| return .{ .ptr = p, .base = 0, .len = src.size };
    const cl = src.clusters;
    const i: u32 = addr >> cluster_shift;
    const last_index: u32 = (src.size - 1) >> cluster_shift;
    var first = i;
    const lo = i -| run_cap;
    while (first > lo and cl[first - 1] +% 1 == cl[first]) first -= 1;
    var last = i;
    const hi = @min(last_index, i + run_cap);
    while (last < hi and cl[last + 1] == cl[last] +% 1) last += 1;
    const base = first << cluster_shift;
    const len = @min((last - first + 1) << cluster_shift, src.size - base);
    return .{ .ptr = src.data_base + (@as(u32, cl[first]) - 2) * cluster_size, .base = base, .len = len };
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
    /// 0x1B2: SRAM kind byte (bits 4-3: 00 both bytes, 10 even bytes,
    /// 11 odd bytes); 0x1B3 0x40 = serial EEPROM (not emulated: treated
    /// as absent). 0x1B4 / 0x1B8: first and last SRAM byte address.
    sram_kind: u8,
    sram_eeprom: bool,
    sram_start: u32,
    sram_end: u32,
    /// 0x1F0: region letters (J, U, E or the newer hex digit).
    region: [3]u8,

    /// Bytes the header says the ROM has (end - start + 1, in u64 so a
    /// header claiming 00000000-FFFFFFFF reads 4 GB rather than wrapping),
    /// or null when the end lies before the start (review EM-03).
    pub fn declared_size(h: *const Header) ?u64 {
        if (h.rom_end < h.rom_start) return null;
        return @as(u64, h.rom_end) - h.rom_start + 1;
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
    h.sram_kind = read8(src, 0x1B2);
    h.sram_eeprom = read8(src, 0x1B3) == 0x40;
    h.sram_start = read32(src, 0x1B4);
    h.sram_end = read32(src, 0x1B8);
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

// ---- Cartridge SRAM (SPEC.md section 11) ----

/// Largest SRAM kept (in RAM, not saved). The RAM cart keeps 8 KB of
/// address space (its streamed sound needed the other 8 KB, PLAN.md "Sound
/// on the new firmware (2026-10-04)"): an odd-byte SRAM declared over 16 KB
/// shows its first 4 KB there. The party cart keeps 4 KB (its lobby and
/// lockstep need the rest; multiplayer games rarely have SRAM).
pub const sram_max: u32 = if (@import("build_options").party) 4 * 1024 else if (@import("tunables.zig").tight_ram) 8 * 1024 else 16 * 1024;

/// Where the 68000 sees the cartridge SRAM: `lo..hi` inclusive, bytes at
/// `sram[addr - lo]` (odd- or even-byte SRAM leaves every other byte of
/// the array unused, so 8 KB of odd bytes spans the whole 16 KB). An empty
/// map has `lo` > `hi`, so the bus's one compare rejects everything.
pub const SramMap = struct {
    lo: u32 = 0xFFFF_FFFF,
    hi: u32 = 0,

    pub fn present(m: SramMap) bool {
        return m.lo <= m.hi;
    }
};

/// The SRAM range the header declares, clipped to `sram_max` bytes, or an
/// empty map (none declared, EEPROM, reversed or outside 200000-3FFFFF).
pub fn sram_map(h: *const Header) SramMap {
    if (!h.has_sram or h.sram_eeprom) return .{};
    const lo = h.sram_start & 0xFFFFFE;
    if (h.sram_end < h.sram_start or lo < 0x200000 or h.sram_end >= max_size) return .{};
    return .{ .lo = lo, .hi = @min(h.sram_end, lo + sram_max - 1) };
}

// ---- Load-time checks (SPEC.md section 11) ----

/// Why a ROM will not run. `ok` runs.
pub const Refusal = enum(u8) {
    ok,
    /// Under 512 bytes or no "SEGA" at 0x100.
    no_header,
    /// SMD format (512-byte copier header, 16 KB odd/even blocks).
    smd_interleaved,
    /// Over 4 MB, or an SSF2-style bank-switching mapper.
    mapper,
    /// Virtua Racing's SVP chip.
    svp,
    /// The header's ROM end address lies before its start.
    bad_range,

    /// The line the frontend prints.
    pub fn text(r: Refusal) []const u8 {
        return switch (r) {
            .ok => "ok",
            .no_header => "no SEGA header",
            .smd_interleaved => "SMD interleaved: convert to .bin",
            .mapper => "mapper or over 4 MB: unsupported",
            .svp => "SVP chip: unsupported",
            .bad_range => "bad header ROM range",
        };
    }
};

/// SMD layout: a 512-byte copier header (bytes 8-9 AA BB) before 16 KB
/// blocks, or a first 16 KB block that reads "SEGA" at 0x100 only once
/// de-interleaved (each block: the odd bytes, then the even bytes; so the
/// "SE" of 0x100 sits at 0x2080 and "GA"'s at 0x81 and 0x2081).
pub fn is_smd(src: *const RomSource) bool {
    if (src.size % 0x4000 == 512 and read8(src, 8) == 0xAA and read8(src, 9) == 0xBB) return true;
    if (src.size < 0x4000 or is_genesis(src)) return false;
    // De-interleaved byte i of a 16 KB block at `b`: even i from b + 0x2000
    // + i/2, odd i from b + i/2.
    const b: u32 = if (src.size % 0x4000 == 512) 512 else 0;
    if (b + 0x4000 > src.size) return false;
    return read8(src, b + 0x2000 + 0x80) == 'S' and read8(src, b + 0x80) == 'E' and
        read8(src, b + 0x2000 + 0x81) == 'G' and read8(src, b + 0x81) == 'A';
}

/// The load-time verdict. Header checks run first so an SMD file (whose
/// 0x100 is not "SEGA") says SMD, not "no header".
pub fn check(src: *const RomSource) Refusal {
    if (src.size >= header_end and is_smd(src)) return .smd_interleaved;
    if (!is_genesis(src)) return .no_header;
    const h = parse_header(src);
    const declared = h.declared_size() orelse return .bad_range;
    if (src.size > max_size or declared > max_size) return .mapper;
    if (std.mem.indexOf(u8, &h.system, "SSF") != null) return .mapper;
    if (read8(src, 0x1C8) == 'S' and read8(src, 0x1C9) == 'V') return .svp;
    var product: [14]u8 = undefined;
    copy(src, 0x180, &product);
    if (std.mem.indexOf(u8, &product, "MK-1229") != null) return .svp;
    return .ok;
}
