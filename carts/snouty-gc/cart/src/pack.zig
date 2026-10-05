//! Track packs on the badge drive (SPEC 19.2, docs/PACKS.md; M7). New for
//! Snouty GCP.
//!
//! `scan` lists the drive's `.GCP` files (each one's directory parsed and
//! checked by pack_format.zig), `tick` runs their CRCs in the background a
//! few KB a call, and `load` copies one track or arena of a checked pack
//! into the slots the built-in leagues use (the tile and horizon slots,
//! the map buffer), then points `track.pack_league`
//! and `track.pack_track` at them: a World with `Setup.track =
//! track.pack_base` runs on it. Only the tiles, the horizon and the map
//! are copied (the floor loop reads them per pixel); the palette,
//! attributes, centerline, feat, props, arena blob and props cells are
//! read in place from the drive's flash window, as the emulator carts read
//! their ROMs (RAM is short: PLAN M7, L100), so those sections must each
//! lie in one run of clusters (`fragmented` otherwise). Every byte a section gives is checked
//! before it is used (the packed streams are decoded with bounds, the map's
//! tile indices, the centerline, the feat kinds, the props, the arena), so
//! a damaged or hostile file is refused with a reason, never a crash.
//!
//! No cart API: the drive is a `romfs.Image` (the badge's flash window,
//! the simulator's embedded image, a test's bytes) and `load_bytes` reads a
//! pack straight from memory, so the host tests run all of it.
const std = @import("std");
const romfs = @import("romfs");
const fmt = @import("pack_format.zig");
const track = @import("track.zig");
const world = @import("world.zig");

pub const Refusal = fmt.Refusal;
/// `.GCP` files listed at most.
pub const max_packs = 8;
/// CRC bytes hashed per `tick`.
pub const crc_step: u32 = 4096;

/// One `.GCP` file on the drive.
pub const Pack = struct {
    /// The drive entry: first cluster and size.
    cluster: u16 = 0,
    size: u32 = 0,
    status: Refusal = .checking,
    /// Its 8.3 name as listed (for a refused file's row).
    file: [12]u8 = @splat(' '),
    file_len: u8 = 0,
    league: [fmt.name_len]u8 = @splat(' '),
    track_n: u8 = 0,
    arena_n: u8 = 0,
    /// The header's CRC of bytes 64.. (checked by `tick`).
    crc: u32 = 0,
    /// The link id: CRC-32 of header bytes 0..48 (the names and counts)
    /// XOR the content CRC, low 24 bits (net.Rules carries 3 bytes), so two
    /// badges agree on name and contents.
    id: u32 = 0,

    pub fn ok(p: *const Pack) bool {
        return p.status == .ok;
    }
    pub fn file_name(p: *const Pack) []const u8 {
        return p.file[0..p.file_len];
    }
};

pub var packs: [max_packs]Pack = @splat(.{});
pub var count: u8 = 0;
/// The volume `scan` read (null: none yet, or no drive).
var image: ?romfs.Image = null;
/// One file's cluster chain (the CRC job and the loader take turns).
var clusters: [fmt.file_max / romfs.sector_size]u16 = undefined;
/// The background CRC: the pack being hashed and how far.
var job_at: u32 = 0;
var job_crc: u32 = 0xFFFFFFFF;
var job_pack: u8 = 0xFF;

/// What `load` last put in the slots (null: nothing, or it failed).
pub const Loaded = struct { pack: u8, k: u8, id: u32 };
pub var loaded: ?Loaded = null;
/// `load_bytes`' pack (host tests, the simulator's `-Dgc-pack` builds go
/// through `image` instead).
var bytes_src: ?[]const u8 = null;

/// The loaded track's props sheet (its cells in the drive file) and names.
var sheet: track.PropSheet = .{};
var name_buf: [fmt.name_len]u8 = undefined;
var league_buf: [fmt.name_len]u8 = undefined;

// --- Reading a mapped file -----------------------------------------------

/// The bytes of `s` (bounds checked by pack_format.parse) into `dst`.
fn copy(m: *const romfs.Mapped, off: u32, dst: []u8) void {
    if (m.chunk(off, @intCast(dst.len))) |p| {
        @memcpy(dst, p[0..dst.len]);
        return;
    }
    for (dst, 0..) |*d, i| d.* = m.read(off + @as(u32, @intCast(i)));
}

