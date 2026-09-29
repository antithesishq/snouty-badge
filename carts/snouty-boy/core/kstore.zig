//! Keyframe page store (SPEC.md 19.3). Owner in M6: track C.
//!
//! A keyframe is the console as the four byte regions of
//! `Gb.state_regions` (packed `Small`, VRAM, WRAM, cart RAM). Each region is
//! cut into pages of `page_size` bytes; the last page of a region may be
//! short (a "tail page": `Small` is not a multiple of the page size, cart RAM
//! may be empty). A keyframe is stored as a table of page references:
//!
//! - equal to the same page of the newest stored keyframe: share it
//!   (reference count + 1, no copy);
//! - all zero: the shared zero page (`zero_ref`, costs no pool page);
//! - otherwise: a fresh pool page, copied.
//!
//! Keyframes form a ring of at most `max_keyframes`, oldest to newest. When
//! the pool runs out during `put` the oldest keyframes are evicted (their
//! pages released) until the new one fits, never below the newest stored one
//! plus the new one; if even that does not fit, `put` fails and leaves only
//! the previous keyframe. A pool of at least `pages_for(lens)` pages always
//! holds one keyframe, so `reset` + `put` cannot fail then.
//!
//! No allocator, no floats, fixed arrays, deterministic. Compare and copy go
//! word by word (`u32`, unaligned loads on the console side, which
//! Cortex-M33 allows for LDR/STR); pool pages are 4-byte aligned.
const std = @import("std");

/// Number of state regions (`Gb.state_regions`).
pub const region_count = 4;

/// Page reference meaning "the all-zero page".
pub const zero_ref: u16 = std.math.maxInt(u16);

/// Pages needed for regions of lengths `lens` (each region rounded up to
/// whole pages; empty regions take none). Comptime-callable.
pub fn pages_for(page_size: usize, lens: [region_count]usize) usize {
    var n: usize = 0;
    for (lens) |l| n += (l + page_size - 1) / page_size;
    return n;
}

pub const Error = error{
    /// Even with every older keyframe evicted, the pool cannot hold the
    /// previous keyframe and the new one together. The new keyframe is not
    /// stored; the previous one is kept (count 1).
    PoolFull,
};

