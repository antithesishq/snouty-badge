//! What is on the badge drive (SPEC.md section 11, docs/ROM_DRIVE.md
//! section 4): the root's `.lnx`/`.lyx` files, each checked once with
//! `core.cart.parse`, and the chosen one turned into a `core.Cart` over the
//! flash by pointer. Shaped after Snouty Genesis's drive.zig so the M2
//! picker (SPEC.md 18.6: list them, restart into the chosen one) only has
//! to show `Scan.candidates`. M0 runs the first playable one.
//!
//! A module root (`@import("drive")`) imported by romsrc.zig and by the
//! host tests (tests/drive_unit.zig): it sees only `core` and `romfs`, no
//! cart-api. The badge passes `romfs.Image.badge()` as `image`, the tests
//! a fixture image in memory (`romfs.Image.truncated_test`).
//!
//! The caller owns the cluster table (`romfs.max_clusters` u16, 5 KB) and
//! the `Source`: `scan` reuses the table for every file, `open` fills it
//! for the chosen one, and the returned Cart reads fragmented blocks
//! through `Source`, so both must outlive the Cart.
const core = @import("core");
const romfs = @import("romfs");
const cart = core.cart;

/// Files listed at most (the picker's rows); further matches are dropped.
pub const max_candidates = 8;

/// Extensions a Lynx ROM may have on the drive (case-insensitive).
pub const extensions = [_][]const u8{ "lnx", "lyx" };

/// One `.lnx`/`.lyx` file of the root directory.
pub const Candidate = struct {
    entry: romfs.Entry = .{},
    /// `core.cart.parse` of its first 64 bytes and size.
    layout: cart.Layout = .{},
    /// Set when the file's FAT chain could not be walked; `layout` is then
    /// meaningless and the file is not playable.
    map_err: ?romfs.Error = null,

    pub fn playable(c: *const Candidate) bool {
        return c.map_err == null and c.layout.verdict == .ok;
    }

    /// The name the file has on the drive.
    pub fn file_name(c: *const Candidate) []const u8 {
        return c.entry.slice();
    }

    /// Why the file cannot run ("ok" when it can).
    pub fn note(c: *const Candidate) []const u8 {
        if (c.map_err) |e| return @errorName(e);
        return c.layout.verdict.text();
    }
};

pub const Scan = struct {
    /// Only `candidates[0..count]` is set.
    candidates: [max_candidates]Candidate = undefined,
    count: u32 = 0,
    playable_count: u32 = 0,
    /// The volume did not open (no drive, bad geometry); `count` is 0.
    err: ?romfs.Error = null,

    /// Index of the first playable candidate, if any.
    pub fn first_playable(s: *const Scan) ?usize {
        for (s.candidates[0..s.count], 0..) |*c, i| {
            if (c.playable()) return i;
        }
        return null;
    }
};

/// List and check the root's Lynx files, in directory order.
pub fn scan(image: romfs.Image, clusters: []u16) Scan {
    // Field by field: a `.{}` default would put the zeroed candidates in
    // flash and copy them.
    var s: Scan = undefined;
    s.count = 0;
    s.playable_count = 0;
    s.err = null;
    const vol = romfs.Volume.open(image) catch |e| {
        s.err = e;
        return s;
    };
    var entries: [max_candidates]romfs.Entry = undefined;
    const n = vol.find(&extensions, &entries);
    for (entries[0..n], s.candidates[0..n]) |e, *c| {
        c.* = .{ .entry = e };
        const m = vol.map(e, clusters) catch |err| {
            c.map_err = err;
            continue;
        };
        c.layout = layout_of(&m);
        if (c.layout.verdict == .ok) s.playable_count += 1;
    }
    s.count = @intCast(n);
    return s;
}

/// `core.cart.parse` of a mapped file.
pub fn layout_of(m: *const romfs.Mapped) cart.Layout {
    var head: [cart.header_size]u8 = undefined;
    const k: u32 = @min(m.size, cart.header_size);
    for (head[0..k], 0..) |*b, i| b.* = m.read(@intCast(i));
    return cart.parse(head[0..k], m.size);
}

/// The chosen file behind a Cart: the mapping and where block 0 starts in
/// it. Serves the blocks that have no direct pointer.
pub const Source = struct {
    mapped: romfs.Mapped,
    data_offset: u32,

    fn read(ctx: *const anyopaque, offset: u32) u8 {
        const s: *const Source = @ptrCast(@alignCast(ctx));
        return s.mapped.read(s.data_offset + offset);
    }
};

/// Map a candidate from `scan` (fills `clusters` and `src`) and build its
/// Cart: a flash pointer for every whole block whose clusters are one run,
/// the per-cluster path through `src` for the rest.
pub fn open(image: romfs.Image, cand: *const Candidate, clusters: []u16, src: *Source) romfs.Error!core.Cart {
    const vol = try romfs.Volume.open(image);
    src.mapped = try vol.map(cand.entry, clusters);
    const l = &cand.layout;
    src.data_offset = l.data_offset;
    var c = core.Cart.empty(l);
    c.read_fallback = .{ .ctx = src, .func = &Source.read };
    var i: u32 = 0;
    while (i < cart.block_count and (i + 1) * c.block_size <= c.size) : (i += 1) {
        c.blocks[i] = src.mapped.chunk(l.data_offset + i * c.block_size, c.block_size);
    }
    return c;
}
