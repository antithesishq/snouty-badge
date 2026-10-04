//! BUS district (SPEC.md 6, PLAN.md M1 "Bus", M3 "Bus packet"): a raised
//! 36-cell deck with rims, four 2-cell dash lanes whose palette phase runs
//! along the row so the pulse rotation makes the light travel (lanes 0 and 2
//! in pulse A dash, away from the camera; lanes 1 and 3 in pulse B dash,
//! towards it), and pylons beside the deck. Verb: send a packet, a white
//! 3x3 block racing along a lane from just ahead of the camera to the Bus
//! end. The Bus under the camera is entered and ticked by world.tick (it is
//! never the live district); the autopilot's packet is scheduled here.
const world = @import("../world.zig");
const camera = @import("../camera.zig");
const palette = @import("../palette.zig");
const fixed = @import("../fixed.zig");

pub const title: []const u8 = "BUS";
pub const gloss: []const u8 = "the address bus";
pub const caption: []const u8 = "B: send a packet";
pub const alt: i32 = 40;
/// Local row where the autopilot sends its packet (one per Bus). bus.tick
/// schedules it itself: camera.auto_stick presses B for the live district,
/// which on a Bus is the next district.
pub const verb_at: i32 = 24;

/// Autopilot altitude track: no track, the constant `alt`.
pub fn alt_at(ly: i32) i32 {
    _ = ly;
    return alt;
}

// --- Bus knobs --------------------------------------------------------------

/// Deck span [deck_x0, deck_x1) and its height above world.floor.
const deck_x0 = 110;
const deck_x1 = 146;
const deck_h = 8;
/// Rim width at each deck edge (bus_rim colour).
const rim_w = 2;
/// Left cell of each 2-cell lane; lanes 0 and 2 are pulse A dash, 1 and 3 pulse B dash.
const lane_x = [4]u8{ 116, 124, 131, 139 };
/// Phase step between lanes, so neighbouring lanes' dashes do not line up.
const lane_phase = 5;
/// Pylons: 4x4 cells at these left x, every pylon_every rows from local row pylon_y0.
const pylon_x = [2]u8{ 104, 148 };
const pylon_size = 4;
const pylon_y0 = 8;
const pylon_every = 16;
const pylon_h = 14;

/// Static architecture of local row `ly` over the floor already in h/c.
pub fn row(seed: u32, ly: i32, h: *[world.W]u8, c: *[world.W]u8) void {
    _ = seed;
    @memset(h[deck_x0..deck_x1], world.floor + deck_h);
    @memset(c[deck_x0..deck_x1], palette.bus_road);
    @memset(c[deck_x0 .. deck_x0 + rim_w], palette.bus_rim);
    @memset(c[deck_x1 - rim_w .. deck_x1], palette.bus_rim);
    for (lane_x, 0..) |x, k| {
        const base: u8 = if (k & 1 == 0) palette.pulse_a_dash else palette.pulse_b_dash;
        const phase: u8 = @intCast((ly + lane_phase * @as(i32, @intCast(k))) & 15);
        c[x] = base + phase;
        c[x + 1] = base + phase;
    }
    if (ly >= pylon_y0 and @mod(ly - pylon_y0, pylon_every) < pylon_size) {
        for (pylon_x) |x| {
            @memset(h[x .. x + pylon_size], world.floor + pylon_h);
            @memset(c[x .. x + pylon_size], palette.bus_rim);
        }
    }
}

/// The static colour of deck cell x (deck_x0 <= x < deck_x1) on local row
/// ly, as row() paints it; the deck height is world.floor + deck_h there.
noinline fn deck_colour(ly: i32, x: i32) u8 {
    if (x < deck_x0 + rim_w or x >= deck_x1 - rim_w) return palette.bus_rim;
    for (lane_x, 0..) |lx, k| {
        if (x == lx or x == @as(i32, lx) + 1) {
            const base: u8 = if (k & 1 == 0) palette.pulse_a_dash else palette.pulse_b_dash;
            return base + @as(u8, @intCast((ly + lane_phase * @as(i32, @intCast(k))) & 15));
        }
    }
    return palette.bus_road;
}

// --- Packet knobs -----------------------------------------------------------

/// Packets in flight at once; a press with all slots busy is dropped.
const max_packets = 4;
/// Packet footprint: packet_w cells from its lane's left cell, packet_len
/// rows, packet_up cells above the deck, colour palette.white (a tall
/// block top, so never a pulse index).
const packet_w = 3;
const packet_len = 3;
const packet_up = 6;
/// Rows per frame a packet moves, and how far ahead of the camera row it
/// starts. PLAN asked for 6 and 6; at 6 rows per frame a packet crosses the
/// ~40 rows left of the Bus in 7 frames, and from cam_row + 6 it starts
/// under the bottom of the screen (at Bus altitude the bottom row sees about
/// 13 rows ahead), so it is 3 rows per frame from cam_row + 12: on screen
/// from its first frame for about 20 frames.
const packet_speed = 3;
const packet_ahead = 12;
/// A packet runs on the lane nearest the camera x whose centre is at least
/// lane_clear cells to the side: the anteater (sprite.zig, 44 px wide at the
/// bottom centre) hides a lane closer than that from about 16 to 33 rows
/// ahead, most of a packet's run. On the Bus centre line (the autopilot)
/// this is lane 0. PLAN asked for the nearest lane (lane 1 for the
/// autopilot), which the preview showed hidden behind the sprite.
const lane_clear = 8;

