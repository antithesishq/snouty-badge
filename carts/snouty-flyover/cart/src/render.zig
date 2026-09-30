//! The column march, sky and sun, cliff shading (SPEC.md 5.1-5.3). All
//! integer: Q16.16 world coordinates, precomputed step, reciprocal, fog-level,
//! sin and direction tables, so wasm, badge-bench and the badge draw the same
//! frame. The fog dither of SPEC 5.3 is M1.
const cart = @import("cart-api");
const fixed = @import("fixed.zig");
const world = @import("world.zig");
const palette = @import("palette.zig");
const camera = @import("camera.zig");

// --- Knobs (SPEC.md 10 lists the cut order) ---------------------------------

/// Far end of the march in Q16 cells (knob, SPEC.md 10): 256 cells, capped
/// at the rows the map ring keeps generated ahead of the camera.
pub const z_far: i32 = @as(i32, @min(256, world.gen_ahead)) << fixed.Q;
/// Step growth per march step, 1.0075 in Q16 (knob); ~143 steps to z_far.
pub const lod_mul: i32 = 0x1_01EC;
/// First sample distance and first step, Q16 cells.
const z0: i32 = fixed.one;
const dz0: i32 = fixed.one;
/// Vertical view scale: rows per cell of height at z = 1 cell. 32 makes a
/// cell of height 64 at z = 64 subtend 32 rows (PLAN.md renderer constants).
const view_scale: i32 = 32;
/// Horizontal field of view: tan(half FOV) in Q16 (0.8, about 77 degrees, as
/// in the concept); a column's ray offset is u = (2x - 159) / 160 * fov_tan.
const fov_tan: i32 = 52429;
/// Screen columns per unit of tan(angle): 80 / 0.8 (places the sun by yaw).
const px_per_tan: i32 = 100;
/// A span taller than this many rows whose height jump is above cliff_dh
/// cells draws the colour's side entry (c | 1) for district indices.
const cliff_min: i32 = 6;
const cliff_dh: i32 = 12;
/// Fog starts at this distance (cells) and reaches the fog colour at z_far.
const fog_near: i32 = 60;
/// Iris sun: mark scale (24 px -> 72 px), centre rows above the horizon.
const sun_scale = 3;
const sun_size = 24 * sun_scale;
const sun_up: i32 = 20;
/// Sun core colour and the rim darkening (rim = core * sun_rim / 256).
const sun_rgb: u32 = 0xFFB040;
const sun_rim: u32 = 176;
/// Sky gradient stops, rows above the horizon -> 0xRRGGBB (concept `sky`).
const sky_stops = [_]struct { d: i32, rgb: u32 }{
    .{ .d = -1, .rgb = palette.fog_rgb },
    .{ .d = 0, .rgb = 0x7A3A2A }, // warm horizon band
    .{ .d = 3, .rgb = 0x4A2448 },
    .{ .d = 16, .rgb = 0x2A1A5E }, // indigo
    .{ .d = 95, .rgb = 0x06040F }, // near-black top
};
/// Stars: count, rows 0..star_rows at the level horizon, fixed seed.
const star_count = 40;
const star_rows = 40;
const star_seed: u32 = 0x57A2_5EED;

// --- Screen -----------------------------------------------------------------

const sw = 160;
const sh = 128;
/// Table capacity; the march at lod_mul 1.0075 to 256 cells takes ~143 steps
/// (raise this if lod_mul goes below 1.0075).
const max_steps = 192;
/// District indices (>= 96) have a side entry at c | 1.
const district_base = 96;

/// The shared Antithesis Iris mark (lib/iris_mark.zig), bit 23 = leftmost pixel.
const iris_rows = @import("iris").rows;

// --- Tables built by init() -------------------------------------------------

