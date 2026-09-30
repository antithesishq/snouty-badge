//! SORT district (SPEC.md 6, PLAN.md M1 constants): 64 bars of 4 cells
//! across the strip, 17 bands of 7 rows along it, each band a seeded
//! permutation of 0..63 drawn as bar heights and hues. A live quicksort
//! (Lomuto partition, last element pivot, explicit range stack) runs on the
//! nearest unsorted band ahead of the camera, 2 swaps per frame, and repaints
//! the two bars after every swap; the pivot bar is white while its partition
//! runs. B shuffles that band in one frame and re-sorts it at 8 swaps per
//! frame. A finished band is a rainbow ramp.
//!
//! row() is a pure function of (seed, ly): the layout of the segment being
//! generated lives in the `gen` slot (rebuilt when the seed changes), the one
//! being ticked in the `live` slot (rebuilt by enter()). The two are never
//! the same segment once the live one has been edited, because the ring is
//! shorter than a Bus + district cycle (PLAN.md "Ring rule for ticks").
const world = @import("../world.zig");
const palette = @import("../palette.zig");
const fixed = @import("../fixed.zig");

pub const title: []const u8 = "SORT";
pub const gloss: []const u8 = "quicksort, live";
pub const caption: []const u8 = "B: shuffle the band";
pub const alt: i32 = 110;
pub const verb_at: i32 = 60;

// --- Sort knobs -------------------------------------------------------------

/// Bars across the strip and their width in cells (bars * bar_w = world.W).
const bars = 64;
const bar_w = 4;
/// Bands along the district: band r covers local rows band_ly0 + band_pitch * r
/// .. + band_depth - 1 (7 deep, 3 rows of floor between bands).
const bands = 17;
const band_ly0 = 14;
const band_pitch = 10;
const band_depth = 7;
/// Bar height floor + bar_h0 + v * bar_h_span / bars.
const bar_h0 = 6;
const bar_h_span = 74;
/// Hue steps: colour sort_hue0 + 2 * (v * hues / bars).
const hues = 24;
/// Swaps per frame of the running sort, normally and after B (shuffle).
const swaps_slow = 2;
const swaps_fast = 8;
/// Compares allowed per swap of budget in one frame (bounds the frame's work
/// when a partition scans a long run without swapping).
const cmps_per_swap = 16;
/// Bars rewritten per frame at most: 2 per swap of budget + 2 (the pivot
/// bars of a partition ending and the next one starting). Bounds the tail of
/// a sort, where many tiny partitions end without a swap.
const bars_extra = 2;
/// The running band is the nearest unsorted band whose last row is at or
/// beyond cam_row + work_lead. PLAN.md says cam_row - 8 (lead -8), but from
/// cruise altitude 90 the first terrain on screen is ~45 rows ahead, so the
/// swaps would all happen out of sight; 40 keeps them at the bottom of the view.
const work_lead: i32 = 40;
/// Band r starts with r / (bands - 1) of its quicksort partitions already
/// done (and resumes from there when it runs), so the static field reads as
/// the concept's staircase (sort.png: coarse near, finished rainbow ramps
/// far). false: every band starts as a plain permutation.
const presort = true;

comptime {
    if (bars * bar_w != world.W) @compileError("sort bars must cover the strip");
}

// --- Quicksort machine ------------------------------------------------------

