//! HASH district (SPEC.md 6, PLAN.md M2 "Hash"): an open-hashing table seen
//! from altitude. Four rows of eight magenta 10x10 buckets on a 32-cell
//! pitch, each with a collision chain of 0..3 terraces stepping down behind
//! it; pulse-A insert lanes from alternating strip edges to a target bucket;
//! the pulse-B rehash seam across the strip; the denser table of small
//! buckets after it. Dataflow: every grow_every frames a bucket away from
//! the flight line gains a terrace. Verb: rehash, the table doubles where
//! the camera looks: a bucket row in view sinks and rises again with a new
//! bucket between each pair and shorter chains, or the small table rises
//! with a new row between each pair of its rows.
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
/// Rehash (B, SPEC 6 "the whole table doubles"): acts on at most
/// rehash_secs table sections, nearest first. A section is one big bucket
/// row or the small table. Picked are the ones whose buckets lie between
/// the rows ahead where a bucket top shows on screen rows rehash_sy_near and
/// rehash_sy_far (camera.rows_ahead), else the one nearest that window
/// still rehash_min_ahead rows ahead; so a press anywhere in the district
/// acts in view, ahead of the anteater.
const rehash_secs = 2;
const rehash_sy_near = 100;
const rehash_sy_far = 66;
const rehash_min_ahead = 6;
/// A section's buckets at full height (a big row, a risen small table) and
/// their chains first sink to floor + drain_h over sink_frames, glowing
/// (hash_small); then over rise_frames the doubled section rises, glowing
/// until its last frame: a big row back to bucket_h with a new bucket
/// between each old pair (16 on col_pitch / 2) and fresh chains from
/// rechain_pick (the load halves); the small table to small_risen_h with a
/// new row mid_dx-staggered between its rows and after the last (on
/// small_pitch / 2). small_risen_h is the big buckets' height: lower, a
/// late press at a manual cruise altitude of ~75 barely shows above the
/// caption. A press during a rehash is queued (one slot); the queued
/// rehash starts when the running one ends.
const sink_frames = 6;
const rise_frames = 14;
const drain_h = 3;
const small_risen_h = bucket_h;
const rechain_pick = [6]u8{ 0, 0, 1, 1, 1, 2 };
const mid_dx = small_xp / 2;
const small_rows = (small_end - small_row0 + small_pitch - 1) / small_pitch;
const small_dy = small_pitch / 2;

comptime {
    if (small_row0 + small_dy * (2 * small_rows - 1) + small > world.district_len) @compileError("hash: rehashed small table past the district");
}

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

/// Table sections: big bucket rows 0..n_rows-1, then the small table.
const n_secs = n_rows + 1;
const small_sec = n_rows;

var seg: world.Segment = .{ .kind = .hash, .y0 = 0, .len = 0, .seed = 1, .index = 0xFFFF_FFFF };
var tick_rng: fixed.Rng = .{ .s = 1 };
/// The camera row as of the last tick (verb() runs right after tick()).
var last_cam_row: i32 = 0;
/// Growing terrace: frames left (0 = none), bucket and terrace index.
var grow_left: i32 = 0;
var grow_j: usize = 0;
var grow_i: usize = 0;
var grow_k: usize = 0;
/// Rehashed sections: a big row has 16 buckets, the small table four
/// rows small_risen_h high.
var doubled: [n_secs]bool = @splat(false);
/// Chain lengths of the buckets a rehash added between the old ones.
var chain_mid: [n_rows][n_cols]u8 = undefined;
/// Rehash: frame (0 = idle), the sections it acts on (slots 0..rehash_n),
/// each one's sink frames (0 for a small table still low) and its state
/// before the rehash (doubled, chain lengths by bucket position).
var rehash_t: i32 = 0;
var rehash_n: usize = 0;
var slot_sec: [rehash_secs]usize = undefined;
var slot_sink: [rehash_secs]i32 = undefined;
var slot_doubled: [rehash_secs]bool = undefined;
var slot_chain: [rehash_secs][2 * n_cols]u8 = undefined;
/// B was pressed; the rehash starts when the running one has finished.
var rehash_pending = false;

