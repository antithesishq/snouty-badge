//! FAT12 reader for the badge's USB drive (the OS `romfs` flash region), so a
//! cart can find a ROM file the user copied onto the drive and read it in
//! place by pointer. Design: docs/ROM_DRIVE.md; interface frozen in
//! carts/snouty-gear/PLAN.md ("Frozen for M0: lib/romfs.zig").
//!
//! The volume is the super-floppy the OS formats
//! (sycl-badge/src/os/loader/storage.zig): boot sector at sector 0, 512-byte
//! sectors, 1 sector per cluster, 32 root entries, "FAT12   ". The reader is
//! read-only over a `[*]const u8` base: the badge passes `base_addr` (the XIP
//! flash window), host tests pass an image in memory. It only touches the
//! boot sector, the root directory, the FAT entries of the chains it walks
//! and the data sectors it is asked for, so truncated test images work. No
//! allocator, no floats, nothing heavy at comptime.
const std = @import("std");

/// Flash address of the romfs region (sycl-badge/src/os/linker.ld, pinned
/// commit). Rechecked whenever the sycl-badge submodule is bumped.
pub const base_addr: usize = 0x10080000;
/// Size of the romfs region in bytes (1280 KB).
pub const size: usize = 1280 * 1024;
/// Bytes per sector, and per cluster (1 sector per cluster).
pub const sector_size: usize = 512;
/// Upper bound on the clusters of any file on the volume; a caller's cluster
/// table of this many `u16` (5 KB) maps every file that fits the drive. A
/// file needs ceil(file size / 512) entries (a 512 KB ROM: 1024).
pub const max_clusters: usize = size / sector_size;

/// NoVolume: no 0xAA55 boot sector signature (erased flash, zeros).
/// BadGeometry: a boot sector, but not the OS geometry (bytes per sector,
/// sectors per cluster, root entries, FAT type string, sizes out of range).
/// BadChain: the FAT chain is shorter than the file, loops, or names a free,
/// reserved, bad or out-of-range cluster. TooManyClusters: the caller's
/// cluster table is shorter than the file's cluster count.
pub const Error = error{ NoVolume, BadGeometry, BadChain, TooManyClusters };

/// A file found by `Volume.find`.
pub const Entry = struct {
    /// The long name if the host wrote one, else the 8.3 name as `NAME.EXT`;
    /// ASCII (other UCS-2 characters become '?'), cut at 64 bytes.
    name: [64]u8 = undefined,
    /// Valid bytes in `name`.
    name_len: u8 = 0,
    /// File size in bytes (directory entry).
    size: u32 = 0,
    /// First data cluster (2..), 0 for an empty file.
    first_cluster: u16 = 0,

    /// The name as a slice.
    pub fn slice(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }
};

const dir_entry_size = 32;
const attr_lfn: u8 = 0x0F;
const attr_volume: u8 = 0x08;
const attr_dir: u8 = 0x10;
const entry_deleted: u8 = 0xE5;
const chain_end: u16 = 0xFF8; // FAT12 end of chain is 0xFF8..0xFFF
const lfn_max_chars = 255;
const ss: u32 = sector_size;

fn rd16(p: [*]const u8, off: usize) u16 {
    return @as(u16, p[off]) | (@as(u16, p[off + 1]) << 8);
}

fn rd32(p: [*]const u8, off: usize) u32 {
    return @as(u32, rd16(p, off)) | (@as(u32, rd16(p, off + 2)) << 16);
}

/// Layout derived from the boot sector (sector numbers from the volume start).
const Geometry = struct {
    fat_start: u32,
    root_start: u32,
    root_entries: u32,
    data_start: u32,
    /// Data clusters on the volume; valid cluster numbers are 2..clusters+1.
    clusters: u32,
};

