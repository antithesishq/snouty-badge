//! TREE district (SPEC.md 6, PLAN.md M2 "Tree"): a balanced binary tree of
//! green ridges seen from altitude, the prototype's gen_tree stored flipped
//! so the root spine is at the far end and the 45-degree forks come toward
//! the camera, down to 32 leaf mounds near the district start. Dataflow: a
//! search, the pulse-B trail of one root-to-leaf path; every key_every
//! frames a new key lights its path from the root, key_level_frames per
//! level, while the old path goes back to the ridge colours. Verb: insert,
//! a search for a new key whose leaf then grows a mound beyond it.
//!
//! The shape is fixed (no seed in the geometry): 63 nodes in heap order
//! (children of i are 2i+1 left and 2i+2 right), built once into `nodes`.
//! Rows are indexed by depth d below the root, d = root_row - ly. The seed
//! picks the initial key, whose trail row() paints; row() is a pure
//! function of (seed, ly). Dynamic edits go through world.rows() and skip
//! rows the ring does not hold.
const world = @import("../world.zig");
const palette = @import("../palette.zig");
const fixed = @import("../fixed.zig");

pub const title: []const u8 = "TREE";
pub const gloss: []const u8 = "binary search";
pub const caption: []const u8 = "B: insert a key";
pub const alt: i32 = 185;
/// The autopilot inserts from the Bus before the Tree (negative local row): from
/// altitude 185 the leaves at local rows 0..11 are already behind the camera
/// once it is inside, and the insert grows a mound past a leaf.
pub const verb_at: i32 = -40;

/// Autopilot altitude above the floor at local row ly: no track.
pub fn alt_at(ly: i32) i32 {
    _ = ly;
    return alt;
}

const W = world.W;
const F: i32 = world.floor;

// --- Tree knobs -------------------------------------------------------------

/// Local row of the root node (depth 0). The whole shape spans depths
/// 0..185 (the leaf mounds end at 185) and the insert mound 186..191, so
/// the root sits on the district's last row: the prototype's "40 rows from
/// the far end" needs a 226-row district.
const root_row = world.district_len - 1;
/// Per level: ridge height above the floor, ridge width, straight run
/// before the fork (rows); fork half-span is 64 >> level.
const hts = [6]u8{ 30, 24, 19, 15, 12, 10 };
const wid = [6]u8{ 12, 9, 7, 6, 5, 4 };
const straight = [6]u8{ 24, 14, 10, 6, 4, 0 };
/// Fork cap: this much wider than the ridge and cap_up higher, rows
/// ys - 2 .. ys + 2 around the fork row ys.
const cap_extra = 4;
const cap_up = 6;
/// Leaf mound: leaf_mound x leaf_mound cells, rows d - 2 .. d + 3 of the leaf.
const leaf_mound = 6;
/// Search trail: pulse B comet, trail_w cells wide, painted only on ridge
/// cells whose 4 neighbours are within trail_dh of their height (so the
/// ridge faces never carry the pulse).
const trail_w = 3;
const trail_dh = 2;
/// Frames between keys, frames per level of the descent, and the delay of
/// the first key after the district becomes live (it is live from the
/// preceding Bus, so the first descent is seen from there).
const key_every = 120;
const key_level_frames = 12;
const first_key_frames = 30;
/// Insert: the new mound (leaf_mound square) starts insert_gap rows beyond
/// the leaf's mound toward the camera (its centre 6 + insert_gap rows past
/// the leaf's; PLAN asks for 8, 6 is what fits in the 192 rows) and rises
/// over insert_frames to the leaf height.
const insert_gap = 0;
const insert_frames = 10;

const levels = 6;
const n_nodes = 63;
const n_leaves = 32;
/// A cell is part of the tree when it is higher than any floor cell.
const struct_min: i32 = F + 8;

// --- Shape ------------------------------------------------------------------

/// One node: centre x, depth d of its first row, level.
const Node = struct { x: u8, d: u8, lvl: u8 };

var nodes: [n_nodes]Node = undefined;
var nodes_ready = false;

