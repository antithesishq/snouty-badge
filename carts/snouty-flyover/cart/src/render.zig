//! The column march, sky and sun, cliff shading (SPEC.md 5.1-5.3). All
//! integer: Q16.16 world coordinates, precomputed step, reciprocal, fog-level,
//! sin and direction tables, so wasm, badge-bench and the badge draw the same
//! frame. Fog is dithered between its eight levels with a 4x4 Bayer
//! threshold per column (SPEC 5.3, PLAN.md M1 "Fog dither"). Water (SPEC
//! 5.6, PLAN.md M2 "Reflection algorithm"): pass 1 records the water rows
//! of a column in a 128-bit mask, pass 2 marches the mirrored heights into
//! them, and the rows it leaves get the mirrored sky and Iris sun.
const cart = @import("cart-api");
const fixed = @import("fixed.zig");
const world = @import("world.zig");
const palette = @import("palette.zig");
const camera = @import("camera.zig");

// --- Knobs (SPEC.md 10 lists the cut order) ---------------------------------

/// Far end of the march in Q16 cells (knob, SPEC.md 10): 256 cells, capped
/// at the rows the map ring keeps generated ahead of the camera.
pub const z_far: i32 = @as(i32, @min(256, world.gen_ahead)) << fixed.Q;
/// Water reflection (SPEC 5.6, PLAN M2): false leaves the flat water
/// surface colour (fog[level][water_idx]) and skips pass 2.
pub const reflections = true;
/// Far end of the reflection march (pass 2) in Q16 cells (knob): 200
/// cells as in the concept (which reflects to 200 of its 280); pass 2
/// only, capped at z_far.
const refl_z_far: i32 = @min(200 << fixed.Q, z_far);
/// Ripple of the reflected land, rows per step, indexed (step + frame) & 15
/// (knob: all zeros is a still mirror).
const ripple = [16]i8{ 0, 1, 1, 0, -1, -1, 0, 0, 1, 0, -1, 0, 0, 1, 0, -1 };
/// Ripple the mirrored sun too, by the same table indexed (row + frame) & 15.
const sun_ripple = true;
/// Reflected sky and sun tint (concept `shade`): lerp(water_tint, c, w) *
/// 0.92 with w from refl_graze_lo at the far shore (rows well below the
/// horizon) up to refl_graze_lo + refl_graze_span right at the horizon.
const water_tint: u32 = 0x0C2C66;
const refl_graze_lo: i32 = 115; // 0.45 in 1/256
const refl_graze_span: i32 = 115; // + 0.45 at the horizon
const refl_graze_rows: i32 = 70; // rows below the horizon where the grazing term reaches 0
const refl_dim: u32 = 236; // 0.92 in 1/256
/// Stack overflow flash: sky lerped this far toward white (percent).
const flash_pct: i32 = 70;
/// Debug only (ship false): treat every sample with mx in [96, 160) and
/// (my & 255) >= 40 as water at height world.water, a fake canal to see
/// reflections in districts without water.
const debug_fake_water = false;
/// Boost fog pull-in (PLAN.md M3): a column's fog levels are read this
/// many steps further out, so the fog closes in; camera.zig eases it
/// (0..fog_pull_max).
pub var fog_pull: u8 = 0;
/// Largest fog_pull: fog_level_t rows carry this many padding entries.
pub const fog_pull_max = 32;
/// Frames of white sky left (the Stack overflow flash); draw() decrements it.
pub var sky_flash: u8 = 0;
/// Last frame: columns that ran pass 2 and the pass-2 steps they took
/// (debug; main.zig's debug_water_cols reads water_cols).
pub var water_cols: u32 = 0;
pub var water_steps: u32 = 0;
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
/// cliff_dh 4 shades bus rims (+8), sort bars and heap faces (+6 and up)
/// but not the free-list ridge (+3).
const cliff_min: i32 = 6;
const cliff_dh: i32 = 4;
/// Fog dither mode (knob): true picks a column's threshold by
/// bayer4[x & 3][frame & 3] (temporal, SPEC 5.3), false by
/// bayer4[x & 3][(x >> 2) & 3] (spatial only, no flicker).
const fog_temporal = true;
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

