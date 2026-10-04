//! HEAP district (SPEC.md 6, PLAN.md M1 "Heap"): rows of amber mesas
//! (allocated blocks) with low teal freed blocks, a corridor of freed blocks
//! down the flight line, and the free list as a pulse-A chain hopping from
//! freed block to freed block. Dataflow: every tick_every frames one block
//! away from the flight line frees (sinks, turns teal) or mallocs (rises,
//! turns amber). Verb: mark and sweep: the unreferenced blocks ahead grey
//! out, then a white wall moves away from the camera and the grey blocks
//! it passes collapse into rubble.
//!
//! The layout (block list) is a pure function of the segment seed. `gen` is
//! the cache row() paints from, keyed by seed; `live` is the segment being
//! ticked, rebuilt by enter(), with the dynamic state per block in `dyn`.
//! Dynamic edits go through world.rows() and skip rows not in the ring.
const world = @import("../world.zig");
const palette = @import("../palette.zig");
const fixed = @import("../fixed.zig");
const camera = @import("../camera.zig");

pub const title: []const u8 = "HEAP";
pub const gloss: []const u8 = "malloc / free / gc";
pub const caption: []const u8 = "B: collect garbage";
/// Autopilot altitude: 52 (was 40, where the mesas filled the view); the
/// camera's clearance spring still lifts it over the tallest blocks.
pub const alt: i32 = 52;
pub const verb_at: i32 = 30;

/// Autopilot altitude track: no track, the constant `alt`.
pub fn alt_at(ly: i32) i32 {
    _ = ly;
    return alt;
}

const W = world.W;
const F: i32 = world.floor;

// --- Heap knobs -------------------------------------------------------------

/// Local row of the first block row; block rows start while ly < rows_end.
const rows_start = 6;
const rows_end = world.district_len - 12;
/// Blocks end at least this many rows before the district end.
const end_margin = 4;
/// Block row depth (inclusive range), the per-block trim off it, and the gap between rows.
const row_depth_min = 10;
const row_depth_max = 27;
const depth_trim_max = 4;
const row_gap_min = 4;
const row_gap_max = 7;
/// First block's x in a row (0..x_start_max); blocks are placed while x < x_stop.
const x_start_max = 5;
const x_stop = W - 8;
/// Block widths and the gap between blocks in a row (inclusive range).
const widths = [8]u8{ 8, 10, 12, 14, 16, 20, 24, 30 };
const gap_min = 3;
const gap_max = 7;
/// Blocks overlapping [corridor_x0, corridor_x1) are freed: the flight line's canyon.
const corridor_x0 = 122;
const corridor_x1 = 134;
/// Percent of the other blocks that are freed, and of allocated blocks that
/// are unreferenced (the GC's victims).
const free_pct = 22;
const unref_pct = 40;
/// Block heights above world.floor (inclusive ranges).
const free_h_min = 6;
const free_h_max = 15;
const alloc_h_min = 20;
const alloc_h_max = 85;
/// Block list capacity. 20000 seeds of the prototype's generator give at
/// most 126 blocks (mean 92); a fuller layout drops its last blocks.
const max_blocks = 144;

/// Free list: 2 cells wide, raising floor cells to floor + list_raise, and
/// painted only on cells at or below floor + list_max_h (never on a tall
/// block's top, whose faces would then carry the pulse colour).
const list_raise = 3;
const list_max_h = 20;

/// Malloc/free: one block every tick_every frames, at least tick_min_dx cells
/// from the camera's x (SPEC 15: never raise under the flight line), with its
/// near edge tick_ahead_min..tick_ahead_max rows ahead of the camera.
const tick_every = 40;
const tick_min_dx = 16;
const tick_ahead_min = 16;
const tick_ahead_max = 160;
/// Frames of the rise/sink, and the target heights above world.floor.
const anim_frames = 8;
const free_to = 8;
const malloc_to = 40;