/// Sample distance per step (Q16 cells), its scaled reciprocal
/// (view_scale * 2^32 / z, so mul(dh, inv_z) >> 16 is rows) and fog level.
var z_tab: [max_steps]i32 = undefined;
var inv_z: [max_steps]i32 = undefined;
var fog_level: [max_steps]u8 = undefined;
var n_steps: usize = 0;
/// sin of i/1024 turn for i in 0..256 (a quarter wave), Q16.
var sin_q: [257]i32 = undefined;
/// Per-column ray direction (Q16, unnormalised: depth along the heading is z).
var dir_x: [sw]i32 = undefined;
var dir_y: [sw]i32 = undefined;
var dir_yaw: i32 = 0;
/// Sky colour by (row - horizon + 128), Pixel bits.
var sky_rel: [256]cart.Pixel = undefined;
/// Sun mask [column][row / 4], 2 bits per row (bits 2*(row % 4)): 0 none,
/// 1 rim, 2 core; colours per mask row.
var sun_mask: [sun_size][sun_size / 4]u8 = undefined;
var sun_core: [sun_size]cart.Pixel = undefined;
var sun_rim_px: [sun_size]cart.Pixel = undefined;
var star_x: [star_count]u8 = undefined;
var star_y: [star_count]u8 = undefined;
var star_px: [star_count]cart.Pixel = undefined;
/// Occlusion row per column after this frame's march (sky is rows 0..occ).
var occ_col: [sw]u8 = undefined;

pub fn init() void {
    init_steps();
    init_sin();
    build_dirs(0);
    init_sky();
    init_sun();
    init_stars();
    palette.begin_frame(0);
}

fn init_steps() void {
    var z = z0;
    var dz = dz0;
    var i: usize = 0;
    while (i < max_steps and z < z_far) : (i += 1) {
        z_tab[i] = z;
        // view_scale * 2^32 / z, as (view_scale << 24) / (z >> 8).
        inv_z[i] = @divTrunc(view_scale << 24, z >> 8);
        fog_level[i] = level_for(z);
        z += dz;
        dz = fixed.mul(dz, lod_mul);
    }
    n_steps = i;
}

/// Fog level of a sample at distance z (Q16 cells): 0 before fog_near, then
/// f = (z - near) / (far - near) on the concept's f^1.4 curve (approximated
/// as 0.6 f + 0.4 f^2), rounded to 0..7. M1 retunes here.
fn level_for(z: i32) u8 {
    const zc8 = z >> 8; // Q8 cells
    const near8 = fog_near << 8;
    if (zc8 <= near8) return 0;
    const span8 = (z_far >> 8) - near8;
    const f = @min(@divTrunc((zc8 - near8) * 256, span8), 256); // Q8
    const g = (154 * f + @divTrunc(102 * f * f, 256)) >> 8; // Q8
    return @intCast(@min((g * (palette.fog_levels - 1) + 128) >> 8, palette.fog_levels - 1));
}

/// Quarter-wave Taylor series to x^9 in Q16 (error about 1 LSB).
fn init_sin() void {
    for (&sin_q, 0..) |*q, i| {
        const x: i32 = @intCast((@as(u32, @intCast(i)) * 102944) >> 8); // i * (pi/2) / 256
        const x2 = fixed.mul(x, x);
        var term = x;
        var sum = x;
        var k: i32 = 1;
        while (k <= 4) : (k += 1) {
            term = -@divTrunc(fixed.mul(term, x2), (2 * k) * (2 * k + 1));
            sum += term;
        }
        q.* = @min(sum, fixed.one);
    }
}

/// sin of a/1024 turn, Q16, mirrored from the quarter wave.
fn sin(a: i32) i32 {
    const i: usize = @intCast(a & 1023);
    return switch (i >> 8) {
        0 => sin_q[i],
        1 => sin_q[512 - i],
        2 => -sin_q[i - 512],
        else => -sin_q[1024 - i],
    };
}
fn cos(a: i32) i32 {
    return sin(a + 256);
}

fn build_dirs(yaw: i32) void {
    const s = sin(yaw);
    const c = cos(yaw);
    for (0..sw) |x| {
        const u = @divTrunc((2 * @as(i32, @intCast(x)) - (sw - 1)) * fov_tan, sw);
        dir_x[x] = s + fixed.mul(u, c);
        dir_y[x] = c - fixed.mul(u, s);
    }
    dir_yaw = yaw;
}

fn init_sky() void {
    for (&sky_rel, 0..) |*px, k| {
        const d = 128 - @as(i32, @intCast(k)); // rows above the horizon
        var rgb: u32 = sky_stops[sky_stops.len - 1].rgb;
        if (d <= sky_stops[0].d) {
            rgb = sky_stops[0].rgb;
        } else {
            for (sky_stops[0 .. sky_stops.len - 1], sky_stops[1..]) |a, b| {
                if (d <= b.d) {
                    rgb = lerp_rgb(a.rgb, b.rgb, d - a.d, b.d - a.d);
                    break;
                }
            }
        }
        px.* = pixel(rgb);
    }
}