/// Sample distance per step (Q16 cells) and its scaled reciprocal
/// (view_scale * 2^32 / z, so mul(dh, inv_z) >> 16 is rows).
var z_tab: [max_steps]i32 = undefined;
var inv_z: [max_steps]i32 = undefined;
/// Fog level per step for each dither threshold t in 0..15:
/// fog_level_t[t][i] = (fog_q[i] + t) >> 4, fog_q the level in Q4 (0..112);
/// entries from n_steps on repeat the last step's level, so a column can
/// read from fog_pull steps in without a clamp in the march.
var fog_level_t: [16][max_steps + fog_pull_max]u8 = undefined;
/// 4x4 ordered-dither thresholds 0..15.
const bayer4 = [4][4]u8{
    .{ 0, 8, 2, 10 },
    .{ 12, 4, 14, 6 },
    .{ 3, 11, 1, 9 },
    .{ 15, 7, 13, 5 },
};
var n_steps: usize = 0;
/// Steps of the reflection march (z_tab[i] < refl_z_far).
var n_refl: usize = 0;
/// sin of i/1024 turn for i in 0..256 (a quarter wave), Q16.
var sin_q: [257]i32 = undefined;
/// Per-column ray direction (Q16, unnormalised: depth along the heading is z).
var dir_x: [sw]i32 = undefined;
var dir_y: [sw]i32 = undefined;
var dir_yaw: i32 = 0;
/// Sky colour by (row - horizon + 128), Pixel bits; sky_flash_rel is the
/// same lerped flash_pct toward white.
var sky_rel: [256]cart.Pixel = undefined;
var sky_flash_rel: [256]cart.Pixel = undefined;
/// Mirrored, water-tinted sky by (row - horizon + 128) for a water row:
/// entry 128 + d holds the tinted sky of d rows above the horizon (the
/// mirror of a row d below it), so a run of water rows copies forwards.
/// PLAN.md writes the same table as sky_water_rel[(2 hor - r) - hor + 128]
/// with the sky order kept; this stores it mirrored.
var sky_water_rel: [256]cart.Pixel = undefined;
/// Sun mask [column][row / 4], 2 bits per row (bits 2*(row % 4)): 0 none,
/// 1 rim, 2 core; colours per mask row.
var sun_mask: [sun_size][sun_size / 4]u8 = undefined;
var sun_core: [sun_size]cart.Pixel = undefined;
var sun_rim_px: [sun_size]cart.Pixel = undefined;
/// Water-tinted sun colours per mask row (the reflection).
var sun_core_w: [sun_size]cart.Pixel = undefined;
var sun_rim_w: [sun_size]cart.Pixel = undefined;
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
    palette.init();
}

fn init_steps() void {
    var z = z0;
    var dz = dz0;
    var i: usize = 0;
    while (i < max_steps and z < z_far) : (i += 1) {
        z_tab[i] = z;
        // view_scale * 2^32 / z, as (view_scale << 24) / (z >> 8).
        inv_z[i] = @divTrunc(view_scale << 24, z >> 8);
        const q = level_for(z);
        for (&fog_level_t, 0..) |*tab, t| tab[i] = @intCast((q + @as(u32, @intCast(t))) >> 4);
        if (z < refl_z_far) n_refl = i + 1;
        z += dz;
        dz = fixed.mul(dz, lod_mul);
    }
    n_steps = i;
    for (&fog_level_t) |*tab| @memset(tab[n_steps..], tab[n_steps - 1]);
}

