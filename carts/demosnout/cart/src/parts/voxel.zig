//! Part 7, Voxel landscape (7 bars, 14 s): a Comanche-style fly-over of a
//! Green Hill Zone island.
//!
//! init() builds one 128x128 map of u16 cells (height in the high byte,
//! colour index in the low byte, 32 KB) from three octaves of wrapping
//! value noise, pulled down to sea by a radial falloff so the coast is
//! water all round, then terraced (flat tops, steep steps between them, as
//! in Green Hill Zone). Colour comes from height and slope: deep and
//! shallow water, sand, grass in a light/dark checker on the flat, and
//! brown/orange checker cliffs on the steep steps, each in four shades from
//! a fixed sun. The colour index is material * 4 + shade; a [16][32] table
//! of pixels fades each colour toward the horizon haze by distance.
//!
//! The camera circles the island once over the part, at a fixed altitude
//! above the highest terrain with a slow bob, heading along the path
//! tangent turned inward so the island stays in view, banked into the
//! turn. render() marches one ray per screen column from near to far over
//! a fixed table of depths that grows geometrically: per step one map
//! load at the 16.16 fixed-point ray position (wrapping & 127), one
//! multiply by a precomputed 1/z to project the height to a screen row, and
//! a fill from the lowest unfilled row up to that row (painter's order, so
//! farther samples only fill above what is drawn). The sky gradient and the
//! sun disc fill what the terrain leaves. Water shades cycle per frame.
//! f32 only per frame and per column; the march is integer.
const std = @import("std");
const cart = @import("cart-api");
const math = @import("../math.zig");
const palette = @import("../palette.zig");
const rng = @import("../rng.zig");

pub const name: []const u8 = "Voxel";

const width = 160;
const height = 128;

pub const map_n = 128;
const map_mask = map_n - 1;
pub const Map = [map_n * map_n]u16;

// Tuning knobs.
pub const sea_level: u8 = 40;
/// Frames per circle of the island (the whole part).
const circle_frames: f32 = 840;
/// Screen columns per ray (1 = full res, 2 = half horizontal res).
const col_w = 1;
const rays = width / col_w;
/// Focal length in pixels (horizontal field of view about 60 degrees).
const focal: f32 = 138;
/// Height units per map cell (heights are u8; 8 units = one cell).
const units_per_cell: f32 = 8;
pub const steps = 150;
const z_near: f32 = 3.0;
const z_growth: f32 = 1.021;
const z_add: f32 = 0.08;
pub const fog_levels = 16;
/// Fog at the last step, out of 256.
const fog_far: f32 = 250;
/// Fog starts at this depth.
const fog_start: f32 = 18;
const horizon_row: f32 = 30;

const materials = 8;
const m_deep = 0;
const m_shallow = 1;
const m_sand = 2;
const m_grass_a = 3;
const m_grass_b = 4;
const m_cliff_a = 5;
const m_cliff_b = 6;
const m_tree = 7;
pub const colours = materials * 4;

const material_rgb = [materials]u32{
    0x1440a8, // deep water
    0x2c9ce0, // shallow water
    0xf0dc8c, // sand
    0x4cd830, // grass, light square
    0x28a828, // grass, dark square
    0x8c4818, // cliff, brown square
    0xe08828, // cliff, orange square
    0x146c1c, // tree
};
/// Shade multipliers in 1/256: away from the sun .. facing it.
const shade_mul = [4]u32{ 150, 205, 256, 300 };
/// Water shades are a ramp that cycles rather than lighting.
const water_mul = [4]u32{ 215, 240, 262, 290 };

const sky_top: u32 = 0x2050c8;
const sky_horizon: u32 = 0xc4e0f8;
const haze: u32 = 0xb8d8f0;
const sun_rgb: u32 = 0xfff4c8;
const sun_glow_rgb: u32 = 0xfce8b0;
/// World direction of the sun, in turns.
const sun_dir: f32 = 0.60;

var map: Map = undefined;
var base_rgb: [colours]u32 = undefined;
var fog_pal: [fog_levels][colours]cart.Pixel = undefined;
/// Per step: depth in 1/256 cell, projection scale in Q16, fog level.
var step_z: [steps]i32 = undefined;
var step_invz: [steps]i32 = undefined;
var step_fog: [steps]u8 = undefined;
var sky_col: [height]cart.Pixel = undefined;
var sun_px: cart.Pixel = undefined;
var glow_px: cart.Pixel = undefined;

