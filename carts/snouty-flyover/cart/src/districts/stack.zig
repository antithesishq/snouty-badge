//! STACK district (SPEC.md 6, PLAN.md M2 "Stack"): the call stack as a
//! canyon down the centre line. The plateau stands `plateau` over the floor;
//! the canyon floor is `d` frames (bands of `band` cells) deep, stepping
//! down toward the middle of the district and back up at the far end, and
//! its walls are terraced, one terrace of `terrace` cells per frame, in red
//! strata by depth with a pale lip on each tread's inner edge. The call /
//! return signal runs down x 127..128 as a pulse-B dash. The autopilot's
//! altitude track follows the canyon floor (`alt_at`): the dive.
//!
//! Verb (B: push a frame): every row from `cam_row + push_lead` to the
//! district end gets one frame deeper, as a wave running away from the
//! camera over `push_frames` frames. Depth saturates at `max_depth`; a push
//! made where the canyon ahead of the camera is already `max_depth` deep is
//! a stack overflow: the floor (the cells inside the lowest terrace) of
//! every full-depth row it reaches falls into a black pit, and the sky
//! flashes (render.sky_flash). Pushes reset when the district is left.
//!
//! Unwind (PLAN.md M4 Track A): `unwind_delay` frames after an overflow's
//! wave has opened the pit, the pushes pop, newest first, one every
//! `pop_interval` frames: a popped push's rows rise one band as a wave from
//! its first row to the district end over `pop_frames` frames (the pit
//! closes to the full-depth floor with the overflowing push, the first pop),
//! the sky flashes `pop_flash` frames on each pop, until no push is left;
//! the static canyon stays. A push during the unwind cancels it (a pop wave
//! already running finishes alongside the new push's wave).
//!
//! row() is a pure function of ly (the seed is unused: every Stack is the
//! same canyon); the pushes live in the live state and are applied through
//! world.rows() only.
const world = @import("../world.zig");
const palette = @import("../palette.zig");
const render = @import("../render.zig");

pub const title: []const u8 = "STACK";
pub const gloss: []const u8 = "call frames";
pub const caption: []const u8 = "B: push a frame";
pub const alt: i32 = 24;
pub const verb_at: i32 = 20;

const W = world.W;
const F: i32 = world.floor;

// --- Stack knobs ------------------------------------------------------------

/// Plateau height over the floor and the height of one frame band, cells.
const plateau: i32 = 90;
const band: i32 = 8;
/// Canyon floor half-width (cells with dx < floor_half are the floor) and
/// the width of one wall terrace, cells (the concept's F and S).
const floor_half: i32 = 10;
const terrace: i32 = 5;
/// Static depth profile: 1 + ly / dive_rows_per_frame below dive_end, then
/// max_depth until climb_start, then one frame less every climb_rows_per_frame.
const dive_rows_per_frame: i32 = 13;
const dive_end: i32 = 130;
const climb_start: i32 = 160;
const climb_rows_per_frame: i32 = 12;
/// Deepest the canyon gets (frames); a push past it is the overflow.
const max_depth: i32 = 10;
/// Autopilot altitude over the canyon floor at the camera row, cells.
const dive_clearance: i32 = 14;
/// A push starts this many rows ahead of the camera row.
const push_lead: i32 = 8;
/// Frames a push takes to run from its first row to the district end.
const push_frames: i32 = 10;
/// Pushes remembered per visit (a push is push_frames long, so a 256-frame
/// visit holds at most 26); further presses are ignored.
const max_pushes = 32;
/// The overflow pit: height (absolute) and colour. PLAN.md says height 0,
/// but a cell at or below world.water is drawn as water (a mirror), so the
/// pit stands one cell above the water line to stay black.
const pit_h: u8 = world.water + 1;
/// Sky flash frames on an overflow.
const overflow_flash: u8 = 6;
/// Frames from the overflow's wave reaching the district end (the pit fully
/// open) to the first pop.
const unwind_delay: i32 = 30;
/// Frames from one pop to the next.
const pop_interval: i32 = 8;
/// Frames a pop's wave takes to run from its first row to the district end
/// (at most pop_interval, so pop waves never overlap).
const pop_frames: i32 = 8;
/// Sky flash frames on each pop.
const pop_flash: u8 = 2;
comptime {
    if (pop_frames > pop_interval) @compileError("pop waves must not overlap");
}