/// Depth where each level of a root-to-leaf path starts (the same for every
/// path), plus the end of the trail rows; the descent schedule.
var level_d: [levels + 1]i32 = undefined;

fn ensure_nodes() void {
    if (nodes_ready) return;
    nodes[0] = .{ .x = 128, .d = 0, .lvl = 0 };
    var i: usize = 0;
    while (i < n_nodes / 2) : (i += 1) {
        const n = nodes[i];
        const ys = @as(i32, n.d) + straight[n.lvl];
        const dx = @as(i32, 64) >> @intCast(n.lvl);
        const cd: u8 = @intCast(ys + dx);
        nodes[2 * i + 1] = .{ .x = @intCast(@as(i32, n.x) - dx), .d = cd, .lvl = n.lvl + 1 };
        nodes[2 * i + 2] = .{ .x = @intCast(@as(i32, n.x) + dx), .d = cd, .lvl = n.lvl + 1 };
    }
    // Nodes 0, 1, 3, 7, 15, 31 are the leftmost path; its depths serve all.
    var l: usize = 0;
    var k: usize = 0;
    while (l < levels) : (l += 1) {
        level_d[l] = nodes[k].d;
        k = 2 * k + 1;
    }
    // The last trail step is centred one row above the leaf and covers it.
    level_d[levels] = level_d[levels - 1] + 1;
    nodes_ready = true;
}

/// Paint the tree's cells on depth row d into h/c (other cells untouched).
/// Nodes in heap order (box, fork cap, then both branches) give the same
/// cells as the prototype's depth-first recursion: where a later node's
/// cells overlap an earlier one's they carry the same height and colour.
fn struct_row(d: i32, h: *[W]u8, c: *[W]u8) void {
    for (nodes) |n| {
        const lvl = n.lvl;
        const nd: i32 = n.d;
        if (d < nd - 2) break; // heap order is sorted by depth
        const x: i32 = n.x;
        const hv: u8 = @intCast(F + hts[lvl]);
        const col = palette.tree_level[lvl];
        const ys = nd + straight[lvl];
        if (lvl == levels - 1) {
            if (d >= nd - 2 and d < nd + 4) world.span(h, c, x - leaf_mound / 2, leaf_mound, hv, col);
            continue;
        }
        const dx = @as(i32, 64) >> @intCast(lvl);
        if (d > ys + dx) continue;
        if (d >= nd and d <= ys) world.span(h, c, x - wid[lvl] / 2, wid[lvl], hv, col);
        if (d >= ys - 2 and d < ys + 3) {
            const nw = @as(i32, wid[lvl]) + cap_extra;
            world.span(h, c, x - @divTrunc(nw, 2), nw, hv + cap_up, col);
        }
        if (d > ys) {
            const s = d - ys;
            const cw: i32 = wid[lvl + 1];
            const bh: u8 = @intCast(F + hts[lvl + 1]);
            const bc = palette.tree_level[lvl + 1];
            world.span(h, c, x - s - @divTrunc(cw, 2), cw, bh, bc);
            world.span(h, c, x + s - @divTrunc(cw, 2), cw, bh, bc);
        }
    }
}

/// Node index of the leaf of `key` (bit 4 - level picks the side: 1 = right).
fn leaf_of(key: u8) usize {
    var k: usize = 0;
    var l: u3 = 0;
    while (l < levels - 1) : (l += 1) {
        const side = (key >> (4 - l)) & 1;
        k = 2 * k + 1 + side;
    }
    return k;
}

// --- Search trail -----------------------------------------------------------

/// Depth rows d - 1, d, d + 1 of the tree's heights (0 off the tree).
const Rows3 = [3][W]u8;

