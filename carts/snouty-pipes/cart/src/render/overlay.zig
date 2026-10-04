//! Track B: 2D overlays on top of the pipes (SPEC.md sections 5, 6): the
//! boot name strip ("SNOUTY PIPES" and the Iris mark) and, in
//! `-Ddebug_overlay` builds, a timing readout.
//!
//! The framebuffer is persistent (.copy_forward) and the pipes are drawn
//! once, so an overlay must not leave marks: `draw` saves the pixels under
//! each overlay before drawing it and `restore` puts them back first thing
//! next frame (main.zig: restore -> director commands -> draw). Pipes drawn
//! under an overlay land in the restored picture and are saved again.
const std = @import("std");
const cart = @import("cart-api");
const iris = @import("iris");

/// A screen rectangle with room for the pixels under it.
fn Region(comptime x0: u8, comptime y0: u8, comptime w: u8, comptime h: u8) type {
    std.debug.assert(@as(u32, x0) + w <= cart.screen_width);
    std.debug.assert(@as(u32, y0) + h <= cart.screen_height);
    return struct {
        var saved: [w][h]cart.Pixel = undefined;
        var held: bool = false;

        fn save() void {
            for (0..w) |i| @memcpy(&saved[i], cart.framebuffer[x0 + i][y0..][0..h]);
            held = true;
        }

        fn restore() void {
            if (!held) return;
            for (0..w) |i| @memcpy(cart.framebuffer[x0 + i][y0..][0..h], &saved[i]);
            cart.mark_dirty_rect(x0, y0, w, h);
            held = false;
        }
    };
}

// The name strip: the 24 px Iris mark left of the title, white over a 1 px
// black drop shadow, the group centred at the bottom of the screen.
const title = "SNOUTY PIPES";
const icon_gap = 4;
const group_w = iris.size + icon_gap + 8 * title.len;
const strip_x: u8 = (cart.screen_width - group_w - 1) / 2;
const strip_y: u8 = cart.screen_height - iris.size - 2;
const Strip = Region(strip_x, strip_y, group_w + 1, iris.size + 1);

// The debug readout: two lines of the 8x8 font on a black box, top left.
const debug_chars = 16;
const debug_w = debug_chars * 8 + 2;
const Debug = Region(0, 0, debug_w, 19);

/// Puts back the pixels under last frame's overlays (marks them dirty).
pub fn restore() void {
    Strip.restore();
    Debug.restore();
}

/// What the debug readout shows.
pub const Stats = struct {
    render_us: u32,
    fps_x10: u32,
    filled: u32,
    alive: u32,
    scene: u32,
    speed: u32,
};

/// Saves what is under each overlay shown this frame, then draws it.
pub fn draw(strip: bool, debug: ?Stats) void {
    if (strip) {
        Strip.save();
        draw_strip();
    }
    if (debug) |s| {
        Debug.save();
        draw_debug(s);
    }
}

fn draw_strip() void {
    const black: cart.DisplayColor = .rgb(0x000000);
    const white: cart.DisplayColor = .rgb(0xffffff);
    const x: i32 = strip_x;
    const y: i32 = strip_y;
    iris.draw(cart, x + 1, y + 1, 1, black);
    iris.draw(cart, x, y, 1, white);
    const tx = x + iris.size + icon_gap;
    const ty = y + (iris.size - 8) / 2;
    cart.text(.{ .str = title, .x = tx + 1, .y = ty + 1, .text_color = black });
    cart.text(.{ .str = title, .x = tx, .y = ty, .text_color = white });
}

var buf: [2 * debug_chars]u8 = undefined;

fn draw_debug(s: Stats) void {
    const line1 = std.fmt.bufPrint(buf[0..debug_chars], "{d}us {d}.{d}", .{ @min(s.render_us, 999999), s.fps_x10 / 10, s.fps_x10 % 10 }) catch return;
    const line2 = std.fmt.bufPrint(buf[debug_chars..], "c{d} p{d} s{d} {d}x", .{ s.filled, s.alive, s.scene % 100, s.speed }) catch return;
    cart.rect(.{ .x = 0, .y = 0, .width = debug_w, .height = 19, .fill_color = .rgb(0x000000) });
    cart.text(.{ .str = line1, .x = 1, .y = 1, .text_color = .rgb(0xffffff) });
    cart.text(.{ .str = line2, .x = 1, .y = 10, .text_color = .rgb(0xffffff) });
}