// --- Rows -------------------------------------------------------------------

/// Static depth of local row ly in frames (1..max_depth).
fn base_depth(ly: i32) i32 {
    const r = @max(ly, 0);
    const d = if (r < dive_end)
        1 + @divTrunc(r, dive_rows_per_frame)
    else if (r < climb_start)
        max_depth
    else
        max_depth - @divTrunc(r - climb_start, climb_rows_per_frame);
    return @max(1, @min(max_depth, d));
}

/// Paint one Stack row of depth d (1..max_depth) over the whole strip; `pit`
/// drops the floor cells into the overflow pit.
fn paint(ly: i32, d: i32, pit: bool, h: *[W]u8, c: *[W]u8) void {
    for (h, c, 0..) |*hc, *cc, xu| {
        const x: i32 = @intCast(xu);
        // Distance from the centre line: 0 for x 127 and 128.
        const dx = if (x >= 128) x - 128 else 127 - x;
        // Terrace index from the canyon floor, ceil((dx - F + 1) / S) clamped to 0..d.
        const kk = @max(0, @min(d, @divFloor(dx - floor_half + terrace, terrace)));
        const rel = plateau - band * (d - kk);
        hc.* = @intCast(F + rel);
        if (kk >= d) {
            cc.* = palette.stack_top;
        } else {
            const j = d - kk; // frame depth 1..max_depth
            cc.* = @intCast(palette.stack_band0 + 2 * (j - 1));
            // The lip: the inner edge cell of each tread. (The concept's
            // `|dx - (F - 1 + (kk - 1) S)| < 0.6` never holds for integer
            // cells, so this is the cell next to it, the tread's edge.)
            if (kk > 0 and dx == floor_half + (kk - 1) * terrace) cc.* = palette.stack_lip;
        }
        if (kk == 0) {
            if (pit) {
                hc.* = pit_h;
                cc.* = palette.pit;
            } else if (x == 127 or x == 128) {
                // The call / return signal (pulse B dash, 2 wide, phase by row).
                cc.* = @intCast(palette.pulse_b_dash + (@as(u32, @bitCast(ly)) & 15));
            }
        }
    }
}

/// Static architecture of local row `ly` (the canyon replaces the floor).
pub fn row(seed: u32, ly: i32, h: *[W]u8, c: *[W]u8) void {
    _ = seed;
    paint(ly, base_depth(ly), false, h, c);
}

// --- Live state -------------------------------------------------------------

/// First row of the live Stack.
var live_y0: i32 = 0;
/// Pushes this visit: the row each started at and whether it overflowed.
/// Rows only grow along the strip (the camera flies +y), so push_from is
/// nondecreasing.
var push_from: [max_pushes]i32 = undefined;
var push_ovf: [max_pushes]bool = undefined;
var pushes: u32 = 0;
/// The push in progress (index pushes - 1): the next row its wave rewrites,
/// or done when it has reached the district end.
var front: i32 = 0;
var pushing = false;
/// The unwind: running (waiting for or making pops), frames to the next
/// pop, and the pop wave in progress: the popped push (no longer counted in
/// `pushes`) still stands on rows from pop_front to the district end.
var unwinding = false;
var unwind_wait: i32 = 0;
var popping = false;
var pop_from: i32 = 0;
var pop_ovf = false;
var pop_front: i32 = 0;
/// The camera row as of the last tick (verb() runs right after tick()).
var last_cam_row: i32 = 0;

/// Cells (height + colour pairs) rewritten this frame and the most in any
/// frame since boot.
var frame_cells: u32 = 0;
pub var max_frame_cells: u32 = 0;

/// Pushes standing in the live Stack this visit (0 before the first push
/// and again once the unwind has popped them all; a pop counts from the
/// frame its wave starts).
pub fn push_count() u32 {
    return pushes;
}

