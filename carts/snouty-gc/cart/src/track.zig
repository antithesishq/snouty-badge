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
/// 256 centerline samples x `sample_bytes`.
pub const sample_bytes = 6;
pub const center_bytes = 256 * sample_bytes;

/// Tile attributes (attr.bin values; tools/leagues.py A_*).
pub const Attr = enum(u8) {
    off = 0,
    surface = 1,
    /// Wreckage wall (Zero's rail).
    wall = 2,
    /// M6, the BATTLE arena: a kicker, a long one-way ramp
    /// (`tuning.kicker_ticks` airborne; Zero's unused overclock pad value).
    /// Like `jump` it launches only a car moving the way the tile faces
    /// (`facing`).
    kicker = 3,
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
    /// M6, the BATTLE arena: a one-way ramp of a race ramp's air time (the
    /// gap jumps and the wall kickers).
    jump = 11,
    /// M7 (track packs, docs/PACKS.md): breakable crust, tiles
    /// `crust_tile` .. + 2. Drivable until its region (a crust hazard)
    /// breaks; then a car on the ground over it falls, as into a pit.
    crust = 12,
    _,
};

/// The crust tiles (intact, cracked, broken; all attribute `crust`).
pub const crust_tile: u8 = 121;

/// Tile indices of the arena's one-way ramps (tools/leagues.py KICKER,
/// JUMP): base + direction (0 E, 1 S, 2 W, 3 N).
pub const kicker_tile: u8 = 64;
pub const jump_tile: u8 = 92;

/// The way a `kicker` or `jump` tile faces, from its tile index: a unit
/// vector in whole px (x, y), y down.
pub fn facing(tile: u8) [2]i32 {
    const base = if (tile >= jump_tile) jump_tile else kicker_tile;
    return switch ((tile -% base) & 3) {
        0 => .{ 1, 0 },
        1 => .{ 0, 1 },
        2 => .{ -1, 0 },
        else => .{ 0, -1 },
    };
}