pub fn init() void {
    generate(&map);
    for (0..materials) |m| for (0..4) |s| {
        const mul = if (m <= m_shallow) water_mul[s] else shade_mul[s];
        base_rgb[m * 4 + s] = scale_rgb(material_rgb[m], mul);
    };
    build_fog(0, colours);
    var z: f32 = z_near;
    for (0..steps) |i| {
        step_z[i] = @intFromFloat(z * 256.0);
        // pixels = dh_units/units_per_cell * focal / z; dh is kept in 1/16
        // units, the product is shifted down 16.
        step_invz[i] = @intFromFloat(focal * 65536.0 / (16.0 * units_per_cell * z));
        const f = math.clamp01((z - fog_start) / (z_far() - fog_start));
        step_fog[i] = @intFromFloat(@min(@as(f32, fog_levels - 1), f * f * 0.3 * @as(f32, fog_levels) + f * 0.7 * @as(f32, fog_levels)));
        z = z * z_growth + z_add;
    }
    for (&sky_col, 0..) |*px, y| {
        const fy: f32 = @floatFromInt(y);
        const f = math.clamp01(fy / (horizon_row + 6));
        px.* = palette.pixel(palette.mix_rgb(sky_top, sky_horizon, @intFromFloat(math.smoothstep01(f) * 256.0)));
    }
    sun_px = palette.pixel(sun_rgb);
    glow_px = palette.pixel(sun_glow_rgb);
}

fn z_far() f32 {
    var z: f32 = z_near;
    for (0..steps - 1) |_| z = z * z_growth + z_add;
    return z;
}

pub fn enter() void {}

fn scale_rgb(rgb: u32, mul: u32) u32 {
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |shift| {
        const c: u32 = @min(255, (((rgb >> shift) & 0xff) * mul) >> 8);
        out |= c << shift;
    }
    return out;
}

/// Fogged palette of the first `n` colours; water shades (colours 0..7)
/// rotated by `phase` (0..3). init() builds all, render() only the water.
fn build_fog(phase: u32, n: usize) void {
    for (0..fog_levels) |l| {
        const f: u32 = @intFromFloat(fog_far * @as(f32, @floatFromInt(l)) / @as(f32, fog_levels - 1));
        for (0..n) |c| {
            var src = c;
            if (c < 8) src = (c & ~@as(usize, 3)) | ((c + phase) & 3);
            fog_pal[l][c] = palette.pixel(palette.mix_rgb(base_rgb[src], haze, f));
        }
    }
}

// ---------------------------------------------------------------------------
// Map generation (host-tested).

fn Lattice(comptime n: u32) type {
    return struct {
        v: [n * n]f32,

        const Self = @This();
        const cell = map_n / n;

        fn init(r: *rng.Xorshift) Self {
            var l: Self = undefined;
            for (&l.v) |*v| v.* = r.unit();
            return l;
        }

        /// Bilinear, smoothstep-weighted, wrapping sample at map cell (x, y).
        fn sample(l: *const Self, x: u32, y: u32) f32 {
            const gx = x / cell;
            const gy = y / cell;
            const fx = math.smoothstep01(@as(f32, @floatFromInt(x % cell)) / @as(f32, cell));
            const fy = math.smoothstep01(@as(f32, @floatFromInt(y % cell)) / @as(f32, cell));
            const x1 = (gx + 1) % n;
            const y1 = (gy + 1) % n;
            const a = l.v[gy * n + gx];
            const b = l.v[gy * n + x1];
            const c = l.v[y1 * n + gx];
            const d = l.v[y1 * n + x1];
            return math.lerp1(math.lerp1(a, b, fx), math.lerp1(c, d, fx), fy);
        }
    };
}

pub inline fn cell_height(c: u16) u8 {
    return @truncate(c >> 8);
}

pub inline fn cell_colour(c: u16) u8 {
    return @truncate(c);
}

pub fn material_of(colour: u8) u8 {
    return colour >> 2;
}

// Classes of the first pass, in the low byte until the second pass.
const c_deep = 0;
const c_shallow = 1;
const c_sand = 2;
const c_land = 3;
const c_high = 4; // land high enough for trees

