//! Forked from snouty-zero/cart/src/track.zig at f8f6962.
//! The league art and track data (PLAN.md "Generated data formats"), read
//! at run time. No comptime decoding.
//!
//! A `League` and a `Track` are runtime structs of slices: the built-in
//! ones point at the embedded `gen/tracks/` files, and a track pack loaded into
//! a RAM buffer later (SPEC 19) can fill the same structs. Nothing selects
//! art at comptime: `select(t)` unpacks the track about to be raced into
//! the one RAM buffer `map_ram` (16 KB) and sets `current`; the renderer
//! takes its art pointers from the track in `render.set_track`. Every tile
//! lookup (`Track.tile_at`/`attr_at`, the floor renderer) reads `map_ram`,
//! so `select` must have run for the track being looked at.
const std = @import("std");
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
    /// Laps of a QUICK RACE here (the menus' track table; `World.laps`).
    laps: u8 = tuning.laps,
    /// The packed 128x128 map (`unpack_map` gives map[y][x]); read it through
    /// `select` + `map_ram`, never directly.
    map_packed: []const u8,
    /// `tile_count` attributes, one per tile index.
    attr: []const u8,
    /// 256 centerline samples x 8 bytes.
    center: []const u8,
    /// Hazard records (`hazard_record` bytes each, at most
    /// `world.hazard_max`; `parse_hazards`): the generic kinds of SPEC
    /// 19.4 with this track's numbers. Empty for a track without hazards.
    feat: []const u8 = &.{},

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

/// A track hazard as the sim runs it (SPEC 19.4), decoded from one
/// `Track.feat` record (all positions world px, speeds Q16 px/tick):
///
/// - `blast` (exhaust vent): a lane from the mouth (x0, y0) to (x1, y1),
///   `size` px either side of it. The cycle of `period` ticks is idle, then
///   `warn` ticks of warning, then `on` ticks firing; a car whose centre is
///   in the lane while it fires takes `damage` once a firing and a shove of
///   `push` along the lane.
/// - `mover` (the Sweeper): a body of radius `size` shuttling between end A
///   (x0, y0) and end B (x1, y1) at `speed`. Each half of the `period` waits
///   at one end, warns for `warn` ticks, then crosses to the other end in
///   `travel` ticks (derived); a car within `size + car_radius` of it while
///   it crosses takes `damage` once a crossing and a shove of `push` away
///   from it plus the mover's own velocity.
/// - `turret`, `crust`: reserved (decoded, never run).
///
/// `phase` is the cycle tick at GO, so hazards on one track can be staggered.
pub const HazardSpec = struct {
    kind: world.HazardKind = .none,
    warn: u16 = 0,
    size: i32 = 0,
    damage: u8 = 0,
    x0: i32 = 0,
    y0: i32 = 0,
    x1: i32 = 0,
    y1: i32 = 0,
    period: u16 = 1,
    on: u16 = 0,
    phase: u16 = 0,
    push: i32 = 0,
    speed: i32 = 0,
    /// Derived: the length from end A (the mouth) to end B in px, the unit
    /// direction A -> B (Q16), and for a mover the crossing time in ticks.
    len: i32 = 0,
    ux: i32 = 0,
    uy: i32 = 0,
    travel: u16 = 0,
};

/// Bytes per `Track.feat` record (little endian): kind u8, warn u8, size
/// u8, damage u8, x0 u16, y0 u16, x1 u16, y1 u16, period u16, on u16,
/// phase u16, push u8 (1/32 px/tick), speed u8 (1/32 px/tick).
/// tools/build_tracks.py `hazard_bytes` writes them and checks the cycles fit.
pub const hazard_record = 20;

/// The selected track's hazards, `hazard_specs[0..hazard_n]`, drive
/// `World.hazards[0..hazard_n]` (filled by `select`, like `crate_spots`).
pub var hazard_specs: [world.hazard_max]HazardSpec = @splat(.{});
pub var hazard_n: u8 = 0;

/// Decode `t.feat` into `out`; returns the count (at most
/// `world.hazard_max`; a short trailing record is ignored).
pub fn parse_hazards(t: *const Track, out: *[world.hazard_max]HazardSpec) u8 {
    var n: usize = 0;
    while (n < out.len and (n + 1) * hazard_record <= t.feat.len) : (n += 1) {
        const b = t.feat[n * hazard_record ..][0..hazard_record];
        const rd = struct {
            fn u(bytes: []const u8, at: usize) u16 {
                return std.mem.readInt(u16, bytes[at..][0..2], .little);
            }
        }.u;
        var h = HazardSpec{
            .kind = if (b[0] <= @backingInt(world.HazardKind.crust)) @fromBackingInt(b[0]) else .none,
            .warn = b[1],
            .size = b[2],
            .damage = b[3],
            .x0 = rd(b, 4),
            .y0 = rd(b, 6),
            .x1 = rd(b, 8),
            .y1 = rd(b, 10),
            .period = @max(1, rd(b, 12)),
            .on = rd(b, 14),
            .phase = rd(b, 16),
            .push = @as(i32, b[18]) << (fixed.Q - 5),
            .speed = @as(i32, b[19]) << (fixed.Q - 5),
        };
        const dx = wrap_px(h.x1 - h.x0);
        const dy = wrap_px(h.y1 - h.y0);
        h.len = @intCast(fixed.isqrt(@intCast(dx * dx + dy * dy)));
        if (h.len > 0) {
            h.ux = @divTrunc(dx << fixed.Q, h.len);
            h.uy = @divTrunc(dy << fixed.Q, h.len);
        }
        if (h.speed > 0) h.travel = @intCast(@min(65535, @divTrunc((h.len << fixed.Q) + h.speed - 1, h.speed)));
        out[n] = h;
    }
    for (out[n..]) |*h| h.* = .{};
    return @intCast(n);
}

