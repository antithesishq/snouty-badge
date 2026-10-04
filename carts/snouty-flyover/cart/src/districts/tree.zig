//! TREE district (SPEC.md 6, PLAN.md M2 "Tree", M3 "Tree insert from
//! inside"): a balanced binary tree of green ridges seen from altitude, the
//! root spine at the district start and the 45-degree forks running away
//! from the camera, out to 32 leaf mounds near the far end. Dataflow: a
//! search, the pulse-B trail of one root-to-leaf path; every key_every
//! frames a new key lights its path from the root, key_level_frames per
//! level, running ahead along the flight, while the old path goes back to
//! the ridge colours. Verb: insert, a new leaf where the camera sees it: a
//! fast search lights the path to its parent, a new branch grows out of the
//! parent and the leaf rises at its end, a tall white block (PLAN.md M4.2).
//!
//! The shape is fixed (no seed in the geometry): 63 nodes in heap order
//! (children of i are 2i+1 left and 2i+2 right), built once into `nodes`.
//! Rows are indexed by depth d below the root, d = ly - root_row. The seed
//! picks the initial key, whose trail row() paints; row() is a pure
//! function of (seed, ly). Dynamic edits go through world.rows() and skip
//! rows the ring does not hold.
const world = @import("../world.zig");
const palette = @import("../palette.zig");
const fixed = @import("../fixed.zig");
const camera = @import("../camera.zig");

pub const title: []const u8 = "TREE";
pub const gloss: []const u8 = "binary search";
pub const caption: []const u8 = "B: insert a key";
pub const alt: i32 = 185;
/// Local row where the autopilot inserts. From altitude 185 with the
/// look-down horizon (row 52) the new leaf lands about 123 rows ahead
/// (local row ~163, insert_aim_sy) and 48 cells to the side, and stays in
/// view for about 60 frames, until it is 75 rows ahead.
pub const verb_at: i32 = 40;

/// Autopilot altitude above the floor at local row ly: no track.
pub fn alt_at(ly: i32) i32 {
    _ = ly;
    return alt;
}

const W = world.W;
const F: i32 = world.floor;

// --- Tree knobs -------------------------------------------------------------

/// Local row of the root node (depth 0). The whole shape spans depths
/// 0..185 (the leaf mounds end at 185) and inserts may use the rows up to
/// 191, so the root sits on the district's first row.
const root_row = 0;
comptime {
    if (root_row + 192 > world.district_len) @compileError("tree does not fit the district");
}
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
/// Insert (PLAN.md M4.2 "B everywhere"): the new key's leaf goes where the
/// camera sees it, whatever the altitude and however far into the district:
/// its foot on screen row insert_aim_sy at the press (camera.rows_ahead, at
/// least insert_near rows ahead), insert_aim_px columns beside the screen
/// centre (clear of the anteater), alternating right and left, at most at
/// the district's last rows; with fewer than insert_min_ahead rows left
/// ahead the press is refused (the leaf would rise below the screen). Its
/// parent is the tree node nearest before it that a tree branch can reach
/// it from (a 45-degree leg off the node's straight run, then straight on):
/// a search for the parent lights its path from the root, insert_rows
/// depth rows per frame (rows nearer the camera than insert_skip are not
/// repainted: nobody sees them), the new branch grows out of the parent at
/// the same rate, lit with the search's pulse, and the leaf rises over
/// insert_frames to insert_h in insert_colour: a white block insert_w x
/// insert_dep cells, as tall as the root's fork cap so it never makes the
/// camera climb more than the tree does. A press during an insert finishes
/// the running one at once (its branch and leaf stay) and starts the next.
const insert_aim_sy = 100;
const insert_near = 24;
const insert_min_ahead = 20;
const insert_aim_px = 40;
const insert_off_min = 12;
const insert_off_max = 48;
const insert_rows = 16;
const insert_skip = 16;
const insert_frames = 6;
const insert_h = 36;
const insert_w = 14;
const insert_dep = 8;
const insert_colour = palette.white;
/// The side alternates per insert unless the tree in front of the leaf
/// (in_front over in_front_rows rows) hides it insert_hide_margin more
/// than the other side would be hidden (one leaf row of a level-1 ridge).
const in_front_rows = 4;
const insert_hide_margin = insert_w * 24;
/// The new branch: link_w cells wide, link_h above the floor (a level-3 ridge).
const link_w = 4;
const link_h = 15;

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

