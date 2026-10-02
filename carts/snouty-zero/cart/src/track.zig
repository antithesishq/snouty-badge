//! The embedded league art and track data (PLAN.md "Generated data
//! formats"), read at run time from the `assets` module. No comptime decoding.
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
    /// 128x128 tile indices, map[y][x].
    map: *const [map_side * map_side]u8,
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

    /// Tile index at world pixel (wx, wy), wrapping.
    pub fn tile_at(self: Track, wx: i32, wy: i32) u8 {
        const tx: usize = @intCast((wx >> 3) & (map_side - 1));
        const ty: usize = @intCast((wy >> 3) & (map_side - 1));
        return self.map[ty * map_side + tx];
    }

    pub fn attr_at(self: Track, wx: i32, wy: i32) Attr {
        return @fromBackingInt(@intCast(self.attr[self.tile_at(wx, wy)]));
    }
};

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

pub const cold_aisle = Track{
    .name = "COLD AISLE",
    .league = &edge,
    .map = assets.cold_aisle_map[0 .. map_side * map_side],
    .attr = assets.cold_aisle_attr[0..tile_count],
    .center = assets.cold_aisle_center[0 .. 256 * 8],
};

pub const substation_sprint = Track{
    .name = "SUBSTATION SPRINT",
    .league = &edge,
    .map = assets.substation_sprint_map[0 .. map_side * map_side],
    .attr = assets.substation_sprint_attr[0..tile_count],
    .center = assets.substation_sprint_center[0 .. 256 * 8],
};

pub const exhaust_ridge = Track{
    .name = "EXHAUST RIDGE",
    .league = &edge,
    .map = assets.exhaust_ridge_map[0 .. map_side * map_side],
    .attr = assets.exhaust_ridge_attr[0..tile_count],
    .center = assets.exhaust_ridge_center[0 .. 256 * 8],
};

pub const fiber_backbone = Track{
    .name = "FIBER BACKBONE",
    .league = &spine,
    .map = assets.fiber_backbone_map[0 .. map_side * map_side],
    .attr = assets.fiber_backbone_attr[0..tile_count],
    .center = assets.fiber_backbone_center[0 .. 256 * 8],
};

pub const rack_row_7 = Track{
    .name = "RACK ROW 7",
    .league = &spine,
    .map = assets.rack_row_7_map[0 .. map_side * map_side],
    .attr = assets.rack_row_7_attr[0..tile_count],
    .center = assets.rack_row_7_center[0 .. 256 * 8],
};

pub const tape_vault = Track{
    .name = "TAPE VAULT",
    .league = &spine,
    .map = assets.tape_vault_map[0 .. map_side * map_side],
    .attr = assets.tape_vault_attr[0..tile_count],
    .center = assets.tape_vault_center[0 .. 256 * 8],
};

/// Every track in league order: Edge (3), then Spine (3).
pub const tracks = [_]*const Track{ &cold_aisle, &substation_sprint, &exhaust_ridge, &fiber_backbone, &rack_row_7, &tape_vault };

/// A league for the menu: its display name and its three tracks in order.
pub const LeagueInfo = struct {
    name: []const u8,
    tracks: []const *const Track,
};

pub const leagues = [_]LeagueInfo{
    .{ .name = "EDGE", .tracks = tracks[0..3] },
    .{ .name = "SPINE", .tracks = tracks[3..6] },
};

fn expect_league_well_formed(l: *const League) !void {
    // No tile texel uses palette index 0 (the fog colour).
    for (l.tiles) |p| try std.testing.expect(p != 0);
}

fn expect_track_well_formed(t: *const Track) !void {
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
    try std.testing.expectEqual(@as(usize, 16384), assets.cold_aisle_map.len);
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
    for (tracks) |t| try expect_track_well_formed(t);
    for (leagues) |l| {
        try std.testing.expectEqual(@as(usize, 3), l.tracks.len);
        for (l.tracks) |t| try std.testing.expect(t.league == l.tracks[0].league);
    }
    try std.testing.expect(leagues[0].tracks[0] == &cold_aisle);
    try std.testing.expect(leagues[1].tracks[0].league == &spine);
}