/// Incremental Lomuto quicksort over one band's 64 values, resumable at any
/// compare. Ranges are pushed larger first so the smaller is sorted first:
/// the stack depth stays at log2(64) + 1.
const Sorter = struct {
    stack: [8][2]u8 = undefined,
    sp: u8 = 0,
    lo: u8 = 0,
    hi: u8 = 0,
    i: u8 = 0,
    j: u8 = 0,
    in_part: bool = false,
    done: bool = true,

    fn start(s: *Sorter) void {
        s.* = .{ .sp = 1, .done = false };
        s.stack[0] = .{ 0, bars - 1 };
    }

    /// True if bar k is the pivot of the partition in progress (drawn white).
    fn is_pivot(s: *const Sorter, k: usize) bool {
        return s.in_part and k == s.hi;
    }

    fn push(s: *Sorter, lo: i32, hi: i32) void {
        if (lo >= hi) return;
        s.stack[s.sp] = .{ @intCast(lo), @intCast(hi) };
        s.sp += 1;
    }

    /// Run until `max_swaps` swaps (a pivot placement counts), `max_cmps`
    /// compares, `max_parts` finished partitions, the end of the sort, or
    /// before a step could take the repaints past `max_paints` (a step
    /// repaints at most 2 bars). out.repaint(k) is called for every bar whose
    /// value or pivot state changed. Returns the partitions finished.
    fn run(s: *Sorter, v: *[bars]u8, max_swaps: u32, max_cmps: u32, max_parts: u32, max_paints: u32, ctx: anytype) u32 {
        var swaps: u32 = 0;
        var cmps: u32 = 0;
        var parts: u32 = 0;
        var paints: u32 = 0;
        const Counted = struct {
            inner: @TypeOf(ctx),
            n: *u32,
            fn repaint(c: @This(), k: usize) void {
                c.n.* += 1;
                c.inner.repaint(k);
            }
        };
        const out: Counted = .{ .inner = ctx, .n = &paints };
        while (!s.done and swaps < max_swaps and cmps < max_cmps and parts < max_parts and paints + 2 <= max_paints) {
            if (!s.in_part) {
                if (s.sp == 0) {
                    s.done = true;
                    break;
                }
                s.sp -= 1;
                s.lo = s.stack[s.sp][0];
                s.hi = s.stack[s.sp][1];
                s.i = s.lo;
                s.j = s.lo;
                s.in_part = true;
                out.repaint(s.hi);
                continue;
            }
            if (s.j < s.hi) {
                cmps += 1;
                if (v[s.j] < v[s.hi]) {
                    if (s.i != s.j) {
                        const t = v[s.i];
                        v[s.i] = v[s.j];
                        v[s.j] = t;
                        swaps += 1;
                        out.repaint(s.i);
                        out.repaint(s.j);
                    }
                    s.i += 1;
                }
                s.j += 1;
                continue;
            }
            // Partition done: the pivot moves to i, both sides are pushed.
            s.in_part = false;
            parts += 1;
            if (s.i != s.hi) {
                const t = v[s.i];
                v[s.i] = v[s.hi];
                v[s.hi] = t;
                swaps += 1;
                out.repaint(s.i);
            }
            out.repaint(s.hi);
            const lo: i32 = s.lo;
            const hi: i32 = s.hi;
            const p: i32 = s.i;
            if (p - lo > hi - p) {
                s.push(lo, p - 1);
                s.push(p + 1, hi);
            } else {
                s.push(p + 1, hi);
                s.push(lo, p - 1);
            }
            // A sort whose last partition just ended is done now, not on the
            // next call (so a band never sits "unsorted" with nothing to do).
            if (s.sp == 0) s.done = true;
        }
        return parts;
    }
};

const Quiet = struct {
    fn repaint(_: Quiet, _: usize) void {}
};

const unlimited: u32 = 1 << 20;

// --- Layouts ----------------------------------------------------------------

/// One Sort segment: every band's values and its quicksort state.
const Layout = struct {
    seed: u32 = 0,
    vals: [bands][bars]u8 = undefined,
    sorters: [bands]Sorter = undefined,
};

/// Build the layout of `seed`: Fisher-Yates per band from one xorshift, then
/// (presort) band r runs r / (bands - 1) of its quicksort partitions.
fn build(l: *Layout, seed: u32) void {
    l.seed = seed;
    var rng: fixed.Rng = .{ .s = seed ^ 0x50F7_BA25 };
    if (rng.s == 0) rng.s = 1;
    for (0..bands) |r| {
        const v = &l.vals[r];
        for (v, 0..) |*e, k| e.* = @intCast(k);
        shuffle(v, &rng);
        const s = &l.sorters[r];
        s.start();
        if (!presort or r == 0) continue;
        var copy = v.*;
        var probe: Sorter = .{};
        probe.start();
        const total = probe.run(&copy, unlimited, unlimited, unlimited, unlimited, Quiet{});
        const want = total * @as(u32, @intCast(r)) / (bands - 1);
        _ = s.run(v, unlimited, unlimited, want, unlimited, Quiet{});
    }
}

fn shuffle(v: *[bars]u8, rng: *fixed.Rng) void {
    var k: usize = bars - 1;
    while (k > 0) : (k -= 1) {
        const j: usize = rng.next() % (k + 1);
        const t = v[k];
        v[k] = v[j];
        v[j] = t;
    }
}

fn bar_height(v: u8) u8 {
    return @intCast(world.floor + bar_h0 + @as(u32, v) * bar_h_span / bars);
}

fn bar_colour(v: u8) u8 {
    return @intCast(palette.sort_hue0 + 2 * (@as(u32, v) * hues / bars));
}

/// Band index of local row ly, or null in the gaps and outside the bands.
fn band_of(ly: i32) ?usize {
    const k = ly - band_ly0;
    if (k < 0) return null;
    const r = @divTrunc(k, band_pitch);
    if (r >= bands or @rem(k, band_pitch) >= band_depth) return null;
    return @intCast(r);
}

fn paint_bar(h: *[world.W]u8, c: *[world.W]u8, k: usize, v: u8, pivot: bool) void {
    const cv: u8 = if (pivot) palette.sort_pivot else bar_colour(v);
    @memset(h[k * bar_w ..][0..bar_w], bar_height(v));
    @memset(c[k * bar_w ..][0..bar_w], cv);
}

fn paint_band(l: *const Layout, r: usize, h: *[world.W]u8, c: *[world.W]u8) void {
    const s = &l.sorters[r];
    for (l.vals[r], 0..) |v, k| paint_bar(h, c, k, v, s.is_pivot(k));
}

