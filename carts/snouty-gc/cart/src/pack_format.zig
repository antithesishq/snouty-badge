//! The track pack file format, version 1 (docs/PACKS.md, SPEC 19; M7). New
//! for Snouty GCP.
//!
//! A pack's directory (the 64-byte header, the 64-byte league block and up
//! to five 64-byte track records: at most `dir_max` bytes from the start of
//! the file) is parsed and checked here from a plain byte slice, so the
//! drive scan, the loader, `tools/build_pack.py`'s checks and the host
//! fuzz tests share one parser. Every offset and length is checked against
//! the file size before anything reads a section. Pure: no cart API, no
//! romfs, no allocation.
const std = @import("std");

pub const magic = "GCPK";
/// The format version this cart reads. A pack with another is refused
/// (`too_new`); bump it whenever the layout or a field's meaning changes.
pub const version: u8 = 1;
pub const header_bytes = 64;
pub const league_bytes = 64;
pub const record_bytes = 64;
pub const track_max = 4;
pub const arena_max = 1;
/// The directory: header, league block, the track records.
pub const dir_max = header_bytes + league_bytes + (track_max + arena_max) * record_bytes;
/// Largest pack file (256 drive clusters: `pack.zig`'s cluster table).
pub const file_max: u32 = 128 * 1024;
pub const name_len = 16;

/// Section sizes (the built-in leagues' and tracks', track.zig).
pub const pal_bytes = 512;
pub const tiles_bytes = 128 * 64;
pub const horizon_bytes = 12352;
pub const attr_bytes = 128;
pub const map_bytes = 128 * 128;
pub const center_bytes = 256 * 6;
pub const feat_record = 20;
pub const feat_max = 4;
pub const cell_pal_bytes = 32;
pub const prop_record = 6;
/// Props placed per track (each one a depth-list entry when in view).
pub const prop_max = 24;
pub const cell_w_max = 32;
pub const cell_h_max = 48;
pub const cell_max = 16;

/// The pack slot (`pack.zig`): everything of a loaded track that is not
/// the tiles, the horizon or the map (those go to the built-in leagues'
/// slots). Fixed part: palette, attributes, centerline, feat, props.
pub const slot_bytes = 8192;
pub const slot_fixed = pal_bytes + attr_bytes + center_bytes + feat_max * feat_record + prop_max * prop_record;
/// Per track: arena blob + the props cells it places, at most this.
pub const slot_free = slot_bytes - slot_fixed;

/// Breakable crust tiles (attribute `crust`): intact, cracked, broken.
pub const crust_tile: u8 = 121;

/// Hazard mask bits (header byte 8): the feat kinds (world.HazardKind
/// values 1..4) and the two attribute hazards.
pub const has_blast: u8 = 1 << 1;
pub const has_mover: u8 = 1 << 2;
pub const has_turret: u8 = 1 << 3;
pub const has_crust: u8 = 1 << 4;
pub const has_slick: u8 = 1 << 5;
pub const has_pit: u8 = 1 << 6;
/// What this cart runs; any other bit is `needs_newer_cart`.
pub const runs: u8 = has_blast | has_mover | has_crust | has_slick | has_pit;

/// Why a pack cannot be raced (the picker's line; `ok` = it can).
pub const Refusal = enum(u8) {
    ok,
    /// No `GCPK` magic: some other file with a .GCP name.
    not_a_pack,
    /// A format version this cart does not read.
    too_new,
    /// A bad header field, a section out of bounds or of the wrong length,
    /// the CRC, or a section's contents (checked at load).
    damaged,
    /// Over `file_max`, or a track over the slot budget.
    too_big,
    /// A hazard kind this cart does not run (a turret, or an unknown bit).
    needs_newer_cart,
    /// Scanned, CRC still running (not pickable yet).
    checking,
    /// The drive's FAT chain for the file is broken.
    bad_file,

    pub fn text(r: Refusal) []const u8 {
        return switch (r) {
            .ok => "",
            .not_a_pack => "NOT A PACK",
            .too_new => "PACK TOO NEW",
            .damaged => "PACK DAMAGED",
            .too_big => "PACK TOO BIG",
            .needs_newer_cart => "NEEDS NEWER CART",
            .checking => "CHECKING PACK",
            .bad_file => "PACK DAMAGED",
        };
    }
};