/// Colour of a marked (garbage) block until the wall collapses it: the
/// palette's unassigned grey pair (palette.zig 208-254), a dead block.
const garbage: u8 = 208;
/// GC sweep: a gc_rows-deep wall, floor + gc_h high and draped wall_lift
/// over the blocks it crosses, starting where its foot shows on screen row
/// gc_sy (camera.rows_ahead, at least gc_start rows ahead and at most half
/// the way to the district end) and moving gc_speed rows per frame to the
/// district end; victims collapse over collapse_frames to floor + rubble_h.
const gc_start = 12;
const gc_sy = 104;
const gc_rows = 2;
const gc_speed = 3;
const gc_h = 24;
const wall_lift = 6;
const collapse_frames = 10;
const rubble_h = 2;
/// Rubble colour: palette.rubble + rubble_shade + (x % 2), indices 21..22,
/// one shade above the darkest so the footprints read against the floor.
const rubble_shade = 1;

comptime {
    if (gc_speed < gc_rows) @compileError("the wall must leave its old rows every frame");
}

// --- Layout -----------------------------------------------------------------

const flag_freed: u8 = 1;
const flag_unref: u8 = 2;

/// One block, in local rows: cells [x, x + w) x [y, y + d).
const Block = struct { x: u8, y: u8, w: u8, d: u8, h: u8, c: u8, flags: u8 };

const Layout = struct {
    seed: u32 = 0,
    n: usize = 0,
    b: [max_blocks]Block = undefined,
};

/// Row generator's cache (keyed by seed) and the live segment's layout.
var gen: Layout = .{};
var live: Layout = .{};

fn range(rng: *fixed.Rng, lo: i32, hi: i32) i32 {
    return lo + @as(i32, @intCast(rng.next() % @as(u32, @intCast(hi - lo + 1))));
}

fn roll(rng: *fixed.Rng, pct: u32) bool {
    return rng.next() % 100 < pct;
}

fn seeded(seed: u32, salt: u32) fixed.Rng {
    const s = seed ^ salt;
    var rng: fixed.Rng = .{ .s = if (s == 0) 1 else s };
    _ = rng.next();
    _ = rng.next();
    return rng;
}

/// The block layout of the Heap with this seed, in (y, x) order.
fn build(out: *Layout, seed: u32) void {
    var rng = seeded(seed, 0x4EA9_B10C);
    out.seed = seed;
    out.n = 0;
    var y: i32 = rows_start;
    while (y < rows_end) {
        const depth = range(&rng, row_depth_min, row_depth_max);
        var x = range(&rng, 0, x_start_max);
        while (x < x_stop) {
            const wd = @min(@as(i32, widths[rng.next() % widths.len]), W - x);
            const dp = @min(depth - range(&rng, 0, depth_trim_max), world.district_len - end_margin - y);
            const corridor = x < corridor_x1 and x + wd > corridor_x0;
            const freed = corridor or roll(&rng, free_pct);
            const hgt = F + (if (freed) range(&rng, free_h_min, free_h_max) else range(&rng, alloc_h_min, alloc_h_max));
            const unref = !freed and roll(&rng, unref_pct);
            const col: u8 = if (freed) palette.heap_free else palette.heap_alloc[rng.next() % 3];
            if (out.n < max_blocks) {
                out.b[out.n] = .{
                    .x = @intCast(x),
                    .y = @intCast(y),
                    .w = @intCast(wd),
                    .d = @intCast(dp),
                    .h = @intCast(hgt),
                    .c = col,
                    .flags = (if (freed) flag_freed else 0) | (if (unref) flag_unref else 0),
                };
                out.n += 1;
            }
            x += wd + range(&rng, gap_min, gap_max);
        }
        y += depth + range(&rng, row_gap_min, row_gap_max);
    }
}

// --- Static rows ------------------------------------------------------------

