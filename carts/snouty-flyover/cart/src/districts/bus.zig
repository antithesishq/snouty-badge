//! BUS district (SPEC.md 6, PLAN.md M1 "Bus", M3 "Bus packet"): a raised
//! 36-cell deck with rims, four 2-cell dash lanes whose palette phase runs
//! along the row so the pulse rotation makes the light travel (lanes 0 and 2
//! in pulse A dash, away from the camera; lanes 1 and 3 in pulse B dash,
//! towards it), and pylons beside the deck. Verb: send a packet, a white
//! block across all four lanes (each lane's cells a little higher) that
//! starts where it shows just above the caption and races off down the deck,
//! running on over the next district's rows when the Bus ends in front of
//! it (PLAN.md M4.2). The Bus under the camera is entered and ticked by
//! world.tick (it is never the live district); the autopilot's packet is
//! scheduled here.
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

// --- Packet knobs -----------------------------------------------------------

/// Packets in flight at once; a press with all slots busy is dropped.
const max_packets = 4;
/// Packet footprint: a word on all four lanes, the deck between the rims
/// (packet_x0 .. packet_x1) for packet_len rows, each lane's two cells
/// white and packet_bit higher than the rest (cell_top, cell_colour). A
/// single lane is too thin to read: from manual altitude 72 the deck shows
/// from 31 rows ahead, where a 3-cell block is 8 px wide.
const packet_x0 = deck_x0 + rim_w;
const packet_x1 = deck_x1 - rim_w;
const packet_w = packet_x1 - packet_x0;
const packet_len = 4;
const packet_bit = 3;
/// Packet top: packet_below cells under the altitude the camera is heading
/// for (the clearance scan in camera.zig keeps 12 cells over anything
/// ahead, so a packet top, lane cells included, at least 13 under that
/// never holds the camera up): a camera sinking d cells per frame has a
/// target 2^spring_shift d below it (camera.zig's altitude spring), and the
/// autopilot's is at most floor + the live district's alt_at. At most
/// packet_up_max or half the camera's height over the deck above the deck,
/// whichever is more (from high up the deck ahead is hidden by the
/// anteater, and only a taller block shows beside it), and at least
/// packet_up_min above it; a camera too low for that (the autopilot over a
/// Bus before the Pipeline) gets a flat packet, the deck recoloured with
/// nothing raised.
const packet_below = 16;
const packet_up_min = 4;
const packet_up_max = 32;
const spring_shift = 4;
/// A packet starts where its top shows on screen row packet_sy (above the
/// caption, beside the anteater) but at least packet_near rows ahead, and
/// runs for packet_life frames, speeding up from packet_v0 by packet_acc
/// per frame to packet_vmax (rows per frame in 1/16 rows): it holds beside
/// the anteater for a few frames, then races off. From altitude 72 that is
/// 20 to about 100 rows ahead, its top climbing from row 90 to row 69; late
/// in the Bus the camera leaves (leave_rows) about 16 frames after a press.
const packet_sy = 90;
const packet_near = 8;
const packet_v0 = 16;
const packet_acc = 2;
const packet_vmax = 64;
const packet_life = 36;
/// Late in the Bus the deck ahead is under the bottom of the screen, so a
/// packet runs on over the next district's rows (only cells no higher than
/// its top, each put back unless the district rewrote it). The Bus is ticked
/// only while the camera is on it (world.tick), so every packet is taken
/// down once the camera is within leave_rows of the Bus end (it moves under
/// 2 rows per frame), and a press there is refused.
const leave_rows = 2;

// --- Live state -------------------------------------------------------------

const Packet = struct {
    /// World row of the packet's first row in 1/16 rows (row = yq >> 4),
    /// its top (cells), frames run.
    yq: i32,
    top: u8,
    age: u8,
    /// The cells under the footprint before paint().
    under_h: [packet_len][packet_w]u8,
    under_c: [packet_len][packet_w]u8,
};

/// The Bus under the camera (set by enter, which world.tick runs before
/// any tick or verb).
var seg: world.Segment = undefined;
var packets: [max_packets]Packet = undefined;
var n_packets: u32 = 0;
/// Camera row seen by the last tick (packet start and the autopilot trigger).
var last_row: i32 = 0;
/// Camera altitude (Q16) seen by the last tick, and how far it fell since
/// the tick before (Q16 cells, 0 when level or climbing).
var last_alt: i32 = 0;
var alt_fall: i32 = 0;
/// Packets launched since boot (debug_bus_packets).
var total_sent: u32 = 0;

/// Packets in flight on the Bus under the camera. While this is non-zero the
/// Bus's rows (and the next district's) carry dynamic cells.
pub fn in_flight() u32 {
    return n_packets;
}

/// Packets launched since boot.
pub fn sent() u32 {
    return total_sent;
}

/// The camera enters Bus `s`: clear the packet list (the previous Bus took
/// its packets down before the camera left, or the ring is being
/// regenerated after a skip).
pub fn enter(s: world.Segment) void {
    seg = s;
    n_packets = 0;
    last_row = s.y0 - 1;
    last_alt = camera.cam.alt;
    alt_fall = 0;
}