/// Fog level of a sample at distance z (Q16 cells) in Q4 (0..112): 0 before
/// fog_near, then f = (z - near) / (far - near) on the concept's f^1.4 curve
/// (approximated as 0.6 f + 0.4 f^2) times 7 levels; the dither rounds it.
fn level_for(z: i32) u32 {
    const zc8 = z >> 8; // Q8 cells
    const near8 = fog_near << 8;
    if (zc8 <= near8) return 0;
    const span8 = (z_far >> 8) - near8;
    const f = @min(@divTrunc((zc8 - near8) * 256, span8), 256); // Q8
    const g = (154 * f + @divTrunc(102 * f * f, 256)) >> 8; // Q8
    const top = (palette.fog_levels - 1) * 16;
    return @intCast(@min((g * top) >> 8, top));
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

/// Sky gradient colour d rows above the horizon (fog colour below it).
fn sky_rgb(d: i32) u32 {
    if (d <= sky_stops[0].d) return sky_stops[0].rgb;
    for (sky_stops[0 .. sky_stops.len - 1], sky_stops[1..]) |a, b| {
        if (d <= b.d) return lerp_rgb(a.rgb, b.rgb, d - a.d, b.d - a.d);
    }
    return sky_stops[sky_stops.len - 1].rgb;
}

/// A colour seen in the water d rows from the horizon (concept `shade`):
/// toward the water tint, less so at grazing angles, then dimmed.
fn water_rgb(rgb: u32, d: i32) u32 {
    const g = std_clamp(refl_graze_rows - d, 0, refl_graze_rows);
    const w = refl_graze_lo + @divTrunc(refl_graze_span * g, refl_graze_rows);
    return scale_rgb(lerp_rgb(water_tint, rgb, w, 256), refl_dim);
}

fn init_sky() void {
    for (0..256) |k| {
        const d = 128 - @as(i32, @intCast(k)); // rows above the horizon
        const rgb = sky_rgb(d);
        sky_rel[k] = pixel(rgb);
        sky_flash_rel[k] = pixel(lerp_rgb(rgb, 0xFFFFFF, flash_pct, 100));
        const dm = @max(@as(i32, @intCast(k)) - 128, 0); // water row dm below the horizon
        sky_water_rel[k] = pixel(water_rgb(sky_rgb(dm), dm));
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
        const dw = @max(d, 0); // the mirrored row is d rows below the horizon
        sun_core_w[sy] = pixel(water_rgb(c, dw));
        sun_rim_w[sy] = pixel(water_rgb(scale_rgb(c, sun_rim), dw));
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
    const ft: usize = frame & 3;
    const cam = camera.cam;
    if (cam.yaw != dir_yaw) build_dirs(cam.yaw);

    // Per-column horizon shear: cam.roll rows across the whole screen.
    const roll80 = @divTrunc(cam.roll, sw / 2);
    const cx = cam.x;
    // The march only needs the row modulo the ring depth, and it already
    // wraps with +%: the low 32 bits of the i64 Q16 y are enough.
    const cy: i32 = @truncate(cam.y);
    const alt = cam.alt;
    const h_cam: i32 = world.height[@intCast((cy >> fixed.Q) & (world.DEPTH - 1))][@intCast((cx >> fixed.Q) & (world.W - 1))];
    const sky = if (sky_flash != 0) &sky_flash_rel else &sky_rel;
    const pull: usize = @min(fog_pull, fog_pull_max);
    // Mirrored land height offset: a land sample at h projects as 2 water - h.
    const alt_m = alt - ((2 * @as(i32, world.water)) << fixed.Q);
    const alt_w = alt - (@as(i32, world.water) << fixed.Q);

    // Sun position: yaw 0 is straight ahead; tan(yaw) * px_per_tan columns left.
    const yaw_s = sin(cam.yaw);
    const yaw_c = cos(cam.yaw);
    const sun_off = if (yaw_c > 0) @divTrunc(yaw_s * px_per_tan, yaw_c) else 10 * sw;
    const sun_cx = sw / 2 - sun_off;
    const sun_x0 = sun_cx - sun_size / 2;
    const hor_sun = cam.horizon + ((roll80 * (std_clamp(sun_cx, 0, sw - 1) - sw / 2)) >> fixed.Q);
    const sun_y0 = hor_sun - sun_up - sun_size / 2;

    water_cols = 0;
    water_steps = 0;
    for (cart.framebuffer, 0..) |*col, x| {
        const hor = cam.horizon + ((roll80 * (@as(i32, @intCast(x)) - sw / 2)) >> fixed.Q);
        const dx = dir_x[x];
        const dy = dir_y[x];
        const t = if (fog_temporal) bayer4[x & 3][ft] else bayer4[x & 3][(x >> 2) & 3];
        const fog_level: [*]const u8 = fog_level_t[t][pull..].ptr;
        var occ: i32 = sh;
        var prev_h = h_cam;
        // Water rows of this column (bit r of wmask[r >> 5]) and the first
        // water step.
        var wmask = [4]u32{ 0, 0, 0, 0 };
        var w_first: usize = max_steps;
        var i: usize = 0;
        while (i < n_steps) : (i += 1) {
            const z = z_tab[i];
            const mx: usize = @intCast(((cx +% fixed.mul(dx, z)) >> fixed.Q) & (world.W - 1));
            const my: usize = @intCast(((cy +% fixed.mul(dy, z)) >> fixed.Q) & (world.DEPTH - 1));
            const h: i32 = if (debug_fake_water and fake_water(mx, my)) world.water else world.height[my][mx];
            const row = hor + (fixed.mul(alt - (h << fixed.Q), inv_z[i]) >> fixed.Q);
            if (row < occ) {
                const top = @max(row, 0);
                var c: usize = world.colour[my][mx];
                if (h == world.water) {
                    c = palette.water_idx;
                    mask_set(&wmask, top, occ);
                    if (w_first == max_steps) w_first = i;
                } else if (c >= district_base and occ - top > cliff_min and h - prev_h > cliff_dh) c |= 1;
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
            @memcpy(col[0..@intCast(occ)], sky[k0..][0..@intCast(occ)]);
        }
        if (!reflections or w_first == max_steps) continue;

        // Pass 2: the mirrored march from the first water step into the
        // water rows still free. A land sample at step j holds the water
        // rows whose mirrored ray is inside its mirrored column at z_j:
        // below the plane row (the ray has left the water, row >= row_w)
        // and above the mirrored tip (row <= row_m). Free rows are kept in
        // wfree, bounded by [lo_f, hi_f).
        var wfree = wmask;
        var lo_f = mask_lo(&wfree);
        var hi_f = mask_hi(&wfree);
        var j = w_first;
        while (j < n_refl) : (j += 1) {
            const z = z_tab[j];
            const mx: usize = @intCast(((cx +% fixed.mul(dx, z)) >> fixed.Q) & (world.W - 1));
            const my: usize = @intCast(((cy +% fixed.mul(dy, z)) >> fixed.Q) & (world.DEPTH - 1));
            const h: i32 = if (debug_fake_water and fake_water(mx, my)) world.water else world.height[my][mx];
            if (h == world.water) continue; // a hole to the mirrored sky
            const row_m = hor + (fixed.mul(alt_m + (h << fixed.Q), inv_z[j]) >> fixed.Q) + ripple[(j + frame) & 15];
            if (row_m < lo_f) continue;
            const row_w = hor + (fixed.mul(alt_w, inv_z[j]) >> fixed.Q);
            const a = @max(row_w, lo_f);
            const b = @min(row_m + 1, hi_f);
            if (a >= b) continue;
            const px: cart.Pixel = @bitCast(palette.fog_w[fog_level[j]][world.colour[my][mx]]);
            var runs: Runs = .{ .m = &wfree, .r = @intCast(a), .hi = @intCast(b) };
            while (runs.next()) |run| @memset(col[run[0]..run[1]], px);
            mask_clear(&wfree, a, b);
            lo_f = mask_lo(&wfree);
            hi_f = mask_hi(&wfree);
            if (lo_f >= hi_f) break;
        }
        water_cols += 1;
        water_steps += @intCast(j - w_first);

        // The water rows pass 2 left: mirrored sky, and the mirrored sun
        // where the column is under it (mirror line: this column's horizon).
        if (lo_f >= hi_f) continue;
        const sx_i = @as(i32, @intCast(x)) - sun_x0;
        const under_sun = sx_i >= 0 and sx_i < sun_size;
        var runs: Runs = .{ .m = &wfree, .r = @intCast(lo_f), .hi = @intCast(hi_f) };
        while (runs.next()) |run| {
            const a: i32 = @intCast(run[0]);
            const b: i32 = @intCast(run[1]);
            const k_lo = a - hor + 128;
            if (k_lo >= 0 and b - hor + 128 <= 256) {
                @memcpy(col[run[0]..run[1]], sky_water_rel[@intCast(k_lo)..][0 .. run[1] - run[0]]);
            } else {
                for (run[0]..run[1]) |r| col[r] = sky_water_rel[@intCast(std_clamp(@as(i32, @intCast(r)) - hor + 128, 0, 255))];
            }
            if (!under_sun) continue;
            const sx: usize = @intCast(sx_i);
            const mask = &sun_mask[sx];
            // Mirrored row 2 hor - r lies in the sun for r in (2 hor - sun_y0 - sun_size, 2 hor - sun_y0].
            const r_lo = @max(a, 2 * hor - sun_y0 - sun_size - 1);
            const r_hi = @min(b, 2 * hor - sun_y0 + 2);
            var r = r_lo;
            while (r < r_hi) : (r += 1) {
                const wob: i32 = if (sun_ripple) ripple[(@as(usize, @intCast(r)) +% frame) & 15] else 0;
                const sy_i = 2 * hor - r + wob - sun_y0;
                if (sy_i < 0 or sy_i >= sun_size) continue;
                const sy: usize = @intCast(sy_i);
                switch ((mask[sy / 4] >> @intCast(2 * (sy % 4))) & 3) {
                    0 => {},
                    1 => col[@intCast(r)] = sun_rim_w[sy],
                    else => col[@intCast(r)] = sun_core_w[sy],
                }
            }
        }
    }
    if (sky_flash != 0) sky_flash -= 1;

    // Stars (behind the sun), sliding at half the sun's rate.
    const star_shift = @divFloor(sun_cx - sw / 2, 2);
    for (0..star_count) |i| {
        const x = @mod(@as(i32, star_x[i]) + star_shift, sw);
        const hor = cam.horizon + ((roll80 * (x - sw / 2)) >> fixed.Q);
        const y = @as(i32, star_y[i]) + hor - 64;
        if (y >= 0 and y < occ_col[@intCast(x)]) cart.framebuffer[@intCast(x)][@intCast(y)] = star_px[i];
    }

    // The Iris sun, drawn only where the column still shows sky.
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
}

/// The debug_fake_water canal.
inline fn fake_water(mx: usize, my: usize) bool {
    return mx >= 96 and mx < 160 and (my & 255) >= 40;
}

/// Set rows [lo, hi) (0 <= lo <= hi <= 128) in a column's water mask.
inline fn mask_set(m: *[4]u32, lo: i32, hi: i32) void {
    var r: u32 = @intCast(lo);
    const e: u32 = @intCast(hi);
    while (r < e) {
        const b: u5 = @truncate(r);
        const n = @min(e - r, 32 - @as(u32, b));
        const ones: u32 = if (n == 32) 0xFFFF_FFFF else (@as(u32, 1) << @intCast(n)) - 1;
        m[r >> 5] |= ones << b;
        r += n;
    }
}

/// Clear rows [lo, hi) (0 <= lo <= hi <= 128) in a column's water mask.
inline fn mask_clear(m: *[4]u32, lo: i32, hi: i32) void {
    var r: u32 = @intCast(lo);
    const e: u32 = @intCast(hi);
    while (r < e) {
        const b: u5 = @truncate(r);
        const n = @min(e - r, 32 - @as(u32, b));
        const ones: u32 = if (n == 32) 0xFFFF_FFFF else (@as(u32, 1) << @intCast(n)) - 1;
        m[r >> 5] &= ~(ones << b);
        r += n;
    }
}

/// First set row of a water mask (128 if none).
inline fn mask_lo(m: *const [4]u32) i32 {
    for (m, 0..) |w, k| if (w != 0) return @intCast(32 * k + @ctz(w));
    return sh;
}

/// Last set row + 1 of a water mask (0 if none).
inline fn mask_hi(m: *const [4]u32) i32 {
    var k: usize = 4;
    while (k > 0) {
        k -= 1;
        if (m[k] != 0) return @intCast(32 * k + 32 - @clz(m[k]));
    }
    return 0;
}

/// The runs [a, b) of set rows of a water mask inside [r, hi).
const Runs = struct {
    m: *const [4]u32,
    r: u32,
    hi: u32,

    fn next(self: *Runs) ?[2]u32 {
        while (self.r < self.hi) {
            var bits = self.m[self.r >> 5] >> @as(u5, @truncate(self.r));
            if (bits == 0) {
                self.r = (self.r | 31) + 1;
                continue;
            }
            const skip: u5 = @intCast(@ctz(bits));
            bits >>= skip;
            const a = self.r + skip;
            if (a >= self.hi) break;
            // bits has zeros shifted in at the top, so a run stops at the word end.
            const b = @min(a + @ctz(~bits), self.hi);
            self.r = b;
            return .{ a, b };
        }
        self.r = self.hi;
        return null;
    }
};

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
