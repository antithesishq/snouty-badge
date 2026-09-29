//! FAT12 reader for the badge's USB drive (the OS `romfs` flash region), so a
//! cart can find a ROM file the user copied onto the drive and read it in place
//! by pointer. Design: docs/ROM_DRIVE.md. This is the M0 stub that only knows
//! the interface (carts/snouty-gear/PLAN.md, "Frozen: lib/romfs.zig"); the
//! real reader replaces it.
const std = @import("std");

/// Flash address of the romfs region (sycl-badge/src/os/linker.ld, pinned commit).
pub const base_addr: usize = 0x10080000;
pub const size: usize = 1280 * 1024;
pub const sector_size: usize = 512;
/// Upper bound on data clusters (1 sector per cluster), sizes the caller's table.
pub const max_clusters: usize = size / sector_size;

pub const Error = error{ NoVolume, BadGeometry, BadChain, TooManyClusters };

pub const Entry = struct {
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    size: u32 = 0,
    first_cluster: u16 = 0,

    pub fn slice(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Volume = struct {
    base: [*]const u8,

    pub fn open(base: [*]const u8) Error!Volume {
        _ = base;
        return error.NoVolume;
    }

    pub fn find(self: *const Volume, exts: []const []const u8, out: []Entry) usize {
        _ = self;
        _ = exts;
        _ = out;
        return 0;
    }

    pub fn map(self: *const Volume, e: Entry, clusters: []u16) Error!Mapped {
        _ = self;
        _ = e;
        _ = clusters;
        return error.BadChain;
    }
};

pub const Mapped = struct {
    size: u32,
    clusters: []const u16,
    data_base: [*]const u8,

    pub fn contiguous(self: *const Mapped) ?[*]const u8 {
        return self.chunk(0, self.size);
    }

    pub fn chunk(self: *const Mapped, offset: u32, len: u32) ?[*]const u8 {
        _ = self;
        _ = offset;
        _ = len;
        return null;
    }

    pub fn read(self: *const Mapped, offset: u32) u8 {
        _ = self;
        _ = offset;
        return 0xFF;
    }

    pub fn crc32(self: *const Mapped) u32 {
        _ = self;
        return 0;
    }
};

test "stub opens nothing" {
    const zeros = std.mem.zeroes([512]u8);
    try std.testing.expectError(error.NoVolume, Volume.open(&zeros));
}
