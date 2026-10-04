//! PIPELINE district (SPEC.md 6, PLAN.md M2 "Pipeline"): six springs at the
//! far end feed channels that braid in pairs into three streams, each
//! stream passes a filter dam with a notch, and they run out into a mirror
//! lake that fills the near end. Flow is toward the camera: the packets are
//! a 1-wide pulse-A dash thread along each channel centre, just above the
//! water, whose distance count starts at the spring, so the palette rotation
//! moves the lit dashes toward the lake.
//!
//! Integer port of tools/concept.py gen_pipeline (Q16 smoothstep, camera.sin
//! for the cosine and sine offsets). row() is a pure function of ly: the
//! channel centres are recomputed per row (a few dozen sines), so the
//! district has no layout cache.
//!
//! Verb (B: burst the pipe, PLAN.md M3 "Pipeline flood ahead"): the channels
//! ahead of the camera flood: every non-water cell within `flood_half` of a
//! stream or spring channel centre, from 10 rows ahead of the camera (never
//! before the dams) to two rows short of the springs, sinks one cell per
//! frame to the water line, white while it sinks (at most 19 frames from
//! the floor's top), holds `hold_frames`, then the rows are restored one per frame from the far end
//! through world.regen_row. From over the lake (and the Bus before it) the
//! flood covers the stream sections between the dams and the merge point,
//! as in M2.
const world = @import("../world.zig");
const palette = @import("../palette.zig");
const fixed = @import("../fixed.zig");
const camera = @import("../camera.zig");

pub const title: []const u8 = "PIPELINE";
pub const gloss: []const u8 = "packets to the lake";
pub const caption: []const u8 = "B: burst the pipe";
pub const alt: i32 = 18;
/// Late enough that the flooded stream sections (local rows 122..149) are in
/// view from over the lake when the autopilot's burst runs (30 put them 90
/// rows out).
pub const verb_at: i32 = 70;

const W = world.W;
const F: i32 = world.floor;
const water: u8 = world.water;

// --- Pipeline knobs ---------------------------------------------------------

/// Local rows 0..lake_rows-1 are the lake (height water, colour water_idx).
const lake_rows: i32 = 110;
/// Spring row (the channels start there) and the merge row where each pair
/// has joined into one stream (flow runs from spring_ly down to the lake).
const spring_ly: i32 = 170;
const merge_ly: i32 = 150;
/// Spring x positions (pairs 0-1, 2-3, 4-5) and the three stream x's.
const springs = [6]i32{ 28, 70, 108, 148, 186, 228 };
const merged = [3]i32{ 49, 128, 207 };
/// Braid: offset (sx - pair mid) * cos(braid_rate * (spring_ly - ly)), in
/// 1/1024 turn per row in Q8 (0.06 rad per row), fading out by smoothstep.
const braid_rate_q8: i32 = 2503;
/// Spring channels are 2 * spring_half wide.
const spring_half: i32 = 2;
/// Streams meander by meander_amp * sin(meander_rate * (merge_ly - ly) +
/// phase): 0.05 rad per row in Q8 of 1/1024 turn, and each stream's phase
/// (the concept adds the stream's x, in radians, to the angle).
const meander_amp: i32 = 6;
const meander_rate_q8: i32 = 2086;
const meander_phase = [3]i32{ 818, 381, 968 };
/// Stream width: stream_w0 + stream_dw * (merge_ly - ly) / (merge_ly - lake_rows),
/// widening toward the lake.
const stream_w0: i32 = 7;
const stream_dw: i32 = 6;
/// Dams: dam_rows deep from dam_ly, 2 * dam_half wide, at floor + dam_h;
/// a 2 * notch_half wide notch at water + 1 carries the dash.
const dam_ly: i32 = merge_ly - 34;
const dam_rows: i32 = 6;
const dam_half: i32 = 9;
const dam_h: i32 = 16;
const notch_half: i32 = 1;
/// Springs: 2 * tower_half square towers at floor + tower_h from spring_ly,
/// with a 2 * cap_half square pulse-A cap at floor + cap_h.
const tower_half: i32 = 4;
const tower_h: i32 = 26;
const cap_half: i32 = 2;
const cap_h: i32 = 28;
/// Autopilot altitude over the lake, relative to world.floor: 10 cells over
/// the water (the concept's skim). After the lake the district's `alt`.
const lake_alt: i32 = @as(i32, water) + 10 - F;
/// Burst: from over the lake rows flood_ly0..merge_ly-1 (between the dams
/// and the merge point); from the channels max(cam + flood_ahead, flood_ly0)
/// ..flood_ly1-1. Cells within flood_half of a stream (or, from merge_ly,
/// spring channel) centre sink one cell per frame for sink_frames, hold
/// hold_frames, then the rows restore one per frame.
const flood_ly0: i32 = dam_ly + dam_rows;
const flood_ly1: i32 = spring_ly - 2;
const flood_ahead: i32 = 10;
const flood_half: i32 = 12;
const sink_frames: u32 = 20;
/// Colour of a flooding cell until it reaches the water line: the night
/// floor and the water are both dark blue, so the sinking channels show as
/// white water (the flood ahead reads from altitude).
const foam: u8 = palette.white;
const hold_frames: u32 = 40;