/// The segment becomes live: rebuild the layout from its seed, reset dynamics.
pub fn enter(s: world.Segment) void {
    seg = s;
    build(&live, s.seed);
    tick_rng = seeded(s.seed, 0x71C4_4A5B);
    grow_left = 0;
    doubled = @splat(false);
    rehash_t = 0;
    rehash_n = 0;
    rehash_pending = false;
}

/// Write rows [y, y + d) x [x, x + w) (local coordinates) with colour cv
/// and height hv; with `raise` higher cells keep their height.
noinline fn block(x: i32, y: i32, w: i32, d: i32, hv: i32, cv: u8, raise: bool) void {
    var yy = y;
    while (yy < y + d) : (yy += 1) {
        const r = world.rows(seg.y0 + yy) orelse continue;
        var k: i32 = 0;
        while (k < w) : (k += 1) {
            const i: usize = @intCast((x + k) & (W - 1));
            r.h[i] = @intCast(if (raise) @max(@as(i32, r.h[i]), hv) else hv);
            r.c[i] = cv;
        }
    }
}

fn raise_block(x: i32, y: i32, w: i32, d: i32, hv: i32, cv: u8) void {
    block(x, y, w, d, hv, cv, true);
}

fn set_block(x: i32, y: i32, w: i32, d: i32, hv: i32, cv: u8) void {
    block(x, y, w, d, hv, cv, false);
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
    last_cam_row = cam_row;
    const busy = rehash_pending or rehash_t != 0;
    if (frame % grow_every == 0 and grow_left == 0 and !busy) start_grow(cam_row);
    if (grow_left > 0) {
        // A queued rehash finishes the growing terrace at once.
        grow_left = if (rehash_pending) 0 else grow_left - 1;
        const t = terrace(col_x(grow_i), row_y(grow_j), grow_k);
        const top: i32 = t.h;
        raise_block(t.x, t.y, t.w, chain_depth, F + @divTrunc((top - F) * (grow_frames - grow_left), grow_frames), t.c);
    }
    if (rehash_t == 0 and rehash_pending) start_rehash(cam_row);
    if (rehash_t != 0) rehash_step();
}

/// Bucket position p of a big row (even: old bucket p / 2, odd: the one a
/// rehash adds after it).
inline fn big_x(p: usize) i32 {
    return col0 + col_pitch / 2 * @as(i32, @intCast(p));
}

/// Chain length of bucket position p of big row j now.
fn chain_at(j: usize, p: usize) u8 {
    if (p % 2 == 0) return live.chain[j][p / 2];
    return if (doubled[j]) chain_mid[j][p / 2] else 0;
}

/// First and last row of section q's buckets (local).
fn sec_first(q: usize) i32 {
    return if (q == small_sec) small_row0 else row_y(q);
}

fn sec_last(q: usize) i32 {
    return if (q == small_sec) small_row0 + small_dy * (2 * small_rows - 1) + small - 1 else row_y(q) + bucket - 1;
}

/// The sections a rehash now acts on, nearest first, into `out`; returns
/// how many (0 when no section is ahead of the camera).
fn pick(cam_row: i32, out: *[rehash_secs]usize) usize {
    const top: i32 = F + bucket_h;
    const near = camera.rows_ahead(rehash_sy_near, top, rehash_min_ahead);
    const far = camera.rows_ahead(rehash_sy_far, top, near);
    var n: usize = 0;
    var closest: ?usize = null;
    for (0..n_secs) |q| {
        const first = seg.y0 + sec_first(q) - cam_row;
        const last = seg.y0 + sec_last(q) - cam_row;
        if (last < rehash_min_ahead) continue;
        if (last < near) {
            closest = q;
            continue;
        }
        // The first section past the window counts when none is in it (a
        // camera below the bucket tops sees no further than `far`).
        if (n == rehash_secs or (n > 0 and first > far)) break;
        out[n] = q;
        n += 1;
    }
    if (n == 0) {
        out[0] = closest orelse return 0;
        n = 1;
    }
    return n;
}

fn rechain() u8 {
    return rechain_pick[tick_rng.next() % rechain_pick.len];
}

