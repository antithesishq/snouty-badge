//! Forked from snouty-zero/cart/src/render.zig at f8f6962.
//! The Mode 7 floor (Zero SPEC 6.2), the horizon strip (6.4) and the fog
//! banks. Rendering reads the camera and the track and never writes game
//! state. The art (tiles, palette, horizon) comes from the track's league
//! at `set_track` through runtime slices, so a track pack in a RAM buffer
//! (SPEC 19) can plug in; the floor loop is the row loop Zero's M0 chose.
const cart = @import("cart-api");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const track = @import("track.zig");
const camera = @import("camera.zig");
const hills = @import("hills.zig");

pub const horizon_y: i32 = tuning.horizon_y;
/// First floor row.
pub const floor_y0: usize = @intCast(horizon_y + 1);
pub const screen_w: i32 = @intCast(cart.screen_width);
pub const screen_h: i32 = @intCast(cart.screen_height);

/// Fog banks: palette k blended k/4 toward the league fog colour (palette 0).
var fog: [4][256]cart.Pixel = undefined;
/// Per row: which fog bank (pointer), the row distance z and the lateral
/// scale (world px per screen px), both Q16.16. Rebuilt when the camera
/// height changes.
var row_fog: [128]*const [256]cart.Pixel = undefined;
var row_z: [128]i32 = undefined;
var row_scale: [128]i32 = undefined;
var rows_height: i32 = -1;

/// Per-frame row tables: start point and per-pixel step in world space.
var row_x0: [128]i32 = undefined;
var row_y0: [128]i32 = undefined;
var row_dx: [128]i32 = undefined;
var row_dy: [128]i32 = undefined;

/// Horizon strip palettes as pixels.
var front_pal: [16]cart.Pixel = undefined;
var back_pal: [16]cart.Pixel = undefined;
var fog_pixel: cart.Pixel = undefined;

var league: *const track.League = &track.dumps;

/// What the floor loop and the horizon strip read: the active league's
/// art, set by `set_track` (the RAM cart's art is in RAM already).
var tiles_art: [*]const u8 = track.dumps.tiles.ptr;
var horizon_art: [*]const u8 = track.dumps.horizon.ptr;

/// Shake ticks left (rail hits, SPEC 6.2): the horizon row and the floor
/// jitter by one pixel on alternate ticks. Set by main from the player's shake.
pub var shake: u32 = 0;
/// Frame counter for the LED blink and the shake parity (set by main).
pub var frame: u32 = 0;
/// Hills on: the row tables come from the forward march every frame.
pub var hills_on: bool = false;
/// BIT FLIP on the followed car (M2, SPEC 10): every floor row slides 0 or
/// 1 px sideways, a pattern that changes every frame. Set by main.
pub var row_jitter: bool = false;
/// Front palette entry 15 as drawn (`led_on`), swapped with entry 14 every 8 ticks (SPEC 6.4).
var led_on: cart.Pixel = undefined;
var led_off: cart.Pixel = undefined;

/// Select the track (and its league art): builds the fog banks and the
/// horizon palettes. Call at race start.
/// RGB565 as the generator writes it (r in the high bits) to DisplayColor
/// (a packed struct whose first field, r, is the LOW bits): a plain bitcast
/// swaps red and blue, which is what every frame up to M4 showed.
fn color565(v: u16) cart.DisplayColor {
    return .{ .r = @intCast((v >> 11) & 31), .g = @intCast((v >> 5) & 63), .b = @intCast(v & 31) };
}