pub const Section = struct {
    off: u32 = 0,
    len: u32 = 0,

    fn at(b: []const u8, o: usize) Section {
        return .{ .off = rd32(b, o), .len = rd32(b, o + 4) };
    }

    /// Past the directory (`dir_len` bytes) and inside a file of `size`
    /// bytes, 4-byte aligned (an empty section must be (0, 0)).
    fn fits(s: Section, dir_len: u32, size: u32) bool {
        if (s.len == 0) return s.off == 0;
        return s.off % 4 == 0 and s.off >= dir_len and s.off <= size and s.len <= size - s.off;
    }
};

pub const Kind = enum(u8) { race = 0, arena = 1 };

/// One track record.
pub const TrackRec = struct {
    name: [name_len]u8 = @splat(' '),
    laps: u8 = 0,
    kind: Kind = .race,
    map: Section = .{},
    center: Section = .{},
    feat: Section = .{},
    arena: Section = .{},
    props: Section = .{},
};

/// A parsed, bounds-checked directory.
pub const Directory = struct {
    track_n: u8 = 0,
    arena_n: u8 = 0,
    hazards: u8 = 0,
    cell_w: u8 = 0,
    cell_h: u8 = 0,
    cell_n: u8 = 0,
    name: [name_len]u8 = @splat(' '),
    league: [name_len]u8 = @splat(' '),
    size: u32 = 0,
    crc: u32 = 0,
    pal: Section = .{},
    tiles: Section = .{},
    horizon: Section = .{},
    attr: Section = .{},
    cells: Section = .{},
    cell_pal: Section = .{},
    /// Race tracks first, then the arena: `tracks[0 .. track_n + arena_n]`.
    tracks: [track_max + arena_max]TrackRec = @splat(.{}),

    /// Bytes of the directory in the file.
    pub fn bytes(d: *const Directory) u32 {
        return header_bytes + league_bytes + @as(u32, d.track_n + d.arena_n) * record_bytes;
    }

    /// Bytes of one props cell at 4 bpp.
    pub fn cell_bytes(d: *const Directory) u32 {
        return @as(u32, d.cell_w) * d.cell_h / 2;
    }

    pub fn arena(d: *const Directory) ?*const TrackRec {
        if (d.arena_n == 0) return null;
        return &d.tracks[d.track_n];
    }
};

fn rd16(b: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, b[o..][0..2], .little);
}
fn rd32(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .little);
}

fn zero(b: []const u8) bool {
    for (b) |v| if (v != 0) return false;
    return true;
}