/// Paint (or, with light = false, un-paint) the trail of `key` on depth row d.
/// hs holds the tree heights of rows d - 1, d, d + 1; out_c is row d's colour;
/// ridge is row d's tree colour (used when un-painting).
const TrailCtx = struct {
    hs: *const Rows3,
    out_c: *[W]u8,
    ridge: ?*const [W]u8,

    pub fn cell(self: TrailCtx, x: i32, p: i32) void {
        const i: usize = @intCast(x & (W - 1));
        const il: usize = @intCast((x - 1) & (W - 1));
        const ir: usize = @intCast((x + 1) & (W - 1));
        const hc: i32 = self.hs[1][i];
        if (hc < struct_min) return;
        const lim = hc - trail_dh;
        if (self.hs[1][il] < lim or self.hs[1][ir] < lim or self.hs[0][i] < lim or self.hs[2][i] < lim) return;
        // The B range rotates toward lower indices, so counting down along
        // the path makes the light run from the root to the leaf.
        self.out_c[i] = if (self.ridge) |r| r[i] else @intCast(palette.pulse_b + ((-p) & 15));
    }
};

/// The trail of `key` on depth row d: the prototype's path through the
/// nodes (x, d) and (x, ys) of the root-to-leaf path, root first.
fn trail_row(key: u8, d: i32, ctx: TrailCtx) void {
    if (d < 0 or d >= level_d[levels]) return;
    var k: usize = 0;
    var p: i32 = 0;
    var l: u3 = 0;
    while (true) : (l += 1) {
        const n = nodes[k];
        const x: i32 = n.x;
        const ys = @as(i32, n.d) + straight[n.lvl];
        p = world.leg_row(d, x, n.d, x, ys, trail_w, p, ctx);
        if (l == levels - 1) break;
        k = 2 * k + 1 + ((key >> (4 - l)) & 1);
        const c = nodes[k];
        p = world.leg_row(d, x, ys, c.x, c.d, trail_w, p, ctx);
    }
}

/// Fill hs[j] with the tree heights of depth row d - 1 + j.
fn tree_heights(hs: *Rows3, j: usize, d: i32) void {
    var junk: [W]u8 = undefined;
    @memset(&hs[j], 0);
    struct_row(d, &hs[j], &junk);
}

fn seeded(seed: u32, salt: u32) fixed.Rng {
    const s = seed ^ salt;
    var rng: fixed.Rng = .{ .s = if (s == 0) 1 else s };
    _ = rng.next();
    _ = rng.next();
    return rng;
}

/// The key whose trail the static rows show.
fn initial_key(seed: u32) u8 {
    var rng = seeded(seed, 0x7EE5_EA2C);
    return @intCast(rng.next() >> 27);
}

// --- Static rows ------------------------------------------------------------

/// Static architecture of local row `ly` over the floor already in h/c: the
/// tree, then the initial key's trail.
pub fn row(seed: u32, ly: i32, h: *[W]u8, c: *[W]u8) void {
    ensure_nodes();
    const d = root_row - ly;
    struct_row(d, h, c);
    if (d < 0 or d >= level_d[levels]) return;
    var hs: Rows3 = undefined;
    tree_heights(&hs, 0, d - 1);
    hs[1] = h.*; // floor cells are all below struct_min
    tree_heights(&hs, 2, d + 1);
    trail_row(initial_key(seed), d, .{ .hs = &hs, .out_c = c, .ridge = null });
}

// --- Live state -------------------------------------------------------------

var seg: world.Segment = .{ .kind = .tree, .y0 = 0, .len = 0, .seed = 1, .index = 0xFFFF_FFFF };
var tick_rng: fixed.Rng = .{ .s = 1 };
/// The key the rows show (above the descent front) and the one lighting.
var old_key: u8 = 0;
var cur_key: u8 = 0;
/// Descent: frames since the key changed, and the next depth row to repaint
/// (level_d[levels] = done).
var descent_t: i32 = 0;
var descent_row: i32 = 0;
/// Frames until the next key.
var key_wait: i32 = 0;
/// Insert: requested (runs after the current descent), the running descent
/// is an insert, and the rising mound (frames left, 0 = none) at leaf x.
var insert_pending = false;
var insert_descent = false;
var mound_left: i32 = 0;
var mound_x: i32 = 0;
/// Leaves that have grown an insert mound in this visit (bit = key).
var inserted: u32 = 0;

