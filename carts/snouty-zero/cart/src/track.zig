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

pub const cold_aisle = Track{
    .name = "COLD AISLE",
    .league = &edge,
    .map = assets.cold_aisle_map[0 .. map_side * map_side],
    .attr = assets.cold_aisle_attr[0..tile_count],
    .center = assets.cold_aisle_center[0 .. 256 * 8],
};

pub const tracks = [_]*const Track{&cold_aisle};

test "cold aisle data is well formed" {
    try std.testing.expectEqual(@as(usize, 16384), assets.cold_aisle_map.len);
    try std.testing.expectEqual(@as(usize, 256), assets.cold_aisle_attr.len);
    try std.testing.expectEqual(@as(usize, 2048), assets.cold_aisle_center.len);
    try std.testing.expectEqual(@as(usize, 16384), assets.edge_tiles.len);
    try std.testing.expectEqual(@as(usize, 512), assets.edge_pal.len);
    try std.testing.expectEqual(@as(usize, 12352), assets.edge_horizon.len);
    // Every centerline sample sits on a drivable tile and no tile uses palette 0.
    for (0..256) |i| {
        const s = cold_aisle.sample(i);
        const a = cold_aisle.attr_at(s.x, s.y);
        try std.testing.expect(a != .off and a != .rail);
    }
    for (assets.edge_tiles) |p| try std.testing.expect(p != 0);
    try std.testing.expectEqual(Attr.start, cold_aisle.attr_at(cold_aisle.sample(0).x, cold_aisle.sample(0).y));
}
