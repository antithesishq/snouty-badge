//! HASH district (SPEC.md 6, PLAN.md M2 "Hash"): an open-hashing table seen
//! from altitude. Four rows of eight magenta 10x10 buckets on a 32-cell
//! pitch, each with a collision chain of 0..3 terraces stepping down behind
//! it; pulse-A insert lanes from alternating strip edges to a target bucket;
//! the pulse-B rehash seam across the strip; the denser table of small
//! buckets after it. Dataflow: every grow_every frames a bucket away from
//! the flight line gains a terrace. Verb: rehash, the chains ahead of the
//! camera drain while small buckets rise between the big ones.
//!
//! The layout (chain lengths, lane targets) is a pure function of the
//! segment seed: `gen` is the cache row() paints from, keyed by seed; `live`
//! is the ticked segment's copy, whose chain counts the dynamics change.
//! Dynamic edits go through world.rows() and skip rows the ring does not hold.
const world = @import("../world.zig");
const palette = @import("../palette.zig");
const fixed = @import("../fixed.zig");
const camera = @import("../camera.zig");

pub const title: []const u8 = "HASH";
pub const gloss: []const u8 = "open hashing";
pub const caption: []const u8 = "B: rehash the table";
pub const alt: i32 = 120;
pub const verb_at: i32 = 40;

/// Autopilot altitude above the floor at local row ly: no track.
pub fn alt_at(ly: i32) i32 {
    _ = ly;
    return alt;
}

const W = world.W;
const F: i32 = world.floor;

// --- Hash knobs -------------------------------------------------------------

/// Big buckets: n_rows rows from local row row0 every row_pitch, n_cols per
/// row at x = col0 + col_pitch i, bucket x bucket cells, bucket_h above the floor.
const n_rows = 4;
const n_cols = 8;
const row0 = 10;
const row_pitch = 36;
const col0 = 11;
const col_pitch = 32;
const bucket = 10;
const bucket_h = 40;
/// Chain lengths drawn from this table (the prototype's rng.choice).
const chain_pick = [6]u8{ 0, 1, 1, 2, 3, 3 };
/// Terrace k: rows y + chain_gap + chain_pitch k, chain_depth deep,
/// chain_w0 - 2 k wide centred on the bucket, chain_h0 - chain_dh k high.
const max_chain = 3;
const chain_gap = 11;
const chain_pitch = 7;
const chain_depth = 6;
const chain_w0 = 8;
const chain_h0 = 30;
const chain_dh = 8;
/// Insert lanes (rows 1..3): pulse A comet lane_w wide along row y - 3 from
/// the strip edge (x 0 for odd rows, 255 for even) to a target bucket from
/// lane_targets, then to the bucket; floor cells raised to lane_h.
const lane_w = 2;
const lane_h = 2;
const lane_back = 3;
const lane_targets = [4]u8{ 1, 2, 5, 6 };
/// Rehash seam: pulse B dash seam_w wide across the strip at seam_row,
/// raised to seam_h.
const seam_row = 150;
const seam_w = 3;
const seam_h = 4;
/// Small buckets after the seam: rows from small_row0 every small_pitch
/// while below small_end, n_small per row at x = small_x0 + small_xp i,
/// small x small cells, small_h high.
const small_row0 = 158;
const small_pitch = 18;
const small_end = world.district_len - 10;
const n_small = 16;
const small_x0 = 5;
const small_xp = 16;
const small = 6;
const small_h = 20;

/// Grow tick: every grow_every frames one bucket with fewer than max_chain
/// terraces, at least grow_min_dx cells from the camera's x (SPEC 15) and
/// with its new terrace grow_ahead_min..grow_ahead_max rows ahead, gains a
/// terrace over grow_frames.
const grow_every = 90;
const grow_min_dx = 16;
const grow_ahead_min = 16;
const grow_ahead_max = 200;
const grow_frames = 8;
/// Rehash: over rehash_frames the terraces of every bucket row whose front
/// is ahead of the camera sink to floor + drain_h, while n_cols small
/// buckets per such row (x = new_x0 + col_pitch i, rows y + new_dy, small x
/// small) rise to small_h; then one bucket row per frame gets its true floor back.
const rehash_frames = 30;
const drain_h = 3;
const new_x0 = 27;
const new_dy = 2;