// --- Search trail -----------------------------------------------------------

/// Depth rows d - 1, d, d + 1 of the tree's heights (0 off the tree).
const Rows3 = [3][W]u8;

/// Paint the trail of `key` on depth row d: hs holds the tree heights of
/// rows d - 1, d, d + 1; out_h and out_c are row d. Cells an insert raised
/// (out_h above the tree) keep their colour.
const TrailCtx = struct {
    hs: *const Rows3,
    out_h: *const [W]u8,
    out_c: *[W]u8,

    pub fn cell(self: TrailCtx, x: i32, p: i32) void {
        const i: usize = @intCast(x & (W - 1));
        const il: usize = @intCast((x - 1) & (W - 1));
        const ir: usize = @intCast((x + 1) & (W - 1));
        const hc: i32 = self.hs[1][i];
        if (hc < struct_min or self.out_h[i] != hc) return;
        const lim = hc - trail_dh;
        if (self.hs[1][il] < lim or self.hs[1][ir] < lim or self.hs[0][i] < lim or self.hs[2][i] < lim) return;
        self.out_c[i] = pulse(p);
    }
};

/// The B range rotates toward lower indices, so counting down along the
/// path makes the light run from the root to the leaf.
fn pulse(p: i32) u8 {
    return @intCast(palette.pulse_b + ((-p) & 15));
}

/// A trail: the path of `key` from the root down to its level-`stop` node,
/// whose straight run it follows to depth row `end` (a search: the leaf, so
/// `end` is level_d[levels - 1]; an insert: the new branch's parent).
const Trail = struct { key: u8, stop: u3, end: i32 };

/// The trail's cells on depth row d: the prototype's path through the
/// nodes (x, d) and (x, ys) of the path, root first. Returns the pulse
/// phase at the trail's end (for any d).
fn trail_legs(t: Trail, d: i32, ctx: anytype) i32 {
    var k: usize = 0;
    var p: i32 = 0;
    var l: u3 = 0;
    while (true) : (l += 1) {
        const n = nodes[k];
        const x: i32 = n.x;
        const ys = if (l == t.stop) t.end else @as(i32, n.d) + straight[n.lvl];
        p = world.leg_row(d, x, n.d, x, ys, trail_w, p, ctx);
        if (l == t.stop) return p;
        k = 2 * k + 1 + ((t.key >> (4 - l)) & 1);
        const c = nodes[k];
        p = world.leg_row(d, x, ys, c.x, c.d, trail_w, p, ctx);
    }
}

fn trail_row(t: Trail, d: i32, ctx: TrailCtx) void {
    if (d < 0 or d >= level_d[levels]) return;
    _ = trail_legs(t, d, ctx);
}

const NoCells = struct {
    pub fn cell(_: NoCells, _: i32, _: i32) void {}
};

/// The search trail of `key`, root to leaf.
fn search(key: u8) Trail {
    return .{ .key = key, .stop = levels - 1, .end = level_d[levels - 1] };
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
    const d = ly - root_row;
    struct_row(d, h, c);
    if (d < 0 or d >= level_d[levels]) return;
    var hs: Rows3 = undefined;
    tree_heights(&hs, 0, d - 1);
    hs[1] = h.*; // floor cells are all below struct_min
    tree_heights(&hs, 2, d + 1);
    trail_row(search(initial_key(seed)), d, .{ .hs = &hs, .out_h = h, .out_c = c });
}

// --- Live state -------------------------------------------------------------

