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
    init_sprites();
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

// Sprite palettes (PLAN.md M2 track A). One 16-entry table per sprite
// sheet and tint; sprites are not distance-shaded, so only three sets:
// normal, rewind (Iris) and hurt (red), built with the same `tint` as the
// walls so both move together.

/// Sprite sheets in palette order; enemies map by `@intFromEnum(kind)`.
pub const SpriteSheet = enum(u8) { gnat = 0, wasp, beetle, spider, boss, pickups, projectiles };
pub const sprite_sheet_count = 7;
pub const SpriteTint = enum(u8) { normal = 0, rewind = 1, hurt = 2 };
pub const sprite_tint_count = 3;
/// `sprite_pal[sheet][tint][index]`, 7 x 3 x 16 x 2 = 672 bytes.
pub var sprite_pal: [sprite_sheet_count][sprite_tint_count][16]cart.Pixel = undefined;

/// Tint for sprites from `view.shade_override`: null/0..3 normal, 4 rewind, 5 hurt.
pub fn sprite_tint(override: ?u8) SpriteTint {
    const o = override orelse return .normal;
    return switch (o) {
        4 => .rewind,
        5 => .hurt,
        else => .normal,
    };
}

pub fn init_sprites() void {
    build_sprite_palette(.gnat, gfx.bug_gnat.colors);
    build_sprite_palette(.wasp, gfx.bug_wasp.colors);
    build_sprite_palette(.beetle, gfx.bug_beetle.colors);
    build_sprite_palette(.spider, gfx.bug_spider.colors);
    build_sprite_palette(.boss, gfx.bug_boss.colors);
    build_sprite_palette(.pickups, gfx.pickups.colors);
    build_sprite_palette(.projectiles, gfx.projectiles.colors);
}

fn build_sprite_palette(sheet: SpriteSheet, colors: anytype) void {
    const p = &sprite_pal[@backingInt(sheet)];
    for (0..16) |i| {
        // Short palettes: pad with the first color (index 0 is transparent anyway).
        const c = if (i < colors.len) colors[i] else colors[0];
        const r: u32 = @as(u32, c.r) * 255 / 31;
        const g: u32 = @as(u32, c.g) * 255 / 63;
        const b: u32 = @as(u32, c.b) * 255 / 31;
        const lum = (r * 77 + g * 150 + b * 29) >> 8;
        p[0][i] = px(r, g, b, 256);
        p[1][i] = tint(r, g, b, lum, iris_rgb);
        p[2][i] = tint(r, g, b, lum, hurt_rgb);
    }
}