fn init_sun() void {
    for (0..sun_size) |sx| {
        @memset(&sun_mask[sx], 0);
        for (0..sun_size) |sy| {
            const m: u8 = if (!sun_bit(@intCast(sx), @intCast(sy)))
                0
            else if (sun_bit(@as(i32, @intCast(sx)) - 1, @intCast(sy)) and
                sun_bit(@as(i32, @intCast(sx)) + 1, @intCast(sy)) and
                sun_bit(@intCast(sx), @as(i32, @intCast(sy)) - 1) and
                sun_bit(@intCast(sx), @as(i32, @intCast(sy)) + 1))
                2
            else
                1;
            sun_mask[sx][sy / 4] |= m << @intCast(2 * (sy % 4));
        }
    }
    // Concept core: 0xFFD878 at the top to 0xFF7A30 at the bottom, 35% toward
    // sun_rgb, then hazed toward the warm band near the horizon.
    for (0..sun_size) |sy| {
        const r: i32 = @intCast(sy / sun_scale);
        var c = lerp_rgb(0xFFD878, 0xFF7A30, r, 23);
        c = lerp_rgb(c, sun_rgb, 35, 100);
        const d = sun_up + sun_size / 2 - @as(i32, @intCast(sy)); // rows above the horizon
        const haze = std_clamp(14 - d, 0, 11); // (14 - d) / 20 up to 0.55
        c = lerp_rgb(c, 0x7A3A2A, haze, 20);
        sun_core[sy] = pixel(c);
        sun_rim_px[sy] = pixel(scale_rgb(c, sun_rim));
    }
}

fn sun_bit(sx: i32, sy: i32) bool {
    if (sx < 0 or sy < 0 or sx >= sun_size or sy >= sun_size) return false;
    const u: u5 = @intCast(@divTrunc(sx, sun_scale));
    const v: usize = @intCast(@divTrunc(sy, sun_scale));
    return iris_rows[v] & (@as(u24, 1) << (23 - u)) != 0;
}

fn init_stars() void {
    var rng: fixed.Rng = .{ .s = star_seed };
    for (0..star_count) |i| {
        star_x[i] = @intCast(rng.next() % sw);
        star_y[i] = @intCast(rng.next() % star_rows);
        star_px[i] = pixel(if (rng.next() & 16 != 0) 0xE0E4FF else 0x7078B0);
    }
}