var seg: world.Segment = .{ .kind = .tree, .y0 = 0, .len = 0, .seed = 1, .index = 0xFFFF_FFFF };
var tick_rng: fixed.Rng = .{ .s = 1 };
/// The trail lighting (the rows past the descent front show older ones).
var cur: Trail = .{ .key = 0, .stop = levels - 1, .end = 0 };
/// Descent: frames since the trail changed, the next depth row to repaint,
/// the row after the trail's last (descent_row >= trail_end = done), and
/// frames per level of a search.
var descent_t: i32 = 0;
var descent_row: i32 = 0;
var trail_end: i32 = 0;
/// Frames until the next key.
var key_wait: i32 = 0;

/// One insert: the trail to its parent (none when no node reaches the
/// leaf), the parent's x and the depth row e where the new branch leaves
/// its straight run, the leaf's centre x (unwrapped, relative to the
/// parent's) and first depth row, and the pulse phase at e (the trail's
/// end, so the light runs on into the branch).
const Insert = struct { t: ?Trail, px: i32, e: i32, x: i32, d: i32, p: i32 };
/// The insert planned by verb() (pending until the next tick) and the one
/// running; its phases: the trail (insert_descent), the branch (branch_row
/// to branch_end), the leaf (leaf_left frames of the rise left).
var insert_pending = false;
var planned: Insert = undefined;
var ins: Insert = undefined;
var ins_live = false;
var insert_descent = false;
var branch_row: i32 = 0;
var branch_end: i32 = 0;
var leaf_left: i32 = 0;
/// Side of the next insert (false = right).
var insert_left = false;

/// The segment becomes live: the rows show the seed's key; reset dynamics.
pub fn enter(s: world.Segment) void {
    ensure_nodes();
    seg = s;
    tick_rng = seeded(s.seed, 0x71C4_7EE5);
    cur = search(initial_key(s.seed));
    descent_t = 0;
    trail_end = level_d[levels];
    descent_row = trail_end;
    key_wait = first_key_frames;
    insert_pending = false;
    ins_live = false;
    insert_descent = false;
    branch_row = 0;
    branch_end = 0;
    leaf_left = 0;
    insert_left = false;
}

/// World row of depth row d.
fn world_y(d: i32) i32 {
    return seg.y0 + root_row + d;
}

/// Repaint depth rows [descent_row, to): every lit tree cell back to its
/// ridge colour (clearing whichever trail lit it, so a dropped search
/// leaves none), then the current trail lit. Insert cells (white, or raised
/// above the tree) are left alone.
fn repaint_to(to: i32) void {
    if (descent_row >= to) return;
    var hs: Rows3 = undefined;
    var ridge_c: [W]u8 = undefined;
    tree_heights(&hs, 0, descent_row - 1);
    tree_heights(&hs, 1, descent_row);
    var d = descent_row;
    while (d < to) : (d += 1) {
        tree_heights(&hs, 2, d + 1);
        if (world.rows(world_y(d))) |r| {
            var ridge_h = hs[1];
            struct_row(d, &ridge_h, &ridge_c);
            for (hs[1], r.c, ridge_c) |th, *c, rc| {
                if (th >= struct_min and c.* -% palette.pulse_b < 16) c.* = rc;
            }
            trail_row(cur, d, .{ .hs = &hs, .out_h = r.h, .out_c = r.c });
        }
        hs[0] = hs[1];
        hs[1] = hs[2];
    }
    descent_row = to;
}

/// Cells of the new branch: raised to link_h (never lowered, so a taller
/// ridge it leaves keeps its shape) and lit with the pulse.
const BranchCtx = struct {
    h: *[W]u8,
    c: *[W]u8,

    pub fn cell(self: BranchCtx, x: i32, p: i32) void {
        const i: usize = @intCast(x & (W - 1));
        if (self.h[i] > F + link_h) return;
        self.h[i] = F + link_h;
        self.c[i] = pulse(p);
    }
};