// --- Layout -----------------------------------------------------------------

const Layout = struct {
    seed: u32 = 0,
    /// Terraces behind bucket (row j, column i).
    chain: [n_rows][n_cols]u8 = undefined,
    /// Lane target column of row j (row 0 has no lane).
    target: [n_rows]u8 = undefined,
};

var gen: Layout = .{};
var live: Layout = .{};

fn seeded(seed: u32, salt: u32) fixed.Rng {
    const s = seed ^ salt;
    var rng: fixed.Rng = .{ .s = if (s == 0) 1 else s };
    _ = rng.next();
    _ = rng.next();
    return rng;
}

/// The layout of the Hash with this seed, in the prototype's draw order.
noinline fn build(out: *Layout, seed: u32) void {
    var rng = seeded(seed, 0x4A5B_C0DE);
    out.seed = seed;
    for (0..n_rows) |j| {
        for (&out.chain[j]) |*n| n.* = chain_pick[rng.next() % chain_pick.len];
        out.target[j] = if (j > 0) lane_targets[rng.next() % lane_targets.len] else 0;
    }
}

inline fn row_y(j: usize) i32 {
    return row0 + row_pitch * @as(i32, @intCast(j));
}

inline fn col_x(i: usize) i32 {
    return col0 + col_pitch * @as(i32, @intCast(i));
}

/// Terrace k of the bucket at (x, y): first row, first x, width, height.
const Terrace = struct { y: i32, x: i32, w: i32, h: u8, c: u8 };

noinline fn terrace(x: i32, y: i32, k: usize) Terrace {
    const ki: i32 = @intCast(k);
    const w = chain_w0 - 2 * ki;
    return .{
        .y = y + chain_gap + chain_pitch * ki,
        .x = x + bucket / 2 - @divTrunc(w, 2),
        .w = w,
        .h = @intCast(F + chain_h0 - chain_dh * ki),
        .c = palette.hash_chain[k],
    };
}

// --- Static rows ------------------------------------------------------------

/// A pulse path cell: raise to at least `raise`, colour base + p % 16.
const PathCtx = struct {
    h: *[W]u8,
    c: *[W]u8,
    base: u8,
    raise: u8,

    pub fn cell(self: PathCtx, x: i32, p: i32) void {
        const i: usize = @intCast(x & (W - 1));
        self.h[i] = @max(self.h[i], self.raise);
        self.c[i] = @intCast(self.base + (p & 15));
    }
};

/// Static architecture of local row `ly` over the floor already in h/c.
pub fn row(seed: u32, ly: i32, h: *[W]u8, c: *[W]u8) void {
    if (gen.seed != seed) build(&gen, seed);
    const lay = &gen;
    for (0..n_rows) |j| {
        const y = row_y(j);
        if (ly < y - lane_back - 1 or ly >= y + chain_gap + chain_pitch * (max_chain - 1) + chain_depth) continue;
        if (ly >= y and ly < y + bucket) {
            for (0..n_cols) |i| world.span(h, c, col_x(i), bucket, F + bucket_h, palette.hash_bucket);
        }
        for (0..n_cols) |i| {
            for (0..lay.chain[j][i]) |k| {
                const t = terrace(col_x(i), y, k);
                if (ly >= t.y and ly < t.y + chain_depth) world.span(h, c, t.x, t.w, t.h, t.c);
            }
        }
        if (j > 0) {
            const tgt = col_x(lay.target[j]) + bucket / 2;
            const src: i32 = if (j % 2 == 1) 0 else W - 1;
            const ctx: PathCtx = .{ .h = h, .c = c, .base = palette.pulse_a, .raise = F + lane_h };
            const p = world.leg_row(ly, src, y - lane_back, tgt, y - lane_back, lane_w, 0, ctx);
            _ = world.leg_row(ly, tgt, y - lane_back, tgt, y, lane_w, p, ctx);
        }
    }
    const seam_ctx: PathCtx = .{ .h = h, .c = c, .base = palette.pulse_b_dash, .raise = F + seam_h };
    _ = world.leg_row(ly, 0, seam_row, W, seam_row, seam_w, 0, seam_ctx);
    if (ly >= small_row0 and ly < small_end) {
        const in_row = @mod(ly - small_row0, small_pitch);
        const first = ly - in_row;
        if (in_row < small and first < small_end) {
            for (0..n_small) |i| {
                world.span(h, c, small_x0 + small_xp * @as(i32, @intCast(i)), small, F + small_h, palette.hash_small);
            }
        }
    }
}