// --- Geometry ---------------------------------------------------------------

/// Q16 x of spring channel i at local row ly (merge_ly..spring_ly).
fn spring_x(i: usize, ly: i32) i32 {
    const u = spring_ly - ly; // 0 at the springs
    const t = @divTrunc(u * fixed.one, spring_ly - merge_ly);
    const s = fixed.mul(fixed.mul(t, t), 3 * fixed.one - 2 * t); // smoothstep
    const sep = fixed.one - s;
    const pair = i - i % 2;
    const mid = @divTrunc(springs[pair] + springs[pair + 1], 2);
    const m = merged[i / 2];
    const braid = camera.cos((u * braid_rate_q8) >> 8);
    return mid * fixed.one + (m - mid) * s + (springs[i] - mid) * fixed.mul(braid, sep);
}

/// Q16 x of stream mi at local row ly (lake..merge_ly).
fn stream_x(mi: usize, ly: i32) i32 {
    const a = (((merge_ly - ly) * meander_rate_q8) >> 8) + meander_phase[mi];
    return merged[mi] * fixed.one + meander_amp * camera.sin(a);
}

/// Fill [x0, x1) of a row (x wraps) with height hv and colour cv.
fn fill(h: *[W]u8, c: *[W]u8, x0: i32, x1: i32, hv: u8, cv: u8) void {
    var x = x0;
    while (x < x1) : (x += 1) {
        const k: usize = @intCast(x & (W - 1));
        h[k] = hv;
        c[k] = cv;
    }
}

/// Thread (packet path) point q of spring channel i: q 0..10 run from the
/// spring row down to merge_ly in steps of 2 rows; for even i, q 11..31 go
/// on down the stream to lake_rows (as in the concept, the first stream
/// point repeats the merge row, a short sideways hop).
fn thread_points(i: usize) usize {
    return if (i % 2 == 0) 32 else 11;
}

const Pt = struct { x: i32, y: i32 };

fn thread_point(i: usize, q: usize) Pt {
    const qi: i32 = @intCast(q);
    if (q <= 10) {
        const y = spring_ly - 2 * qi;
        return .{ .x = spring_x(i, y), .y = y };
    }
    const y = merge_ly - 2 * (qi - 11);
    return .{ .x = stream_x(i / 2, y), .y = y };
}

