//! The map ring and the segment sequencer (SPEC.md 5.4, PLAN.md M1 "Fixed
//! interfaces"). Row y of the endless strip lives at `height[y & (DEPTH-1)]`;
//! `advance_to` keeps the window [cam_row - keep_behind, cam_row + gen_ahead)
//! generated. The strip is a sequence of 256-row pairs, each a 64-row Bus
//! followed by a 192-row district from `order`; `gen_row` draws the noise
//! floor and then the segment's `row()`. `tick` drives the live district's
//! dataflow (its per-frame cell edits) through `rows`.
const build_options = @import("build_options");
const fixed = @import("fixed.zig");
const bus = @import("districts/bus.zig");
const heap = @import("districts/heap.zig");
const sort = @import("districts/sort.zig");
const tree = @import("districts/tree.zig");
const hash = @import("districts/hash.zig");
const stack = @import("districts/stack.zig");
const pipeline = @import("districts/pipeline.zig");

/// Strip width in cells; x wraps.
pub const W = 256;
/// Ring depth in rows; power of two, from -Dflyover_depth (128 or 256).
pub const DEPTH = build_options.flyover_depth;
comptime {
    if (DEPTH & (DEPTH - 1) != 0) @compileError("flyover_depth must be a power of two");
}

// --- World knobs ------------------------------------------------------------

/// Rows kept valid behind the camera row (the camera moves at most 2 rows per
/// frame and camera.update reads its own row before advance_to runs).
pub const keep_behind = 8;
/// Rows generated ahead of the camera row (exclusive bound). The ring holds
/// DEPTH rows, so behind + ahead cannot exceed it: 248 at depth 256, 120 at
/// depth 128. render.z_far (in cells) must not exceed this, or the march reads
/// rows that alias the ones just behind the camera.
pub const gen_ahead = DEPTH - keep_behind;
/// Noise floor base height; every structure builds on floor + n.
pub const floor: u8 = 20;
/// Water level: a cell with h <= water is water (colour palette.water_idx);
/// the renderer draws it as a mirror (SPEC 5.6).
pub const water: u8 = floor - 12;
/// Seed of the noise floor.
const floor_seed: u32 = 0x5EED_F1A1;
/// Segment lengths in rows; a Bus and a district make one 256-row pair.
pub const bus_len = 64;
pub const district_len = 192;
pub const pair_len = bus_len + district_len;
comptime {
    if (pair_len != 256) @compileError("segment_at assumes 256-row pairs");
}

// --- Segments ---------------------------------------------------------------

pub const Kind = enum(u8) { bus, heap, sort, tree, hash, stack, pipeline };
/// District cycle: pair p holds order[p % order.len] after its Bus.
pub const order = [_]Kind{ .heap, .sort, .tree, .hash, .stack, .pipeline };

pub const Segment = struct {
    kind: Kind,
    /// First row and length in rows.
    y0: i32,
    len: i32,
    /// Per-visit seed (never 0), so no two Heaps are the same.
    seed: u32,
    /// Segment number along the strip: pair * 2 (+1 for the district).
    index: u32,
};

pub const Rows = struct { h: *[W]u8, c: *[W]u8 };

/// A district module as a table entry (districts/<name>.zig exports these pub decls).
pub const District = struct {
    title: []const u8,
    gloss: []const u8,
    caption: []const u8,
    /// Autopilot cruise altitude above `floor`, cells.
    alt: i32,
    /// Local row where the autopilot presses B, -1 never.
    verb_at: i32,
    /// Autopilot altitude above `floor` at local row ly (negative on the Bus
    /// before the district); districts without a track return `alt`.
    alt_at: *const fn (ly: i32) i32,
    row: *const fn (seed: u32, ly: i32, h: *[W]u8, c: *[W]u8) void,
    enter: *const fn (seg: Segment) void,
    tick: *const fn (frame: u32, cam_row: i32) void,
    verb: *const fn () void,
};

fn entry(comptime M: type) District {
    return .{
        .title = M.title,
        .gloss = M.gloss,
        .caption = M.caption,
        .alt = M.alt,
        .verb_at = M.verb_at,
        .alt_at = &M.alt_at,
        .row = &M.row,
        .enter = &M.enter,
        .tick = &M.tick,
        .verb = &M.verb,
    };
}

const table = [_]District{ entry(bus), entry(heap), entry(sort), entry(tree), entry(hash), entry(stack), entry(pipeline) };

pub fn info(kind: Kind) *const District {
    return &table[@backingInt(kind)];
}

/// The segment containing row y (y may be negative: the rows behind the start).
pub fn segment_at(y: i32) Segment {
    const pair = y >> 8;
    const in_pair = y & (pair_len - 1);
    const is_bus = in_pair < bus_len;
    const kind: Kind = if (is_bus) .bus else order[@intCast(@mod(pair, @as(i32, order.len)))];
    const index: u32 = @bitCast(pair * 2 + @as(i32, @intFromBool(!is_bus)));
    return .{
        .kind = kind,
        .y0 = pair * pair_len + @as(i32, if (is_bus) 0 else bus_len),
        .len = if (is_bus) bus_len else district_len,
        .seed = seed_of(index, kind),
        .index = index,
    };
}

fn seed_of(index: u32, kind: Kind) u32 {
    var h: u32 = index *% 0x9E37_79B1 ^ (@as(u32, @backingInt(kind)) +% 1) *% 0x85EB_CA77 ^ 0x5EED_1A2E;
    h ^= h >> 15;
    h *%= 0x2C1B_3C6D;
    h ^= h >> 12;
    return if (h == 0) 1 else h;
}