fn geometry(base: [*]const u8) Error!Geometry {
    if (rd16(base, 510) != 0xAA55) return error.NoVolume;
    if (rd16(base, 11) != sector_size) return error.BadGeometry;
    if (base[13] != 1) return error.BadGeometry;
    const reserved: u32 = rd16(base, 14);
    const fats: u32 = base[16];
    const root_entries: u32 = rd16(base, 17);
    var total: u32 = rd16(base, 19);
    if (total == 0) total = rd32(base, 32);
    const fat_sectors: u32 = rd16(base, 22);
    if (root_entries != 32) return error.BadGeometry;
    if (!std.mem.eql(u8, base[54..62], "FAT12   ")) return error.BadGeometry;
    if (reserved == 0 or fats == 0 or fat_sectors == 0) return error.BadGeometry;
    const root_start = reserved + fats * fat_sectors;
    const root_sectors = (root_entries * dir_entry_size + ss - 1) / ss;
    const data_start = root_start + root_sectors;
    if (total <= data_start or total > 0xFFFF) return error.BadGeometry;
    var clusters = total - data_start;
    // The FAT must be able to hold every cluster entry; FAT12 tops out at 4084.
    const fat_capacity = fat_sectors * ss * 2 / 3;
    if (clusters + 2 > fat_capacity) clusters = fat_capacity - 2;
    if (clusters > 4084) return error.BadGeometry;
    return .{
        .fat_start = reserved,
        .root_start = root_start,
        .root_entries = root_entries,
        .data_start = data_start,
        .clusters = clusters,
    };
}

/// The standard 8.3 name checksum stored in each LFN entry.
fn sfn_checksum(sfn: [*]const u8) u8 {
    var sum: u8 = 0;
    for (0..11) |i| sum = ((sum & 1) << 7) +% (sum >> 1) +% sfn[i];
    return sum;
}

/// Byte offsets of the 13 UCS-2 characters inside an LFN entry.
const lfn_offsets = [13]u8{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };

fn ascii_lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// True when `name`'s extension (after the last '.') equals one of `exts`,
/// ignoring case.
fn ext_matches(name: []const u8, exts: []const []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot + 1 ..];
    for (exts) |want| {
        if (want.len != ext.len) continue;
        var same = true;
        for (want, ext) |a, b| {
            if (ascii_lower(a) != ascii_lower(b)) same = false;
        }
        if (same) return true;
    }
    return false;
}

