//! The map ring: DEPTH rows x W cells of height and colour index, generated
//! ahead of the camera (SPEC.md 5.4, PLAN.md "Fixed interfaces"). Row y of
//! the endless strip lives at `height[y & (DEPTH-1)]`; `advance_to` keeps the
//! window [cam_row - keep_behind, cam_row + gen_ahead) generated. M0 fills
//! rows with the noise floor and the test blocks (`gen_row`); M1 swaps
//! `gen_row` for the segment sequencer.
const build_options = @import("build_options");
const fixed = @import("fixed.zig");

/// Strip width in cells; x wraps.
pub const W = 256;
/// Ring depth in rows; power of two, from -Dflyover_depth (128 or 256).
pub const DEPTH = build_options.flyover_depth;
comptime {
    if (DEPTH & (DEPTH - 1) != 0) @compileError("flyover_depth must be a power of two");
}

// --- World knobs ------------------------------------------------------------

/// Rows kept valid behind the camera row (the camera moves at most 2 rows per
/// frame and camera.update reads its own row before advance_to runs).
pub const keep_behind = 8;
/// Rows generated ahead of the camera row (exclusive bound). The ring holds
/// DEPTH rows, so behind + ahead cannot exceed it: 248 at depth 256, 120 at
/// depth 128. render.z_far (in cells) must not exceed this, or the march reads
/// rows that alias the ones just behind the camera.
pub const gen_ahead = DEPTH - keep_behind;
/// Seed of the M0 noise floor.
const seed: u32 = 0x5EED_F1A1;
/// Noise floor base height and palette index of the grid lines (SPEC 5.4).
const floor_base = 8;
const grid_colour = 8;
/// Test pattern (M0 only): every `block_period` rows, eight blocks of
/// `block_size` cells from x = 16 in steps of 32; heights 16..128 and colour
/// indices 96, 98, ..., 110. Placed at rows 64..79 of each period so the
/// camera does not start inside one.
const block_period = 128;
const block_row0 = 64;
const block_size = 16;

// --- State ------------------------------------------------------------------

pub var height: [DEPTH][W]u8 = undefined;
pub var colour: [DEPTH][W]u8 = undefined;

/// Next row to generate (every row below it, back to generated - DEPTH, is
/// in the ring). Starts at -keep_behind so the first call also fills the rows
/// just behind the start position.
var generated: i32 = -keep_behind;

/// Generate every row up to cam_row + gen_ahead (exclusive) that is not in
/// the ring yet. Call at start() and every frame; the camera moves at most a
/// couple of rows, so a frame generates 0 to 2 rows.
pub fn advance_to(cam_row: i32) void {
    const target = cam_row + gen_ahead;
    // A jump of more than the ring (never in normal flight) regenerates it.
    if (target - generated > DEPTH) generated = target - DEPTH;
    while (generated < target) : (generated += 1) {
        const i: usize = @intCast(generated & (DEPTH - 1));
        gen_row(generated, &height[i], &colour[i]);
    }
}

/// True when row y is in the ring (for the debug overlay and camera probes).
pub fn generated_row(y: i32) bool {
    return y < generated and y >= generated - DEPTH;
}

/// One row of the M0 world: noise floor, grid lines, test blocks.
/// Deterministic in y; about 256 x (noise2 + a few ops).
pub fn gen_row(y: i32, out_h: *[W]u8, out_c: *[W]u8) void {
    const grid_row = y & 63 == 0;
    for (out_h, out_c, 0..) |*h, *c, xu| {
        const x: i32 = @intCast(xu);
        const n: u8 = fixed.noise2(x, y, seed) >> 5; // 0..7, amplitude 8
        h.* = floor_base + n;
        c.* = if (grid_row or x & 63 == 0) grid_colour else n;
    }
    const by = y & (block_period - 1);
    if (by >= block_row0 and by < block_row0 + block_size) {
        for (0..8) |k| {
            const x0 = 16 + 32 * k;
            @memset(out_h[x0..][0..block_size], @intCast(16 * (k + 1)));
            @memset(out_c[x0..][0..block_size], @intCast(96 + 2 * k));
        }
    }
}