pub fn set_track(t: *const track.Track) void {
    league = t.league;
    tiles_art = league.tiles.ptr;
    horizon_art = league.horizon.ptr;
    const fog_c: cart.DisplayColor = color565(league.pal_rgb565(0));
    fog_pixel = .from_color(fog_c);
    for (0..256) |i| {
        const c: cart.DisplayColor = color565(league.pal_rgb565(i));
        for (0..4) |k| {
            const kk: i32 = @intCast(k);
            fog[k][i] = .from_color(.{
                .r = @intCast(@as(i32, c.r) + @divTrunc((@as(i32, fog_c.r) - @as(i32, c.r)) * kk, 4)),
                .g = @intCast(@as(i32, c.g) + @divTrunc((@as(i32, fog_c.g) - @as(i32, c.g)) * kk, 4)),
                .b = @intCast(@as(i32, c.b) + @divTrunc((@as(i32, fog_c.b) - @as(i32, c.b)) * kk, 4)),
            });
        }
    }
    for (0..16) |i| {
        front_pal[i] = .from_color(color565(league.horizon_front_pal(i)));
        back_pal[i] = .from_color(color565(league.horizon_back_pal(i)));
    }
    led_on = front_pal[15];
    led_off = front_pal[14];
    rows_height = -1;
}

/// Current one-pixel jitter (0 or 1) from the shake.
fn jitter() i32 {
    return if (shake > 0 and (frame & 1) == 1) 1 else 0;
}

fn bank_of(zi: i32) usize {
    return if (zi >= tuning.fog_z[2]) 3 else if (zi >= tuning.fog_z[1]) 2 else if (zi >= tuning.fog_z[0]) 1 else 0;
}

/// Hills (SPEC 15): march forward over the height profile and project each
/// step; a screen row takes the nearest z whose projection reaches it
/// (rows hidden behind a crest keep the crest). Rows the march never
/// reaches (a dip ahead) get the far distance.
fn build_rows_hills(height: i32) void {
    rows_height = -1; // always rebuilt
    const far: i32 = (height * tuning.focal) << fixed.Q;
    for (floor_y0..128) |y| row_z[y] = far;
    var z: i32 = @divTrunc(height * tuning.focal, 95); // the bottom row's flat distance
    var y_min: i32 = 128; // lowest projected row reached so far (rows above are still open)
    var steps: u32 = 0;
    while (z < 8192 and steps < 240) : (steps += 1) {
        const h = hills.height_ahead(z, tuning.cam_behind);
        const dy = @divTrunc((height - h) * tuning.focal, z);
        const y = horizon_y + @max(dy, 1);
        if (y < y_min) {
            // Fill every open row from y_min - 1 down to y with this z.
            var r = y_min - 1;
            while (r >= y and r >= @as(i32, @intCast(floor_y0))) : (r -= 1) row_z[@intCast(r)] = z * fixed.one;
            y_min = y;
            if (y_min <= @as(i32, @intCast(floor_y0))) break;
        }
        z += @max(1, z >> 4);
    }
    for (floor_y0..128) |y| {
        const zq = row_z[y];
        row_scale[y] = @divTrunc(zq, tuning.focal);
        row_fog[y] = &fog[bank_of(zq >> fixed.Q)];
    }
}

/// Row distance and scale tables for a camera height (SPEC 6.2): z(y) =
/// height * focal / (y - horizon), scale(y) = height / (y - horizon).
fn build_rows(height: i32) void {
    rows_height = height;
    for (floor_y0..128) |y| {
        const dy: i32 = @as(i32, @intCast(y)) - horizon_y;
        const z = fixed.div(height * tuning.focal, dy);
        row_z[y] = z;
        row_scale[y] = fixed.div(height, dy);
        const zi = z >> fixed.Q;
        const bank: usize = if (zi >= tuning.fog_z[2]) 3 else if (zi >= tuning.fog_z[1]) 2 else if (zi >= tuning.fog_z[0]) 1 else 0;
        row_fog[y] = &fog[bank];
    }
}

/// Distance of floor row y, world px (Q16.16); for sprite scaling.
pub fn z_of_row(y: usize) i32 {
    return row_z[y];
}
pub fn scale_of_row(y: usize) i32 {
    return row_scale[y];
}

/// Whole frame: horizon strip, horizon row, floor.
pub fn draw() void {
    const cam = camera.cam;
    if (hills_on and hills.any) build_rows_hills(cam.height) else if (cam.height != rows_height) build_rows(cam.height);
    front_pal[15] = if ((frame / 8) % 2 == 0) led_on else led_off;
    draw_horizon(cam.yaw);
    draw_floor(cam);
}

