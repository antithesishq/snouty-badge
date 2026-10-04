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
//! Verb (B: burst the pipe, PLAN.md M4.2 "B everywhere"): the pipe bursts
//! where the camera looks, anywhere in the district: two white jets shoot
//! up beside the flight line and the ground between them floods with
//! pulse-A rings running outward, which settle into a mirror pool and
//! drain (the rows are restored through world.regen_row). A press during a
//! burst starts a new one.
const world = @import("../world.zig");
const palette = @import("../palette.zig");
const fixed = @import("../fixed.zig");
const camera = @import("../camera.zig");

pub const title: []const u8 = "PIPELINE";
pub const gloss: []const u8 = "packets to the lake";
pub const caption: []const u8 = "B: burst the pipe";
pub const alt: i32 = 18;
/// Over the lake at the skim altitude, before the climb over the dams (from
/// local row ~76) would carry the view off the burst just ahead.
pub const verb_at: i32 = 24;

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
/// Burst (B, PLAN.md M4.2 "B everywhere"): the pipe bursts ahead of the
/// camera, on its x leaning with the heading. Water floods an ellipse
/// of ground whose near and far edges show on screen rows burst_sy_near and
/// burst_sy_far (camera.rows_ahead), growing to full over foam_frames;
/// after foam_hold the foam settles into a mirror pool (the cells sink to
/// the water line) from the centre out over pool_frames, holds pool_hold,
/// and the burst ends. Cells above flood_max_h (dams, springs) stand in the
/// flood. Two jets of white water shoot up beside the flight line. A press
/// during a burst starts a new one from the camera's new position; the old
/// burst's rows drain (are restored) drain_rows per frame, far end first.
const burst_sy_near: i32 = 108;
const burst_sy_far: i32 = 76;
/// Ellipse half-depth (rows) and half-width (cells): rx = rx_per_z16 / 16
/// of the centre's distance, about 0.75 of the view's half-width there.
const burst_ry_min: i32 = 8;
const burst_ry_max: i32 = 40;
const burst_rx_min: i32 = 16;
const burst_rx_max: i32 = 56;
const rx_per_z16: i32 = 10;
const flood_max_h: i32 = F + 8;
const foam_frames: i32 = 12;
const foam_hold: i32 = 10;
const pool_frames: i32 = 10;
const pool_hold: i32 = 20;
const burst_frames: i32 = foam_frames + foam_hold + pool_frames + pool_hold;
/// Colour of the flood until it settles: rings of the pulse-A comet
/// (palette rotation runs them outward), ring_steps of them from the centre
/// to the rim, on an octagonal distance (max + min / 2 of the per-axis
/// distances, each ring_steps * 16 at the rim).
const ring_steps: i32 = 3;
/// Jets: jet_w x jet_rows cells at the ellipse centre row, jet_dx cells
/// either side of its x: at least jet_dx_min (inner edge 22 cells out,
/// clear of the flight model's clearance scan, 16 cells either side plus
/// the heading's lean, so they do not lift the camera) and jet_dx_per_z16
/// / 16 of their distance (beside the anteater on screen); none closer
/// than jet_z_min rows, where they would be off screen. They rise to
/// jet_over above the camera (jet_h_min..jet_h_max) over jet_up frames, hold
/// jet_hold and fall to flood_max_h over jet_down.
const jet_w: i32 = 6;
const jet_rows: i32 = 3;
const jet_dx_min: i32 = 25;
const jet_z_min: i32 = 32;
const jet_dx_per_z16: i32 = 9;
const jet_over: i32 = 6;
const jet_h_min: i32 = F + 24;
const jet_h_max: i32 = 240;
const jet_up: i32 = 4;
const jet_hold: i32 = 18;
const jet_down: i32 = 8;
const jet_frames: i32 = jet_up + jet_hold + jet_down;
/// Rows a drain restores per frame (whole rows through world.regen_row).
const drain_rows: i32 = 2;

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

/// The running burst, in world cells and rows. foam_q and pool_q are the
/// ellipse fractions painted so far (Q8, 0..256); [y0, y1) its rows inside
/// the district; the jets cover rows [jet_y, jet_y + jet_rows) at
/// cx +- jet_dx, rising to jet_top.
const Burst = struct {
    t: i32 = 0,
    cx: i32 = 0,
    cy: i32 = 0,
    rx: i32 = 1,
    ry: i32 = 1,
    y0: i32 = 0,
    y1: i32 = 0,
    foam_q: i32 = 0,
    pool_q: i32 = 0,
    jet_y: i32 = 0,
    jet_dx: i32 = 0,
    jet_top: i32 = 0,
    jets: bool = false,
    /// Q16 ring units per cell across and per row along.
    kx: i32 = 0,
    ky: i32 = 0,
};

var live_y0: i32 = 0;
var burst_on = false;
var burst: Burst = .{};
/// Rows waiting to drain (be restored), [drain_lo, drain_hi), empty when
/// drain_lo >= drain_hi.
var drain_lo: i32 = 0;
var drain_hi: i32 = 0;
/// Camera row at the last tick (the verb runs after the tick, same frame).
var tick_row: i32 = 0;

