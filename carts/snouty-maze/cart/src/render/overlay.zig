//! Text overlays: debug timing readout (M1) and the name strip (M2).
const std = @import("std");
const cart = @import("cart-api");
const camera = @import("../camera.zig");
const textures = @import("textures.zig");

var buf: [32]u8 = undefined;

/// Top-left: render microseconds and fps on line 1, the camera cell and
/// compass heading on line 2, so a photo of the badge says where it was.
pub fn draw_debug(render_us: u32, fps_x10: u32) void {
    const line1 = std.fmt.bufPrint(buf[0..16], "{d}us {d}.{d}", .{ render_us, fps_x10 / 10, fps_x10 % 10 }) catch return;
    const c = &camera.cam;
    const cx: i32 = @intFromFloat(std.math.clamp(@floor(c.pos[0]), -99.0, 999.0));
    const cz: i32 = @intFromFloat(std.math.clamp(@floor(c.pos[2]), -99.0, 999.0));
    const letter = "NESW"[@backingInt(camera.heading(c.yaw))];
    const line2 = std.fmt.bufPrint(buf[16..], "{d},{d} {c}", .{ cx, cz, letter }) catch return;
    const width = @max(line1.len, line2.len) * 8 + 2;
    cart.rect(.{ .x = 0, .y = 0, .width = @intCast(width), .height = 19, .fill_color = .rgb(0x000000) });
    cart.text(.{ .str = line1, .x = 1, .y = 1, .text_color = .rgb(0xffffff) });
    cart.text(.{ .str = line2, .x = 1, .y = 10, .text_color = .rgb(0xffffff) });
}

/// Bottom strip for the overhead phase: the Iris mark (24x24) left of two
/// lines in the built-in 8x8 font, white over a 1 px black drop shadow, no
/// box; the icon and text group is centred and each line is centred in the
/// text block. The overhead pose keeps the maze in y = 4..100, so the strip
/// (y = 104..127) sits on the background.
const name_line1 = "ADRIAN HATCH";
const name_line2 = "ANTITHESIS";
const icon_size = 24;
const icon_gap = 4;
const text_w: usize = 8 * @as(usize, @max(name_line1.len, name_line2.len));
const group_x: usize = (cart.screen_width - (icon_size + icon_gap + text_w)) / 2;
const icon_y = 104;

pub fn draw_name_strip() void {
    draw_iris(group_x, icon_y);
    const tx = group_x + icon_size + icon_gap;
    shadow_text_centred(name_line1, tx, 106);
    shadow_text_centred(name_line2, tx, 116);
}

/// 1:1 blit of the Iris mark, which the art pipeline renders at 24x24
/// centred in the 32x32 iris sheet (texels 4..27 either way), with the same
/// 1 px black drop shadow as the text; palette index 0 is transparent. 2D
/// only, no z test.
const icon_inset = (textures.size - icon_size) / 2;

fn draw_iris(x0: usize, y0: usize) void {
    const t = &textures.iris;
    const black: cart.Pixel = .{ .bits = 0 };
    inline for (.{ 1, 0 }) |off| {
        for (0..icon_size) |i| {
            const x = x0 + i + off;
            if (x >= cart.screen_width) continue;
            const col = &cart.framebuffer[x];
            const u = i + icon_inset;
            for (0..icon_size) |j| {
                const y = y0 + j + off;
                if (y >= cart.screen_height) continue;
                const idx = t.texels[(u << 5) | (j + icon_inset)];
                if (idx == 0) continue;
                col[y] = if (off == 1) black else t.palette[idx];
            }
        }
    }
}

fn shadow_text_centred(comptime str: []const u8, x_left: i32, y: i32) void {
    const x: i32 = x_left + ((@as(i32, text_w) - 8 * @as(i32, str.len)) >> 1);
    cart.text(.{ .str = str, .x = x + 1, .y = y + 1, .text_color = .rgb(0x000000) });
    cart.text(.{ .str = str, .x = x, .y = y, .text_color = .rgb(0xffffff) });
}

/// 4x4 ordered-dither (Bayer) thresholds, indexed [y & 3][x & 3]. A pixel
/// turns black when its threshold is below `level`, so level k blacks
/// exactly k of the 16 pixels in every aligned 4x4 block, and each level's
/// set contains the previous one (the dissolve only ever adds black):
///
///      0  8  2 10
///     12  4 14  6
///      3 11  1  9
///     15  7 13  5
const bayer = [4][4]u8{
    .{ 0, 8, 2, 10 },
    .{ 12, 4, 14, 6 },
    .{ 3, 11, 1, 9 },
    .{ 15, 7, 13, 5 },
};

/// Darken the finished frame: `level` 0 leaves it alone, 16 (or more) is
/// all black, in between blacks `level`/16 of the pixels through the Bayer
/// mask. Call after everything else is drawn. Only the blacked pixels are
/// touched: per column, each of the four row phases is either skipped or
/// stored with a stride of 4.
pub fn fade(level: u8) void {
    if (level == 0) return;
    const black: cart.Pixel = .{ .bits = 0 }; // black is 0 in either byte order
    if (level >= 16) {
        for (cart.framebuffer) |*col| @memset(col, black);
        return;
    }
    for (cart.framebuffer, 0..) |*col, x| {
        inline for (0..4) |r| {
            if (bayer[r][x & 3] < level) {
                var y: usize = r;
                while (y < cart.screen_height) : (y += 4) col[y] = black;
            }
        }
    }
}