/// Depth rows [branch_row, to) of the running insert's branch: a 45-degree
/// leg from the parent's run out to the leaf's x, then straight on to it.
fn branch_to(to: i32) void {
    while (branch_row < to) : (branch_row += 1) {
        const r = world.rows(world_y(branch_row)) orelse continue;
        const ctx: BranchCtx = .{ .h = r.h, .c = r.c };
        const ye = ins.e + @as(i32, @intCast(@abs(ins.x - ins.px)));
        const p = world.leg_row(branch_row, ins.px, ins.e, ins.x, ye, link_w, ins.p, ctx);
        _ = world.leg_row(branch_row, ins.x, ye, ins.x, ins.d, link_w, p, ctx);
    }
}

/// The running insert's leaf at frame `f` of insert_frames of its rise.
fn paint_leaf(f: i32) void {
    const top = F + @divTrunc(insert_h * f, insert_frames);
    var d = ins.d;
    while (d < ins.d + insert_dep) : (d += 1) {
        const r = world.rows(world_y(d)) orelse continue;
        var k: i32 = 0;
        while (k < insert_w) : (k += 1) {
            const i: usize = @intCast((ins.x - insert_w / 2 + k) & (W - 1));
            if (r.h[i] < top) r.h[i] = @intCast(top);
            r.c[i] = insert_colour;
        }
    }
}

/// Finish the running insert at once: the rest of its branch, its leaf full height.
fn finish_insert() void {
    if (!ins_live) return;
    branch_to(branch_end);
    paint_leaf(insert_frames);
    ins_live = false;
    insert_descent = false;
    leaf_left = 0;
}

/// The insert for a leaf centred on x from depth row d: its parent is the
/// node whose run a branch leaves nearest before d (see insert_aim_sy).
fn plan_insert(x: i32, d: i32) Insert {
    var best: Insert = .{ .t = null, .px = x, .e = d, .x = x, .d = d, .p = 0 };
    var best_k: usize = 0;
    var best_e: i32 = -1;
    var best_dx: i32 = W;
    for (nodes, 0..) |n, k| {
        // Wrapped offset from the node to the leaf, in [-W/2, W/2).
        const dx = @mod(x - n.x + W / 2, W) - W / 2;
        const adx: i32 = @intCast(@abs(dx));
        const run0: i32 = n.d;
        const run1: i32 = if (n.lvl == levels - 1) run0 + 3 else run0 + straight[n.lvl];
        const e = @min(run1, d - adx);
        if (e < run0 or e < best_e or (e == best_e and adx >= best_dx)) continue;
        best_k = k;
        best_e = e;
        best_dx = adx;
    }
    if (best_e < 0) return best; // nothing reaches it: the leaf alone
    const n = nodes[best_k];
    // The path to the parent: its index within its level, MSB first, is
    // the key's top bits.
    const idx = best_k + 1 - (@as(usize, 1) << @intCast(n.lvl));
    const t: Trail = .{ .key = @intCast(idx << @intCast(levels - 1 - n.lvl)), .stop = @intCast(n.lvl), .end = best_e };
    best.t = t;
    best.px = n.x;
    best.e = best_e;
    best.x = @as(i32, n.x) + @mod(x - n.x + W / 2, W) - W / 2;
    best.p = trail_legs(t, -1 << 20, NoCells{});
    return best;
}