var gen: Layout = .{};

/// Static architecture of local row `ly` over the floor already in h/c.
pub fn row(seed: u32, ly: i32, h: *[world.W]u8, c: *[world.W]u8) void {
    const r = band_of(ly) orelse return;
    if (gen.seed != seed) build(&gen, seed);
    paint_band(&gen, r, h, c);
}

// --- Live state -------------------------------------------------------------

var live: Layout = .{};
/// First row of the live segment.
var live_y0: i32 = 0;
/// Band the sort runs on, or null.
var running: ?usize = null;
/// After B: swaps_fast per frame until the band is sorted.
var fast = false;
var shuffle_rng: fixed.Rng = .{ .s = 1 };
/// The camera row as of the last tick (verb() runs right after tick()).
var last_cam_row: i32 = 0;

/// Bars rewritten this frame and the most in any frame since boot (a bar is
/// band_depth rows x bar_w cells of height and colour).
var frame_bars: u32 = 0;
pub var max_frame_bars: u32 = 0;
/// The same for frames without a shuffle (the tick alone).
pub var max_tick_bars: u32 = 0;

/// Debug: running band (0xFF none) | sorted bands << 8 | fast << 16.
pub fn debug_state() u32 {
    var n: u32 = 0;
    for (live.sorters) |s| n += @intFromBool(s.done);
    const r: u32 = if (running) |x| @intCast(x) else 0xFF;
    return r | n << 8 | @as(u32, @intFromBool(fast)) << 16;
}

fn band_y0(r: usize) i32 {
    return live_y0 + band_ly0 + band_pitch * @as(i32, @intCast(r));
}

/// Rewrites one bar of live band r through world.rows (rows outside the ring are skipped).
const Painter = struct {
    r: usize,
    fn repaint(p: Painter, k: usize) void {
        frame_bars += 1;
        const v = live.vals[p.r][k];
        const piv = live.sorters[p.r].is_pivot(k);
        var y = band_y0(p.r);
        while (y < band_y0(p.r) + band_depth) : (y += 1) {
            if (world.rows(y)) |rw| paint_bar(rw.h, rw.c, k, v, piv);
        }
    }
};

fn repaint_band(r: usize) void {
    frame_bars += bars;
    var y = band_y0(r);
    while (y < band_y0(r) + band_depth) : (y += 1) {
        if (world.rows(y)) |rw| paint_band(&live, r, rw.h, rw.c);
    }
}

/// The segment becomes live: rebuild the layout from its seed, reset dynamics.
pub fn enter(seg: world.Segment) void {
    build(&live, seg.seed);
    live_y0 = seg.y0;
    running = null;
    fast = false;
    shuffle_rng = .{ .s = seg.seed ^ 0x5A0F_F1E5 };
    if (shuffle_rng.s == 0) shuffle_rng.s = 1;
}

/// Nearest band whose last row is at or beyond cam_row + work_lead and that
/// is not sorted (any band when `any`), or null.
fn next_band(cam_row: i32, any: bool) ?usize {
    for (0..bands) |r| {
        if (band_y0(r) + band_depth - 1 < cam_row + work_lead) continue;
        if (any or !live.sorters[r].done) return r;
    }
    return null;
}

/// Per-frame dataflow: advance the quicksort on the running band. A band
/// left behind keeps its state (and its white pivot) as it is.
pub fn tick(frame: u32, cam_row: i32) void {
    _ = frame;
    last_cam_row = cam_row;
    frame_bars = 0;
    defer {
        max_frame_bars = @max(max_frame_bars, frame_bars);
        max_tick_bars = @max(max_tick_bars, frame_bars);
    }
    // A fast (shuffled) band keeps sorting while any of its rows is in the
    // ring; a slow one hands over once the work line passes it.
    if (running) |r| {
        const last = band_y0(r) + band_depth - 1;
        const limit = if (fast) cam_row - world.keep_behind else cam_row + work_lead;
        if (last < limit) {
            running = null;
            fast = false;
        }
    }
    if (running == null) running = next_band(cam_row, false);
    const r = running orelse return;
    const n: u32 = if (fast) swaps_fast else swaps_slow;
    const s = &live.sorters[r];
    _ = s.run(&live.vals[r], n, n * cmps_per_swap, unlimited, 2 * n + bars_extra, Painter{ .r = r });
    if (s.done) {
        running = null;
        fast = false;
    }
}

/// B: shuffle the running band (or the next one ahead, sorted or not) in one
/// frame and re-sort it at swaps_fast per frame.
pub fn verb() void {
    const cam_row = last_cam_row;
    const r = running orelse (next_band(cam_row, false) orelse (next_band(cam_row, true) orelse return));
    shuffle(&live.vals[r], &shuffle_rng);
    live.sorters[r].start();
    repaint_band(r);
    running = r;
    fast = true;
    max_frame_bars = @max(max_frame_bars, frame_bars);
}