/// Two-layer parallax strip over rows 0..31, the fog colour on row 32.
fn draw_horizon(yaw: fixed.Turn) void {
    const front = horizon_art;
    const back = horizon_art + 512 * 32 / 2;
    const scroll_f: u32 = @as(u32, yaw) >> 7; // 512 px per turn
    const scroll_b: u32 = @as(u32, yaw) >> 8; // 256 px per turn, half rate
    const j: usize = @intCast(jitter());
    for (0..@intCast(screen_w)) |x| {
        const col = &cart.framebuffer[x];
        const sxf: usize = @intCast((@as(u32, @intCast(x)) + scroll_f) & 511);
        const sxb: usize = @intCast((@as(u32, @intCast(x)) + scroll_b) & 255);
        const shf: u3 = if (sxf & 1 == 1) 4 else 0;
        const shb: u3 = if (sxb & 1 == 1) 4 else 0;
        // With the shake the strip's row y+j lands on screen row y.
        for (0..32) |y| {
            const sy: usize = @min(y + j, 31);
            const f: u8 = (front[sy * 256 + (sxf >> 1)] >> shf) & 15;
            if (f != 0) {
                col[y] = front_pal[f];
            } else {
                col[y] = back_pal[(back[sy * 128 + (sxb >> 1)] >> shb) & 15];
            }
        }
        col[@intCast(horizon_y)] = fog_pixel;
    }
}

/// Row tables for this frame, then the row loop.
fn draw_floor(cam: camera.Cam) void {
    const c = fixed.cos(cam.yaw);
    const s = fixed.sin(cam.yaw);
    const half_w: i32 = screen_w / 2;
    // Shake: the whole floor slides one screen pixel sideways on alternate ticks.
    const jit: i32 = jitter();
    for (floor_y0..128) |y| {
        const z = row_z[y];
        const sc = row_scale[y];
        // forward * z, right * scale (right = (-sin, cos))
        const fx = fixed.mul(c, z);
        const fy = fixed.mul(s, z);
        const rx = fixed.mul(-s, sc);
        const ry = fixed.mul(c, sc);
        const rj: i32 = if (row_jitter) @intCast(((y *% 0x45 +% frame *% 0x1D) >> 3) & 1) else 0;
        row_x0[y] = cam.x +% fx -% rx * (half_w + jit + rj);
        row_y0[y] = cam.y +% fy -% ry * (half_w + jit + rj);
        row_dx[y] = rx;
        row_dy[y] = ry;
    }
    floor_rows();
}

/// Row loop: incremental adds along each screen row, writes at a 256-byte
/// stride (Zero's M0 measured it 16% cheaper than the column loop).
fn floor_rows() void {
    const map = &track.map_ram;
    const tiles = tiles_art;
    var y: usize = floor_y0;
    while (y < 128) : (y += 1) {
        var wx: u32 = @bitCast(row_x0[y]);
        var wy: u32 = @bitCast(row_y0[y]);
        const dx: u32 = @bitCast(row_dx[y]);
        const dy: u32 = @bitCast(row_dy[y]);
        const pal = row_fog[y];
        var x: usize = 0;
        while (x < @as(usize, @intCast(screen_w))) : (x += 1) {
            const t: usize = map[((wy >> 19) & 127) << 7 | ((wx >> 19) & 127)];
            const idx: usize = tiles[t << 6 | ((wy >> 16) & 7) << 3 | ((wx >> 16) & 7)];
            cart.framebuffer[x][y] = pal[idx];
            wx +%= dx;
            wy +%= dy;
        }
    }
}

/// World point under screen pixel (x, y) on the floor, Q16.16 (for tests
/// and the sprite placement check). Valid after draw().
pub fn floor_world(x: i32, y: usize) struct { x: i32, y: i32 } {
    return .{ .x = row_x0[y] +% x *% row_dx[y], .y = row_y0[y] +% x *% row_dy[y] };
}