// --- Live state -------------------------------------------------------------

var seg: world.Segment = .{ .kind = .hash, .y0 = 0, .len = 0, .seed = 1, .index = 0xFFFF_FFFF };
var tick_rng: fixed.Rng = .{ .s = 1 };
/// Growing terrace: frames left (0 = none), bucket and terrace index.
var grow_left: i32 = 0;
var grow_j: usize = 0;
var grow_i: usize = 0;
var grow_k: usize = 0;
/// Rehash: frames done (0 = idle, 1..rehash_frames), the bucket rows it
/// drains (bit j), each row's chain lengths at the start, and the next row
/// to put the floor back under (n_rows = none left).
var rehash_t: i32 = 0;
var rehash_rows: u8 = 0;
var drained: [n_rows][n_cols]u8 = undefined;
var settle_j: usize = n_rows;
/// B was pressed; the rehash starts when no terrace is growing.
var rehash_pending = false;

/// The segment becomes live: rebuild the layout from its seed, reset dynamics.
pub fn enter(s: world.Segment) void {
    seg = s;
    build(&live, s.seed);
    tick_rng = seeded(s.seed, 0x71C4_4A5B);
    grow_left = 0;
    rehash_t = 0;
    rehash_rows = 0;
    settle_j = n_rows;
    rehash_pending = false;
}

/// Write rows [y, y + d) x [x, x + w) (local coordinates). With `set`
/// false: a block of height at least `hv` (higher cells keep their height)
/// and colour cv; with `set` true: height exactly hv, colour unchanged.
noinline fn block(x: i32, y: i32, w: i32, d: i32, hv: i32, cv: u8, set: bool) void {
    var yy = y;
    while (yy < y + d) : (yy += 1) {
        const r = world.rows(seg.y0 + yy) orelse continue;
        var k: i32 = 0;
        while (k < w) : (k += 1) {
            const i: usize = @intCast((x + k) & (W - 1));
            if (set) {
                r.h[i] = @intCast(hv);
            } else {
                r.h[i] = @intCast(@max(@as(i32, r.h[i]), hv));
                r.c[i] = cv;
            }
        }
    }
}

fn raise_block(x: i32, y: i32, w: i32, d: i32, hv: i32, cv: u8) void {
    block(x, y, w, d, hv, cv, false);
}

fn set_block_h(x: i32, y: i32, w: i32, d: i32, hv: u8) void {
    block(x, y, w, d, hv, 0, true);
}

/// Put the noise floor back under a block.
noinline fn floor_block(x: i32, y: i32, w: i32, d: i32) void {
    var yy = y;
    while (yy < y + d) : (yy += 1) {
        const wy = seg.y0 + yy;
        const r = world.rows(wy) orelse continue;
        var k: i32 = 0;
        while (k < w) : (k += 1) {
            const i: usize = @intCast((x + k) & (W - 1));
            const f = world.floor_cell(x + k, wy);
            r.h[i] = f.h;
            r.c[i] = f.c;
        }
    }
}

