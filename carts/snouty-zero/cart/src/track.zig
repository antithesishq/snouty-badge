//! The embedded league art and track data (PLAN.md "Generated data
//! formats"), read at run time from the `assets` module. No comptime decoding.
//!
//! Maps are stored packed; `select(t)` unpacks the track about to be raced
//! into the one RAM buffer `map_ram` (16 KB) and sets `current`. Every tile
//! lookup (`Track.tile_at`/`attr_at`, the floor renderer) reads `map_ram`,
//! so `select` must have run for the track being looked at.
const std = @import("std");
const assets = @import("assets");

pub const map_side = 128;
pub const tile_count = 256;

/// Tile attributes (attr.bin values).
pub const Attr = enum(u8) {
    off = 0,
    surface = 1,
    rail = 2,
    pad = 3,
    throttled = 4,
    cold = 5,
    hot = 6,
    hop = 7,
    start = 8,
    sector1 = 9,
    sector2 = 10,
    _,
};

pub const League = struct {
    /// 256 tiles x 64 bytes, each 8x8 row-major palette indices.
    tiles: *const [tile_count * 64]u8,
    /// 256 x u16 RGB565 little-endian; entry 0 is the fog colour.
    pal: *const [tile_count * 2]u8,
    /// Front 512x32 4 bpp, back 256x32 4 bpp, front palette 16 x u16, back palette 16 x u16.
    horizon: *const [12352]u8,

    pub fn pal_rgb565(self: League, i: usize) u16 {
        return std.mem.readInt(u16, self.pal[i * 2 ..][0..2], .little);
    }
    pub fn horizon_front(self: League) *const [512 * 32 / 2]u8 {
        return self.horizon[0 .. 512 * 32 / 2];
    }
    pub fn horizon_back(self: League) *const [256 * 32 / 2]u8 {
        return self.horizon[512 * 32 / 2 ..][0 .. 256 * 32 / 2];
    }
    pub fn horizon_front_pal(self: League, i: usize) u16 {
        return std.mem.readInt(u16, self.horizon[8192 + 4096 + i * 2 ..][0..2], .little);
    }
    pub fn horizon_back_pal(self: League, i: usize) u16 {
        return std.mem.readInt(u16, self.horizon[8192 + 4096 + 32 + i * 2 ..][0..2], .little);
    }
};

/// Centerline sample `flags` bits (PLAN.md "Generated data formats").
pub const flag_rail: u8 = 1 << 0;
pub const flag_open: u8 = 1 << 1;
pub const flag_pad: u8 = 1 << 2;
pub const flag_throttled: u8 = 1 << 3;
pub const flag_cold: u8 = 1 << 4;
pub const flag_hot: u8 = 1 << 5;
/// On a hop segment; the samples just past the hop plate may sit over the
/// hop gap (attribute `off`), which a machine crosses in the air.
pub const flag_hop: u8 = 1 << 6;

pub const Sample = struct {
    x: u16,
    y: u16,
    tangent: u16,
    half: u8,
    flags: u8,
};

pub const Track = struct {
    name: []const u8,
    league: *const League,
    /// The packed 128x128 map (`unpack_map` gives map[y][x]); read it through
    /// `select` + `map_ram`, never directly.
    map_packed: []const u8,
    attr: *const [tile_count]u8,
    /// 256 centerline samples x 8 bytes.
    center: *const [256 * 8]u8,

    pub fn sample(self: Track, i: usize) Sample {
        const b = self.center[(i & 255) * 8 ..][0..8];
        return .{
            .x = std.mem.readInt(u16, b[0..2], .little),
            .y = std.mem.readInt(u16, b[2..4], .little),
            .tangent = std.mem.readInt(u16, b[4..6], .little),
            .half = b[6],
            .flags = b[7],
        };
    }

    /// Tile index at world pixel (wx, wy), wrapping. Reads `map_ram`: only
    /// valid for the track `select` last unpacked (`current`).
    pub fn tile_at(self: Track, wx: i32, wy: i32) u8 {
        _ = self;
        const tx: usize = @intCast((wx >> 3) & (map_side - 1));
        const ty: usize = @intCast((wy >> 3) & (map_side - 1));
        return map_ram[ty * map_side + tx];
    }

    pub fn attr_at(self: Track, wx: i32, wy: i32) Attr {
        return @fromBackingInt(@intCast(self.attr[self.tile_at(wx, wy)]));
    }
};

/// The selected track's unpacked map, map[y][x] (filled by `select`).
pub var map_ram: [map_side * map_side]u8 = undefined;
/// The track whose map is in `map_ram`. Meaningful once `select` has run.
pub var current: *const Track = &cold_aisle;

/// Unpack `t`'s map into `map_ram` and make it `current`. Call at race
/// start (sim.reset), before any tile lookup on `t`; ~16 K byte copies.
pub fn select(t: *const Track) void {
    unpack_map(t.map_packed, &map_ram);
    current = t;
}