/// Walk thread i's polyline from its spring (the concept's World.path, width
/// 1): each segment of n = max(|dx|, |dy|) steps paints n cells, the
/// distance p counting up from the spring. Cells on local row ly are raised
/// to water + 1 and painted pulse_a_dash + p % 16 when `h` is given.
/// Returns p of the first cell on row ly, or null.
fn thread_row(i: usize, ly: i32, h: ?*[W]u8, c: ?*[W]u8) ?u32 {
    var first: ?u32 = null;
    var p: u32 = 0;
    var a = thread_point(i, 0);
    for (1..thread_points(i)) |q| {
        const b = thread_point(i, q);
        defer a = b;
        const dxq = b.x - a.x;
        const dy = b.y - a.y; // 0 or -2
        const n: i32 = @max(@as(i32, @intCast(@abs(dxq) >> fixed.Q)), @as(i32, @intCast(@abs(dy))));
        if (n == 0) continue;
        // Rows this segment touches: a.y down to b.y.
        if (ly > a.y or ly < b.y) {
            p += @intCast(n);
            continue;
        }
        var k: i32 = 0;
        while (k < n) : (k += 1) {
            defer p += 1;
            const y = a.y - @divFloor(4 * k + n, 2 * n) * @divTrunc(-dy, 2);
            if (y != ly) continue;
            const xq = a.x + @divTrunc(dxq * k, n);
            const x: usize = @intCast(((xq + fixed.one / 2) >> fixed.Q) & (W - 1));
            if (first == null) first = p;
            if (h) |hh| {
                hh[x] = @max(hh[x], water + 1);
                c.?[x] = @intCast(palette.pulse_a_dash + (p & 15));
            }
        }
    }
    return first;
}

/// Static architecture of local row `ly` over the floor already in h/c.
pub fn row(seed: u32, ly: i32, h: *[W]u8, c: *[W]u8) void {
    _ = seed;
    if (ly < lake_rows) {
        @memset(h, water);
        @memset(c, palette.water_idx);
    }
    // Channels (water) from two rows inside the lake up to the springs.
    if (ly >= lake_rows - 2 and ly <= spring_ly) {
        if (ly >= merge_ly) {
            for (0..springs.len) |i| {
                const x = spring_x(i, ly) >> fixed.Q;
                fill(h, c, x - spring_half, x + spring_half, water, palette.water_idx);
            }
        } else {
            const wd = stream_w0 + @divTrunc(stream_dw * (merge_ly - ly), merge_ly - lake_rows);
            for (0..merged.len) |mi| {
                const x = stream_x(mi, ly) >> fixed.Q;
                const x0 = x - @divFloor(wd, 2);
                fill(h, c, x0, x0 + wd, water, palette.water_idx);
            }
        }
    }
    // Packets: the dash threads along the channel centres.
    if (ly >= lake_rows and ly <= spring_ly) {
        for (0..springs.len) |i| _ = thread_row(i, ly, h, c);
    }
    // Dams with their notch (the thread's dash carried through it).
    if (ly >= dam_ly and ly < dam_ly + dam_rows) {
        for (0..merged.len) |mi| {
            const x = stream_x(mi, dam_ly) >> fixed.Q;
            fill(h, c, x - dam_half, x + dam_half, F + dam_h, palette.pipe_dam);
            const p = thread_row(2 * mi, ly, null, null) orelse 0;
            fill(h, c, x - notch_half, x + notch_half, water + 1, @intCast(palette.pulse_a_dash + (p & 15)));
        }
    }
    // Springs: towers with a pulse-A cap.
    if (ly >= spring_ly and ly < spring_ly + 2 * tower_half) {
        const cap = ly >= spring_ly + tower_half - cap_half and ly < spring_ly + tower_half + cap_half;
        for (springs) |sx| {
            fill(h, c, sx - tower_half, sx + tower_half, F + tower_h, palette.pipe_spring);
            if (cap) {
                const cap_phase: u32 = @intCast(4 * (spring_ly + tower_half + cap_half - 1 - ly));
                fill(h, c, sx - cap_half, sx + cap_half, F + cap_h, @intCast(palette.pulse_a + (cap_phase & 15)));
            }
        }
    }
}

/// Autopilot altitude above the floor at local row ly: 10 over the water
/// across the lake (and the Bus before it), then `alt` (the clearance
/// spring lifts over the dams and springs).
pub fn alt_at(ly: i32) i32 {
    return if (ly < lake_rows) lake_alt else alt;
}

// --- Live state -------------------------------------------------------------

const Phase = enum { idle, sink, hold, restore };

var live_y0: i32 = 0;
var phase: Phase = .idle;
/// Frames into the sink or hold phase; the next row to restore.
var phase_t: u32 = 0;
var restore_ly: i32 = 0;
/// The running burst's local rows [burst_ly0, burst_ly1).
var burst_ly0: i32 = flood_ly0;
var burst_ly1: i32 = merge_ly;
/// Camera row at the last tick (the verb runs after the tick, same frame).
var tick_row: i32 = 0;