/// Static architecture of local row `ly` over the floor already in h/c: the
/// blocks, then the free list over them.
pub fn row(seed: u32, ly: i32, h: *[W]u8, c: *[W]u8) void {
    if (gen.seed != seed) build(&gen, seed);
    const lay = &gen;
    for (lay.b[0..lay.n]) |b| {
        if (b.y > ly) break;
        if (ly >= b.y + @as(i32, b.d)) continue;
        @memset(h[b.x..][0..b.w], b.h);
        @memset(c[b.x..][0..b.w], b.c);
    }
    free_list_row(lay, ly, h, c);
}

/// One free-list cell: raise to floor + list_raise and colour by distance
/// along the list, only where the cell is low.
inline fn list_cell(x: i32, dist: i32, h: *[W]u8, c: *[W]u8) void {
    const i: usize = @intCast(x & (W - 1));
    if (h[i] > F + list_max_h) return;
    h[i] = @max(h[i], F + list_raise);
    c[i] = @intCast(palette.pulse_a + (dist & 15));
}

/// The part of the free list on local row ly. The list is a polyline through
/// the freed blocks' centres in (y, x) order, each hop a vertical leg then a
/// horizontal leg; step k of a leg from (xa, ya) paints the 2x2 cells
/// [xa' - 1, xa'] x [ya' - 1, ya'] with distance p + k, later steps over
/// earlier ones (the prototype's World.path with width 2).
fn free_list_row(lay: *const Layout, ly: i32, h: *[W]u8, c: *[W]u8) void {
    var have_prev = false;
    var px: i32 = 0;
    var py: i32 = 0;
    var p: i32 = 0;
    for (lay.b[0..lay.n]) |b| {
        if (b.flags & flag_freed == 0) continue;
        const cx = @as(i32, b.x) + (b.w >> 1);
        const cy = @as(i32, b.y) + (b.d >> 1);
        if (!have_prev) {
            have_prev = true;
            px = cx;
            py = cy;
            continue;
        }
        // Vertical leg (px, py) -> (px, cy): rows y - 1 and y at step k with y = py + sy k.
        const n1 = @as(i32, @intCast(@abs(cy - py)));
        if (n1 > 0) {
            const sy: i32 = if (cy > py) 1 else -1;
            // Steps whose cells cover ly: y == ly or y == ly + 1, in increasing k.
            const ka = (ly - py) * sy;
            const kb = (ly + 1 - py) * sy;
            const k0 = @min(ka, kb);
            const k1 = @max(ka, kb);
            for ([2]i32{ k0, k1 }) |k| {
                if (k >= 0 and k < n1) {
                    list_cell(px - 1, p + k, h, c);
                    list_cell(px, p + k, h, c);
                }
            }
            p += n1;
        }
        // Horizontal leg (px, cy) -> (cx, cy): rows cy - 1 and cy.
        const n2 = @as(i32, @intCast(@abs(cx - px)));
        if (n2 > 0) {
            if (ly == cy - 1 or ly == cy) {
                const sx: i32 = if (cx > px) 1 else -1;
                var k: i32 = 0;
                while (k < n2) : (k += 1) {
                    const x = px + sx * k;
                    list_cell(x - 1, p + k, h, c);
                    list_cell(x, p + k, h, c);
                }
            }
            p += n2;
        }
        px = cx;
        py = cy;
    }
}

// --- Live state -------------------------------------------------------------

/// Dynamic state bits: `changed` = differs from row() (re-applied after a
/// regen), `alloc` = currently allocated, `rubble` = collapsed (colour by x),
/// `victim` = collapsing or collapsed by the GC, `unref` = allocated and
/// unreferenced (the next sweep's garbage).
const d_changed: u8 = 1;
const d_alloc: u8 = 2;
const d_rubble: u8 = 4;
const d_victim: u8 = 8;
const d_unref: u8 = 16;

/// Per live block: current height and colour, and the rise/sink animation
/// from `from` to `to` with `left` of `len` frames to go.
const Dyn = struct { h: u8, c: u8, from: u8, to: u8, left: u8, len: u8, flags: u8 };