/// Cells written this frame (height + colour pairs) and the most since boot.
var frame_cells: u32 = 0;
pub var max_frame_cells: u32 = 0;

/// Debug: phase (0 idle, 1 foam, 2 pool, 3 draining) | frames into the burst << 8.
pub fn debug_state() u32 {
    const ph: u32 = if (burst_on) (if (burst.t < foam_frames + foam_hold) 1 else 2) else if (drain_lo < drain_hi) 3 else 0;
    return ph | @as(u32, @intCast(if (burst_on) burst.t else 0)) << 8;
}

/// The segment becomes live: no burst, nothing to drain.
pub fn enter(seg: world.Segment) void {
    live_y0 = seg.y0;
    burst_on = false;
    drain_lo = 0;
    drain_hi = 0;
}

inline fn clamp(v: i32, lo: i32, hi: i32) i32 {
    return @max(lo, @min(hi, v));
}

/// floor(sqrt(v)), bit by bit.
fn isqrt(v: u32) i32 {
    var rem = v;
    var root: u32 = 0;
    var bit: u32 = 1 << 30;
    while (bit > rem) bit >>= 2;
    while (bit != 0) : (bit >>= 2) {
        if (rem >= root + bit) {
            rem -= root + bit;
            root = (root >> 1) + bit;
        } else root >>= 1;
    }
    return @intCast(root);
}

/// Half-width in cells of the burst ellipse scaled by q (Q8) on the row dy
/// from its centre, -1 when the row is outside it.
noinline fn half_width(b: *const Burst, q: i32, dy: i32) i32 {
    const r = (q * b.rx * b.ry) >> 8;
    const d = @as(i32, @intCast(@abs(dy))) * b.rx;
    if (q == 0 or d > r) return -1;
    const s: u32 = @intCast(r * r - d * d);
    return @divTrunc(isqrt(s), b.ry);
}

const Fill = enum { foam, pool };

/// Flood cells x0..x1 (inclusive, x wraps) of one row, v its ring distance
/// along: foam paints the ground with the rings (water rises to water + 1),
/// pool sinks it to the mirror; cells above flood_max_h stand (noinline:
/// called from four places).
noinline fn flood_span(rw: world.Rows, x0: i32, x1: i32, fill_kind: Fill, v: i32) void {
    var x = x0;
    while (x <= x1) : (x += 1) {
        const k: usize = @intCast(x & (W - 1));
        if (rw.h[k] > flood_max_h) continue;
        switch (fill_kind) {
            .foam => {
                const u = (@as(i32, @intCast(@abs(x - burst.cx))) * burst.kx) >> fixed.Q;
                const d = @max(u, v) + (@min(u, v) >> 1);
                rw.h[k] = @max(rw.h[k], water + 1);
                rw.c[k] = @intCast(palette.pulse_a + (d & 15));
            },
            .pool => {
                rw.h[k] = water;
                rw.c[k] = palette.water_idx;
            },
        }
    }
    frame_cells += @intCast(x1 - x0 + 1);
}

/// Grow the flood on row y from fraction q0 to q1: the cells inside the
/// q1 ellipse and outside the q0 one (q0 0: all of them).
fn grow_row(rw: world.Rows, dy: i32, q0: i32, q1: i32, fill_kind: Fill) void {
    const b = &burst;
    const ho = half_width(b, q1, dy);
    if (ho < 0) return;
    const hi = half_width(b, q0, dy);
    const v = (@as(i32, @intCast(@abs(dy))) * b.ky) >> fixed.Q;
    if (hi < 0) {
        flood_span(rw, b.cx - ho, b.cx + ho, fill_kind, v);
    } else if (ho > hi) {
        flood_span(rw, b.cx - ho, b.cx - hi - 1, fill_kind, v);
        flood_span(rw, b.cx + hi + 1, b.cx + ho, fill_kind, v);
    }
}

/// Jet height at burst frame t (0 when it has ended).
fn jet_h(t: i32) i32 {
    const top = burst.jet_top;
    if (t < jet_up) return flood_max_h + @divTrunc((top - flood_max_h) * (t + 1), jet_up);
    if (t < jet_up + jet_hold) return top;
    if (t < jet_frames) return top - @divTrunc((top - flood_max_h) * (t - jet_up - jet_hold), jet_down);
    return 0;
}

/// Paint the jets' cells on row y at height hv.
noinline fn jets_row(rw: world.Rows, y: i32, hv: i32) void {
    const b = &burst;
    if (!b.jets or hv == 0 or y < b.jet_y or y >= b.jet_y + jet_rows) return;
    for ([2]i32{ b.cx - b.jet_dx, b.cx + b.jet_dx }) |jx| {
        world.span(rw.h, rw.c, jx - @divTrunc(jet_w, 2), jet_w, @intCast(hv), palette.white);
        frame_cells += jet_w;
    }
}

