//! What is on the badge drive (SPEC.md section 11, PLAN.md M2 Track B):
//! the root's `.gen`/`.md`/`.bin` files, each checked once with
//! `core.rom.check`, as the picker and the help screen list them. A module
//! root (`@import("drive")`), imported by the cart's romsrc.zig and by the
//! host tests (tests/drive_unit.zig), so it sees only `core` and `romfs`
//! (the build also offers `rom`): no cart-api, no clock, nothing badge
//! specific. The badge passes `romfs.Image.badge()` as `image`, the tests
//! a fixture image in memory (`romfs.Image.truncated_test`).
//!
//! The caller owns the cluster table (`romfs.max_clusters` u16, 5 KB):
//! `scan` reuses it for every file, `open` fills it for the chosen one and
//! the returned `Mapped` (and any `RomSource` built from it) reads through
//! it, so it must outlive both.
const core = @import("core");
const romfs = @import("romfs");

/// Files listed at most (the picker's rows); further matches are dropped.
pub const max_candidates = 8;

/// Extensions a Genesis ROM may have on the drive (case-insensitive).
pub const extensions = [_][]const u8{ "gen", "md", "bin" };

/// Bytes kept of a header name (the header field's width).
pub const name_max = 48;

/// One `.gen`/`.md`/`.bin` file of the root directory.
pub const Candidate = struct {
    entry: romfs.Entry = .{},
    /// `core.rom.check`'s verdict (`.no_header` for a file with no "SEGA"
    /// header at all: listed, dimmed, never run).
    verdict: core.rom.Refusal = .no_header,
    /// Set when the file's FAT chain could not be walked; `verdict` is then
    /// meaningless and the file is not playable.
    map_err: ?romfs.Error = null,
    /// The header's domestic name, else its overseas name, trimmed and
    /// with runs of spaces collapsed; empty when refused.
    name_buf: [name_max]u8 = undefined,
    name_len: u8 = 0,
    /// File size in bytes (the directory entry's).
    size: u32 = 0,

    pub fn playable(c: *const Candidate) bool {
        return c.map_err == null and c.verdict == .ok;
    }

    /// The header name (may be empty).
    pub fn name(c: *const Candidate) []const u8 {
        return c.name_buf[0..c.name_len];
    }

    /// The name the file has on the drive.
    pub fn file_name(c: *const Candidate) []const u8 {
        return c.entry.slice();
    }

    /// One line about the file: the header name when playable, else why not.
    pub fn note(c: *const Candidate) []const u8 {
        if (c.map_err) |e| return @errorName(e);
        if (c.verdict == .ok) return c.name();
        return c.verdict.text();
    }
};

/// The result of `scan`.
pub const Scan = struct {
    /// Only `candidates[0..count]` is set.
    candidates: [max_candidates]Candidate = undefined,
    /// Valid entries in `candidates`.
    count: u32 = 0,
    /// Of those, how many `playable()`.
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

/// List and check the volume's root ROM files, in directory order. Each
/// file is mapped once through `clusters` (left holding the last file's
/// chain: `open` the chosen one again).
pub fn scan(image: romfs.Image, clusters: []u16) Scan {
    // Field by field: a `.{}` default would put 1 KB of zeroed candidates
    // in flash and copy it.
    var s: Scan = undefined;
    s.count = 0;
    s.playable_count = 0;
    s.err = add(&s, image, 0, clusters);
    return s;
}

/// Append another drive's ROM files to `s` (up to `max_candidates` in all),
/// their entries tagged `drive` so the caller opens each from
/// `romfs.Image.drive(c.entry.drive)`. Returns the volume's error, adding
/// nothing, when it does not open.
pub fn add(s: *Scan, image: romfs.Image, drive: u8, clusters: []u16) ?romfs.Error {
    var vol = romfs.Volume.open(image) catch |e| return e;
    vol.drive = drive;
    var entries: [max_candidates]romfs.Entry = undefined;
    const n = vol.find(&extensions, entries[0 .. max_candidates - s.count]);
    for (entries[0..n], s.candidates[s.count..][0..n]) |e, *c| {
        c.* = .{ .entry = e, .size = e.size };
        const m = vol.map(e, clusters) catch |err| {
            c.map_err = err;
            continue;
        };
        const src = source_of(&m);
        c.verdict = core.rom.check(&src);
        if (c.verdict != .ok) continue;
        c.name_len = header_name(&src, &c.name_buf);
        s.playable_count += 1;
    }
    s.count += @intCast(n);
    return null;
}

/// Map a candidate from `scan` for running (fills `clusters`).
pub fn open(image: romfs.Image, cand: *const Candidate, clusters: []u16) romfs.Error!romfs.Mapped {
    const vol = try romfs.Volume.open(image);
    return vol.map(cand.entry, clusters);
}

/// The RomSource for a mapped file: the flash pointer when its clusters are
/// one run, else the cluster table over the volume's data area.
pub fn source_of(m: *const romfs.Mapped) core.RomSource {
    const size: u32 = @min(m.size, core.rom.max_size);
    if (m.contiguous()) |p| return .{ .size = size, .base = p };
    return .{ .size = size, .clusters = m.clusters, .data_base = m.data_base };
}

/// The header's domestic name, else its overseas name, into `out`: trailing
/// and leading spaces dropped, runs of spaces collapsed to one (headers pad
/// words apart, "SONIC THE               HEDGEHOG"), bytes outside printable
/// ASCII shown as '?'. Returns the length (0: both names blank).
pub fn header_name(src: *const core.RomSource, out: *[name_max]u8) u8 {
    const h = core.rom.parse_header(src);
    const n = tidy(&h.domestic, out);
    if (n > 0) return n;
    return tidy(&h.overseas, out);
}

fn tidy(field: *const [name_max]u8, out: *[name_max]u8) u8 {
    var n: u8 = 0;
    var space = false;
    for (core.rom.trim(field)) |ch| {
        if (ch == ' ' or ch == 0) {
            space = n > 0;
            continue;
        }
        if (space) {
            out[n] = ' ';
            n += 1;
            space = false;
        }
        out[n] = if (ch > ' ' and ch < 0x7F) ch else '?';
        n += 1;
    }
    return n;
}