/// Unpack a packed map stream (PLAN.md "Generated data formats",
/// tools/build_tracks.py `pack_map`) into `dst`, no allocation. Ops until
/// `dst` is full:
///   c = 0x00..0x7F: literal run, the next c + 1 bytes;
///   c = 0x80..0xFF: copy (c & 0x7F) + 3 bytes from `distance` back, where
///     distance is b + 1 for one byte b < 0x80, else ((b & 0x7F) << 8 | b2) + 1
///     with a second byte b2; the copy runs forward byte by byte, so it may
///     overlap its own output (distance 1 repeats one tile, 128 a row).
/// The stream is generator output checked by the tests; a malformed one is
/// caught by safety checks in Debug builds only.
pub fn unpack_map(src: []const u8, dst: *[map_side * map_side]u8) void {
    var i: usize = 0;
    var o: usize = 0;
    while (o < dst.len) {
        const c = src[i];
        i += 1;
        if (c < 0x80) {
            const n = @as(usize, c) + 1;
            @memcpy(dst[o..][0..n], src[i..][0..n]);
            i += n;
            o += n;
        } else {
            var d: usize = src[i];
            i += 1;
            if (d >= 0x80) {
                d = (d & 0x7F) << 8 | src[i];
                i += 1;
            }
            d += 1;
            const end = o + (c & 0x7F) + 3;
            while (o < end) : (o += 1) dst[o] = dst[o - d];
        }
    }
}

pub const edge = League{
    .tiles = assets.edge_tiles[0 .. tile_count * 64],
    .pal = assets.edge_pal[0 .. tile_count * 2],
    .horizon = assets.edge_horizon[0..12352],
};

pub const spine = League{
    .tiles = assets.spine_tiles[0 .. tile_count * 64],
    .pal = assets.spine_pal[0 .. tile_count * 2],
    .horizon = assets.spine_horizon[0..12352],
};

pub const core = League{
    .tiles = assets.core_tiles[0 .. tile_count * 64],
    .pal = assets.core_pal[0 .. tile_count * 2],
    .horizon = assets.core_horizon[0..12352],
};

pub const cold_aisle = Track{
    .name = "COLD AISLE",
    .league = &edge,
    .map_packed = assets.cold_aisle_map,
    .attr = assets.cold_aisle_attr[0..tile_count],
    .center = assets.cold_aisle_center[0 .. 256 * 8],
};

pub const substation_sprint = Track{
    .name = "SUBSTATION SPRINT",
    .league = &edge,
    .map_packed = assets.substation_sprint_map,
    .attr = assets.substation_sprint_attr[0..tile_count],
    .center = assets.substation_sprint_center[0 .. 256 * 8],
};

pub const exhaust_ridge = Track{
    .name = "EXHAUST RIDGE",
    .league = &edge,
    .map_packed = assets.exhaust_ridge_map,
    .attr = assets.exhaust_ridge_attr[0..tile_count],
    .center = assets.exhaust_ridge_center[0 .. 256 * 8],
};

pub const fiber_backbone = Track{
    .name = "FIBER BACKBONE",
    .league = &spine,
    .map_packed = assets.fiber_backbone_map,
    .attr = assets.fiber_backbone_attr[0..tile_count],
    .center = assets.fiber_backbone_center[0 .. 256 * 8],
};

pub const rack_row_7 = Track{
    .name = "RACK ROW 7",
    .league = &spine,
    .map_packed = assets.rack_row_7_map,
    .attr = assets.rack_row_7_attr[0..tile_count],
    .center = assets.rack_row_7_center[0 .. 256 * 8],
};

pub const tape_vault = Track{
    .name = "TAPE VAULT",
    .league = &spine,
    .map_packed = assets.tape_vault_map,
    .attr = assets.tape_vault_attr[0..tile_count],
    .center = assets.tape_vault_center[0 .. 256 * 8],
};

pub const hot_aisle = Track{
    .name = "HOT AISLE",
    .league = &core,
    .map_packed = assets.hot_aisle_map,
    .attr = assets.hot_aisle_attr[0..tile_count],
    .center = assets.hot_aisle_center[0 .. 256 * 8],
};

pub const kernel_ring = Track{
    .name = "KERNEL RING",
    .league = &core,
    .map_packed = assets.kernel_ring_map,
    .attr = assets.kernel_ring_attr[0..tile_count],
    .center = assets.kernel_ring_center[0 .. 256 * 8],
};

pub const weights_loop = Track{
    .name = "WEIGHTS LOOP",
    .league = &core,
    .map_packed = assets.weights_loop_map,
    .attr = assets.weights_loop_attr[0..tile_count],
    .center = assets.weights_loop_center[0 .. 256 * 8],
};

/// Every track in league order: Edge (3), Spine (3), Core (3).
pub const tracks = [_]*const Track{
    &cold_aisle,     &substation_sprint, &exhaust_ridge,
    &fiber_backbone, &rack_row_7,        &tape_vault,
    &hot_aisle,      &kernel_ring,       &weights_loop,
};

/// A league for the menu: its display name and its three tracks in order.
pub const LeagueInfo = struct {
    name: []const u8,
    tracks: []const *const Track,
};