/// An open FAT12 volume. Holds only the base pointer; the geometry is read
/// again from the boot sector (a few loads) by each call.
pub const Volume = struct {
    /// Start of the volume (boot sector): `base_addr` on the badge.
    base: [*]const u8,

    /// Checks the boot sector: signature 0xAA55 (else NoVolume), 512-byte
    /// sectors, 1 sector per cluster, 32 root entries, "FAT12   " and sane
    /// sizes (else BadGeometry). FAT, root directory and data positions come
    /// from the boot sector fields, so any FAT size the OS computes works.
    pub fn open(base: [*]const u8) Error!Volume {
        _ = try geometry(base);
        return .{ .base = base };
    }

    /// Scans the root directory in order for files whose extension (after
    /// the last '.', compared case-insensitively, given without the dot) is
    /// one of `exts`, and fills `out` with them. The name matched and
    /// reported is the long name when LFN entries with the right checksum
    /// directly precede the 8.3 entry, else the 8.3 name as `NAME.EXT`
    /// (lower-cased where the Windows NT case bits say so). Skips deleted
    /// entries, directories, the volume label, LFN entries without their 8.3
    /// entry and macOS AppleDouble files (names starting with "._"); stops at
    /// the end-of-directory marker. Returns the number of entries written,
    /// at most `out.len` (further matches are dropped).
    pub fn find(self: *const Volume, exts: []const []const u8, out: []Entry) usize {
        const g = geometry(self.base) catch return 0;
        const root = self.base + g.root_start * sector_size;
        var count: usize = 0;
        // LFN assembly: characters by position, the sequence still expected
        // next (counting down to 1) and the checksum of the group.
        var lfn: [lfn_max_chars + 1]u8 = undefined;
        var lfn_len: usize = 0;
        var lfn_next: u8 = 0; // 0: no LFN group in progress
        var lfn_sum: u8 = 0;
        var lfn_ok = false;
        var i: u32 = 0;
        while (i < g.root_entries and count < out.len) : (i += 1) {
            const e = root + i * dir_entry_size;
            if (e[0] == 0x00) break;
            const attr = e[11];
            if (e[0] == entry_deleted) {
                lfn_next = 0;
                lfn_ok = false;
                continue;
            }
            if (attr & 0x3F == attr_lfn) {
                const seq = e[0] & 0x1F;
                if (e[0] & 0x40 != 0) {
                    // Last (first on disk) entry of a group: sets the length.
                    lfn_sum = e[13];
                    lfn_len = 0;
                    lfn_ok = seq != 0 and @as(usize, seq) * 13 <= lfn_max_chars + 13;
                    lfn_next = seq;
                    if (lfn_ok) lfn_len = @as(usize, seq) * 13; // trimmed at the 0 below
                } else if (seq == 0 or seq != lfn_next or e[13] != lfn_sum) {
                    lfn_ok = false;
                }
                if (lfn_ok and seq == lfn_next) {
                    const at = (@as(usize, seq) - 1) * 13;
                    for (lfn_offsets, 0..) |off, k| {
                        const c = rd16(e, off);
                        const pos = at + k;
                        if (c == 0x0000 or c == 0xFFFF) {
                            if (pos < lfn_len) lfn_len = pos;
                            break;
                        }
                        if (pos < lfn.len) lfn[pos] = if (c < 0x80) @intCast(c) else '?';
                    }
                    lfn_next = seq - 1;
                } else {
                    lfn_ok = false;
                }
                continue;
            }
            const use_lfn = lfn_ok and lfn_next == 0 and lfn_len > 0 and lfn_sum == sfn_checksum(e);
            lfn_ok = false;
            lfn_next = 0;
            if (attr & (attr_volume | attr_dir) != 0) continue;

            var short: [12]u8 = undefined;
            var name: []const u8 = undefined;
            if (use_lfn) {
                name = lfn[0..@min(lfn_len, lfn.len)];
            } else {
                var n: usize = 0;
                const lower_base = e[12] & 0x08 != 0;
                const lower_ext = e[12] & 0x10 != 0;
                for (0..8) |k| {
                    var c = e[k];
                    if (c == ' ') break;
                    if (k == 0 and c == 0x05) c = 0xE5;
                    short[n] = if (lower_base) ascii_lower(c) else c;
                    n += 1;
                }
                if (e[8] != ' ') {
                    short[n] = '.';
                    n += 1;
                    for (8..11) |k| {
                        if (e[k] == ' ') break;
                        short[n] = if (lower_ext) ascii_lower(e[k]) else e[k];
                        n += 1;
                    }
                }
                name = short[0..n];
            }
            if (name.len >= 2 and name[0] == '.' and name[1] == '_') continue;
            if (!ext_matches(name, exts)) continue;
            const o = &out[count];
            const keep = @min(name.len, o.name.len);
            @memcpy(o.name[0..keep], name[0..keep]);
            o.name_len = @intCast(keep);
            o.size = rd32(e, 28);
            o.first_cluster = rd16(e, 26);
            count += 1;
        }
        return count;
    }

    /// Walks the FAT chain of `e` into `clusters` (ceil(e.size / 512)
    /// entries are needed; TooManyClusters when the slice is shorter) and
    /// returns the mapping. BadChain when the chain ends early, loops or
    /// names a cluster that is free, reserved, bad (0xFF7) or beyond the
    /// volume. Links past the file's last cluster are not read. An empty
    /// file maps to zero clusters.
    pub fn map(self: *const Volume, e: Entry, clusters: []u16) Error!Mapped {
        const g = try geometry(self.base);
        const need: u32 = e.size / ss + @intFromBool(e.size % ss != 0);
        if (need > clusters.len) return error.TooManyClusters;
        if (need > g.clusters) return error.BadChain;
        const fat = self.base + g.fat_start * sector_size;
        var seen = std.mem.zeroes([max_clusters / 8 + 1]u8);
        const last_valid: u32 = g.clusters + 1;
        var c: u32 = e.first_cluster;
        var n: u32 = 0;
        while (n < need) : (n += 1) {
            if (c < 2 or c > last_valid) return error.BadChain;
            if (c < seen.len * 8) {
                const bit = @as(u8, 1) << @intCast(c & 7);
                if (seen[c >> 3] & bit != 0) return error.BadChain;
                seen[c >> 3] |= bit;
            }
            clusters[n] = @intCast(c);
            if (n + 1 == need) break;
            // FAT12: entry c at byte offset c * 1.5, 12 bits.
            const off = c + c / 2;
            const v = rd16(fat, off);
            c = if (c & 1 != 0) v >> 4 else v & 0x0FFF;
            if (c >= chain_end) return error.BadChain; // ends before the file does
        }
        return .{
            .size = e.size,
            .clusters = clusters[0..need],
            .data_base = self.base + g.data_start * sector_size,
        };
    }
};