/// `page_size`: bytes per page, a multiple of 4. `pool_pages`: pages of
/// storage. `max_keyframes`: ring capacity (at most 255, the reference
/// count is a u8). `max_pages`: page references per keyframe, at least
/// `pages_for(page_size, lens)` of the regions the store will see.
pub fn Store(
    comptime page_size: usize,
    comptime pool_pages: usize,
    comptime max_keyframes: usize,
    comptime max_pages: usize,
) type {
    if (page_size == 0 or page_size % 4 != 0) @compileError("page_size must be a positive multiple of 4");
    if (pool_pages == 0 or pool_pages >= zero_ref) @compileError("pool_pages out of range");
    if (max_keyframes < 2 or max_keyframes > 255) @compileError("max_keyframes must be 2..255");
    if (max_pages == 0) @compileError("max_pages must be positive");
    return struct {
        const Self = @This();

        pub const page_bytes = page_size;
        pub const capacity_pages = pool_pages;
        pub const capacity_keyframes = max_keyframes;
        pub const table_pages = max_pages;
        pub const Ref = u16;
        pub const Regions = [region_count][]u8;
        pub const ConstRegions = [region_count][]const u8;

        const Page = [page_size / 4]u32;

        /// Page storage, 4-byte aligned by type.
        pool: [pool_pages]Page = undefined,
        /// References to each pool page from keyframe tables (0 = free).
        refs: [pool_pages]u8 = @splat(0),
        /// Stack of free pool pages; `free[0..n_free]` are free.
        free: [pool_pages]Ref = undefined,
        n_free: usize = 0,
        /// Keyframe tables in a ring: slot `(head + max - age) % max` holds
        /// the keyframe of `age` (0 = newest).
        tables: [max_keyframes][max_pages]Ref = undefined,
        head: usize = 0,
        count: usize = 0,
        /// Pages per keyframe, fixed by the first `put` after `reset`.
        n_pages: usize = 0,

        // ---- Stats of the last `put` ----
        /// Pages copied into fresh pool pages.
        last_copied: usize = 0,
        /// Pages shared with the previous keyframe.
        last_shared: usize = 0,
        /// Pages that were all zero.
        last_zero: usize = 0,
        /// Keyframes evicted to make room.
        last_evicted: usize = 0,

        /// Empty store with every pool page free. Call once before use (a
        /// `var s: Store = .{}` must be `reset` too; `undefined` + `reset`
        /// is fine and avoids a large struct literal).
        pub fn reset(s: *Self) void {
            s.n_free = pool_pages;
            for (&s.free, 0..) |*f, i| f.* = @intCast(pool_pages - 1 - i);
            @memset(&s.refs, 0);
            s.head = 0;
            s.count = 0;
            s.n_pages = 0;
            s.last_copied = 0;
            s.last_shared = 0;
            s.last_zero = 0;
            s.last_evicted = 0;
        }

        pub fn pages_in_use(s: *const Self) usize {
            return pool_pages - s.n_free;
        }

        pub fn bytes_in_use(s: *const Self) usize {
            return s.pages_in_use() * page_size;
        }

        fn slot_of_age(s: *const Self, age: usize) usize {
            std.debug.assert(age < s.count);
            return (s.head + max_keyframes - age) % max_keyframes;
        }

        fn release(s: *Self, r: Ref) void {
            if (r == zero_ref) return;
            std.debug.assert(s.refs[r] > 0);
            s.refs[r] -= 1;
            if (s.refs[r] == 0) {
                s.free[s.n_free] = r;
                s.n_free += 1;
            }
        }

        fn release_table(s: *Self, t: []const Ref) void {
            for (t) |r| s.release(r);
        }

        /// Drop the `n` oldest keyframes (at most `count`).
        pub fn drop_oldest(s: *Self, n: usize) void {
            var k = @min(n, s.count);
            while (k > 0) : (k -= 1) {
                s.release_table(s.tables[s.slot_of_age(s.count - 1)][0..s.n_pages]);
                s.count -= 1;
            }
        }

        /// Drop the `n` newest keyframes (at most `count`): truncation after
        /// resuming from a scrubbed position.
        pub fn drop_newest(s: *Self, n: usize) void {
            var k = @min(n, s.count);
            while (k > 0) : (k -= 1) {
                s.release_table(s.tables[s.head][0..s.n_pages]);
                s.head = (s.head + max_keyframes - 1) % max_keyframes;
                s.count -= 1;
            }
        }

        /// Store the regions as the new newest keyframe. Evicts the oldest
        /// keyframes as needed (see the file comment); `last_*` report what
        /// it cost. The region lengths must be the same on every `put`
        /// between two `reset`s.
        pub fn put(s: *Self, regions: ConstRegions) Error!void {
            var lens: [region_count]usize = undefined;
            for (regions, &lens) |r, *l| l.* = r.len;
            const n = pages_for(page_size, lens);
            std.debug.assert(n <= max_pages);
            if (s.count == 0) s.n_pages = n;
            std.debug.assert(n == s.n_pages);

            s.last_copied = 0;
            s.last_shared = 0;
            s.last_zero = 0;
            s.last_evicted = 0;
            if (s.count == max_keyframes) {
                s.drop_oldest(1);
                s.last_evicted = 1;
            }
            const slot = (s.head + 1) % max_keyframes;
            const prev: ?[]const Ref = if (s.count > 0) s.tables[s.head][0..n] else null;
            const t = &s.tables[slot];

            var i: usize = 0;
            for (regions) |region| {
                var off: usize = 0;
                while (off < region.len) : (off += page_size) {
                    const src = region[off..@min(off + page_size, region.len)];
                    const p: Ref = if (prev) |pt| pt[i] else zero_ref;
                    if (p == zero_ref) {
                        if (is_zero(src)) {
                            t[i] = zero_ref;
                            s.last_zero += 1;
                            i += 1;
                            continue;
                        }
                    } else if (eql(&s.pool[p], src)) {
                        s.refs[p] += 1;
                        t[i] = p;
                        s.last_shared += 1;
                        i += 1;
                        continue;
                    } else if (is_zero(src)) {
                        t[i] = zero_ref;
                        s.last_zero += 1;
                        i += 1;
                        continue;
                    }
                    // A fresh page, evicting the oldest keyframes (never the
                    // previous one) until one is free.
                    while (s.n_free == 0 and s.count > 1) {
                        s.drop_oldest(1);
                        s.last_evicted += 1;
                    }
                    if (s.n_free == 0) {
                        s.release_table(t[0..i]);
                        return error.PoolFull;
                    }
                    s.n_free -= 1;
                    const f = s.free[s.n_free];
                    s.refs[f] = 1;
                    copy_in(&s.pool[f], src);
                    t[i] = f;
                    s.last_copied += 1;
                    i += 1;
                }
            }
            std.debug.assert(i == n);
            s.head = slot;
            s.count += 1;
        }

        /// Copy keyframe `age` (0 = newest) into the regions, which must have
        /// the lengths the keyframes were `put` with.
        pub fn get(s: *const Self, age: usize, regions: Regions) void {
            const t = s.tables[s.slot_of_age(age)][0..s.n_pages];
            var i: usize = 0;
            for (regions) |region| {
                var off: usize = 0;
                while (off < region.len) : (off += page_size) {
                    const dst = region[off..@min(off + page_size, region.len)];
                    const r = t[i];
                    if (r == zero_ref) @memset(dst, 0) else copy_out(dst, &s.pool[r]);
                    i += 1;
                }
            }
            std.debug.assert(i == s.n_pages);
        }

        /// True if the regions equal keyframe `age` byte for byte (the
        /// in-cart replay self check).
        pub fn matches(s: *const Self, age: usize, regions: ConstRegions) bool {
            const t = s.tables[s.slot_of_age(age)][0..s.n_pages];
            var i: usize = 0;
            for (regions) |region| {
                var off: usize = 0;
                while (off < region.len) : (off += page_size) {
                    const src = region[off..@min(off + page_size, region.len)];
                    const r = t[i];
                    if (!(if (r == zero_ref) is_zero(src) else eql(&s.pool[r], src))) return false;
                    i += 1;
                }
            }
            return i == s.n_pages;
        }

        /// Pool pages referenced by keyframe `age` that it owns alone
        /// (reference count 1): what dropping it would free.
        pub fn pages_owned(s: *const Self, age: usize) usize {
            var c: usize = 0;
            for (s.tables[s.slot_of_age(age)][0..s.n_pages]) |r| {
                if (r != zero_ref and s.refs[r] == 1) c += 1;
            }
            return c;
        }

        /// Recount every reference from the tables and check it against
        /// `refs` and the free list (host tests: nothing leaks).
        pub fn check(s: *const Self) bool {
            var counted: [pool_pages]u16 = @splat(0);
            for (0..s.count) |a| {
                for (s.tables[s.slot_of_age(a)][0..s.n_pages]) |r| {
                    if (r == zero_ref) continue;
                    if (r >= pool_pages) return false;
                    counted[r] += 1;
                }
            }
            var used: usize = 0;
            for (counted, s.refs) |c, r| {
                if (c != r) return false;
                if (c != 0) used += 1;
            }
            if (used != s.pages_in_use()) return false;
            var seen: [pool_pages]bool = @splat(false);
            for (s.free[0..s.n_free]) |f| {
                if (s.refs[f] != 0 or seen[f]) return false;
                seen[f] = true;
            }
            return true;
        }

        // ---- Word-wise page helpers ----

        fn is_zero(src: []const u8) bool {
            const w = src.len / 4;
            const words: [*]align(1) const u32 = @ptrCast(src.ptr);
            var acc: u32 = 0;
            var k: usize = 0;
            // Four words per iteration, one branch per 16 bytes.
            while (k + 4 <= w) : (k += 4) {
                acc |= words[k] | words[k + 1] | words[k + 2] | words[k + 3];
                if (acc != 0) return false;
            }
            while (k < w) : (k += 1) acc |= words[k];
            for (src[w * 4 ..]) |b| acc |= b;
            return acc == 0;
        }

        fn eql(page: *const Page, src: []const u8) bool {
            const w = src.len / 4;
            const words: [*]align(1) const u32 = @ptrCast(src.ptr);
            var k: usize = 0;
            while (k + 4 <= w) : (k += 4) {
                const d = (page[k] ^ words[k]) | (page[k + 1] ^ words[k + 1]) |
                    (page[k + 2] ^ words[k + 2]) | (page[k + 3] ^ words[k + 3]);
                if (d != 0) return false;
            }
            while (k < w) : (k += 1) if (page[k] != words[k]) return false;
            const pb: *const [page_size]u8 = @ptrCast(page);
            return std.mem.eql(u8, pb[w * 4 .. src.len], src[w * 4 ..]);
        }

        fn copy_in(page: *Page, src: []const u8) void {
            const w = src.len / 4;
            const words: [*]align(1) const u32 = @ptrCast(src.ptr);
            for (page[0..w], words[0..w]) |*d, v| d.* = v;
            const pb: *[page_size]u8 = @ptrCast(page);
            @memcpy(pb[w * 4 .. src.len], src[w * 4 ..]);
            // Bytes past a tail page's end are never read; zero them anyway
            // so the pool is deterministic.
            @memset(pb[src.len..], 0);
        }

        fn copy_out(dst: []u8, page: *const Page) void {
            const w = dst.len / 4;
            const words: [*]align(1) u32 = @ptrCast(dst.ptr);
            for (words[0..w], page[0..w]) |*d, v| d.* = v;
            const pb: *const [page_size]u8 = @ptrCast(page);
            @memcpy(dst[w * 4 ..], pb[w * 4 .. dst.len]);
        }
    };
}