/// Decode a packed stream (track.zig `unpack`'s format) of section `s`
/// into exactly `dst`: false when it would read past its section, copy
/// from before the output's start, overrun `dst`, or leave bytes over.
pub fn unpack_checked(m: *const romfs.Mapped, s: fmt.Section, dst: []u8) bool {
    var i: u32 = 0;
    var o: usize = 0;
    const n_src = s.len;
    while (o < dst.len) {
        if (i >= n_src) return false;
        const c = m.read(s.off + i);
        i += 1;
        if (c < 0x80) {
            const n: usize = @as(usize, c) + 1;
            if (o + n > dst.len or i + n > n_src) return false;
            copy(m, s.off + i, dst[o..][0..n]);
            i += @intCast(n);
            o += n;
        } else {
            if (i >= n_src) return false;
            var d: usize = m.read(s.off + i);
            i += 1;
            if (d >= 0x80) {
                if (i >= n_src) return false;
                d = (d & 0x7F) << 8 | m.read(s.off + i);
                i += 1;
            }
            d += 1;
            const end = o + (c & 0x7F) + 3;
            if (d > o or end > dst.len) return false;
            while (o < end) : (o += 1) dst[o] = dst[o - d];
        }
    }
    return i == n_src;
}

/// A mapping of `b` as if it were a contiguous file on a drive (the
/// cluster table filled with consecutive clusters).
fn map_bytes(b: []const u8) ?romfs.Mapped {
    if (b.len == 0 or b.len > fmt.file_max) return null;
    const n = (b.len + romfs.sector_size - 1) / romfs.sector_size;
    for (clusters[0..n], 0..) |*c, i| c.* = @intCast(i + 2);
    return .{ .size = @intCast(b.len), .clusters = clusters[0..n], .data_base = b.ptr };
}

/// Map pack `i`'s file again (its FAT chain into `clusters`).
fn map_pack(i: usize) ?romfs.Mapped {
    if (bytes_src) |b| return map_bytes(b);
    const img = image orelse return null;
    const vol = romfs.Volume.open(img) catch return null;
    const p = &packs[i];
    return vol.map(.{ .size = p.size, .first_cluster = p.cluster }, &clusters) catch null;
}

/// The first `dir_max` bytes (or the whole file) and its parsed directory.
fn read_dir(m: *const romfs.Mapped, d: *fmt.Directory) Refusal {
    var head: [fmt.dir_max]u8 = undefined;
    const n: u32 = @min(m.size, fmt.dir_max);
    copy(m, 0, head[0..n]);
    return fmt.parse(head[0..n], m.size, d);
}

fn head_id(m: *const romfs.Mapped) u32 {
    var h: [48]u8 = undefined;
    copy(m, 0, &h);
    return crc_update(0xFFFFFFFF, &h) ^ 0xFFFFFFFF;
}

/// CRC-32 (zlib's, reflected 0xEDB88320) a nibble at a time: a 64-byte
/// table instead of std's kilobytes (RAM, PLAN M7). Start from
/// 0xFFFFFFFF and XOR the end with it.
pub fn crc_update(crc_in: u32, bytes: []const u8) u32 {
    const t = [16]u32{
        0x00000000, 0x1DB71064, 0x3B6E20C8, 0x26D930AC, 0x76DC4190, 0x6B6B51F4, 0x4DB26158, 0x5005713C,
        0xEDB88320, 0xF00F9344, 0xD6D6A3E8, 0xCB61B38C, 0x9B64C2B0, 0x86D3D2D4, 0xA00AE278, 0xBDBDF21C,
    };
    var c = crc_in;
    for (bytes) |b| {
        c ^= b;
        c = (c >> 4) ^ t[c & 15];
        c = (c >> 4) ^ t[c & 15];
    }
    return c;
}

test "crc_update is zlib's CRC-32" {
    try std.testing.expectEqual(std.hash.Crc32.hash("123456789"), crc_update(0xFFFFFFFF, "123456789") ^ 0xFFFFFFFF);
}

// --- The drive scan and the background CRC -----------------------------------