/// The running burst's state on a freshly regenerated row y.
fn reapply_row(rw: world.Rows, y: i32) void {
    if (!burst_on or y < burst.y0 or y >= burst.y1) return;
    const dy = y - burst.cy;
    grow_row(rw, dy, 0, burst.foam_q, .foam);
    grow_row(rw, dy, 0, burst.pool_q, .pool);
    jets_row(rw, y, jet_h(burst.t));
}

/// Queue rows [y0, y1) to drain.
fn drain_add(y0: i32, y1: i32) void {
    if (drain_lo >= drain_hi) {
        drain_lo = y0;
        drain_hi = y1;
    } else {
        drain_lo = @min(drain_lo, y0);
        drain_hi = @max(drain_hi, y1);
    }
}

/// Restore row y (static content) and put the running burst back on it.
noinline fn restore_row(y: i32) void {
    world.regen_row(y);
    frame_cells += W;
    if (world.rows(y)) |rw| reapply_row(rw, y);
}

/// One frame of the burst: the foam, then the pool, grow; the jets rise
/// and fall (their rows restore when they end); at the end the burst's
/// rows join the drain.
fn burst_step() void {
    const b = &burst;
    b.t += 1;
    const t = b.t;
    const foam_q = @min(256, @divTrunc(256 * t, foam_frames));
    const pool_q = clamp(@divTrunc(256 * (t - foam_frames - foam_hold), pool_frames), 0, 256);
    const jh = jet_h(t);
    var y = b.y0;
    while (y < b.y1) : (y += 1) {
        const rw = world.rows(y) orelse continue;
        const dy = y - b.cy;
        if (foam_q != b.foam_q) grow_row(rw, dy, b.foam_q, foam_q, .foam);
        if (pool_q != b.pool_q) grow_row(rw, dy, b.pool_q, pool_q, .pool);
        jets_row(rw, y, jh);
    }
    b.foam_q = foam_q;
    b.pool_q = pool_q;
    if (t == jet_frames and b.jets) {
        y = b.jet_y;
        while (y < b.jet_y + jet_rows) : (y += 1) restore_row(y);
    }
    if (t >= burst_frames) {
        burst_on = false;
        drain_add(b.y0, b.y1);
    }
}

/// Per-frame: drain a few queued rows (far end first, rows the ring has
/// dropped behind the camera skipped), then run the burst.
pub fn tick(frame: u32, cam_row: i32) void {
    _ = frame;
    tick_row = cam_row;
    frame_cells = 0;
    defer max_frame_cells = @max(max_frame_cells, frame_cells);
    drain_lo = @max(drain_lo, cam_row - world.keep_behind);
    var n: i32 = 0;
    while (n < drain_rows and drain_lo < drain_hi) : (n += 1) {
        drain_hi -= 1;
        restore_row(drain_hi);
    }
    if (burst_on) burst_step();
}

/// B: burst the pipe ahead of the camera, anywhere in the district (a press
/// during a burst starts a new one; the old one drains). Ignored only in
/// the district's last rows, with nothing ahead to flood.
pub fn verb() bool {
    const end = live_y0 + world.district_len;
    if (tick_row + jet_rows + 1 >= end) return false;
    if (burst_on) {
        // The old jets go at once; the rest of the old flood drains.
        burst_on = false;
        if (burst.jets and burst.t < jet_frames) {
            var y = burst.jet_y;
            while (y < burst.jet_y + jet_rows) : (y += 1) restore_row(y);
        }
        drain_add(burst.y0, burst.y1);
    }
    // Ground height the ellipse is fitted to: the lake's water or the floor.
    const hg: i32 = if (tick_row - live_y0 < lake_rows) water + 1 else F;
    const zn = camera.rows_ahead(burst_sy_near, hg, 4);
    const zf = camera.rows_ahead(burst_sy_far, hg, zn + 2 * burst_ry_min);
    const ry = clamp(@divTrunc(zf - zn, 2), burst_ry_min, burst_ry_max);
    const zc = @min(zn + ry, end - 2 - tick_row);
    const lean = camera.sin(camera.cam.yaw); // Q16 x cells per row
    const cx = (camera.cam.x + lean * zc) >> fixed.Q;
    const jet_y = @min(tick_row + zc - @divTrunc(jet_rows, 2), end - jet_rows);
    const zj = jet_y - tick_row;
    const rx = clamp(@divTrunc(zc * rx_per_z16, 16), burst_rx_min, burst_rx_max);
    burst = .{
        .cx = cx,
        .cy = tick_row + zc,
        .rx = rx,
        .ry = ry,
        .kx = @divTrunc(ring_steps * 16 * fixed.one, rx),
        .ky = @divTrunc(ring_steps * 16 * fixed.one, ry),
        .y0 = @max(tick_row + zc - ry, live_y0),
        .y1 = @min(tick_row + zc + ry + 1, end),
        .jet_y = jet_y,
        .jet_dx = @max(jet_dx_min, @divTrunc(zj * jet_dx_per_z16, 16)),
        .jet_top = clamp((camera.cam.alt >> fixed.Q) + jet_over, jet_h_min, jet_h_max),
        .jets = zj >= jet_z_min,
    };
    burst_on = true;
    return true;
}