/// Parse and check the directory at the start of a pack: `head` holds the
/// file's first `@min(size, dir_max)` bytes, `size` is the file size (the
/// drive's directory entry). Checks everything that does not need the
/// sections' contents: magic, version, counts, the file size field, every
/// section's bounds, alignment and length, the props cells, the hazard
/// mask, the size cap and each track's slot budget (with its props
/// records' count; the cells it uses are counted at load). The CRC is the
/// caller's (`crc` is the header's value).
pub fn parse(head: []const u8, size: u32, out: *Directory) Refusal {
    out.* = .{};
    if (head.len < 4 or !std.mem.eql(u8, head[0..4], magic)) return .not_a_pack;
    if (head.len < header_bytes) return .damaged;
    if (head[4] != version) return if (head[4] > version) .too_new else .damaged;
    if (head[5] != header_bytes) return .damaged;
    if (size > file_max) return .too_big;
    const tn = head[6];
    const an = head[7];
    if (tn < 1 or tn > track_max or an > arena_max) return .damaged;
    const dir_len: u32 = header_bytes + league_bytes + @as(u32, tn + an) * record_bytes;
    if (head.len < dir_len or size < dir_len) return .damaged;
    if (rd32(head, 44) != size) return .damaged;
    if (!zero(head[52..64])) return .damaged;
    const mask = head[8];
    if (mask & 0x81 != 0) return .damaged;
    if (mask & ~runs != 0) return .needs_newer_cart;
    out.track_n = tn;
    out.arena_n = an;
    out.hazards = mask;
    out.cell_w = head[9];
    out.cell_h = head[10];
    out.cell_n = head[11];
    @memcpy(&out.name, head[12..28]);
    @memcpy(&out.league, head[28..44]);
    out.size = size;
    out.crc = rd32(head, 48);
    const L = header_bytes;
    out.pal = .at(head, L);
    out.tiles = .at(head, L + 8);
    out.horizon = .at(head, L + 16);
    out.attr = .at(head, L + 24);
    out.cells = .at(head, L + 32);
    out.cell_pal = .at(head, L + 40);
    if (!zero(head[L + 48 .. L + 64])) return .damaged;
    const league = [_]Section{ out.pal, out.tiles, out.horizon, out.attr, out.cells, out.cell_pal };
    for (league) |s| if (!s.fits(dir_len, size)) return .damaged;
    if (out.pal.len != pal_bytes or out.attr.len != attr_bytes) return .damaged;
    if (out.tiles.len == 0 or out.tiles.len > tiles_bytes + tiles_bytes / 64 + 4) return .damaged;
    if (out.horizon.len == 0 or out.horizon.len > horizon_bytes + horizon_bytes / 64 + 4) return .damaged;
    // Props: none (all zero), or a cell size and count with the cells and
    // their palette present at the right lengths.
    if (out.cell_n == 0) {
        if (out.cell_w != 0 or out.cell_h != 0 or out.cells.len != 0 or out.cell_pal.len != 0) return .damaged;
    } else {
        if (out.cell_w == 0 or out.cell_w % 2 != 0 or out.cell_w > cell_w_max) return .damaged;
        if (out.cell_h == 0 or out.cell_h > cell_h_max or out.cell_n > cell_max) return .damaged;
        if (out.cells.len != out.cell_bytes() * out.cell_n or out.cell_pal.len != cell_pal_bytes) return .damaged;
    }
    for (0..tn + an) |k| {
        const b = head[header_bytes + league_bytes + k * record_bytes ..][0..record_bytes];
        const t = &out.tracks[k];
        @memcpy(&t.name, b[0..16]);
        t.laps = b[16];
        if (b[17] > 1 or b[18] != 0 or b[19] != 0 or !zero(b[60..64])) return .damaged;
        t.kind = @enumFromInt(b[17]);
        // Race tracks first, then the arena.
        if ((k >= tn) != (t.kind == .arena)) return .damaged;
        t.map = .at(b, 20);
        t.center = .at(b, 28);
        t.feat = .at(b, 36);
        t.arena = .at(b, 44);
        t.props = .at(b, 52);
        for ([_]Section{ t.map, t.center, t.feat, t.arena, t.props }) |s| if (!s.fits(dir_len, size)) return .damaged;
        if (t.kind == .race and (t.laps < 1 or t.laps > 9 or t.arena.len != 0)) return .damaged;
        if (t.kind == .arena and (t.laps != 0 or t.arena.len < 8)) return .damaged;
        if (t.map.len == 0 or t.map.len > map_bytes + map_bytes / 64 + 4) return .damaged;
        if (t.center.len != center_bytes) return .damaged;
        if (t.feat.len % feat_record != 0 or t.feat.len > feat_max * feat_record) return .damaged;
        if (t.props.len % prop_record != 0 or t.props.len > prop_max * prop_record) return .damaged;
        if (t.props.len != 0 and out.cell_n == 0) return .damaged;
        // The arena blob alone may not overflow the slot (the cells it
        // uses are counted at load, `budget`).
        if (t.arena.len > slot_free) return .too_big;
    }
    return .ok;
}

/// The slot bytes track `k` needs beyond the fixed part: its arena blob
/// and one cell for each distinct props cell its props records (`props`)
/// and its movers' sprites (`feat`, byte 0 bits 4..7 = cell + 1) use, the
/// cells the loader copies. `null` when a record names a cell past
/// `cell_n`.
pub fn budget(d: *const Directory, k: usize, props: []const u8, feat: []const u8) ?u32 {
    const used = cells_used(d, props, feat) orelse return null;
    return d.tracks[k].arena.len + @popCount(used) * d.cell_bytes();
}