/// List and check the `.GCP` files on `img` (header and directory now, the
/// CRC through `tick`). A file listed by the last scan with the same
/// cluster, size and header CRC keeps its verdict (no second CRC).
pub fn scan(img: romfs.Image) void {
    bytes_src = null;
    image = img;
    var old: [max_packs]Pack = undefined;
    const old_n = count;
    @memcpy(old[0..old_n], packs[0..old_n]);
    count = 0;
    job_pack = 0xFF;
    const vol = romfs.Volume.open(img) catch return;
    var ents: [max_packs]romfs.Entry = undefined;
    const n = vol.find(&.{"gcp"}, &ents);
    for (ents[0..n]) |e| {
        const p = &packs[count];
        p.* = .{ .cluster = e.first_cluster, .size = e.size };
        const nl = @min(e.name_len, p.file.len);
        @memcpy(p.file[0..nl], e.name[0..nl]);
        p.file_len = @intCast(nl);
        count += 1;
        const m = vol.map(e, &clusters) catch {
            p.status = if (e.size > fmt.file_max) .too_big else .bad_file;
            continue;
        };
        var d: fmt.Directory = undefined;
        const r = read_dir(&m, &d);
        if (r != .ok) {
            p.status = r;
            continue;
        }
        p.league = d.league;
        p.track_n = d.track_n;
        p.arena_n = d.arena_n;
        p.crc = d.crc;
        p.id = head_id(&m);
        p.status = .checking;
        for (old[0..old_n]) |*o| {
            if (o.cluster == p.cluster and o.size == p.size and o.crc == p.crc and o.status != .checking) {
                p.status = o.status;
                p.id = o.id;
            }
        }
    }
}

/// One slice of the background CRC (`crc_step` bytes of the first pack
/// still `checking`). True while any pack is still being checked.
pub fn tick() bool {
    var i: usize = 0;
    while (i < count and packs[i].status != .checking) i += 1;
    if (i >= count) return false;
    const p = &packs[i];
    if (job_pack != i) {
        job_pack = @intCast(i);
        job_at = fmt.header_bytes;
        job_crc = 0xFFFFFFFF;
    }
    const m = map_pack(i) orelse {
        p.status = .bad_file;
        job_pack = 0xFF;
        return true;
    };
    const end = @min(m.size, job_at + crc_step);
    while (job_at < end) {
        // Cluster by cluster (a run of them when consecutive).
        const take = @min(end - job_at, romfs.sector_size - job_at % romfs.sector_size);
        const ptr = m.chunk(job_at, take) orelse break;
        job_crc = crc_update(job_crc, ptr[0..take]);
        job_at += take;
    }
    if (job_at >= m.size) {
        const crc = job_crc ^ 0xFFFFFFFF;
        p.status = if (crc == p.crc) .ok else .damaged;
        // The link id: 24 bits on the wire (net.Rules).
        p.id = (p.id ^ crc) & 0xFFFFFF;
        job_pack = 0xFF;
    }
    return true;
}

/// Forget the drive (host tests: leave no packs behind for the next test).
pub fn forget() void {
    count = 0;
    image = null;
    bytes_src = null;
    fail();
}

/// Run every pending CRC now (host tests, the bench pokes).
pub fn check_all() void {
    while (tick()) {}
}

/// Any pack still checking.
pub fn busy() bool {
    for (packs[0..count]) |*p| if (p.status == .checking) return true;
    return false;
}

/// The checked pack with link id `id` (null: none on this drive).
pub fn find_id(id: u32) ?u8 {
    for (packs[0..count], 0..) |*p, i| {
        if (p.ok() and p.id == id) return @intCast(i);
    }
    return null;
}

// --- Loading -------------------------------------------------------------------

/// The centerline sanity check (docs/PACKS.md): half widths 8..120, a
/// closed loop of samples under 48 px apart; on a race track sample 0 on a
/// start tile and each sample on drivable floor (or over a ramp's gap).
fn center_ok(t: *const track.Track, race: bool) bool {
    for (0..256) |i| {
        const s = t.sample(i);
        const nx = t.sample(i + 1);
        if (s.half < 8 or s.half > 120) return false;
        const dx = ((@as(i32, nx.x) - s.x + 512) & 1023) - 512;
        const dy = ((@as(i32, nx.y) - s.y + 512) & 1023) - 512;
        if (dx * dx + dy * dy >= 48 * 48) return false;
        if (!race) continue;
        const a = t.attr_at(s.x, s.y);
        if (a == .off and s.flags & track.flag_ramp != 0) continue;
        if (a == .off or a == .wall) return false;
    }
    return !race or t.attr_at(t.sample(0).x, t.sample(0).y) == .start;
}