/// Per-frame dataflow: start an insert (dropping the running search) or a
/// key when due, advance the descent, grow the insert's branch and leaf.
pub fn tick(frame: u32, cam_row: i32) void {
    _ = frame;
    if (key_wait > 0) key_wait -= 1;
    if (insert_pending) {
        insert_pending = false;
        finish_insert();
        start_insert(cam_row);
    } else if (descent_row >= trail_end and key_wait == 0) {
        cur = search(@intCast(tick_rng.next() >> 27));
        descent_t = 0;
        descent_row = 0;
        trail_end = level_d[levels];
        key_wait = key_every;
    }
    if (descent_row < trail_end) {
        // Rows behind the ring's back edge have nothing to repaint: skip them.
        const back = cam_row - world.keep_behind - world_y(0);
        if (insert_descent) {
            descent_row = @max(descent_row, @min(trail_end, back));
            repaint_to(@min(trail_end, descent_row + insert_rows));
        } else {
            // Level L covers depth rows [level_d[L], level_d[L + 1]) in
            // key_level_frames frames.
            const lv: usize = @intCast(@min(@divTrunc(descent_t, key_level_frames), levels - 1));
            const s = descent_t - @as(i32, @intCast(lv)) * key_level_frames + 1;
            const a = level_d[lv];
            const b = level_d[lv + 1];
            descent_row = @max(descent_row, @min(b, back));
            repaint_to(@min(b, a + @divTrunc((b - a) * s, key_level_frames)));
            descent_t += 1;
        }
    }
    if (!ins_live) return;
    if (insert_descent) {
        if (descent_row < trail_end) return;
        insert_descent = false;
        if (branch_row >= branch_end) leaf_left = insert_frames;
    }
    if (branch_row < branch_end) {
        branch_to(@min(branch_end, branch_row + insert_rows));
        if (branch_row >= branch_end) leaf_left = insert_frames;
    } else if (leaf_left > 0) {
        leaf_left -= 1;
        paint_leaf(insert_frames - leaf_left);
        if (leaf_left == 0) ins_live = false;
    }
}

/// Start the planned insert: its trail from the first row the camera can
/// see (insert_skip ahead), then its branch, then its leaf.
fn start_insert(cam_row: i32) void {
    ins = planned;
    ins_live = true;
    branch_row = @max(0, ins.e - link_w / 2); // never into the Bus before
    branch_end = if (ins.e < ins.d or ins.x != ins.px) ins.d else branch_row;
    leaf_left = 0;
    key_wait = key_every;
    if (ins.t) |t| {
        cur = t;
        insert_descent = true;
        trail_end = ins.e + 2; // the last trail step covers ins.e + 1
        descent_row = @max(0, cam_row + insert_skip - world_y(0));
    } else {
        insert_descent = false;
        descent_row = trail_end;
        branch_end = branch_row;
        leaf_left = insert_frames;
    }
}

/// How much of the tree stands in front of a leaf centred on x from depth
/// row d: the sum of its ridge heights above the floor over the leaf's
/// columns on in_front_rows rows nearer the camera (4, 8, ... rows).
fn in_front(x: i32, d: i32) i32 {
    var h: [W]u8 = undefined;
    var c: [W]u8 = undefined;
    var sum: i32 = 0;
    var k: i32 = 1;
    while (k <= in_front_rows) : (k += 1) {
        @memset(&h, F);
        struct_row(d - 4 * k, &h, &c);
        var j: i32 = 0;
        while (j < insert_w) : (j += 1) sum += h[@intCast((x - insert_w / 2 + j) & (W - 1))] - F;
    }
    return sum;
}

/// B pressed while this district is live: insert a key where the camera
/// sees it (a search for its parent from the root, a new branch, its
/// leaf), dropping the running search; refused in the district's last
/// rows, where the leaf would rise below the screen.
pub fn verb() bool {
    const cl = camera.cam_row() - world_y(0);
    const last = world.district_len - root_row - insert_dep;
    const d = @min(cl + camera.rows_ahead(insert_aim_sy, F, insert_near), last);
    if (cl < 0 or d - cl < insert_min_ahead) return false;
    const off: i32 = @max(insert_off_min, @min(insert_off_max, @divTrunc((d - cl) * insert_aim_px, 100)));
    // The view's centre line at the leaf's row leans with the heading (the
    // autopilot's serpentine puts it 30 cells off the camera's x there).
    const cx = (camera.cam.x + camera.sin(camera.cam.yaw) * (d - cl)) >> fixed.Q;
    // Alternate sides, unless the tree hides this side's leaf more.
    var left = insert_left;
    const here = in_front(cx + if (left) -off else off, d);
    const there = in_front(cx + if (left) off else -off, d);
    if (here > there + insert_hide_margin) left = !left;
    planned = plan_insert((cx + if (left) -off else off) & (W - 1), d);
    insert_left = !left;
    insert_pending = true;
    return true;
}