/// A mapped file: its size and cluster list over the volume's data area.
pub const Mapped = struct {
    /// File size in bytes.
    size: u32,
    /// Cluster numbers in file order, ceil(size / 512) of them.
    clusters: []const u16,
    /// Address of cluster 2 (the first data sector).
    data_base: [*]const u8,

    fn cluster_ptr(self: *const Mapped, index: usize) [*]const u8 {
        return self.data_base + (@as(usize, self.clusters[index]) - 2) * sector_size;
    }

    /// Pointer to the whole file when its clusters form one run (always the
    /// case for a file copied onto a freshly wiped drive), else null. Null
    /// for an empty file.
    pub fn contiguous(self: *const Mapped) ?[*]const u8 {
        return self.chunk(0, self.size);
    }

    /// Pointer to bytes offset..offset+len of the file when that range lies
    /// inside the file and the clusters covering it are consecutive on the
    /// volume, else null (also for len 0). A 16 KB bank needs 32 clusters in
    /// a row.
    pub fn chunk(self: *const Mapped, offset: u32, len: u32) ?[*]const u8 {
        if (len == 0 or offset >= self.size or len > self.size - offset) return null;
        const first = offset / ss;
        const last = (offset + len - 1) / ss;
        var i = first;
        while (i < last) : (i += 1) {
            if (self.clusters[i + 1] != self.clusters[i] + 1) return null;
        }
        return self.cluster_ptr(first) + offset % ss;
    }

    /// The file byte at `offset` through the cluster table (one shift and
    /// load more than a direct pointer); 0xFF past the end of the file.
    pub fn read(self: *const Mapped, offset: u32) u8 {
        if (offset >= self.size) return 0xFF;
        return self.cluster_ptr(offset / ss)[offset % ss];
    }

    /// CRC-32 (IEEE 802.3, the same as Python's zlib.crc32) of the whole
    /// file, taken run by run over the mapped sectors (`Crc` in one go).
    pub fn crc32(self: *const Mapped) u32 {
        var c = Crc.init();
        while (!c.step(self, std.math.maxInt(u32))) {}
        return c.final();
    }

    /// `crc32` spread over several calls, so a cart can hash a large file a
    /// slice per frame: `init`, then `step(m, bytes)` until it returns true,
    /// then `final`. Each step hashes the next `bytes` of the file (fewer at
    /// the end), run by run over consecutive clusters.
    pub const Crc = struct {
        h: std.hash.Crc32,
        /// File bytes hashed so far.
        at: u32,

        pub fn init() Crc {
            return .{ .h = std.hash.Crc32.init(), .at = 0 };
        }

        /// Hash up to `bytes` more of `m`; true when the whole file is in.
        pub fn step(c: *Crc, m: *const Mapped, bytes: u32) bool {
            var budget: u32 = bytes;
            while (c.at < m.size and budget > 0) {
                const i: usize = c.at / ss;
                const off: u32 = c.at % ss;
                const want: u32 = @min(budget, m.size - c.at);
                // Extend a run of consecutive clusters while it is short of
                // `want`, then hash it in one go.
                var j = i + 1;
                var run: u32 = ss - off;
                while (run < want and j < m.clusters.len and m.clusters[j] == m.clusters[j - 1] + 1) : (j += 1) run += ss;
                const take = @min(run, want);
                c.h.update(m.cluster_ptr(i)[off..][0..take]);
                c.at += take;
                budget -= take;
            }
            return c.at >= m.size;
        }

        pub fn final(c: *const Crc) u32 {
            return c.h.final();
        }
    };
};