/// The segment becomes live: the rows show the seed's key; reset dynamics.
pub fn enter(s: world.Segment) void {
    ensure_nodes();
    seg = s;
    tick_rng = seeded(s.seed, 0x71C4_7EE5);
    cur_key = initial_key(s.seed);
    old_key = cur_key;
    descent_t = 0;
    descent_row = level_d[levels];
    key_wait = first_key_frames;
    insert_pending = false;
    insert_descent = false;
    mound_left = 0;
    inserted = 0;
}

/// World row of depth row d.
fn world_y(d: i32) i32 {
    return seg.y0 + root_row - d;
}

/// Repaint depth rows [descent_row, to): the old key's trail back to the
/// ridge colour, then the new key's lit.
fn repaint_to(to: i32) void {
    if (descent_row >= to) return;
    var hs: Rows3 = undefined;
    var ridge_h: [W]u8 = undefined;
    var ridge_c: [W]u8 = undefined;
    tree_heights(&hs, 0, descent_row - 1);
    tree_heights(&hs, 1, descent_row);
    var d = descent_row;
    while (d < to) : (d += 1) {
        tree_heights(&hs, 2, d + 1);
        if (world.rows(world_y(d))) |r| {
            if (old_key != cur_key) {
                @memset(&ridge_h, 0);
                struct_row(d, &ridge_h, &ridge_c);
                trail_row(old_key, d, .{ .hs = &hs, .out_c = r.c, .ridge = &ridge_c });
            }
            trail_row(cur_key, d, .{ .hs = &hs, .out_c = r.c, .ridge = null });
        }
        hs[0] = hs[1];
        hs[1] = hs[2];
    }
    descent_row = to;
}

/// The leaf_mound rows from depth d_first of a mound centred on x, rising:
/// frame `f` of insert_frames.
fn paint_mound(x: i32, d_first: i32, f: i32) void {
    const top = F + @divTrunc(@as(i32, hts[levels - 1]) * f, insert_frames);
    var d = d_first;
    while (d < d_first + leaf_mound) : (d += 1) {
        const r = world.rows(world_y(d)) orelse continue;
        var k: i32 = 0;
        while (k < leaf_mound) : (k += 1) {
            const i: usize = @intCast((x - leaf_mound / 2 + k) & (W - 1));
            if (r.h[i] < top) r.h[i] = @intCast(top);
            r.c[i] = palette.tree_level[levels - 1];
        }
    }
}

/// First depth row of the insert mound: beyond the leaf mound (which ends
/// at leaf d + 3) by insert_gap.
fn mound_d() i32 {
    return level_d[levels - 1] + 4 + insert_gap;
}

/// Per-frame dataflow: start a key when due (an insert waits for the
/// running descent), advance the descent, raise the insert mound.
pub fn tick(frame: u32, cam_row: i32) void {
    _ = frame;
    _ = cam_row;
    const done = descent_row >= level_d[levels];
    if (key_wait > 0) key_wait -= 1;
    if (done and (key_wait == 0 or insert_pending)) {
        old_key = cur_key;
        cur_key = @intCast(tick_rng.next() >> 27);
        insert_descent = insert_pending;
        insert_pending = false;
        descent_t = 0;
        descent_row = 0;
        key_wait = key_every;
    }
    if (descent_row < level_d[levels]) {
        // Level L covers depth rows [level_d[L], level_d[L + 1]) in
        // key_level_frames frames.
        const lv: usize = @intCast(@min(@divTrunc(descent_t, key_level_frames), levels - 1));
        const s = descent_t - @as(i32, @intCast(lv)) * key_level_frames + 1;
        const a = level_d[lv];
        const b = level_d[lv + 1];
        repaint_to(@min(b, a + @divTrunc((b - a) * s, key_level_frames)));
        descent_t += 1;
        if (descent_row >= level_d[levels] and insert_descent) {
            insert_descent = false;
            mound_x = nodes[leaf_of(cur_key)].x;
            mound_left = insert_frames;
            inserted |= @as(u32, 1) << @intCast(cur_key);
        }
    }
    if (mound_left > 0) {
        mound_left -= 1;
        paint_mound(mound_x, mound_d(), insert_frames - mound_left);
    }
}

/// B pressed while this district is live: insert a key (a search for it
/// from the root, then its mound), after the running search.
pub fn verb() void {
    insert_pending = true;
}