/// Fills `out` with the island: height << 8 | colour index. Three passes
/// over `out` itself (no big stack buffers: the badge stack is small):
/// elevation to height and class, then colour from class, slope and light,
/// then tree clumps.
pub fn generate(out: *Map) void {
    var r = rng.Xorshift.init(0x6a11_2e57);
    const o1 = Lattice(4).init(&r);
    const o2 = Lattice(8).init(&r);
    const o3 = Lattice(16).init(&r);
    const o4 = Lattice(32).init(&r);
    for (0..map_n) |y| for (0..map_n) |x| {
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        const n = 0.45 * o1.sample(ux, uy) + 0.3 * o2.sample(ux, uy) +
            0.17 * o3.sample(ux, uy) + 0.08 * o4.sample(ux, uy);
        const dx = @as(f32, @floatFromInt(x)) - 64.0;
        const dy = @as(f32, @floatFromInt(y)) - 64.0;
        const d = @sqrt(dx * dx + dy * dy) / 60.0;
        const mask = 1.0 - math.smoothstep(0.35, 1.0, d);
        const e = mask * (0.25 + 1.1 * n) - 0.3;
        // Water flat at sea level, a flat beach, then terraces.
        var h: u8 = undefined;
        var class: u8 = undefined;
        if (e <= 0) {
            h = sea_level;
            class = if (e < -0.1) c_deep else c_shallow;
        } else if (e < 0.04) {
            h = sea_level + 1 + @as(u8, @intFromFloat(e * 50.0));
            class = c_sand;
        } else {
            const levels: f32 = 5;
            const s = (e - 0.04) * levels / 0.8;
            const k = @floor(s);
            const f = math.smoothstep(0.7, 0.95, s - k);
            const terr = @min(1.0, (k + f) / levels);
            h = @intFromFloat(@min(245.0, @as(f32, @floatFromInt(sea_level)) + 3.0 + terr * 140.0));
            class = if (e > 0.08) c_high else c_land;
        }
        out[y * map_n + x] = @as(u16, h) << 8 | class;
    };
    // Colour: reads neighbours' heights (high bytes), rewrites low bytes.
    for (0..map_n) |y| for (0..map_n) |x| {
        const i = y * map_n + x;
        const h = cell_height(out[i]);
        const class = cell_colour(out[i]);
        const hl: i32 = cell_height(out[y * map_n + ((x + map_mask) & map_mask)]);
        const hr: i32 = cell_height(out[y * map_n + ((x + 1) & map_mask)]);
        const hu: i32 = cell_height(out[((y + map_mask) & map_mask) * map_n + x]);
        const hd: i32 = cell_height(out[((y + 1) & map_mask) * map_n + x]);
        const slope = @max(@abs(hr - hl), @abs(hd - hu));
        const light = (hl + hu) - (hr + hd); // sun from -x, -y
        var mat: u8 = undefined;
        var shade: u8 = undefined;
        if (class <= c_shallow) {
            mat = if (class == c_deep) m_deep else m_shallow;
            // Diagonal wave bands, cycled by the palette.
            const xu: u32 = @intCast(x);
            const yu: u32 = @intCast(y);
            shade = @intCast(((xu + 2 * yu + (xu * yu >> 5)) >> 1) & 3);
        } else {
            if (class == c_sand) {
                mat = m_sand;
            } else if (slope > 14) {
                const band: u32 = @as(u32, h) / 12 + @as(u32, @intCast((x + y) >> 2));
                mat = if (band & 1 == 0) m_cliff_a else m_cliff_b;
            } else {
                mat = if (((x >> 2) ^ (y >> 2)) & 1 == 0) m_grass_a else m_grass_b;
                // Trees only on flat, high grass (marked for pass three).
                if (class == c_high and slope < 6) mat |= 0x80;
            }
            shade = @intCast(std.math.clamp(2 + @divFloor(light, 10), 0, 3));
        }
        out[i] = @as(u16, h) << 8 | (@as(u16, mat & 0x7f) * 4 + shade) | (@as(u16, mat & 0x80));
    };
    // Tree clumps: 2x2 cells, raised a little, where pass two allowed.
    for (0..90) |_| {
        const cx = r.below(map_n);
        const cy = r.below(map_n);
        for (0..2) |ty| for (0..2) |tx| {
            const i = ((cy + ty) & map_mask) * map_n + ((cx + tx) & map_mask);
            const c = out[i];
            if (c & 0x80 == 0) continue;
            const h = cell_height(c) +| 5;
            out[i] = @as(u16, h) << 8 | (m_tree * 4 + (c & 3)) | 0x80;
        };
    }
    for (out) |*c| c.* &= 0xff7f;
}

// ---------------------------------------------------------------------------
// Render.