/// Load track `k` of the checked pack `i` (race tracks 0 .. track_n - 1,
/// the arena at track_n) into the slots and `track.pack_track`. `.ok` or
/// why not; a refusal from the pack's contents marks the pack refused
/// (`packs[i].status`), and the slots then hold nothing (`track.select` of
/// a built-in track reloads it).
pub fn load(i: u8, k: u8) Refusal {
    if (i >= count or !packs[i].ok()) return if (i < count) packs[i].status else .bad_file;
    const r = load_mapped(i, k);
    if (r != .ok) {
        packs[i].status = r;
        fail();
    }
    return r;
}

/// `load` straight from a pack's bytes in memory (host tests, Track B's
/// content tests): the bytes stand for one drive file, checked in full
/// (directory, CRC, contents) on every call. `b` must outlive the race.
/// Then `sim.reset(&w, .{ .track = track.pack_base, .mode = ... })`.
pub fn load_bytes(b: []const u8, k: u8) Refusal {
    bytes_src = b;
    image = null;
    count = 1;
    packs[0] = .{ .size = @intCast(@min(b.len, std.math.maxInt(u32))) };
    const m = map_bytes(b) orelse {
        packs[0].status = if (b.len > fmt.file_max) .too_big else .not_a_pack;
        fail();
        return packs[0].status;
    };
    var d: fmt.Directory = undefined;
    const r = read_dir(&m, &d);
    if (r != .ok) {
        packs[0].status = r;
        fail();
        return r;
    }
    packs[0].crc = d.crc;
    packs[0].league = d.league;
    packs[0].track_n = d.track_n;
    packs[0].arena_n = d.arena_n;
    packs[0].id = head_id(&m);
    packs[0].status = .checking;
    check_all();
    return load(0, k);
}

fn fail() void {
    loaded = null;
    track.art_league = null;
    track.map_owner = null;
    track.pack_reload = null;
}

/// A section read in place: a pointer into the drive's flash window (or
/// the bytes of `load_bytes`), null when its clusters are not one run.
fn in_place(m: *const romfs.Mapped, sec: fmt.Section) ?[]const u8 {
    if (sec.len == 0) return &.{};
    const p = m.chunk(sec.off, sec.len) orelse return null;
    return p[0..sec.len];
}

