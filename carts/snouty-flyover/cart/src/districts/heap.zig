//! HEAP district (SPEC.md 6, PLAN.md M1 constants). Scaffold stub: the
//! floor only; the track fills in row(), enter(), tick() and verb().
const world = @import("../world.zig");
const palette = @import("../palette.zig");
const fixed = @import("../fixed.zig");

pub const title: []const u8 = "HEAP";
pub const gloss: []const u8 = "malloc / free / gc";
pub const caption: []const u8 = "B: collect garbage";
pub const alt: i32 = 40;
pub const verb_at: i32 = 30;

/// Static architecture of local row `ly` over the floor already in h/c.
pub fn row(seed: u32, ly: i32, h: *[world.W]u8, c: *[world.W]u8) void {
    _ = seed;
    _ = ly;
    _ = h;
    _ = c;
}

/// The segment becomes live: rebuild the layout from its seed, reset dynamics.
pub fn enter(seg: world.Segment) void {
    _ = seg;
}

/// Per-frame dataflow edits through world.rows().
pub fn tick(frame: u32, cam_row: i32) void {
    _ = frame;
    _ = cam_row;
}

/// B pressed while this district is live.
pub fn verb() void {}
