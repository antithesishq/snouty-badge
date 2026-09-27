//! Unpacks the 4-bit gfx sheets into u8 texel grids at start() and builds
//! Pixel palettes, so the inner loops are a byte load and a u16 load.
const cart = @import("cart-api");
const gfx = @import("gfx");

pub const size = 32;

pub const Texture = struct {
    /// Indexed `texels[(u << 5) | v]` (column-major, like the framebuffer):
    /// u is the image column, v the image row.
    texels: *const [size * size]u8,
    palette: *const [16]cart.Pixel,
    /// Extent of the image in the grid, in texture units: sprite quads map
    /// u, v over [0, uv_max] (1.0 for every current sheet).
    uv_max: f32 = 1.0,
};

var wall_texels: [size * size]u8 = undefined;
var floor_texels: [size * size]u8 = undefined;
var ceiling_texels: [size * size]u8 = undefined;
var finish_texels: [size * size]u8 = undefined;
var wall_lit_pal: [16]cart.Pixel = undefined;
var wall_dark_pal: [16]cart.Pixel = undefined;
var floor_pal: [16]cart.Pixel = undefined;
var ceiling_pal: [16]cart.Pixel = undefined;
var finish_pal: [16]cart.Pixel = undefined;

/// x-axis wall runs (faces pointing north/south).
pub var wall_lit: Texture = .{ .texels = &wall_texels, .palette = &wall_lit_pal };
/// z-axis wall runs (faces pointing east/west), about 70% brightness.
pub var wall_dark: Texture = .{ .texels = &wall_texels, .palette = &wall_dark_pal };
pub var floor: Texture = .{ .texels = &floor_texels, .palette = &floor_pal };
pub var ceiling: Texture = .{ .texels = &ceiling_texels, .palette = &ceiling_pal };
pub var finish: Texture = .{ .texels = &finish_texels, .palette = &finish_pal };

var snouty_texels: [4][size * size]u8 = undefined;
var smiley_texels: [size * size]u8 = undefined;
var logo_texels: [size * size]u8 = undefined;
var snouty_pal: [16]cart.Pixel = undefined;
var smiley_pal: [16]cart.Pixel = undefined;
var logo_pal: [16]cart.Pixel = undefined;

/// Actor sprites. Palette index 0 is the transparent magenta key, skipped
/// by `Fill.sprite`. Snouty's four 32x32 walk frames share one palette.
pub var snouty: [4]Texture = .{
    .{ .texels = &snouty_texels[0], .palette = &snouty_pal },
    .{ .texels = &snouty_texels[1], .palette = &snouty_pal },
    .{ .texels = &snouty_texels[2], .palette = &snouty_pal },
    .{ .texels = &snouty_texels[3], .palette = &snouty_pal },
};
pub var smiley: Texture = .{ .texels = &smiley_texels, .palette = &smiley_pal };
pub var logo: Texture = .{ .texels = &logo_texels, .palette = &logo_pal };

var wall_pic_texels: [size * size]u8 = undefined;
var start_texels: [size * size]u8 = undefined;
var iris_texels: [size * size]u8 = undefined;
var wall_pic_pal: [16]cart.Pixel = undefined;
var start_pal: [16]cart.Pixel = undefined;
var iris_pal: [16]cart.Pixel = undefined;

/// The picture hung on about one wall segment in eight (opaque).
pub var wall_pic: Texture = .{ .texels = &wall_pic_texels, .palette = &wall_pic_pal };
/// Start button and Iris mark (index 0 transparent).
pub var start: Texture = .{ .texels = &start_texels, .palette = &start_pal };
pub var iris: Texture = .{ .texels = &iris_texels, .palette = &iris_pal };

/// Flat colour for wall tops.
pub var top_color: cart.Pixel = undefined;

pub fn init() void {
    unpack(gfx.wall, &wall_texels);
    unpack(gfx.floor, &floor_texels);
    unpack(gfx.ceiling, &ceiling_texels);
    unpack(gfx.finish, &finish_texels);
    palette(gfx.wall, &wall_lit_pal, 10);
    palette(gfx.wall, &wall_dark_pal, 7);
    palette(gfx.floor, &floor_pal, 10);
    palette(gfx.ceiling, &ceiling_pal, 10);
    palette(gfx.finish, &finish_pal, 10);
    top_color = .from_color(.rgb(0x808080));

    for (&snouty_texels, 0..) |*t, f| unpack_region(gfx.snouty, f * size, size, t);
    unpack(gfx.smiley, &smiley_texels);
    unpack(gfx.logo, &logo_texels);
    palette(gfx.snouty, &snouty_pal, 10);
    palette(gfx.smiley, &smiley_pal, 10);
    palette(gfx.logo, &logo_pal, 10);

    unpack(gfx.wall_pic, &wall_pic_texels);
    unpack(gfx.start, &start_texels);
    unpack(gfx.iris, &iris_texels);
    palette(gfx.wall_pic, &wall_pic_pal, 10);
    palette(gfx.start, &start_pal, 10);
    palette(gfx.iris, &iris_pal, 10);
}

/// Copies an n x n block starting at sheet column x0 into the top-left of a
/// 32x32 grid; texels outside the block are 0 (transparent for sprites).
fn unpack_region(comptime sheet: type, x0: usize, comptime n: usize, out: *[size * size]u8) void {
    comptime {
        if (sheet.height < n or n > size) @compileError("sprite region out of range");
    }
    @memset(out, 0);
    for (0..n) |v| {
        for (0..n) |u| {
            out[(u << 5) | v] = sheet.indices.get(v * sheet.width + x0 + u);
        }
    }
}

fn unpack(comptime sheet: type, out: *[size * size]u8) void {
    comptime {
        if (sheet.width < size or sheet.height < size) @compileError("texture sheet smaller than 32x32");
    }
    for (0..size) |v| {
        for (0..size) |u| {
            out[(u << 5) | v] = sheet.indices.get(v * sheet.width + u);
        }
    }
}

/// Palette scaled by tenths (10 = unchanged). Unused entries are black.
fn palette(comptime sheet: type, out: *[16]cart.Pixel, comptime tenths: u32) void {
    for (out, 0..) |*p, i| {
        const c: cart.DisplayColor = if (i < sheet.colors.len) sheet.colors[i] else .{ .r = 0, .g = 0, .b = 0 };
        p.* = .from_color(.{
            .r = @intCast(@as(u32, c.r) * tenths / 10),
            .g = @intCast(@as(u32, c.g) * tenths / 10),
            .b = @intCast(@as(u32, c.b) * tenths / 10),
        });
    }
}