comptime {
    // A packet must fit on the deck from every lane.
    for (lane_x) |x| if (x + packet_w > deck_x1 - rim_w) @compileError("packet leaves the deck");
}

// --- Live state -------------------------------------------------------------

const Packet = struct {
    /// World row of the packet's first row; its lane's left cell.
    y: i32,
    x: u8,
};

/// The Bus under the camera (set by enter, which world.tick runs before
/// any tick or verb).
var seg: world.Segment = undefined;
var packets: [max_packets]Packet = undefined;
var n_packets: u32 = 0;
/// Camera row seen by the last tick (packet start and the autopilot trigger).
var last_row: i32 = 0;
/// Packets launched since boot (debug_bus_packets).
var total_sent: u32 = 0;

/// Packets in flight on the Bus under the camera. While this is non-zero the
/// Bus's rows carry dynamic cells (debug_world_check must skip them).
pub fn in_flight() u32 {
    return n_packets;
}

/// Packets launched since boot.
pub fn sent() u32 {
    return total_sent;
}

/// The camera enters Bus `s`: clear the packet list (the previous Bus's rows
/// were restored by world.tick or are being regenerated after a skip).
pub fn enter(s: world.Segment) void {
    seg = s;
    n_packets = 0;
    last_row = s.y0 - 1;
}

/// Write the packet footprint at world row y, lane cell x: raised white
/// (lit) or the static deck (lit = false). Rows outside the ring are skipped.
noinline fn paint(y: i32, x: i32, lit: bool) void {
    var r: i32 = 0;
    while (r < packet_len) : (r += 1) {
        const row_cells = world.rows(y + r) orelse continue;
        var k: i32 = 0;
        while (k < packet_w) : (k += 1) {
            const i: usize = @intCast(x + k);
            row_cells.h[i] = if (lit) world.floor + deck_h + packet_up else world.floor + deck_h;
            row_cells.c[i] = if (lit) palette.white else deck_colour(y + r - seg.y0, x + k);
        }
    }
}

/// Launch a packet on lane `lane` at packet_ahead rows past the camera, if
/// it fits before the Bus end and a slot is free.
fn launch(lane: usize) bool {
    const y = last_row + packet_ahead;
    if (n_packets >= max_packets or y < seg.y0 or y + packet_len > seg.y0 + seg.len) return false;
    packets[n_packets] = .{ .y = y, .x = lane_x[lane] };
    n_packets += 1;
    total_sent +%= 1;
    paint(y, lane_x[lane], true);
    return true;
}

/// Per-frame dataflow on the Bus under the camera: the autopilot's packet
/// when the camera crosses verb_at, then every packet moves packet_speed
/// rows (all restored first, then all drawn, so packets on one lane never
/// erase each other); a packet whose next position passes the Bus end is
/// retired, leaving the deck as row() made it.
pub fn tick(frame: u32, cam_row: i32) void {
    _ = frame;
    const trigger = seg.y0 + verb_at;
    const cross = last_row < trigger and cam_row >= trigger;
    last_row = cam_row;
    for (packets[0..n_packets]) |p| paint(p.y, p.x, false);
    var j: u32 = 0;
    for (packets[0..n_packets]) |p| {
        const y = p.y + packet_speed;
        if (y + packet_len > seg.y0 + seg.len) continue;
        packets[j] = .{ .y = y, .x = p.x };
        paint(y, p.x, true);
        j += 1;
    }
    n_packets = j;
    if (cross and camera.autopilot) _ = verb();
}

/// The lane a packet takes from camera cell cx (see lane_clear).
fn lane_for(cx: i32) usize {
    var best: usize = 0;
    var best_d: i32 = 4 * world.W;
    for (lane_x, 0..) |x, k| {
        // Doubled coordinates: the lane centre is its right cell's left edge
        // (2x + 2), the camera cell's centre 2cx + 1.
        const d: i32 = @intCast(@abs(2 * cx + 1 - 2 * (@as(i32, x) + 1)));
        if (d >= 2 * lane_clear and d < best_d) {
            best_d = d;
            best = k;
        }
    }
    return best;
}

/// B on the Bus under the camera: a packet beside the camera.
pub fn verb() bool {
    return launch(lane_for((camera.cam.x >> fixed.Q) & (world.W - 1)));
}
