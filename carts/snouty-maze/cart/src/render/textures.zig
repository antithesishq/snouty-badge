//! Unpacks the 4-bit gfx sheets into u8 texel grids at start() and builds
//! Pixel palettes. Track A owns. Texel layout is Track A's choice; only
//! `Texture` and the named textures are used by scene.zig (also Track A).
const cart = @import("cart-api");
const gfx = @import("gfx");

pub const size = 32;

pub const Texture = struct {
    /// Indexed `texels[(u << 5) | v]` (column-major, like the framebuffer).
    texels: *const [size * size]u8,
    palette: *const [16]cart.Pixel,
};

var wall_texels: [size * size]u8 = undefined;
var wall_lit_pal: [16]cart.Pixel = undefined;
var wall_dark_pal: [16]cart.Pixel = undefined;

pub var wall_lit: Texture = .{ .texels = &wall_texels, .palette = &wall_lit_pal };
pub var wall_dark: Texture = .{ .texels = &wall_texels, .palette = &wall_dark_pal };

/// Flat colour for wall tops.
pub var top_color: cart.Pixel = undefined;

/// STUB: unpacks the wall sheet only, with a lit and a half-brightness palette.
pub fn init() void {
    const sheet = gfx.wall;
    for (0..size) |v| {
        for (0..size) |u| {
            wall_texels[(u << 5) | v] = sheet.indices.get(v * sheet.width + u);
        }
    }
    for (0..16) |i| {
        const c: cart.DisplayColor = if (i < sheet.colors.len) sheet.colors[i] else .{ .r = 0, .g = 0, .b = 0 };
        wall_lit_pal[i] = .from_color(c);
        wall_dark_pal[i] = .from_color(.{ .r = c.r / 2, .g = c.g / 2, .b = c.b / 2 });
    }
    top_color = .from_color(.{ .r = 20, .g = 20, .b = 20 });
}
