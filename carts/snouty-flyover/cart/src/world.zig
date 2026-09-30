//! The map ring: DEPTH rows x W cells of height and colour index, generated
//! ahead of the camera (SPEC.md 5.4, PLAN.md "Fixed interfaces"). Stub: Track
//! B fills advance_to with the noise floor and M0 test blocks.
const build_options = @import("build_options");
const fixed = @import("fixed.zig");

/// Strip width in cells; x wraps.
pub const W = 256;
/// Ring depth in rows; power of two, from -Dflyover_depth.
pub const DEPTH = build_options.flyover_depth;

pub var height: [DEPTH][W]u8 = undefined;
pub var colour: [DEPTH][W]u8 = undefined;

/// Highest row generated so far (exclusive); rows below cam_row - 8 are stale.
var generated: i32 = 0;

/// Generate rows up to cam_row + z_far (in cells) so the march never reads
/// an ungenerated row.
pub fn advance_to(cam_row: i32) void {
    _ = cam_row;
}

pub fn generated_row(y: i32) bool {
    return y < generated;
}
