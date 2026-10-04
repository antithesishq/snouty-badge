//! Sprite, background and text drawing on top of the cart API.
const cart = @import("cart-api");
const gfx = @import("gfx");
const world = @import("world.zig");

pub const anti_black = cart.DisplayColor.rgb(0x16031B);
pub const anti_white = cart.DisplayColor.rgb(0xFCFBF9);
pub const coral = cart.DisplayColor.rgb(0xF18271);
pub const cream = cart.DisplayColor.rgb(0xF4EFDF);
pub const black = cart.DisplayColor.rgb(0x000000);
pub const star_dim = cart.DisplayColor.rgb(0x958D9D);
pub const red = cart.DisplayColor.rgb(0xEE453C);

pub const hud_height: i32 = 8;
pub const near_y: i32 = 104;

const sw: i32 = @intCast(cart.screen_width);
const sh: i32 = @intCast(cart.screen_height);

pub const SpriteOpts = struct {
    /// Draw every non-transparent pixel as Anti-White (hit flash).
    flash_white: bool = false,
    /// Skip pixels where screen (x + y) is odd (checkerboard ghost).
    skip_odd: bool = false,
};

/// Palette of `sheet` converted to framebuffer pixels at comptime.
fn sheet_pixels(comptime sheet: type) [sheet.colors.len]cart.Pixel {
    var out: [sheet.colors.len]cart.Pixel = undefined;
    for (sheet.colors, 0..) |c, i| out[i] = .from_color(c);
    return out;
}

/// Palette index `i` of a 4-bit sheet: two pixels per byte, the even one in
/// the low nibble (`convert_gfx` packing, bit offset 0). A direct read is
/// about a quarter of the cost of the generic `PackedIntSlice.get`, which
/// was half of every frame in M7's badge-bench profile.
inline fn nibble(bytes: []const u8, i: usize) u8 {
    return (bytes[i >> 1] >> @intCast((i & 1) << 2)) & 0xF;
}

/// Draws cell `index` of a horizontal strip (`cell_w` x `cell_h` cells,
/// source x = index * cell_w) with its top-left at (x, y). Palette index 0
/// is transparent. Clipped to the screen.
pub fn draw_sprite(
    comptime sheet: type,
    comptime cell_w: u32,
    comptime cell_h: u32,
    index: u32,
    x: i32,
    y: i32,
    opts: SpriteOpts,
) void {
    const pixels = comptime sheet_pixels(sheet);
    const white: cart.Pixel = comptime .from_color(anti_white);
    const cw: i32 = cell_w;
    const ch: i32 = cell_h;
    const col_begin: i32 = @max(0, -x);
    const col_end: i32 = @min(cw, sw - x);
    const row_begin: i32 = @max(0, -y);
    const row_end: i32 = @min(ch, sh - y);
    if (col_begin >= col_end or row_begin >= row_end) return;
    const src_x0: usize = index * cell_w;
    const bytes = sheet.indices.bytes;
    var col = col_begin;
    while (col < col_end) : (col += 1) {
        const dx = x + col;
        const column = &cart.framebuffer[@intCast(dx)];
        var row = row_begin;
        while (row < row_end) : (row += 1) {
            const dy = y + row;
            if (opts.skip_odd and ((dx + dy) & 1) == 1) continue;
            const src: usize = @as(usize, @intCast(row)) * sheet.width + src_x0 + @as(usize, @intCast(col));
            const idx = nibble(bytes, src);
            if (idx == 0) continue;
            column[@intCast(dy)] = if (opts.flash_white) white else pixels[idx];
        }
    }
}

// Background: far layer (opaque, 256x120 at y 8), stars, near layer
// (transparent, 256x24 at y 104). Scroll state advances in `tick_bg`.

const Star = struct { x: u8, y: u8, fast: bool };
const star_count = 24;

