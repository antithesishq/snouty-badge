//! Track A: draws grid cells into the persistent framebuffer (SPEC.md
//! section 4). Each primitive is ray cast per pixel inside its screen rect,
//! depth tested against zbuf.zig, Phong shaded and dithered (shade.zig), and
//! its rect is marked dirty so the OS sends it to the LCD in .copy_forward
//! mode. Generic over the pixel sink so host tests can draw into an array.
//!
//! `S` must provide:
//!   pub fn put(x: u32, y: u32, c: u16) void       // c = cart DisplayColor bits (r low 5, g 6, b high 5)
//!   pub fn mark_dirty(r: camera.Rect) void
const std = @import("std");
const math = @import("../math.zig");
const grid = @import("../grid.zig");
const camera = @import("../camera.zig");
const zbuf = @import("zbuf.zig");

/// Dissolve blocks: the screen as 4x4 pixel blocks, 40 x 32.
pub const block_count = (camera.screen_w / 4) * (camera.screen_h / 4);

pub fn Renderer(comptime S: type) type {
    return struct {
        /// Draws the part of cell `p`'s path between fractions s0 and s1
        /// (0 = the entry face, or the centre for a pipe start; 1 = the exit
        /// face, or the centre for a pipe end). Calls with consecutive
        /// ranges must build the same image as one call with 0..1.
        pub fn draw_cell(cam: *const camera.Camera, p: grid.Prim, s0: f32, s1: f32) void {
            _ = cam;
            _ = p;
            _ = s0;
            _ = s1;
        }

        /// Background everywhere, z buffer to far, whole screen dirty.
        pub fn clear_all() void {
            zbuf.clear();
            S.mark_dirty(camera.Rect.full);
        }

        /// Dissolve step: clears blocks [from, to) of a fixed pseudo-random
        /// permutation of the `block_count` 4x4 blocks (screen and z buffer).
        pub fn clear_blocks(from: u16, to: u16) void {
            _ = from;
            _ = to;
        }
    };
}
