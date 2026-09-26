//! Wall and door textures, unpacked once from `gfx` into column-major
//! `u8` arrays, and the shade palette sets (SPEC.md section 5).
//!
//! Texel values are indices into one combined 32-entry palette: walls use
//! 0..15 (the `walls.png` palette), doors 16..31 (`doors.png`). That way
//! a single `Pixel` table per shade set serves both sheets and the inner
//! loop is `column[y] = pal[tex_column[ty >> 16]]`.
const cart = @import("cart-api");
const gfx = @import("gfx");

pub const tex_size = 32;
pub const wall_count = 8;
pub const door_count = 5;
pub const tex_count = wall_count + door_count;
/// Door texture `k` lives at `tex[door_tex_base + k]`.
pub const door_tex_base = wall_count;
pub const door_pal_base = 16;

pub const Column = [tex_size]u8;
pub const Texture = [tex_size]Column;

/// `tex[id][x][y]`, 13 x 32 x 32 = 13 KB.
pub var tex: [tex_count]Texture = undefined;

pub const Set = enum(u8) {
    lit = 0,
    dark = 1,
    dim = 2,
    dimmer = 3,
    rewind = 4,
    hurt = 5,
};
pub const set_count = 6;
pub const Palette = [32]cart.Pixel;
/// `shade[set][palette index]`.
pub var shade: [set_count]Palette = undefined;

const iris_rgb = [3]u32{ 0x8E, 0x42, 0xDE };
const hurt_rgb = [3]u32{ 0xFF, 0x30, 0x20 };

pub fn init() void {
    unpack(gfx.walls, wall_count, 0, 0);
    unpack(gfx.doors, door_count, door_tex_base, door_pal_base);
    build_palettes(gfx.walls.colors, 0);
    build_palettes(gfx.doors.colors, door_pal_base);
}

fn unpack(comptime sheet: type, comptime cells: usize, comptime first: usize, comptime pal_base: u8) void {
    comptime {
        if (sheet.width != cells * tex_size or sheet.height != tex_size)
            @compileError("texture sheet has the wrong size");
        if (sheet.colors.len > 16) @compileError("texture sheet has more than 16 colors");
    }
    for (0..cells) |c| {
        const t = &tex[first + c];
        for (0..tex_size) |x| {
            for (0..tex_size) |y| {
                const idx: u8 = sheet.indices.get(y * sheet.width + c * tex_size + x);
                t[x][y] = pal_base + idx;
            }
        }
    }
}

fn build_palettes(colors: anytype, base: usize) void {
    for (0..16) |i| {
        // Palettes shorter than 16 entries: pad with the first color.
        const c = if (i < colors.len) colors[i] else colors[0];
        const r: u32 = @as(u32, c.r) * 255 / 31;
        const g: u32 = @as(u32, c.g) * 255 / 63;
        const b: u32 = @as(u32, c.b) * 255 / 31;
        shade[0][base + i] = px(r, g, b, 256);
        shade[1][base + i] = px(r, g, b, 176); // Wolf3D-style dark side, ~0.69
        shade[2][base + i] = px(r, g, b, 136); // > 6 cells
        shade[3][base + i] = px(r, g, b, 84); // > 10 cells
        // Tints: keep luminance, push hue toward the tint colour.
        const lum = (r * 77 + g * 150 + b * 29) >> 8;
        shade[4][base + i] = tint(r, g, b, lum, iris_rgb);
        shade[5][base + i] = tint(r, g, b, lum, hurt_rgb);
    }
}

fn px(r: u32, g: u32, b: u32, scale: u32) cart.Pixel {
    return rgb_pixel((r * scale) >> 8, (g * scale) >> 8, (b * scale) >> 8);
}

fn tint(r: u32, g: u32, b: u32, lum: u32, t: [3]u32) cart.Pixel {
    // 40 % original, 60 % luminance-scaled tint (tint at lum 255 is 1.4x t, clamped).
    const tr: u32 = @min(255, lum * t[0] * 7 / (5 * 255));
    const tg: u32 = @min(255, lum * t[1] * 7 / (5 * 255));
    const tb: u32 = @min(255, lum * t[2] * 7 / (5 * 255));
    return rgb_pixel((r * 2 + tr * 3) / 5, (g * 2 + tg * 3) / 5, (b * 2 + tb * 3) / 5);
}

pub fn rgb_pixel(r: u32, g: u32, b: u32) cart.Pixel {
    const rr: u32 = @min(r, 255);
    const gg: u32 = @min(g, 255);
    const bb: u32 = @min(b, 255);
    return .from_color(.rgb((rr << 16) | (gg << 8) | bb));
}