fn load_mapped(i: u8, k: u8) Refusal {
    const m = map_pack(i) orelse return .bad_file;
    var d: fmt.Directory = undefined;
    const r = read_dir(&m, &d);
    if (r != .ok) return r;
    if (d.crc != packs[i].crc) return .damaged;
    if (k >= d.track_n + d.arena_n) return .damaged;
    const rec = &d.tracks[k];
    // The art and the map are unpacked into the built-in slots (the floor
    // loop reads them per pixel: never from flash).
    if (!unpack_checked(&m, d.tiles, &track.art_tiles)) return .damaged;
    if (!unpack_checked(&m, d.horizon, &track.art_horizon)) return .damaged;
    if (!unpack_checked(&m, rec.map, &track.map_ram)) return .damaged;
    for (track.map_ram) |v| if (v >= track.tile_count) return .damaged;
    // Everything else is read where it lies on the drive (RAM is short:
    // PLAN M7, L100), so each section must be one run of clusters.
    const pal = in_place(&m, d.pal) orelse return .fragmented;
    const attr = in_place(&m, d.attr) orelse return .fragmented;
    const center = in_place(&m, rec.center) orelse return .fragmented;
    const feat = in_place(&m, rec.feat) orelse return .fragmented;
    const props = in_place(&m, rec.props) orelse return .fragmented;
    const arena = in_place(&m, rec.arena) orelse return .fragmented;
    const cells = in_place(&m, d.cells) orelse return .fragmented;
    const cell_pal = in_place(&m, d.cell_pal) orelse return .fragmented;
    for (attr) |a| if (a > @backingInt(track.Attr.crust)) return .damaged;
    // Feat kinds: in the header's mask; a turret is not run; a sprite only
    // on a mover, inside the sheet; crust in whole tiles inside the map,
    // its tiles carrying the crust attribute.
    var f: usize = 0;
    while (f < feat.len) : (f += fmt.feat_record) {
        const kind = feat[f] & 15;
        if (kind == 0 or kind > @backingInt(world.HazardKind.crust)) return .damaged;
        if (kind == @backingInt(world.HazardKind.turret)) return .needs_newer_cart;
        if (d.hazards & (@as(u8, 1) << @intCast(kind)) == 0) return .damaged;
        if (std.mem.readInt(u16, feat[f + 12 ..][0..2], .little) == 0) return .damaged;
        if (kind != @backingInt(world.HazardKind.crust)) continue;
        const x0 = std.mem.readInt(u16, feat[f + 4 ..][0..2], .little);
        const y0 = std.mem.readInt(u16, feat[f + 6 ..][0..2], .little);
        const x1 = std.mem.readInt(u16, feat[f + 8 ..][0..2], .little);
        const y1 = std.mem.readInt(u16, feat[f + 10 ..][0..2], .little);
        if (x0 >= x1 or y0 >= y1 or x1 > 1024 or y1 > 1024) return .damaged;
        if (attr[track.crust_tile] != @backingInt(track.Attr.crust)) return .damaged;
    }
    _ = fmt.cells_used(&d, props, feat) orelse return .damaged;
    // The props sheet: the pack's cells stacked as one column (each cell
    // row-major in the file), drawn by `cell * cell_h` rows down.
    sheet = .{ .bytes = cells, .cells = d.cell_n, .cell_w = d.cell_w, .cell_h = d.cell_h, .pal = cell_pal };
    const nl = fmt.show_name(&rec.name, &name_buf);
    const ll = fmt.show_name(&d.league, &league_buf);
    track.pack_league = .{
        .name = league_buf[0..ll],
        .tiles_packed = &.{},
        .horizon_packed = &.{},
        .pal = pal,
    };
    track.pack_track = .{
        .name = name_buf[0..nl],
        .league = &track.pack_league,
        .laps = if (rec.kind == .race) rec.laps else 0,
        .map_packed = &.{},
        .attr = attr,
        .center = center,
        .feat = feat,
        .arena = arena,
        .props = props,
        .sheet = if (d.cell_n > 0) &sheet else null,
    };
    // The arena blob must parse (spawns, nodes, tables in range).
    if (rec.kind == .arena) {
        var a: track.Arena = .{};
        var pads: [world.crate_max]track.CrateSpot = undefined;
        var pn: u8 = 0;
        if (!track.parse_arena(&track.pack_track, &a, &pads, &pn) or a.spawn_n == 0) return .damaged;
        for (a.next) |v| if (v != track.no_node and v >= a.node_n) return .damaged;
        for (a.ground) |v| if (v != track.no_node and v >= a.node_n) return .damaged;
        for (a.cells) |v| if (v != track.no_node and v >= a.node_n) return .damaged;
        for (a.nodes[0..a.node_n]) |nd| if (nd.jump != track.no_node and nd.jump >= a.node_n) return .damaged;
    }
    track.art_league = &track.pack_league;
    track.map_owner = &track.pack_track;
    if (!center_ok(&track.pack_track, rec.kind == .race)) return .damaged;
    loaded = .{ .pack = i, .k = k, .id = packs[i].id };
    track.pack_reload = &reload;
    return .ok;
}

/// `track.pack_reload`: load the same pack track again (its art and map
/// were overwritten by a built-in track's).
fn reload() bool {
    const l = loaded orelse return false;
    return load(l.pack, l.k) == .ok;
}

/// Load the pack with link id `id`, track `k` (a link race): `.ok`, or
/// `.bad_file` when this drive has no such pack.
pub fn load_id(id: u32, k: u8) Refusal {
    const i = find_id(id) orelse return .bad_file;
    if (loaded) |l| if (l.pack == i and l.k == k and track.map_owner == &track.pack_track and track.art_league == &track.pack_league) return .ok;
    return load(i, k);
}