/// Cells written this frame (height + colour pairs) and the most since boot.
var frame_cells: u32 = 0;
pub var max_frame_cells: u32 = 0;

/// Debug: phase (0 idle, 1 sink, 2 hold, 3 restore) | frames in it << 8.
pub fn debug_state() u32 {
    return @as(u32, @backingInt(phase)) | phase_t << 8;
}

/// The segment becomes live: no burst.
pub fn enter(seg: world.Segment) void {
    live_y0 = seg.y0;
    phase = .idle;
    phase_t = 0;
}

/// One sink step over the flood area: every non-water cell within
/// flood_half of a stream centre (below merge_ly) or a spring channel centre
/// (from merge_ly; the two channels of a pair as one span where they
/// overlap), the dash thread excepted, drops a cell; cells reaching the
/// water line turn water.
fn sink_step() void {
    var ly = burst_ly0;
    while (ly < burst_ly1) : (ly += 1) {
        const rw = world.rows(live_y0 + ly) orelse continue;
        if (ly < merge_ly) {
            for (0..merged.len) |mi| {
                const cx = stream_x(mi, ly) >> fixed.Q;
                sink_span(rw, cx - flood_half, cx + flood_half);
            }
        } else {
            for (0..merged.len) |pi| {
                const a = spring_x(2 * pi, ly) >> fixed.Q;
                const b = spring_x(2 * pi + 1, ly) >> fixed.Q;
                const lo = @min(a, b);
                const hi = @max(a, b);
                if (hi - lo <= 2 * flood_half) {
                    sink_span(rw, lo - flood_half, hi + flood_half);
                } else {
                    sink_span(rw, lo - flood_half, lo + flood_half);
                    sink_span(rw, hi - flood_half, hi + flood_half);
                }
            }
        }
    }
}

/// Sink cells x0..x1 (inclusive, x wraps) of one row by a cell (noinline:
/// four inlined copies cost about 0.9 KB of .text).
noinline fn sink_span(rw: world.Rows, x0: i32, x1: i32) void {
    var x = x0;
    while (x <= x1) : (x += 1) {
        const k: usize = @intCast(x & (W - 1));
        const cc = rw.c[k];
        if (rw.h[k] <= water) continue;
        if (cc >= palette.pulse_a_dash and cc < palette.pulse_a_dash + 16) continue;
        rw.h[k] -= 1;
        rw.c[k] = if (rw.h[k] == water) palette.water_idx else foam;
        frame_cells += 1;
    }
}

/// Per-frame: run the burst (sink, hold, restore).
pub fn tick(frame: u32, cam_row: i32) void {
    _ = frame;
    tick_row = cam_row;
    frame_cells = 0;
    defer max_frame_cells = @max(max_frame_cells, frame_cells);
    switch (phase) {
        .idle => {},
        .sink => {
            sink_step();
            phase_t += 1;
            if (phase_t >= sink_frames) {
                phase = .hold;
                phase_t = 0;
            }
        },
        .hold => {
            phase_t += 1;
            if (phase_t >= hold_frames) {
                phase = .restore;
                restore_ly = burst_ly1 - 1;
            }
        },
        .restore => {
            world.regen_row(live_y0 + restore_ly);
            frame_cells += W;
            restore_ly -= 1;
            if (restore_ly < burst_ly0) phase = .idle;
        },
    }
}

/// B: burst the pipe ahead of the camera (ignored while a burst is running,
/// and within flood_ahead rows of the flood's far end, where nothing is left
/// ahead to flood).
pub fn verb() bool {
    if (phase != .idle) return false;
    const cam_ly = tick_row - live_y0;
    const ly0 = if (cam_ly < lake_rows) flood_ly0 else @max(cam_ly + flood_ahead, flood_ly0);
    const ly1 = if (cam_ly < lake_rows) merge_ly else flood_ly1;
    if (ly0 >= ly1) return false;
    burst_ly0 = ly0;
    burst_ly1 = ly1;
    phase = .sink;
    phase_t = 0;
    return true;
}
