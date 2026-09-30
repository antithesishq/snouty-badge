//! BUS district (SPEC.md 6, PLAN.md M1 "Bus"): a raised 36-cell deck with
//! rims, four 2-cell dash lanes whose palette phase runs along the row so the
//! pulse rotation makes the light travel (lanes 0 and 2 in pulse A dash, away
//! from the camera; lanes 1 and 3 in pulse B dash, towards it), and pylons
//! beside the deck. Static only: the lanes move through palette cycling, and
//! the packet verb is M3.
const world = @import("../world.zig");
const palette = @import("../palette.zig");

pub const title: []const u8 = "BUS";
pub const gloss: []const u8 = "the address bus";
pub const caption: []const u8 = "B: send a packet";
pub const alt: i32 = 40;
pub const verb_at: i32 = -1;

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

/// Nothing to rebuild: the Bus has no layout or dynamic state in M1.
pub fn enter(seg: world.Segment) void {
    _ = seg;
}

/// No per-frame edits: the lanes flow through palette cycling alone.
pub fn tick(frame: u32, cam_row: i32) void {
    _ = frame;
    _ = cam_row;
}

/// The packet verb is M3; B does nothing on a Bus in M1.
pub fn verb() void {}