var dyn: [max_blocks]Dyn = undefined;
var seg: world.Segment = .{ .kind = .heap, .y0 = 0, .len = 0, .seed = 1, .index = 0xFFFF_FFFF };
var tick_rng: fixed.Rng = .{ .s = 1 };
/// Camera row at the last tick (verb() takes no arguments and runs after tick).
var cam_row_last: i32 = 0;
/// GC sweep: running, wall top row (world y), and the row it collects from
/// (gc_start rows ahead of the camera at the press: the blocks between there
/// and the wall's first row collapse at once, as if it rose under the
/// camera); sweeps started this visit (restarts not counted).
var sweep_on = false;
var wall_y: i32 = 0;
var wall_y0: i32 = 0;
var sweeps: u32 = 0;

/// The segment becomes live: rebuild the layout from its seed, reset dynamics.
pub fn enter(s: world.Segment) void {
    seg = s;
    build(&live, s.seed);
    tick_rng = seeded(s.seed, 0x71C4_5EED);
    for (live.b[0..live.n], dyn[0..live.n]) |b, *d| {
        const flags: u8 = if (b.flags & flag_freed != 0) 0 else if (b.flags & flag_unref != 0) d_alloc | d_unref else d_alloc;
        d.* = .{ .h = b.h, .c = b.c, .from = b.h, .to = b.h, .left = 0, .len = 1, .flags = flags };
    }
    sweep_on = false;
    sweeps = 0;
}

/// Write block i's current state into ring row y (world row inside the block).
fn apply_row(i: usize, r: world.Rows) void {
    const b = live.b[i];
    const d = dyn[i];
    @memset(r.h[b.x..][0..b.w], d.h);
    if (d.flags & d_rubble != 0) {
        for (r.c[b.x..][0..b.w], b.x..) |*cc, x| cc.* = @intCast(palette.rubble + rubble_shade + x % 2);
    } else {
        @memset(r.c[b.x..][0..b.w], d.c);
    }
}

/// Write block i's current state into every one of its rows in the ring.
noinline fn apply_block(i: usize) void {
    const b = live.b[i];
    var y = seg.y0 + b.y;
    const y1 = y + b.d;
    while (y < y1) : (y += 1) {
        if (world.rows(y)) |r| apply_row(i, r);
    }
}

/// Restore ring row y: static content, then every changed block covering it.
fn restore_row(y: i32) void {
    world.regen_row(y);
    const r = world.rows(y) orelse return;
    const ly = y - seg.y0;
    for (live.b[0..live.n], dyn[0..live.n], 0..) |b, d, i| {
        if (b.y > ly) break;
        if (d.flags & d_changed == 0 or ly >= b.y + @as(i32, b.d)) continue;
        apply_row(i, r);
    }
}

fn start_anim(i: usize, to: i32, frames: u8) void {
    const d = &dyn[i];
    d.from = d.h;
    d.to = @intCast(to);
    d.left = frames;
    d.len = frames;
    d.flags |= d_changed;
}

/// Wrapped distance in cells from x to the span [x0, x0 + w).
fn x_dist(x: i32, x0: i32, w: i32) i32 {
    if (((x - x0) & (W - 1)) < w) return 0;
    return @min((x0 - x) & (W - 1), (x - (x0 + w - 1)) & (W - 1));
}

/// Pick one settled block ahead of the camera and away from its x: free it
/// if allocated, malloc it if freed.
fn malloc_or_free(cam_row: i32) void {
    if (live.n == 0) return;
    const cam_x = (camera.cam.x >> fixed.Q) & (W - 1);
    const first = tick_rng.next() % live.n;
    var k: usize = 0;
    while (k < live.n) : (k += 1) {
        const i = (first + k) % live.n;
        const b = live.b[i];
        const d = dyn[i];
        if (d.left != 0 or d.flags & d_victim != 0) continue;
        const near = seg.y0 + b.y - cam_row;
        if (near < tick_ahead_min or near > tick_ahead_max) continue;
        if (x_dist(cam_x, b.x, b.w) < tick_min_dx) continue;
        if (d.flags & d_alloc != 0) {
            dyn[i].c = palette.heap_free;
            dyn[i].flags &= ~(d_alloc | d_unref);
            start_anim(i, F + free_to, anim_frames);
        } else {
            dyn[i].c = palette.heap_alloc[0];
            dyn[i].flags |= d_alloc;
            start_anim(i, F + malloc_to, anim_frames);
        }
        return;
    }
}