pub const leagues = [_]LeagueInfo{
    .{ .name = "EDGE", .tracks = tracks[0..3] },
    .{ .name = "SPINE", .tracks = tracks[3..6] },
    .{ .name = "CORE", .tracks = tracks[6..9] },
};

fn expect_league_well_formed(l: *const League) !void {
    // No tile texel uses palette index 0 (the fog colour).
    for (l.tiles) |p| try std.testing.expect(p != 0);
}

fn expect_track_well_formed(t: *const Track) !void {
    select(t);
    // Every centerline sample sits on a drivable tile, except over a hop gap.
    for (0..256) |i| {
        const s = t.sample(i);
        const a = t.attr_at(s.x, s.y);
        if (a == .off and s.flags & flag_hop != 0) continue;
        try std.testing.expect(a != .off and a != .rail);
    }
    try std.testing.expectEqual(Attr.start, t.attr_at(t.sample(0).x, t.sample(0).y));
}

test "cold aisle data is well formed" {
    try std.testing.expect(assets.cold_aisle_map.len < 8192);
    try std.testing.expectEqual(@as(usize, 256), assets.cold_aisle_attr.len);
    try std.testing.expectEqual(@as(usize, 2048), assets.cold_aisle_center.len);
    try std.testing.expectEqual(@as(usize, 16384), assets.edge_tiles.len);
    try std.testing.expectEqual(@as(usize, 512), assets.edge_pal.len);
    try std.testing.expectEqual(@as(usize, 12352), assets.edge_horizon.len);
    try expect_league_well_formed(&edge);
    try expect_track_well_formed(&cold_aisle);
}

test "every track and league is well formed" {
    try std.testing.expectEqual(@as(usize, 16384), assets.spine_tiles.len);
    try std.testing.expectEqual(@as(usize, 512), assets.spine_pal.len);
    try std.testing.expectEqual(@as(usize, 12352), assets.spine_horizon.len);
    try expect_league_well_formed(&spine);
    for ([_][]const u8{ assets.core_tiles, assets.core_pal, assets.core_horizon }, [_]usize{ 16384, 512, 12352 }) |f, n|
        try std.testing.expectEqual(n, f.len);
    try expect_league_well_formed(&core);
    for (tracks) |t| try expect_track_well_formed(t);
    for (leagues) |l| {
        try std.testing.expectEqual(@as(usize, 3), l.tracks.len);
        for (l.tracks) |t| try std.testing.expect(t.league == l.tracks[0].league);
    }
    try std.testing.expect(leagues[0].tracks[0] == &cold_aisle);
    try std.testing.expect(leagues[1].tracks[0].league == &spine);
    try std.testing.expectEqual(@as(usize, 3), leagues.len);
    try std.testing.expect(leagues[2].tracks[0] == &hot_aisle and leagues[2].tracks[2] == &weights_loop);
    try std.testing.expect(leagues[2].tracks[1].league == &core);
}

test "packed maps unpack the same twice, under 8 KB each" {
    const first = try std.testing.allocator.create([map_side * map_side]u8);
    defer std.testing.allocator.destroy(first);
    for (tracks) |t| {
        try std.testing.expect(t.map_packed.len < 8192);
        select(t);
        try std.testing.expect(current == t);
        first.* = map_ram;
        @memset(&map_ram, 0xAA);
        unpack_map(t.map_packed, &map_ram);
        try std.testing.expectEqualSlices(u8, first, &map_ram);
        // The map uses only named tiles: no tile index the attr table leaves
        // undefined past the hop gap set (120..255 are copies of tile 1).
        for (map_ram) |v| try std.testing.expect(v != 0 and v < 120);
    }
}

test "unpack_map decodes every op form" {
    // 128 literal bytes, a 2-byte-distance copy of the row above (128), a
    // 1-byte-distance copy of the row above, then runs of distance 1 to the
    // end (overlapping copies) and a one-byte literal tail.
    var src: [1024]u8 = undefined;
    var n: usize = 0;
    src[n] = 0x7F;
    n += 1;
    for (0..128) |k| src[n + k] = @intCast(k * 7 & 0xFF);
    n += 128;
    src[n..][0..3].* = .{ 0x80 | 125, 0x80, 127 };
    n += 3;
    src[n..][0..2].* = .{ 0x80 | 125, 127 };
    n += 2;
    var o: usize = 128 * 3;
    while (map_side * map_side - o > 130) : (o += 130) {
        src[n..][0..2].* = .{ 0xFF, 0 };
        n += 2;
    }
    const rest = map_side * map_side - o - 1;
    src[n..][0..2].* = .{ @intCast(0x80 | (rest - 3)), 0 };
    n += 2;
    src[n..][0..2].* = .{ 0, 42 };
    n += 2;
    var dst: [map_side * map_side]u8 = undefined;
    unpack_map(src[0..n], &dst);
    for (0..3) |row| for (0..128) |k| try std.testing.expectEqual(@as(u8, @intCast(k * 7 & 0xFF)), dst[row * 128 + k]);
    for (dst[128 * 3 .. dst.len - 1]) |v| try std.testing.expectEqual(dst[128 * 3 - 1], v);
    try std.testing.expectEqual(@as(u8, 42), dst[dst.len - 1]);
}