/// Packet cell at strip cell x for a packet top `top`: a lane's two cells
/// white and packet_bit higher, the cells between them pulse A comet with
/// the phase running across the deck (the rotation sends glints sideways).
fn cell_top(x: usize, top: u8) u8 {
    return if (on_lane(x) and top > world.floor + deck_h) top + packet_bit else top;
}
fn cell_colour(x: usize) u8 {
    return if (on_lane(x)) palette.white else palette.pulse_a + @as(u8, @intCast(x & 15));
}
fn on_lane(x: usize) bool {
    for (lane_x) |lx| if (x == lx or x == lx + 1) return true;
    return false;
}

/// Draw packet p, saving the cells under it. Cells higher than the
/// packet are left alone (it passes behind a district's taller blocks);
/// rows outside the ring are skipped and saved as 255, above any packet
/// cell, so unpaint() leaves them alone even once the ring holds them.
noinline fn paint(p: *Packet) void {
    for (0..packet_len) |r| {
        const row_cells = world.rows((p.yq >> 4) + @as(i32, @intCast(r))) orelse {
            @memset(&p.under_h[r], 255);
            continue;
        };
        for (0..packet_w) |k| {
            const i = packet_x0 + k;
            const t = cell_top(i, p.top);
            p.under_h[r][k] = row_cells.h[i];
            p.under_c[r][k] = row_cells.c[i];
            if (row_cells.h[i] > t) continue;
            row_cells.h[i] = t;
            row_cells.c[i] = cell_colour(i);
        }
    }
}

/// Put back the cells packet p painted, each field only while it still
/// holds the packet's value: a district tick may have rewritten a cell
/// since (the Tree's search trail recolours its ridges every frame), and
/// what it wrote stays.
noinline fn unpaint(p: *const Packet) void {
    for (0..packet_len) |r| {
        const row_cells = world.rows((p.yq >> 4) + @as(i32, @intCast(r))) orelse continue;
        for (0..packet_w) |k| {
            const i = packet_x0 + k;
            const t = cell_top(i, p.top);
            if (p.under_h[r][k] > t) continue;
            if (row_cells.h[i] == t) row_cells.h[i] = p.under_h[r][k];
            if (row_cells.c[i] == cell_colour(i)) row_cells.c[i] = p.under_c[r][k];
        }
    }
}

/// Launch a packet where its top shows on screen row packet_sy, if a slot
/// is free and the camera is not about to leave the Bus.
fn launch() bool {
    if (n_packets >= max_packets or last_row + leave_rows >= seg.y0 + seg.len) return false;
    const deck_top: i32 = world.floor + deck_h;
    const cam_alt = camera.cam.alt >> fixed.Q;
    var goal = (camera.cam.alt - (alt_fall << spring_shift)) >> fixed.Q;
    if (camera.autopilot) {
        const live = world.live();
        goal = @min(goal, world.floor + world.info(live.kind).alt_at(last_row - live.y0));
    }
    const up = @min(@min(cam_alt, goal) - packet_below - deck_top, @max(packet_up_max, (cam_alt - deck_top) >> 1));
    const top = deck_top + if (up < packet_up_min) 0 else @min(up, 254 - packet_bit - deck_top);
    const p = &packets[n_packets];
    p.* = .{
        .yq = (last_row + camera.rows_ahead(packet_sy, top, packet_near)) << 4,
        .top = @intCast(top),
        .age = 0,
        .under_h = undefined,
        .under_c = undefined,
    };
    paint(p);
    n_packets += 1;
    total_sent +%= 1;
    return true;
}

/// Per-frame dataflow on the Bus under the camera: every packet is taken
/// down (newest first, so overlapping packets unwind in order), then each
/// still running moves on and is drawn again (oldest first);
/// near the Bus end all of them stay down. The autopilot's packet goes out
/// when the camera crosses verb_at.
pub fn tick(frame: u32, cam_row: i32) void {
    _ = frame;
    const trigger = seg.y0 + verb_at;
    const cross = last_row < trigger and cam_row >= trigger;
    last_row = cam_row;
    alt_fall = @max(last_alt - camera.cam.alt, 0);
    last_alt = camera.cam.alt;
    var k = n_packets;
    while (k > 0) {
        k -= 1;
        unpaint(&packets[k]);
    }
    if (cam_row + leave_rows >= seg.y0 + seg.len) {
        n_packets = 0;
        return;
    }
    var j: u32 = 0;
    for (0..n_packets) |i| {
        if (packets[i].age + 1 >= packet_life) continue;
        if (j != i) packets[j] = packets[i];
        packets[j].yq += @min(packet_v0 + packet_acc * @as(i32, packets[j].age), packet_vmax);
        packets[j].age += 1;
        paint(&packets[j]);
        j += 1;
    }
    n_packets = j;
    if (cross and camera.autopilot) _ = verb();
}

/// B on the Bus under the camera: a packet down the deck ahead.
pub fn verb() bool {
    return launch();
}
