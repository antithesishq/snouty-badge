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