/// The cells a track loads (bit c = cell c): its props' and its movers'.
pub fn cells_used(d: *const Directory, props: []const u8, feat: []const u8) ?u32 {
    var used: u32 = 0;
    var i: usize = 0;
    while (i + prop_record <= props.len) : (i += prop_record) {
        if (props[i] >= d.cell_n) return null;
        used |= @as(u32, 1) << @intCast(props[i]);
    }
    i = 0;
    while (i + feat_record <= feat.len) : (i += feat_record) {
        const sp = feat[i] >> 4;
        if (sp == 0) continue;
        if (feat[i] & 15 != 2 or sp - 1 >= d.cell_n) return null;
        used |= @as(u32, 1) << @intCast(sp - 1);
    }
    return used;
}

/// A name field as shown: trailing spaces and zeros cut, anything outside
/// printable ASCII as '?'. Returns the length written to `out`.
pub fn show_name(field: *const [name_len]u8, out: *[name_len]u8) u8 {
    var n: usize = name_len;
    while (n > 0 and (field[n - 1] == ' ' or field[n - 1] == 0)) n -= 1;
    for (field[0..n], out[0..n]) |c, *o| o.* = if (c >= 0x20 and c < 0x7F) c else '?';
    return @intCast(n);
}

test "a header-sized buffer of junk is refused, never parsed" {
    var d: Directory = undefined;
    var b: [dir_max]u8 = @splat(0);
    try std.testing.expectEqual(Refusal.not_a_pack, parse(&b, dir_max, &d));
    @memcpy(b[0..4], magic);
    try std.testing.expectEqual(Refusal.damaged, parse(b[0..10], 10, &d));
    b[4] = 2;
    try std.testing.expectEqual(Refusal.too_new, parse(&b, dir_max, &d));
    b[4] = 0;
    try std.testing.expectEqual(Refusal.damaged, parse(&b, dir_max, &d));
}

test "the budget counts a mover's sprite cell with the props' cells, once" {
    var d: Directory = .{ .cell_w = 32, .cell_h = 48, .cell_n = 8, .track_n = 1 };
    d.tracks[0].arena.len = slot_free - 7 * 768 + 1;
    // Props on cells 0..5, the mover on cell 6: seven cells, one byte over.
    var props: [6 * prop_record]u8 = @splat(0);
    for (0..6) |c| props[c * prop_record] = @intCast(c);
    var feat: [feat_record]u8 = @splat(0);
    feat[0] = 2 | (7 << 4);
    try std.testing.expectEqual(@as(?u32, slot_free + 1), budget(&d, 0, &props, &feat));
    // The mover on a cell the props use already: six cells, under.
    feat[0] = 2 | (1 << 4);
    try std.testing.expectEqual(@as(?u32, slot_free + 1 - 768), budget(&d, 0, &props, &feat));
    // A sprite past the sheet, or on a kind other than a mover, is damage.
    feat[0] = 2 | (9 << 4);
    try std.testing.expectEqual(@as(?u32, null), budget(&d, 0, &props, &feat));
    feat[0] = 1 | (1 << 4);
    try std.testing.expectEqual(@as(?u32, null), budget(&d, 0, &props, &feat));
}

test "slot arithmetic" {
    try std.testing.expectEqual(@as(usize, 2400), slot_fixed);
    try std.testing.expectEqual(@as(usize, 5792), slot_free);
    _ = rd16;
}

test "the committed test pack parses, and its CRC matches" {
    const b = @embedFile("gen/packs/TEST.GCP");
    var d: Directory = undefined;
    try std.testing.expectEqual(Refusal.ok, parse(b[0..@min(b.len, dir_max)], b.len, &d));
    try std.testing.expectEqual(@as(u8, 2), d.track_n);
    try std.testing.expectEqual(@as(u8, 1), d.arena_n);
    try std.testing.expectEqual(std.hash.Crc32.hash(b[header_bytes..]), d.crc);
    var nm: [name_len]u8 = undefined;
    try std.testing.expectEqualStrings("TEST PACK", nm[0..show_name(&d.name, &nm)]);
    try std.testing.expectEqualStrings("TEST SANDBOX", nm[0..show_name(&d.arena().?.name, &nm)]);
}
