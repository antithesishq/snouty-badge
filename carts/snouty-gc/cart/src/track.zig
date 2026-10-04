//! Forked from snouty-zero/cart/src/track.zig at f8f6962.
//! The league art and track data (PLAN.md "Generated data formats"), read
//! at run time. No comptime decoding.
//!
//! A `League` and a `Track` are runtime structs of slices: the built-in
//! ones point at the embedded `assets` files, and a track pack loaded into
//! a RAM buffer later (SPEC 19) can fill the same structs. Nothing selects
//! art at comptime: `select(t)` unpacks the track about to be raced into
//! the one RAM buffer `map_ram` (16 KB) and sets `current`; the renderer
//! takes its art pointers from the track in `render.set_track`. Every tile
//! lookup (`Track.tile_at`/`attr_at`, the floor renderer) reads `map_ram`,
//! so `select` must have run for the track being looked at.
const std = @import("std");
const assets = @import("assets");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");

pub const map_side = 128;
/// Tiles per league (SPEC 13.2): 128 x 64 bytes = 8 KB.
pub const tile_count = 128;
pub const tiles_bytes = tile_count * 64;
pub const pal_bytes = 256 * 2;
pub const horizon_bytes = 12352;
pub const center_bytes = 256 * 8;

/// Tile attributes (attr.bin values; tools/leagues.py A_*).
pub const Attr = enum(u8) {
    off = 0,
    surface = 1,
    /// Wreckage wall (Zero's rail).
    wall = 2,
    /// Zero's overclock pad; no GC tile uses it.
    reserved = 3,
    /// Coolant: grip falls to 0.97 (Zero's throttled zone).
    coolant = 4,
    /// Service bay: repairs armor from M2 (Zero's cold aisle).
    bay = 5,
    /// Exhaust vent (the Runoff, M3; Zero's hot spot).
    vent = 6,
    /// Ramp: airborne (Zero's hop).
    ramp = 7,
    start = 8,
    sector1 = 9,
    sector2 = 10,
    _,
};

pub const League = struct {
    name: []const u8,
    /// `tile_count` tiles x 64 bytes, each 8x8 row-major palette indices.
    tiles: []const u8,
    /// 256 x u16 RGB565 little-endian; entry 0 is the fog colour.
    pal: []const u8,
    /// Front 512x32 4 bpp, back 256x32 4 bpp, front palette 16 x u16, back palette 16 x u16.
    horizon: []const u8,

    pub fn pal_rgb565(self: *const League, i: usize) u16 {
        return std.mem.readInt(u16, self.pal[i * 2 ..][0..2], .little);
    }
    pub fn horizon_front_pal(self: *const League, i: usize) u16 {
        return std.mem.readInt(u16, self.horizon[8192 + 4096 + i * 2 ..][0..2], .little);
    }
    pub fn horizon_back_pal(self: *const League, i: usize) u16 {
        return std.mem.readInt(u16, self.horizon[8192 + 4096 + 32 + i * 2 ..][0..2], .little);
    }
};

/// Centerline sample `flags` bits (PLAN.md "Generated data formats").
pub const flag_wall: u8 = 1 << 0;
pub const flag_open: u8 = 1 << 1;
/// An RMA crate row across the track at this sample (M2; the generator's
/// `crates` feature sets it on one sample, the middle of its segment).
pub const flag_crates: u8 = 1 << 2;
pub const flag_coolant: u8 = 1 << 3;
pub const flag_bay: u8 = 1 << 4;
pub const flag_vent: u8 = 1 << 5;
/// On a ramp segment; the samples just past the ramp may sit over its pit
/// (attribute `off`), which a car crosses in the air.
pub const flag_ramp: u8 = 1 << 6;
pub const flag_hill: u8 = 1 << 7;

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
    /// `tile_count` attributes, one per tile index.
    attr: []const u8,
    /// 256 centerline samples x 8 bytes.
    center: []const u8,

    pub fn sample(self: *const Track, i: usize) Sample {
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
    pub fn tile_at(self: *const Track, wx: i32, wy: i32) u8 {
        _ = self;
        const tx: usize = @intCast((wx >> 3) & (map_side - 1));
        const ty: usize = @intCast((wy >> 3) & (map_side - 1));
        return map_ram[ty * map_side + tx];
    }

    pub fn attr_at(self: *const Track, wx: i32, wy: i32) Attr {
        return @fromBackingInt(self.attr[self.tile_at(wx, wy) & (tile_count - 1)]);
    }
};

/// The selected track's unpacked map, map[y][x] (filled by `select`).
pub var map_ram: [map_side * map_side]u8 = undefined;
/// The track whose map is in `map_ram`. Meaningful once `select` has run.
pub var current: *const Track = &landfill_loop;

/// An RMA crate spawn (SPEC 3.3), world px. `World.crates[k]` is spawn k's
/// respawn timer (0 = the crate is there).
pub const CrateSpot = struct { x: u16, y: u16 };
/// The selected track's crate spawns, `crate_spots[0..crate_n]`, in
/// centerline order, each row left to right across the direction of travel
/// (filled by `select`, like `map_ram`: a cache of the track data).
pub var crate_spots: [world.crate_max]CrateSpot = undefined;
pub var crate_n: u8 = 0;