const RowState = struct { d: i32, pit: bool };

/// The live depth of strip row y: its static depth plus the pushes whose
/// wave has passed it, saturated at max_depth; pit if an overflowing push
/// reached it and it is full depth.
fn state_at(y: i32) RowState {
    const ly = y - live_y0;
    var extra: i32 = 0;
    var ovf = false;
    for (0..pushes) |k| {
        if (push_from[k] > y) break;
        if (pushing and k == pushes - 1 and y >= front) break;
        extra += 1;
        ovf = ovf or push_ovf[k];
    }
    if (popping and y >= pop_front and y >= pop_from) {
        extra += 1;
        ovf = ovf or pop_ovf;
    }
    const d = @min(max_depth, base_depth(ly) + extra);
    return .{ .d = d, .pit = ovf and d == max_depth };
}

fn repaint(y: i32) void {
    const rw = world.rows(y) orelse return;
    const s = state_at(y);
    paint(y - live_y0, s.d, s.pit, rw.h, rw.c);
    frame_cells += W;
}

/// Autopilot altitude above the floor at local row ly: the live canyon
/// floor there plus dive_clearance (ly < 0, the Bus before, reads row 0).
pub fn alt_at(ly: i32) i32 {
    return plateau - band * state_at(live_y0 + @max(ly, 0)).d + dive_clearance;
}

/// The segment becomes live: forget the pushes.
pub fn enter(seg: world.Segment) void {
    live_y0 = seg.y0;
    pushes = 0;
    pushing = false;
    front = 0;
    unwinding = false;
    popping = false;
}

/// Per-frame: advance the push wave and the unwind (each wave rewrites at
/// most ceil(rows / its frames) rows a frame).
pub fn tick(frame: u32, cam_row: i32) void {
    _ = frame;
    last_cam_row = cam_row;
    frame_cells = 0;
    defer max_frame_cells = @max(max_frame_cells, frame_cells);
    const end = live_y0 + world.district_len;
    if (pushing) {
        const from = push_from[pushes - 1];
        const step = @divFloor(end - from + push_frames - 1, push_frames);
        const stop = @min(end, front + @max(step, 1));
        while (front < stop) {
            front += 1; // row front - 1 now counts the push (state_at)
            repaint(front - 1);
        }
        if (front >= end) {
            pushing = false;
            // The overflow's pit is open: the unwind starts its countdown.
            if (push_ovf[pushes - 1]) {
                unwinding = true;
                unwind_wait = unwind_delay;
            }
        }
    }
    if (unwinding and !pushing) {
        if (unwind_wait > 0) unwind_wait -= 1;
        if (unwind_wait == 0 and !popping) {
            if (pushes == 0) {
                unwinding = false;
            } else {
                pushes -= 1;
                pop_from = push_from[pushes];
                pop_ovf = push_ovf[pushes];
                pop_front = pop_from;
                popping = true;
                unwind_wait = pop_interval;
                render.sky_flash = @max(render.sky_flash, pop_flash);
            }
        }
    }
    if (popping) {
        const step = @divFloor(end - pop_from + pop_frames - 1, pop_frames);
        const stop = @min(end, pop_front + @max(step, 1));
        while (pop_front < stop) {
            pop_front += 1; // row pop_front - 1 no longer counts the pop
            repaint(pop_front - 1);
        }
        if (pop_front >= end) {
            popping = false;
            if (unwinding and pushes == 0) unwinding = false;
        }
    }
}

/// B: push a frame from cam_row + push_lead to the district end (ignored
/// while the previous push is running or past the district end); overflow
/// if the canyon there is already max_depth deep.
pub fn verb() void {
    if (pushing or pushes >= max_pushes) return;
    const from = @max(last_cam_row + push_lead, live_y0);
    if (from >= live_y0 + world.district_len) return;
    const ovf = state_at(from).d >= max_depth;
    push_from[pushes] = from;
    push_ovf[pushes] = ovf;
    pushes += 1;
    front = from;
    pushing = true;
    unwinding = false; // a push cancels the unwind
    if (ovf) render.sky_flash = overflow_flash;
}