pub fn draw(frame: u32) void {
    _ = frame;
    const cam = camera.cam;
    if (cam.yaw != dir_yaw) build_dirs(cam.yaw);

    // Per-column horizon shear: cam.roll rows across the whole screen.
    const roll80 = @divTrunc(cam.roll, sw / 2);
    const cx = cam.x;
    const cy = cam.y;
    const alt = cam.alt;
    const h_cam: i32 = world.height[@intCast((cy >> fixed.Q) & (world.DEPTH - 1))][@intCast((cx >> fixed.Q) & (world.W - 1))];

    for (cart.framebuffer, 0..) |*col, x| {
        const hor = cam.horizon + ((roll80 * (@as(i32, @intCast(x)) - sw / 2)) >> fixed.Q);
        const dx = dir_x[x];
        const dy = dir_y[x];
        var occ: i32 = sh;
        var prev_h = h_cam;
        var i: usize = 0;
        while (i < n_steps) : (i += 1) {
            const z = z_tab[i];
            const mx: usize = @intCast(((cx +% fixed.mul(dx, z)) >> fixed.Q) & (world.W - 1));
            const my: usize = @intCast(((cy +% fixed.mul(dy, z)) >> fixed.Q) & (world.DEPTH - 1));
            const h: i32 = world.height[my][mx];
            const row = hor + (fixed.mul(alt - (h << fixed.Q), inv_z[i]) >> fixed.Q);
            if (row < occ) {
                const top = @max(row, 0);
                var c: usize = world.colour[my][mx];
                if (c >= district_base and occ - top > cliff_min and h - prev_h > cliff_dh) c |= 1;
                const px: cart.Pixel = @bitCast(palette.fog[fog_level[i]][c]);
                @memset(col[@intCast(top)..@intCast(occ)], px);
                occ = top;
                if (occ <= 0) break;
            }
            prev_h = h;
        }
        occ_col[x] = @intCast(occ);
        if (occ > 0) {
            const hs = std_clamp(hor, 0, sh - 1);
            const k0: usize = @intCast(128 - hs);
            @memcpy(col[0..@intCast(occ)], sky_rel[k0..][0..@intCast(occ)]);
        }
    }

    // Sun position: yaw 0 is straight ahead; tan(yaw) * px_per_tan columns left.
    const s = sin(cam.yaw);
    const c = cos(cam.yaw);
    const sun_off = if (c > 0) @divTrunc(s * px_per_tan, c) else 10 * sw;
    const sun_cx = sw / 2 - sun_off;

    // Stars (behind the sun), sliding at half the sun's rate.
    const star_shift = @divFloor(sun_cx - sw / 2, 2);
    for (0..star_count) |i| {
        const x = @mod(@as(i32, star_x[i]) + star_shift, sw);
        const hor = cam.horizon + ((roll80 * (x - sw / 2)) >> fixed.Q);
        const y = @as(i32, star_y[i]) + hor - 64;
        if (y >= 0 and y < occ_col[@intCast(x)]) cart.framebuffer[@intCast(x)][@intCast(y)] = star_px[i];
    }

    // The Iris sun, drawn only where the column still shows sky.
    const sun_x0 = sun_cx - sun_size / 2;
    const hor_sun = cam.horizon + ((roll80 * (std_clamp(sun_cx, 0, sw - 1) - sw / 2)) >> fixed.Q);
    const sun_y0 = hor_sun - sun_up - sun_size / 2;
    const sx_lo: usize = @intCast(std_clamp(-sun_x0, 0, sun_size));
    const sx_hi: usize = @intCast(std_clamp(sw - sun_x0, 0, sun_size));
    for (sx_lo..sx_hi) |sx| {
        const x: usize = @intCast(sun_x0 + @as(i32, @intCast(sx)));
        const y_hi = @min(@as(i32, occ_col[x]), sun_y0 + sun_size);
        var y = @max(sun_y0, 0);
        const col = &cart.framebuffer[x];
        const mask = &sun_mask[sx];
        while (y < y_hi) : (y += 1) {
            const sy: usize = @intCast(y - sun_y0);
            switch ((mask[sy / 4] >> @intCast(2 * (sy % 4))) & 3) {
                0 => {},
                1 => col[@intCast(y)] = sun_rim_px[sy],
                else => col[@intCast(y)] = sun_core[sy],
            }
        }
    }
    // TODO(M1): 4x4 Bayer fog dither on (x, frame) choosing the upper or lower
    // fog level per column and step (SPEC 5.3).
}

// --- Colour helpers (init only) ---------------------------------------------

/// 0xRRGGBB -> Pixel, rounded to 5/6/5 bits.
fn pixel(rgb: u32) cart.Pixel {
    return .from_color(.{
        .r = @intCast(((rgb >> 16) * 31 + 127) / 255),
        .g = @intCast((((rgb >> 8) & 0xFF) * 63 + 127) / 255),
        .b = @intCast(((rgb & 0xFF) * 31 + 127) / 255),
    });
}

/// a + (b - a) * num / den per 8-bit channel.
fn lerp_rgb(a: u32, b: u32, num: i32, den: i32) u32 {
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |sh_| {
        const ca: i32 = @intCast((a >> sh_) & 0xFF);
        const cb: i32 = @intCast((b >> sh_) & 0xFF);
        const v = ca + @divTrunc((cb - ca) * num, den);
        out |= @as(u32, @intCast(std_clamp(v, 0, 255))) << sh_;
    }
    return out;
}

/// Each 8-bit channel times k / 256.
fn scale_rgb(a: u32, k: u32) u32 {
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |sh_| out |= ((((a >> sh_) & 0xFF) * k) >> 8) << sh_;
    return out;
}

inline fn std_clamp(v: i32, lo: i32, hi: i32) i32 {
    return @max(lo, @min(v, hi));
}