/// Background scroll state, stored in `world.w.bg`. It is carried across
/// `new_game` so the sky scrolls on continuously from the title.
pub const BgState = struct {
    tick: u32 = 0,
    stars: [star_count]Star = initial_stars,
};

/// The stars scattered at comptime with a fixed local generator
/// (independent of the gameplay rng so the sky looks the same every boot).
const initial_stars: [star_count]Star = blk: {
    var out: [star_count]Star = @splat(.{ .x = 0, .y = 0, .fast = false });
    var s: u32 = 0x51A25;
    for (&out, 0..) |*star, i| {
        s ^= s << 13;
        s ^= s >> 17;
        s ^= s << 5;
        star.* = .{
            .x = @truncate(s % cart.screen_width),
            .y = @intCast(hud_height + @as(i32, @intCast((s >> 8) % @as(u32, @intCast(near_y - hud_height))))),
            .fast = i % 2 == 0,
        };
    }
    break :blk out;
};

pub fn tick_bg() void {
    const bg = &world.w.bg;
    bg.tick +%= 1;
    // Slow stars 1 px every 3 ticks, fast ones 1 px every 2 ticks: faster
    // than the far layer (1 px / 4 ticks), at most as fast as the near one.
    for (&bg.stars) |*star| {
        const period: u32 = if (star.fast) 2 else 3;
        if (bg.tick % period == 0) {
            star.x = if (star.x == 0) @intCast(cart.screen_width - 1) else star.x - 1;
        }
    }
}

pub fn draw_bg() void {
    const bg = &world.w.bg;
    draw_far((bg.tick / 4) % gfx.bg_far.width);
    for (bg.stars) |star| {
        cart.hline(.{
            .x = star.x,
            .y = star.y,
            .len = 1,
            .color = if (star.fast) anti_white else star_dim,
        });
    }
    draw_near((bg.tick / 2) % gfx.bg_near.width);
}

fn draw_far(scroll: u32) void {
    const sheet = gfx.bg_far;
    const pixels = comptime sheet_pixels(sheet);
    const y0: usize = @intCast(hud_height);
    for (0..cart.screen_width) |x| {
        const src_x = (x + scroll) % sheet.width;
        const column = cart.framebuffer[x][y0..][0..sheet.height];
        for (column, 0..) |*px, row| {
            px.* = pixels[nibble(sheet.indices.bytes, row * sheet.width + src_x)];
        }
    }
}

fn draw_near(scroll: u32) void {
    const sheet = gfx.bg_near;
    const pixels = comptime sheet_pixels(sheet);
    const y0: usize = @intCast(near_y);
    for (0..cart.screen_width) |x| {
        const src_x = (x + scroll) % sheet.width;
        const column = cart.framebuffer[x][y0..][0..sheet.height];
        for (column, 0..) |*px, row| {
            const idx = nibble(sheet.indices.bytes, row * sheet.width + src_x);
            if (idx != 0) px.* = pixels[idx];
        }
    }
}

/// Sets every pixel with even (x + y) to black: the pause/title dim.
pub fn darken_checker() void {
    const b: cart.Pixel = comptime .from_color(black);
    for (cart.framebuffer, 0..) |*column, x| {
        var y: usize = x & 1;
        while (y < cart.screen_height) : (y += 2) column[y] = b;
    }
}

/// Sets every odd screen row to black, full width: the rewind playback.
pub fn darken_scanlines() void {
    const b: cart.Pixel = comptime .from_color(black);
    for (cart.framebuffer) |*column| {
        var y: usize = 1;
        while (y < cart.screen_height) : (y += 2) column[y] = b;
    }
}

pub fn text(str: []const u8, x: i32, y: i32, color: cart.DisplayColor) void {
    cart.text(.{ .str = str, .x = x, .y = y, .text_color = color });
}

pub fn centered_text(str: []const u8, y: i32, color: cart.DisplayColor) void {
    const w: i32 = @intCast(str.len * cart.font_width);
    text(str, @divTrunc(sw - w, 2), y, color);
}