/// Start the queued rehash: note each section's state, then double it
/// (new chain lengths for a big row; the small table rises).
noinline fn start_rehash(cam_row: i32) void {
    rehash_pending = false;
    rehash_n = pick(cam_row, &slot_sec);
    for (slot_sec[0..rehash_n], 0..) |q, s| {
        slot_doubled[s] = doubled[q];
        slot_sink[s] = if (q != small_sec or doubled[q]) sink_frames else 0;
        if (q != small_sec) {
            for (&slot_chain[s], 0..) |*n, p| n.* = chain_at(q, p);
            for (&live.chain[q], &chain_mid[q]) |*a, *b| {
                a.* = rechain();
                b.* = rechain();
            }
        }
        doubled[q] = true;
    }
    if (rehash_n != 0) rehash_t = 1;
}

noinline fn rehash_step() void {
    var end: i32 = 0;
    for (0..rehash_n) |s| {
        rehash_slot(s, rehash_t);
        end = @max(end, slot_sink[s] + rise_frames);
    }
    rehash_t += 1;
    if (rehash_t > end) rehash_t = 0;
}

/// Frame f of slot s's rehash. Writes per frame, at most: 16 buckets of
/// bucket x bucket cells and their chains (16 x 108 cells, floor_block on
/// the last sink frame) for a big row, 4 x 16 small buckets for the small table.
noinline fn rehash_slot(s: usize, f: i32) void {
    const q = slot_sec[s];
    const sink = slot_sink[s];
    const lo: i32 = F + drain_h;
    const top: i32 = F + @as(i32, if (q == small_sec) small_risen_h else bucket_h);
    if (f <= sink) {
        // Sink: the buckets and chains as they were go down to lo; the
        // chains' floor comes back on the last frame.
        const hv = top + @divTrunc((lo - top) * f, sink);
        if (q == small_sec) {
            small_table(hv, hv, palette.hash_small);
            return;
        }
        const y = row_y(q);
        for (0..2 * n_cols) |p| {
            if (p % 2 == 1 and !slot_doubled[s]) continue;
            const x = big_x(p);
            set_block(x, y, bucket, bucket, hv, palette.hash_small);
            for (0..slot_chain[s][p]) |k| {
                const t = terrace(x, y, k);
                if (f == sink) {
                    floor_block(t.x, t.y, t.w, chain_depth);
                } else {
                    set_block(t.x, t.y, t.w, chain_depth, t.h + @divTrunc((lo - t.h) * f, sink), t.c);
                }
            }
        }
        return;
    }
    // Rise: the doubled section comes up from lo (a small table still low
    // from its own height), in the table's colour on the last frame.
    const g = f - sink;
    if (g > rise_frames) return;
    const cv: u8 = if (g == rise_frames) palette.hash_bucket else palette.hash_small;
    if (q == small_sec) {
        const from: i32 = if (sink != 0) lo else F + small_h;
        small_table(from + @divTrunc((top - from) * g, rise_frames), lo + @divTrunc((top - lo) * g, rise_frames), cv);
        return;
    }
    const y = row_y(q);
    for (0..2 * n_cols) |p| {
        const x = big_x(p);
        set_block(x, y, bucket, bucket, lo + @divTrunc((top - lo) * g, rise_frames), cv);
        for (0..chain_at(q, p)) |k| {
            const t = terrace(x, y, k);
            set_block(t.x, t.y, t.w, chain_depth, lo + @divTrunc((@as(i32, t.h) - lo) * g, rise_frames), t.c);
        }
    }
}

/// The small table's old rows at height h_old and the rows a rehash adds
/// between and after them (x staggered by mid_dx) at h_new, colour cv.
fn small_table(h_old: i32, h_new: i32, cv: u8) void {
    for (0..2 * small_rows) |m| {
        const mi: i32 = @intCast(m);
        const y = small_row0 + small_dy * mi;
        const x0: i32 = small_x0 + if (m % 2 == 1) @as(i32, mid_dx) else 0;
        const hv = if (m % 2 == 1) h_new else h_old;
        for (0..n_small) |i| set_block(x0 + small_xp * @as(i32, @intCast(i)), y, small, small, hv, cv);
    }
}

/// B pressed while this district is live: queue a rehash of the sections
/// in view (refused while one is already queued, or with none ahead).
pub fn verb() bool {
    if (rehash_pending) return false;
    var secs: [rehash_secs]usize = undefined;
    if (pick(last_cam_row, &secs) == 0) return false;
    rehash_pending = true;
    return true;
}