inline fn wrap_px(d: i32) i32 {
    return ((d + 512) & 1023) - 512;
}

/// Unpack `t`'s map into `map_ram`, find its crate spawns and hazards and
/// make it `current`. Call at race start (sim.reset), before any tile
/// lookup on `t`; ~16 K byte copies.
pub fn select(t: *const Track) void {
    unpack_map(t.map_packed, &map_ram);
    crate_n = find_crates(t, &crate_spots);
    hazard_n = parse_hazards(t, &hazard_specs);
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
//
// tools/build_tracks.py writes the data into cart/src/gen/tracks/ (since
// M3: embedded here with @embedFile, so a new track needs no build.zig
// entry; plain byte slices, no comptime decoding, the Mac OOM rule).

pub const dumps = League{
    .name = "THE DUMPS",
    .tiles = @embedFile("gen/tracks/dumps_tiles.bin"),
    .pal = @embedFile("gen/tracks/dumps_pal.bin"),
    .horizon = @embedFile("gen/tracks/dumps_horizon.bin"),
};

pub const runoff = League{
    .name = "THE RUNOFF",
    .tiles = @embedFile("gen/tracks/runoff_tiles.bin"),
    .pal = @embedFile("gen/tracks/runoff_pal.bin"),
    .horizon = @embedFile("gen/tracks/runoff_horizon.bin"),
};

const dumps_attr = @embedFile("gen/tracks/dumps_attr.bin");
const runoff_attr = @embedFile("gen/tracks/runoff_attr.bin");

pub const landfill_loop = Track{
    .name = "LANDFILL LOOP",
    .league = &dumps,
    .map_packed = @embedFile("gen/tracks/landfill_loop_map.bin"),
    .attr = dumps_attr,
    .center = @embedFile("gen/tracks/landfill_loop_center.bin"),
    .feat = @embedFile("gen/tracks/landfill_loop_feat.bin"),
};

pub const monitor_dunes = Track{
    .name = "MONITOR DUNES",
    .league = &dumps,
    .map_packed = @embedFile("gen/tracks/monitor_dunes_map.bin"),
    .attr = dumps_attr,
    .center = @embedFile("gen/tracks/monitor_dunes_center.bin"),
    .feat = @embedFile("gen/tracks/monitor_dunes_feat.bin"),
};

pub const cathode_flats = Track{
    .name = "CATHODE FLATS",
    .league = &dumps,
    .map_packed = @embedFile("gen/tracks/cathode_flats_map.bin"),
    .attr = dumps_attr,
    .center = @embedFile("gen/tracks/cathode_flats_center.bin"),
    .feat = @embedFile("gen/tracks/cathode_flats_feat.bin"),
};

pub const salt_pan_sprint = Track{
    .name = "SALT PAN SPRINT",
    .league = &runoff,
    .map_packed = @embedFile("gen/tracks/salt_pan_sprint_map.bin"),
    .attr = runoff_attr,
    .center = @embedFile("gen/tracks/salt_pan_sprint_center.bin"),
    .feat = @embedFile("gen/tracks/salt_pan_sprint_feat.bin"),
};

pub const outflow_canyon = Track{
    .name = "OUTFLOW CANYON",
    .league = &runoff,
    .map_packed = @embedFile("gen/tracks/outflow_canyon_map.bin"),
    .attr = runoff_attr,
    .center = @embedFile("gen/tracks/outflow_canyon_center.bin"),
    .feat = @embedFile("gen/tracks/outflow_canyon_feat.bin"),
};

pub const coolant_basin = Track{
    .name = "COOLANT BASIN",
    .league = &runoff,
    .map_packed = @embedFile("gen/tracks/coolant_basin_map.bin"),
    .attr = runoff_attr,
    .center = @embedFile("gen/tracks/coolant_basin_center.bin"),
    .feat = @embedFile("gen/tracks/coolant_basin_feat.bin"),
};

/// Every track in menu rotation order (league by league, SPEC 3.2);
/// `World.track` and `Setup.track` index this table. The menus read
/// `name`, `league.name` and `laps` from it.
pub const tracks = [_]*const Track{
    &landfill_loop,   &monitor_dunes,  &cathode_flats,
    &salt_pan_sprint, &outflow_canyon, &coolant_basin,
};

/// The built-in leagues in order (CIRCUIT plays them in this order); each
/// league's tracks are the `tracks_per_league` entries of `tracks` from
/// its index times that.
pub const leagues = [_]*const League{ &dumps, &runoff };
pub const tracks_per_league = 3;

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