/// Unpack `t`'s map into `map_ram`, find its crate spawns and make it
/// `current`. Call at race start (sim.reset), before any tile lookup on
/// `t`; ~16 K byte copies.
pub fn select(t: *const Track) void {
    unpack_map(t.map_packed, &map_ram);
    crate_n = find_crates(t, &crate_spots);
    current = t;
}

/// The crate spawns of `t`: a row at every sample flagged `flag_crates`,
/// 4 crates where the half width is at least `tuning.crate_row4_half`, else
/// 3, `tuning.crate_gap` px apart and centred on the line. At most
/// `world.crate_max` (the generator checks the tracks stay under it).
pub fn find_crates(t: *const Track, out: *[world.crate_max]CrateSpot) u8 {
    var n: usize = 0;
    for (0..256) |i| {
        const s = t.sample(i);
        if (s.flags & flag_crates == 0) continue;
        const count: i32 = if (s.half >= tuning.crate_row4_half) 4 else 3;
        const rx = -fixed.sin(s.tangent);
        const ry = fixed.cos(s.tangent);
        var k: i32 = 0;
        while (k < count and n < out.len) : (k += 1) {
            const lat = @divTrunc((2 * k - (count - 1)) * tuning.crate_gap, 2);
            out[n] = .{
                .x = @intCast((@as(i32, s.x) + ((rx * lat) >> fixed.Q)) & 1023),
                .y = @intCast((@as(i32, s.y) + ((ry * lat) >> fixed.Q)) & 1023),
            };
            n += 1;
        }
    }
    return @intCast(n);
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

// --- The built-in leagues and tracks (embedded) -----------------------------

pub const dumps = League{
    .name = "THE DUMPS",
    .tiles = assets.dumps_tiles,
    .pal = assets.dumps_pal,
    .horizon = assets.dumps_horizon,
};

pub const landfill_loop = Track{
    .name = "LANDFILL LOOP",
    .league = &dumps,
    .map_packed = assets.landfill_loop_map,
    .attr = assets.landfill_loop_attr,
    .center = assets.landfill_loop_center,
};

/// Every track; `World.track` indexes this table.
pub const tracks = [_]*const Track{&landfill_loop};

fn expect_league_well_formed(l: *const League) !void {
    try std.testing.expectEqual(@as(usize, tiles_bytes), l.tiles.len);
    try std.testing.expectEqual(@as(usize, pal_bytes), l.pal.len);
    try std.testing.expectEqual(@as(usize, horizon_bytes), l.horizon.len);
    // No tile texel uses palette index 0 (the fog colour).
    for (l.tiles) |p| try std.testing.expect(p != 0);
}

fn expect_track_well_formed(t: *const Track) !void {
    try std.testing.expectEqual(@as(usize, tile_count), t.attr.len);
    try std.testing.expectEqual(@as(usize, center_bytes), t.center.len);
    try std.testing.expect(t.map_packed.len < 8192);
    select(t);
    // Every tile index is in the set; every centerline sample sits on a
    // drivable tile, except over a ramp pit.
    for (map_ram) |v| try std.testing.expect(v != 0 and v < tile_count);
    for (0..256) |i| {
        const s = t.sample(i);
        const a = t.attr_at(s.x, s.y);
        if (a == .off and s.flags & flag_ramp != 0) continue;
        try std.testing.expect(a != .off and a != .wall);
    }
    try std.testing.expectEqual(Attr.start, t.attr_at(t.sample(0).x, t.sample(0).y));
}

test "every track and league is well formed" {
    for (tracks) |t| {
        try expect_league_well_formed(t.league);
        try expect_track_well_formed(t);
    }
}

test "attribute lookups at known points of Landfill Loop" {
    const t = &landfill_loop;
    select(t);
    // The start line under sample 0, board road a little past it, sand far
    // off the track (the map's corner), the wall beside the top straight.
    const s0 = t.sample(0);
    try std.testing.expectEqual(Attr.start, t.attr_at(s0.x, s0.y));
    const s10 = t.sample(10);
    try std.testing.expectEqual(Attr.surface, t.attr_at(s10.x, s10.y));
    try std.testing.expectEqual(Attr.off, t.attr_at(4, 4));
    var wall_found = false;
    var dy: i32 = 0;
    while (dy < 120 and !wall_found) : (dy += 2) wall_found = t.attr_at(s10.x, @as(i32, s10.y) + dy) == .wall;
    try std.testing.expect(wall_found);
    // The coolant spill and the ramp exist somewhere on the map.
    var coolant = false;
    var ramp = false;
    for (map_ram) |v| {
        const a: Attr = @fromBackingInt(t.attr[v]);
        coolant = coolant or a == .coolant;
        ramp = ramp or a == .ramp;
    }
    try std.testing.expect(coolant and ramp);
}

test "packed maps unpack the same twice" {
    const first = try std.testing.allocator.create([map_side * map_side]u8);
    defer std.testing.allocator.destroy(first);
    for (tracks) |t| {
        select(t);
        try std.testing.expect(current == t);
        first.* = map_ram;
        @memset(&map_ram, 0xAA);
        unpack_map(t.map_packed, &map_ram);
        try std.testing.expectEqualSlices(u8, first, &map_ram);
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
