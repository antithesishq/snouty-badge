//! ROM bank table: the only view of the cartridge the core ever gets.
//! SPEC.md section 7. The core reads ROM through 16 KB bank pointers; where
//! the bytes live (embedded in the cart image, a file on the badge drive,
//! the section 13.1 packed banks) is the frontend's business, so this file
//! has no romfs, cart-api or allocator import.
//!
//! A bank whose pointer is null is served byte by byte through
//! `read_fallback` (the frontend's romfs per-cluster path for a fragmented
//! drive file), or, for a `from_slice` ROM, from the slice itself (a partial
//! last bank). Reads at or beyond `size` return 0xFF (open bus).
const std = @import("std");

pub const bank_size: u32 = 0x4000;
/// 32 x 16 KB = 512 KB, the largest Game Gear cartridge.
pub const max_banks = 32;

/// Per-byte reader for banks that have no direct pointer. `ctx` is owned by
/// the frontend and must outlive the Rom.
pub const ReadFallback = struct {
    ctx: *const anyopaque,
    func: *const fn (ctx: *const anyopaque, offset: u32) u8,
};

pub const Rom = struct {
    /// Bank i covers ROM bytes [i * 16 KB, (i + 1) * 16 KB). Null: read it
    /// with `read` (fallback or slice), never by pointer.
    banks: [max_banks]?[*]const u8 = @splat(null),
    /// ROM size in bytes (capped at 512 KB).
    size: u32 = 0,
    /// ceil(size / 16 KB).
    bank_count: u8 = 0,
    /// Serves null banks when the ROM came from somewhere other than a slice.
    read_fallback: ?ReadFallback = null,
    /// The backing slice of a `from_slice` ROM (empty otherwise), for a
    /// trailing partial bank.
    slice: []const u8 = &.{},

    /// A ROM held in memory (the embedded fallback, host tests). Every full
    /// 16 KB bank gets a pointer into `data`; a partial last bank stays
    /// null and is read through the bounds-checked slice path.
    pub fn from_slice(data: []const u8) Rom {
        const len: u32 = @intCast(@min(data.len, max_banks * bank_size));
        var r: Rom = .{ .size = len, .bank_count = bank_count_for(len), .slice = data[0..len] };
        var i: u32 = 0;
        while ((i + 1) * bank_size <= len) : (i += 1) r.banks[i] = data.ptr + i * bank_size;
        return r;
    }

    /// Bank count for a ROM of `len` bytes (rounded up, capped at 32).
    pub fn bank_count_for(len: u32) u8 {
        return @intCast(@min(max_banks, (len + bank_size - 1) / bank_size));
    }

    /// One ROM byte by absolute offset. The slow, general path; the mapper
    /// reads through `banks` directly when the pointer is there.
    pub fn read(r: *const Rom, offset: u32) u8 {
        if (offset >= r.size) return 0xFF;
        const b = offset / bank_size;
        if (r.banks[b]) |p| return p[offset % bank_size];
        if (offset < r.slice.len) return r.slice[offset];
        if (r.read_fallback) |f| return f.func(f.ctx, offset);
        return 0xFF;
    }

    /// A mapper bank number wrapped to the ROM's bank count, as the
    /// mirrored ROM chip decodes it: a mask for power-of-two counts, a
    /// modulo otherwise (48 KB, odd dumps). Always below `max_banks`; 0 for
    /// an empty ROM. Called on mapper writes, never per memory access.
    pub fn wrap_bank(r: *const Rom, bank: u8) u8 {
        const n: u8 = r.bank_count;
        if (n == 0) return 0;
        if (n & (n - 1) == 0) return bank & (n - 1);
        return bank % n;
    }

    /// True when every bank has a direct pointer (no per-byte fallback).
    pub fn all_direct(r: *const Rom) bool {
        for (r.banks[0..r.bank_count]) |b| if (b == null) return false;
        return true;
    }
};