// --- State ------------------------------------------------------------------

pub var height: [DEPTH][W]u8 = undefined;
pub var colour: [DEPTH][W]u8 = undefined;

/// Next row to generate (every row below it, back to generated - DEPTH, is
/// in the ring). Starts at -keep_behind so the first call also fills the rows
/// just behind the start position.
var generated: i32 = -keep_behind;

/// Index meaning "no segment yet".
const no_segment: u32 = 0xFFFF_FFFF;
/// The district being ticked (index no_segment before the first tick).
var live_seg: Segment = .{ .kind = .bus, .y0 = 0, .len = 0, .seed = 1, .index = no_segment };
/// Segment under the camera last frame, for entered_segment().
var under_index: u32 = no_segment;
var under_seg: Segment = undefined;
var entered: ?Segment = null;

/// Generate every row up to cam_row + gen_ahead (exclusive) that is not in
/// the ring yet. Call at start() and every frame; the camera moves at most a
/// couple of rows, so a frame generates 0 to 2 rows.
pub fn advance_to(cam_row: i32) void {
    const target = cam_row + gen_ahead;
    // A jump of more than the ring (never in normal flight) regenerates it.
    if (target - generated > DEPTH) generated = target - DEPTH;
    while (generated < target) : (generated += 1) {
        const i: usize = @intCast(generated & (DEPTH - 1));
        gen_row(generated, &height[i], &colour[i]);
    }
}

/// True when row y is in the ring (for the debug overlay and camera probes).
pub fn generated_row(y: i32) bool {
    return y < generated and y >= generated - DEPTH;
}

/// Ring row y for dynamic edits, null when the row is not in the ring.
pub fn rows(y: i32) ?Rows {
    if (!generated_row(y)) return null;
    const i: usize = @intCast(y & (DEPTH - 1));
    return .{ .h = &height[i], .c = &colour[i] };
}

/// Rewrite row y's static content (floor + the segment's row()) if it is in the ring.
pub fn regen_row(y: i32) void {
    if (rows(y)) |r| gen_row(y, r.h, r.c);
}

/// One static row of the strip: the noise floor, then the segment's architecture.
pub fn gen_row(y: i32, out_h: *[W]u8, out_c: *[W]u8) void {
    floor_row(y, out_h, out_c);
    const seg = segment_at(y);
    info(seg.kind).row(seg.seed, y - seg.y0, out_h, out_c);
}

/// Noise floor (SPEC 5.4): floor + 0..7, colour 0..14 by height, grid lines
/// every 64 cells in x and y in 16..19.
pub fn floor_row(y: i32, out_h: *[W]u8, out_c: *[W]u8) void {
    const grid_row = y & 63 == 0;
    for (out_h, out_c, 0..) |*h, *c, xu| {
        const x: i32 = @intCast(xu);
        const n: u8 = fixed.noise2(x, y, floor_seed) >> 5; // 0..7
        h.* = floor + n;
        c.* = if (grid_row or x & 63 == 0) 16 + (n >> 1) else 2 * n;
    }
}

/// The district being ticked: the one under the camera, or the next one when
/// the camera is on a Bus.
pub fn live() Segment {
    return live_seg;
}

/// Call after advance_to each frame: tracks the segment under the camera,
/// enters and ticks the live district, runs its verb when `verb` is set.
pub fn tick(frame: u32, cam_row: i32, verb: bool) void {
    const under = segment_at(cam_row);
    if (under.index != under_index) {
        // The segment the camera starts in is not "entered": the boot card
        // (main.zig start()) keeps the screen for its 90 frames.
        if (under_index != no_segment) entered = under;
        under_index = under.index;
        under_seg = under;
    }
    const want = if (under.kind == .bus) segment_at(under.y0 + bus_len) else under;
    if (want.index != live_seg.index) {
        // The old district's rows still in the ring (the keep_behind rows
        // behind the camera) carry its dynamic edits; restore them, so every
        // row outside the live district is gen_row's (debug_world_check).
        if (live_seg.index != no_segment) {
            var y = @max(live_seg.y0, generated - DEPTH);
            while (y < live_seg.y0 + live_seg.len) : (y += 1) regen_row(y);
        }
        live_seg = want;
        info(want.kind).enter(want);
    }
    // Every row of the live district is in the ring from 56 rows before its
    // Bus ends (at depth 256); ticks wait for that, so a tick never finds its
    // rows ungenerated ahead of the camera.
    if (!generated_row(live_seg.y0 + live_seg.len - 1)) return;
    const d = info(live_seg.kind);
    d.tick(frame, cam_row);
    if (verb) d.verb();
}

/// The segment the camera crossed into this frame, reported once.
pub fn entered_segment() ?Segment {
    defer entered = null;
    return entered;
}

/// Caption for the segment under the camera: the district's B verb, or on a
/// Bus the name of the district ahead.
pub fn caption() []const u8 {
    if (under_index == no_segment) return "";
    if (under_seg.kind != .bus) return info(under_seg.kind).caption;
    return next_caption[@backingInt(segment_at(under_seg.y0 + bus_len).kind)];
}

const next_caption = blk: {
    var t: [table.len][]const u8 = undefined;
    for (&t, 0..) |*s, k| s.* = "NEXT: " ++ table[k].title;
    break :blk t;
};