/// Per-frame dataflow edits through world.rows(): the GC wall moves and
/// triggers collapses, one malloc/free every tick_every frames, animations
/// step, then the wall is painted over everything.
pub fn tick(frame: u32, cam_row: i32) void {
    cam_row_last = cam_row;
    const y_end = seg.y0 + seg.len;
    if (sweep_on) {
        var y = wall_y;
        while (y < wall_y + gc_rows) : (y += 1) restore_row(y);
        wall_y += gc_speed;
        if (wall_y + gc_rows > y_end) {
            sweep_on = false;
        } else {
            for (live.b[0..live.n], dyn[0..live.n], 0..) |b, d, i| {
                const near = seg.y0 + b.y;
                if (near > wall_y) break;
                if (d.flags & (d_unref | d_victim) != d_unref or d.left != 0) continue;
                if (near + b.d <= wall_y0) continue;
                dyn[i].flags |= d_victim;
                start_anim(i, F + rubble_h, collapse_frames);
            }
        }
    }
    if (frame % tick_every == 0) malloc_or_free(cam_row);
    for (dyn[0..live.n], 0..) |*d, i| {
        if (d.left == 0) continue;
        d.left -= 1;
        const from: i32 = d.from;
        const to: i32 = d.to;
        d.h = @intCast(to + @divTrunc((from - to) * d.left, d.len));
        if (d.left == 0 and d.flags & d_victim != 0) d.flags |= d_rubble;
        apply_block(i);
    }
    if (sweep_on) paint_wall();
}

/// The wall: white, floor + gc_h high, draped wall_lift over taller cells.
fn paint_wall() void {
    var y = wall_y;
    while (y < wall_y + gc_rows) : (y += 1) {
        const r = world.rows(y) orelse continue;
        for (r.h) |*h| h.* = @max(h.* + wall_lift, F + gc_h);
        @memset(r.c, palette.white);
    }
}

/// B pressed while this district is live: mark (the unreferenced blocks
/// ahead grey out), then sweep: the wall starts in view ahead of the camera
/// (or at the district start). A press during a sweep starts the wall again
/// from the camera; a new sweep after one has run finds new garbage
/// (unref_pct of the allocated blocks it will cross).
pub fn verb() bool {
    const y_end = seg.y0 + seg.len;
    const ahead = camera.rows_ahead(gc_sy, F + gc_h, gc_start);
    const start = @max(cam_row_last + @min(ahead, @max(gc_start, @divTrunc(y_end - cam_row_last, 2))), seg.y0);
    if (start + gc_rows > y_end) return false;
    const from = @max(cam_row_last + gc_start, seg.y0);
    if (sweep_on) {
        var y = wall_y;
        while (y < wall_y + gc_rows) : (y += 1) restore_row(y);
    } else {
        // Mark: the garbage ahead greys out (after a first sweep, new
        // garbage first: unref_pct of the allocated blocks ahead).
        for (live.b[0..live.n], dyn[0..live.n], 0..) |b, *d, i| {
            if (d.flags & (d_alloc | d_victim) != d_alloc or d.left != 0) continue;
            if (seg.y0 + b.y + b.d <= from) continue;
            if (sweeps > 0 and roll(&tick_rng, unref_pct)) d.flags |= d_unref;
            if (d.flags & d_unref == 0) continue;
            d.c = garbage;
            d.flags |= d_changed;
            apply_block(i);
        }
        sweeps += 1;
    }
    sweep_on = true;
    wall_y = start;
    wall_y0 = from;
    paint_wall();
    return true;
}