/// Pick a bucket to grow a terrace: fewer than max_chain, away from the
/// camera's x, its new terrace ahead of the camera.
noinline fn start_grow(cam_row: i32) void {
    const cam_x = (camera.cam.x >> fixed.Q) & (W - 1);
    const first = tick_rng.next() % (n_rows * n_cols);
    var n: usize = 0;
    while (n < n_rows * n_cols) : (n += 1) {
        const b = (first + n) % (n_rows * n_cols);
        const j = b / n_cols;
        const i = b % n_cols;
        const k = live.chain[j][i];
        if (k >= max_chain) continue;
        const t = terrace(col_x(i), row_y(j), k);
        const ahead = seg.y0 + t.y - cam_row;
        if (ahead < grow_ahead_min or ahead > grow_ahead_max) continue;
        if (world.x_dist(cam_x, col_x(i), bucket) < grow_min_dx) continue;
        grow_j = j;
        grow_i = i;
        grow_k = k;
        grow_left = grow_frames;
        live.chain[j][i] += 1;
        return;
    }
}

/// Per-frame dataflow: the grow tick and its animation, the rehash.
pub fn tick(frame: u32, cam_row: i32) void {
    const busy = rehash_pending or rehash_t != 0 or settle_j < n_rows;
    if (frame % grow_every == 0 and grow_left == 0 and !busy) start_grow(cam_row);
    if (grow_left > 0) {
        grow_left -= 1;
        const t = terrace(col_x(grow_i), row_y(grow_j), grow_k);
        const top: i32 = t.h;
        raise_block(t.x, t.y, t.w, chain_depth, F + @divTrunc((top - F) * (grow_frames - grow_left), grow_frames), t.c);
    }
    if (rehash_pending and grow_left == 0) start_rehash(cam_row);
    if (rehash_t != 0) rehash_step();
    if (settle_j < n_rows) settle_step();
}

noinline fn rehash_step() void {
    const f = rehash_t; // 1..rehash_frames
    for (0..n_rows) |j| {
        if (rehash_rows & (@as(u8, 1) << @intCast(j)) == 0) continue;
        const y = row_y(j);
        for (0..n_cols) |i| {
            for (0..drained[j][i]) |k| {
                const t = terrace(col_x(i), y, k);
                const top: i32 = t.h;
                const hv = top + @divTrunc((F + drain_h - top) * f, rehash_frames);
                set_block_h(t.x, t.y, t.w, chain_depth, @intCast(hv));
            }
            raise_block(new_x0 + col_pitch * @as(i32, @intCast(i)), y + new_dy, small, small, F + @divTrunc(small_h * f, rehash_frames), palette.hash_small);
        }
    }
    rehash_t += 1;
    if (rehash_t > rehash_frames) {
        rehash_t = 0;
        settle_j = 0;
    }
}

/// Floor back under one drained row's terraces per frame.
noinline fn settle_step() void {
    while (settle_j < n_rows and rehash_rows & (@as(u8, 1) << @intCast(settle_j)) == 0) settle_j += 1;
    if (settle_j >= n_rows) return;
    const j = settle_j;
    for (0..n_cols) |i| {
        for (0..drained[j][i]) |k| {
            const t = terrace(col_x(i), row_y(j), k);
            floor_block(t.x, t.y, t.w, chain_depth);
        }
    }
    settle_j += 1;
}

/// B pressed while this district is live: rehash the rows ahead, one
/// sweep at a time (it starts once a growing terrace has finished).
pub fn verb() bool {
    if (rehash_t != 0 or settle_j < n_rows) return false;
    rehash_pending = true;
    return true;
}

fn start_rehash(cam_row: i32) void {
    rehash_pending = false;
    rehash_rows = 0;
    for (0..n_rows) |j| {
        if (seg.y0 + row_y(j) <= cam_row) continue;
        rehash_rows |= @as(u8, 1) << @intCast(j);
        drained[j] = live.chain[j];
        live.chain[j] = @splat(0);
    }
    if (rehash_rows != 0) rehash_t = 1;
}
