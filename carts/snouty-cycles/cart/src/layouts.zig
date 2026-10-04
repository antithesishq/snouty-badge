//! Block layouts for the arena (SPEC 6: pillars and bars "for variety"
//! from level 5 on). Data only: `sim.World.init` draws `all[cfg.layout]`
//! into the grid as `block` cells.
//!
//! Every rect is drawn four times, mirrored across both centre lines of
//! the 80 x 60 grid (x -> 79 - x, y -> 59 - y), so each layout is
//! symmetric and fair to the start cells (which are symmetric under a
//! half turn). A rect that straddles a centre line mirrors onto itself.
//! Coordinates are cells; keep rects inside the interior (1..78, 1..58).
//!
//! The start cells and the 5 cells ahead of each start stay free:
//! `World.init` clears them after drawing, and the sim host test checks
//! that no layout touches them in the first place.
//!
//! Index 0 is the open arena. P's ladder (`levels.zig`) picks layouts by
//! index; `name` is for menus and banners.

pub const Rect = struct { x: u8, y: u8, w: u8, h: u8 };

pub const Layout = struct {
    name: []const u8,
    /// Rects in (usually) the top-left quadrant; drawn mirrored 4 ways.
    rects: []const Rect,
};

pub const all = [_]Layout{
    .{ .name = "OPEN", .rects = &.{} },
    // 16 pillars of 2x2 in a loose grid around the centre.
    .{ .name = "PILLARS", .rects = &.{
        .{ .x = 19, .y = 14, .w = 2, .h = 2 },
        .{ .x = 29, .y = 14, .w = 2, .h = 2 },
        .{ .x = 19, .y = 22, .w = 2, .h = 2 },
        .{ .x = 29, .y = 22, .w = 2, .h = 2 },
    } },
    // Long bars top and bottom, short uprights at the sides.
    .{ .name = "BARS", .rects = &.{
        .{ .x = 14, .y = 12, .w = 16, .h = 2 },
        .{ .x = 8, .y = 20, .w = 2, .h = 8 },
    } },
    // A plus sign with an open 8x8 middle.
    .{ .name = "CROSS", .rects = &.{
        .{ .x = 24, .y = 29, .w = 12, .h = 2 },
        .{ .x = 39, .y = 16, .w = 2, .h = 10 },
    } },
    // A box around the centre with a gap in the middle of each side
    // (the start lines run straight through the gaps).
    .{ .name = "RING", .rects = &.{
        .{ .x = 20, .y = 14, .w = 16, .h = 2 },
        .{ .x = 20, .y = 14, .w = 2, .h = 12 },
    } },
    // Two long walls splitting the arena into three lanes, open in the middle.
    .{ .name = "LANES", .rects = &.{
        .{ .x = 6, .y = 20, .w = 26, .h = 2 },
    } },
    // L brackets in the corners.
    .{ .name = "CORNERS", .rects = &.{
        .{ .x = 10, .y = 8, .w = 10, .h = 2 },
        .{ .x = 10, .y = 8, .w = 2, .h = 10 },
    } },
    // Staggered 2x2 blocks.
    .{ .name = "CHECKER", .rects = &.{
        .{ .x = 8, .y = 6, .w = 2, .h = 2 },
        .{ .x = 20, .y = 6, .w = 2, .h = 2 },
        .{ .x = 32, .y = 6, .w = 2, .h = 2 },
        .{ .x = 14, .y = 12, .w = 2, .h = 2 },
        .{ .x = 26, .y = 12, .w = 2, .h = 2 },
        .{ .x = 8, .y = 18, .w = 2, .h = 2 },
        .{ .x = 20, .y = 18, .w = 2, .h = 2 },
        .{ .x = 32, .y = 18, .w = 2, .h = 2 },
        .{ .x = 14, .y = 24, .w = 2, .h = 2 },
        .{ .x = 26, .y = 24, .w = 2, .h = 2 },
    } },
    // Tall uprights: eight columns, staggered.
    .{ .name = "COLUMNS", .rects = &.{
        .{ .x = 20, .y = 4, .w = 2, .h = 16 },
        .{ .x = 30, .y = 10, .w = 2, .h = 14 },
    } },
};

/// Number of layouts, the open arena (index 0) included.
pub const count = all.len;

/// The layout for a `Config.layout` index; out of range is the open arena.
pub fn get(i: u8) *const Layout {
    return if (i < count) &all[i] else &all[0];
}