/// A league's art. The tiles and the horizon are stored packed (the map
/// format, `unpack`) and unpacked into one shared RAM slot (`art_tiles`,
/// `art_horizon`) when a track of the league is selected, which is the
/// track-pack design of SPEC 19.2 (one RAM slot, the renderer reading
/// through the same slices) and saves about 12 KB of the RAM cart over
/// two raw leagues (M3). `tiles` and `horizon` are the slot: they hold
/// this league's art only after `select` (or `load_art`) ran for it, so
/// call `track.select(t)` before `render.set_track(t)`.
pub const League = struct {
    name: []const u8,
    /// Packed `tiles` and `horizon` (tools/build_tracks.py).
    tiles_packed: []const u8,
    horizon_packed: []const u8,
    /// `tile_count` tiles x 64 bytes, each 8x8 row-major palette indices
    /// (the RAM slot).
    tiles: []const u8 = &art_tiles,
    /// 256 x u16 RGB565 little-endian; entry 0 is the fog colour.
    pal: []const u8,
    /// Front 512x32 4 bpp, back 256x32 4 bpp, front palette 16 x u16, back
    /// palette 16 x u16 (the RAM slot).
    horizon: []const u8 = &art_horizon,

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
    /// 256 centerline samples x `sample_bytes` (`sample`).
    center: []const u8,
    /// Hazard records (`hazard_record` bytes each, at most
    /// `world.hazard_max`; `parse_hazards`): the generic kinds of SPEC
    /// 19.4 with this track's numbers. Empty for a track without hazards.
    feat: []const u8 = &.{},
    /// M6: a BATTLE arena's blob (`parse_arena`: spawn pads, crate pads,
    /// the navigation field); empty for a race track. An arena's `center`
    /// is a ring round its outer lanes for the race code that reads one;
    /// battle never ranks or respawns by it.
    arena: []const u8 = &.{},
    /// M7: scenery props, `prop_record` bytes each (cell, radius, x, y;
    /// `parse_props`); empty for the built-in tracks. `cell` indexes
    /// `sheet`'s strip.
    props: []const u8 = &.{},
    /// M7: the props sheet (a pack's cells this track uses, as one strip),
    /// null for a track without one.
    sheet: ?*const PropSheet = null,

    /// Sample i (wrapping). Stored in 6 bytes (M3, the RAM budget): a u32
    /// with x in bits 0..9, y in 10..19 and the tangent's top 12 bits in
    /// 20..31 (so the tangent is a multiple of 16 turn units), then half
    /// and flags.
    pub fn sample(self: *const Track, i: usize) Sample {
        const b = self.center[(i & 255) * sample_bytes ..][0..sample_bytes];
        const v = std.mem.readInt(u32, b[0..4], .little);
        return .{
            .x = @intCast(v & 1023),
            .y = @intCast((v >> 10) & 1023),
            .tangent = @intCast((v >> 20) << 4),
            .half = b[4],
            .flags = b[5],
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

/// M7: a props sheet in RAM (pack.zig fills it): `cells` cells of
/// `cell_w` x `cell_h` side by side in one strip `cells * cell_w` px wide,
/// 4 bpp, the left pixel in the low nibble (sprites.zig `Sheet`), and its
/// 16-entry RGB565 palette (entry 0 transparent).
pub const PropSheet = struct {
    bytes: []const u8 = &.{},
    cells: u8 = 0,
    cell_w: u8 = 0,
    cell_h: u8 = 0,
    pal: []const u8 = &.{},
};

/// A scenery prop (SPEC 19.3) as the sim and the depth list read it: its
/// foot at (x, y) world px, a solid circle of `radius` px (0: decoration),
/// drawn with `cell` of the track's `sheet`.
pub const Prop = struct { x: u16 = 0, y: u16 = 0, cell: u8 = 0, radius: u8 = 0 };
pub const prop_max = 24;
pub const prop_record = 6;
/// The selected track's props (filled by `select`, like `crate_spots`).
pub var props: [prop_max]Prop = @splat(.{});
pub var prop_n: u8 = 0;
/// The largest solid radius among them (0: none; the sim skips the test).
pub var prop_reach: u8 = 0;

/// Decode `t.props` into `out`; returns the count.
pub fn parse_props(t: *const Track, out: *[prop_max]Prop) u8 {
    var n: usize = 0;
    while (n < out.len and (n + 1) * prop_record <= t.props.len) : (n += 1) {
        const b = t.props[n * prop_record ..][0..prop_record];
        out[n] = .{ .cell = b[0], .radius = b[1], .x = std.mem.readInt(u16, b[2..4], .little) & 1023, .y = std.mem.readInt(u16, b[4..6], .little) & 1023 };
    }
    return @intCast(n);
}

// --- M7 track packs (docs/PACKS.md): the loaded pack track ----------------
//
// A pack track runs through the same `League` / `Track` slices as a
// built-in one: pack.zig loads its art into `art_tiles` / `art_horizon`,
// its map into `map_ram`, and everything else into its own slot, then
// points `pack_league` and `pack_track` at them. `Setup.track` and
// `World.track` values from `pack_base` up mean "the loaded pack track"
// (`sim.table_of`); which pack and track is the loader's (and the link
// rules'), not the World's.

pub const pack_base: u8 = 0x80;
pub var pack_league: League = .{ .name = "", .tiles_packed = &.{}, .horizon_packed = &.{}, .pal = @embedFile("gen/tracks/dumps_pal.bin") };
pub var pack_track: Track = .{ .name = "", .league = &pack_league, .map_packed = &.{}, .attr = dumps_attr, .center = @embedFile("gen/tracks/landfill_loop_center.bin") };
/// The track whose map is in `map_ram` (null: none, or a failed load).
pub var map_owner: ?*const Track = null;
/// pack.zig: unpack the loaded pack track's art and map into the slots
/// again (after a built-in track used them); false if the drive no longer
/// gives the same pack.
pub var pack_reload: ?*const fn () bool = null;

/// M7, breakable crust: show each crust region as its World state says
/// (render side, once a frame: intact `crust_tile`, cracked + 1, broken
/// + 2). Rewrites only crust tiles in `map_ram`, which all share the
/// attribute `crust`, so nothing the sim reads changes.
pub fn crust_look(states: []const world.Hazard) void {
    for (hazard_specs[0..hazard_n], 0..) |*h, k| {
        if (h.kind != .crust or k >= states.len) continue;
        const want: u8 = crust_tile + switch (states[k].state) {
            .idle => @as(u8, 0),
            .warn => 1,
            .active => 2,
        };
        if (crust_shown[k] == want) continue;
        crust_shown[k] = want;
        const x0: usize = @intCast(@max(0, h.x0) >> 3);
        const y0: usize = @intCast(@max(0, h.y0) >> 3);
        const x1: usize = @min(map_side, @as(usize, @intCast(@max(0, h.x1))) >> 3);
        const y1: usize = @min(map_side, @as(usize, @intCast(@max(0, h.y1))) >> 3);
        var y = y0;
        while (y < y1) : (y += 1) {
            for (map_ram[y * map_side + x0 .. y * map_side + @max(x0, x1)]) |*v| {
                if (v.* >= crust_tile and v.* < crust_tile + 3) v.* = want;
            }
        }
    }
}
var crust_shown: [world.hazard_max]u8 = @splat(0);

/// The selected track's unpacked map, map[y][x] (filled by `select`).
pub var map_ram: [map_side * map_side]u8 = undefined;
/// The RAM slot for the active league's art (`League.tiles`, `.horizon`)
/// and the league whose art it holds.
pub var art_tiles: [tiles_bytes]u8 = undefined;
pub var art_horizon: [horizon_bytes]u8 = undefined;
pub var art_league: ?*const League = null;

/// Unpack `l`'s tiles and horizon into the RAM slot unless they are there
/// already (~20 K byte copies when the league changes).
pub fn load_art(l: *const League) void {
    if (art_league == l) return;
    unpack(l.tiles_packed, &art_tiles);
    unpack(l.horizon_packed, &art_horizon);
    art_league = l;
}
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

/// M5: the selected track's cycle chips (SPEC 9.1), world px, in
/// centerline order (filled by `select`, like `crate_spots`): bit k of
/// `World.chips` is `chip_spots[k]`.
pub var chip_spots: [world.chip_max]CrateSpot = undefined;
pub var chip_n: u8 = 0;

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
/// - `crust` (M7): a breakable crust region, the whole-tile rectangle (x0,
///   y0) to (x1, y1) (exclusive). The first touch of a car on the ground
///   on one of its crust tiles cracks it; `warn` ticks later it breaks and
///   stays broken `period` ticks, a pit for the cars on it (hazards.zig).
/// - `turret`: reserved (decoded, never run; a pack with one is refused).
///
/// `phase` is the cycle tick at GO, so hazards on one track can be staggered.
pub const HazardSpec = struct {
    kind: world.HazardKind = .none,
    /// M7: a mover drawn with its track's props cell `sprite - 1` (feat
    /// byte 0 bits 4..7; 0: the cart's Sweeper).
    sprite: u8 = 0,
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

// --- BATTLE arenas (M6, SPEC 8.3) ----------------------------------------------
//
// The arena blob (tools/build_arena.py writes it), little endian:
//   header 8 bytes: spawn_n, pad_n, node_n, cell_shift (32 px cells: 5),
//                   grid (cells a side: 32), 1 (the ground table is
//                   there), 2 zero bytes
//   spawn_n x 6:    x u16, y u16 (world px, the pad's centre), heading u16
//   pad_n x 4:      x u16, y u16 (an RMA crate pad's centre)
//   node_n x 6:     x u16, y u16, jump u8 (the node this one jumps to over
//                   a kicker or jump, `no_node` none), flags u8 (`node_bay`,
//                   `node_jump`; bits 4..7 the jump's run-up speed in 1/4
//                   px/tick, `Node.need`)
//   node_n^2:       next hop, next[from * node_n + to] (`no_node` when from
//                   == to)
//   node_n^2:       the same over the ground only (no jump edges)
//   grid^2:         cells[cy * grid + cx], the node to head for from that
//                   cell (the nearest with a clear ground line), `no_node`
//                   outside the arena

/// Navigation nodes an arena may have, spawn pads, and "no node".
pub const nav_max = 48;
pub const spawn_max = 8;
pub const no_node: u8 = 0xFF;
/// Node flags: a service bay; the approach to a jump (`Node.jump`).
pub const node_bay: u8 = 1;
pub const node_jump: u8 = 2;

pub const Spawn = struct { x: u16 = 0, y: u16 = 0, heading: u16 = 0 };
pub const Node = struct {
    x: u16 = 0,
    y: u16 = 0,
    jump: u8 = no_node,
    flags: u8 = 0,

    /// The run-up speed this node's jump needs, Q16 px/tick (0: any).
    pub fn need(self: Node) i32 {
        return @as(i32, self.flags >> 4) << (fixed.Q - 2);
    }
};

/// The selected arena's data (filled by `select`, like `crate_spots`; empty
/// for a race track). The hunter AI and the KERNEL PANIC packet route over
/// the nodes: from node a toward node b the next node is `hop(a, b)`; a
/// world point's node to head for is `cell_node(x, y)`.
pub const Arena = struct {
    spawn_n: u8 = 0,
    spawns: [spawn_max]Spawn = @splat(.{}),
    node_n: u8 = 0,
    nodes: [nav_max]Node = @splat(.{}),
    /// The next-hop tables (with the jumps, and over the ground only) and
    /// the cell grid (slices of the track data).
    next: []const u8 = &.{},
    ground: []const u8 = &.{},
    cells: []const u8 = &.{},
    cell_shift: u5 = 5,
    grid: u8 = 0,

    /// The node to head for from world px (x, y) (wrapping), `no_node`
    /// outside the arena or with no arena.
    pub fn cell_node(self: *const Arena, x: i32, y: i32) u8 {
        if (self.grid == 0) return no_node;
        const g: i32 = self.grid;
        const cx = (x & 1023) >> self.cell_shift;
        const cy = (y & 1023) >> self.cell_shift;
        if (cx >= g or cy >= g) return no_node;
        return self.cells[@intCast(cy * g + cx)];
    }

    /// The node after `from` on the way to `to` (`to` when adjacent,
    /// `no_node` when from == to or either is out of range).
    pub fn hop(self: *const Arena, from: u8, to: u8) u8 {
        if (from >= self.node_n or to >= self.node_n) return no_node;
        return self.next[@as(usize, from) * self.node_n + to];
    }

    /// `hop` over the ground only (no jump edges).
    pub fn ground_hop(self: *const Arena, from: u8, to: u8) u8 {
        if (from >= self.node_n or to >= self.node_n) return no_node;
        return self.ground[@as(usize, from) * self.node_n + to];
    }
};
pub var arena: Arena = .{};

/// Decode `t.arena` into `out` and its crate pads into `pads[0..pad_n]`;
/// false for a track without one (or a blob shorter than its header says,
/// or with more nodes or spawns than the caches hold: the generator keeps
/// within them).
pub fn parse_arena(t: *const Track, out: *Arena, pads: *[world.crate_max]CrateSpot, pad_n: *u8) bool {
    out.* = .{};
    const b = t.arena;
    if (b.len < 8) return false;
    const sn: usize = b[0];
    const pn: usize = b[1];
    const nn: usize = b[2];
    const grid: usize = b[4];
    if (sn > spawn_max or pn > world.crate_max or nn > nav_max) return false;
    const rd = struct {
        fn u(bytes: []const u8, at: usize) u16 {
            return std.mem.readInt(u16, bytes[at..][0..2], .little);
        }
    }.u;
    var at: usize = 8;
    if (b[5] != 1 or b.len < at + sn * 6 + pn * 4 + nn * 6 + 2 * nn * nn + grid * grid) return false;
    for (0..sn) |k| {
        out.spawns[k] = .{ .x = rd(b, at), .y = rd(b, at + 2), .heading = rd(b, at + 4) };
        at += 6;
    }
    for (0..pn) |k| {
        pads[k] = .{ .x = rd(b, at), .y = rd(b, at + 2) };
        at += 4;
    }
    for (0..nn) |k| {
        out.nodes[k] = .{ .x = rd(b, at), .y = rd(b, at + 2), .jump = b[at + 4], .flags = b[at + 5] };
        at += 6;
    }
    out.spawn_n = @intCast(sn);
    out.node_n = @intCast(nn);
    out.next = b[at..][0 .. nn * nn];
    at += nn * nn;
    out.ground = b[at..][0 .. nn * nn];
    at += nn * nn;
    out.cells = b[at..][0 .. grid * grid];
    out.grid = @intCast(grid);
    out.cell_shift = @intCast(@min(b[3], 10));
    pad_n.* = @intCast(pn);
    return true;
}

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
            .kind = if (b[0] & 15 <= @backingInt(world.HazardKind.crust)) @fromBackingInt(b[0] & 15) else .none,
            .sprite = b[0] >> 4,
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

/// Load `t`'s league art into the RAM slot (when the league changes),
/// unpack its map into `map_ram`, find its crate spawns and hazards and
/// make it `current`. Call at race start (sim.reset), before any tile
/// lookup on `t` and before `render.set_track(t)`; ~16 K byte copies
/// (~36 K when the league changes).
pub fn select(t: *const Track) void {
    if (t.map_packed.len > 0) {
        load_art(t.league);
        unpack_map(t.map_packed, &map_ram);
    } else if (map_owner != t or art_league != t.league) {
        // M7: the pack track, its art and map overwritten since it loaded.
        const ok = if (pack_reload) |f| f() else false;
        if (!ok) blank();
    }
    map_owner = t;
    crust_shown = @splat(0);
    prop_n = parse_props(t, &props);
    prop_reach = 0;
    for (props[0..prop_n]) |pr| prop_reach = @max(prop_reach, pr.radius);
    // An arena's crates sit on its pads; a race track's in its rows.
    if (!parse_arena(t, &arena, &crate_spots, &crate_n)) crate_n = find_crates(t, &crate_spots);
    chip_n = find_chips(t, &chip_spots);
    hazard_n = parse_hazards(t, &hazard_specs);
    current = t;
}

/// A pack track whose art could not be reloaded: plain background (tile 1,
/// attribute off) under a dark tile set, so nothing reads stale indices.
fn blank() void {
    @memset(&map_ram, 1);
    @memset(&art_tiles, 1);
    art_league = null;
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

/// The cycle chips of `t` (needs its map in `map_ram`: call from
/// `select`): `tuning.chip_trails` trails of `chip_per_trail` chips along
/// the line, each trail left of the centre, on it, or right of it in turn
/// (`chip_lat_pct` of the half width); a chip that would sit on anything
/// but plain road moves to the centerline, and is dropped if that is not
/// road either.
pub fn find_chips(t: *const Track, out: *[world.chip_max]CrateSpot) u8 {
    var n: usize = 0;
    const sides = [3]i32{ -1, 0, 1 };
    for (0..tuning.chip_trails) |trail| {
        const side = sides[trail % 3];
        for (0..tuning.chip_per_trail) |k| {
            if (n >= out.len) return @intCast(n);
            const s = t.sample(tuning.chip_first + trail * tuning.chip_every + k * tuning.chip_gap);
            const lat = @divTrunc(side * @as(i32, s.half) * tuning.chip_lat_pct, 100);
            const rx = -fixed.sin(s.tangent);
            const ry = fixed.cos(s.tangent);
            var x = (@as(i32, s.x) + ((rx * lat) >> fixed.Q)) & 1023;
            var y = (@as(i32, s.y) + ((ry * lat) >> fixed.Q)) & 1023;
            if (!chip_floor(t.attr_at(x, y))) {
                x = s.x;
                y = s.y;
                if (!chip_floor(t.attr_at(x, y))) continue;
            }
            out[n] = .{ .x = @intCast(x), .y = @intCast(y) };
            n += 1;
        }
    }
    return @intCast(n);
}

/// Floor a chip may lie on: road, the start and sector lines, a bay.
fn chip_floor(a: Attr) bool {
    return switch (a) {
        .surface, .start, .sector1, .sector2, .bay => true,
        else => false,
    };
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
    unpack(src, dst);
}

/// `unpack_map` for any output length (the league art too).
pub fn unpack(src: []const u8, dst: []u8) void {
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
    .tiles_packed = @embedFile("gen/tracks/dumps_tiles.bin"),
    .pal = @embedFile("gen/tracks/dumps_pal.bin"),
    .horizon_packed = @embedFile("gen/tracks/dumps_horizon.bin"),
};

pub const runoff = League{
    .name = "THE RUNOFF",
    .tiles_packed = @embedFile("gen/tracks/runoff_tiles.bin"),
    .pal = @embedFile("gen/tracks/runoff_pal.bin"),
    .horizon_packed = @embedFile("gen/tracks/runoff_horizon.bin"),
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

/// M6: The Sandbox, the BATTLE arena (SPEC 8.3): the Dumps' tileset,
/// tools/build_arena.py.
pub const sandbox = Track{
    .name = "THE SANDBOX",
    .league = &dumps,
    .laps = 0,
    .map_packed = @embedFile("gen/tracks/sandbox_map.bin"),
    .attr = dumps_attr,
    .center = @embedFile("gen/tracks/sandbox_center.bin"),
    .feat = @embedFile("gen/tracks/sandbox_feat.bin"),
    .arena = @embedFile("gen/tracks/sandbox_arena.bin"),
};

/// M6: the BATTLE arenas (`Setup.track` indexes this in battle; M7's pack
/// arenas join after The Sandbox).
pub const arenas = [_]*const Track{&sandbox};

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
    load_art(l);
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
        // select loaded the track's league art into the slot.
        try std.testing.expect(art_league == t.league);
    }
}

test "league art: the slot holds the selected league's, unpacked from its packed bytes" {
    select(&salt_pan_sprint);
    const runoff_first = art_tiles[tiles_bytes - 64 ..][0..64].*;
    const runoff_pal_entry = runoff.horizon_front_pal(15);
    select(&landfill_loop);
    try std.testing.expect(art_league == &dumps);
    try std.testing.expect(dumps.horizon_front_pal(15) != runoff_pal_entry or !std.mem.eql(u8, &runoff_first, art_tiles[tiles_bytes - 64 ..][0..64]));
    // The same league twice does not unpack again (the slot is a cache).
    art_tiles[0] = 0xEE;
    select(&monitor_dunes);
    try std.testing.expectEqual(@as(u8, 0xEE), art_tiles[0]);
    art_league = null;
    select(&monitor_dunes);
    try std.testing.expect(art_tiles[0] != 0xEE);
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