pub fn render(t: u32, fb: cart.FramebufferPtr) void {
    build_fog((t / 5) & 3, 8);

    const tf: f32 = @floatFromInt(t);
    const phase = tf / circle_frames;
    const orbit = 0.62 + phase; // start south-west of the centre
    const radius = 46.0 + 8.0 * math.sin_turns(phase * 2.0);
    const cam_x = 64.0 + radius * math.cos_turns(orbit);
    const cam_y = 64.0 + radius * math.sin_turns(orbit);
    // Tangent of a counter-clockwise circle, turned 54 degrees inward (the centre sits 36 degrees left of the view).
    const heading = orbit + 0.25 + 0.15;
    const fwd_x = math.cos_turns(heading);
    const fwd_y = math.sin_turns(heading);
    // Right-hand vector on screen.
    const right_x = -fwd_y;
    const right_y = fwd_x;
    const alt = 240.0 + 10.0 * math.sin_turns(tf / 300.0);
    const roll: f32 = 0.10 + 0.03 * math.sin_turns(tf / 420.0);
    const bob = 3.0 * math.sin_turns(tf / 170.0);

    const cx: i32 = @intFromFloat(cam_x * 65536.0);
    const cy: i32 = @intFromFloat(cam_y * 65536.0);
    const cam_h: i32 = @intFromFloat(alt * 16.0);

    // Sun column: angle of the sun relative to the heading.
    const rel = math.fract(sun_dir - heading + 0.5) - 0.5;
    const sun_visible = @abs(rel) < 0.2;
    const sun_x: f32 = if (sun_visible) 80.0 + focal * math.sin_turns(rel) / math.cos_turns(rel) else -100.0;

    var ray: u32 = 0;
    while (ray < rays) : (ray += 1) {
        const x0 = ray * col_w;
        const sxf = (@as(f32, @floatFromInt(x0)) + @as(f32, col_w) * 0.5 - 80.0);
        const u = sxf / focal;
        const ddx: i64 = @as(i32, @intFromFloat((fwd_x - right_x * u) * 65536.0));
        const ddy: i64 = @as(i32, @intFromFloat((fwd_y - right_y * u) * 65536.0));
        const hor: i32 = @intFromFloat(horizon_row + bob - sxf * roll);
        const col = &fb[x0];

        var ybot: i32 = height;
        for (0..steps) |i| {
            const zq: i64 = step_z[i];
            const px: i32 = cx +% @as(i32, @truncate((ddx * zq) >> 8));
            const py: i32 = cy +% @as(i32, @truncate((ddy * zq) >> 8));
            const idx = ((@as(u32, @bitCast(py)) >> 16) & map_mask) * map_n + ((@as(u32, @bitCast(px)) >> 16) & map_mask);
            const c = map[idx];
            const dh: i32 = cam_h - @as(i32, c >> 8) * 16;
            var y = hor + ((dh * step_invz[i]) >> 16);
            if (y < ybot) {
                const p = fog_pal[step_fog[i]][c & 0xff];
                if (y < 0) y = 0;
                var r: i32 = ybot;
                while (r > y) {
                    r -= 1;
                    col[@intCast(r)] = p;
                }
                ybot = y;
                if (ybot == 0) break;
            }
        }
        // Sky above whatever the terrain left.
        const top: usize = @intCast(ybot);
        @memcpy(col[0..top], sky_col[0..top]);
        const dxs = @abs(sxf - (sun_x - 80.0));
        if (dxs < 11.0) {
            const sun_y: f32 = @as(f32, @floatFromInt(hor)) - 16.0;
            draw_disc(col, top, sun_y, @sqrt(121.0 - dxs * dxs), glow_px);
            if (dxs < 7.0) draw_disc(col, top, sun_y, @sqrt(49.0 - dxs * dxs), sun_px);
        }
        if (col_w == 2) fb[x0 + 1] = col.*;
    }
}

fn draw_disc(col: *[height]cart.Pixel, top: usize, cy: f32, half: f32, px: cart.Pixel) void {
    const a: i32 = @intFromFloat(@max(0.0, cy - half + 0.5));
    const b: i32 = @intFromFloat(@max(0.0, cy + half + 0.5));
    var y: usize = @intCast(a);
    const end: usize = @min(top, @as(usize, @intCast(b)));
    while (y < end) : (y += 1) col[y] = px;
}

test "island: water at the edges, land and cliffs in the middle" {
    var m: Map = undefined;
    generate(&m);
    // The border is water at sea level all round.
    for (0..map_n) |k| {
        for ([_]usize{ k, k * map_n, (map_n - 1) * map_n + k, k * map_n + map_n - 1 }) |i| {
            try std.testing.expectEqual(sea_level, cell_height(m[i]));
            try std.testing.expect(material_of(cell_colour(m[i])) <= m_shallow);
        }
    }
    var count: [materials]u32 = @splat(0);
    var hmax: u8 = 0;
    for (m) |c| {
        count[material_of(cell_colour(c))] += 1;
        hmax = @max(hmax, cell_height(c));
        try std.testing.expect(cell_colour(c) < colours);
    }
    // Some of every material, a real island, below the camera.
    for (count) |n| try std.testing.expect(n > 0);
    try std.testing.expect(count[m_grass_a] + count[m_grass_b] > 1500);
    try std.testing.expect(count[m_cliff_a] + count[m_cliff_b] > 200);
    try std.testing.expect(hmax > 140 and hmax < 230);
    // Deterministic.
    var m2: Map = undefined;
    generate(&m2);
    try std.testing.expectEqualSlices(u16, &m, &m2);
}
