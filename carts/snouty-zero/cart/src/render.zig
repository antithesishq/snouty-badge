//! The Mode 7 floor (SPEC 6.2), the horizon strip (6.4) and the fog banks.
//! Rendering reads the camera and the track and never writes game state.
const cart = @import("cart-api");
const build_options = @import("build_options");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const track = @import("track.zig");
const camera = @import("camera.zig");

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

var league: *const track.League = &track.edge;
var current: *const track.Track = &track.cold_aisle;

/// Select the track (and its league art): builds the fog banks and the
/// horizon palettes. Call at race start.
pub fn set_track(t: *const track.Track) void {
    current = t;
    league = t.league;
    const fog_c: cart.DisplayColor = @bitCast(league.pal_rgb565(0));
    fog_pixel = .from_color(fog_c);
    for (0..256) |i| {
        const c: cart.DisplayColor = @bitCast(league.pal_rgb565(i));
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
        front_pal[i] = .from_color(@bitCast(league.horizon_front_pal(i)));
        back_pal[i] = .from_color(@bitCast(league.horizon_back_pal(i)));
    }
    rows_height = -1;
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

/// Distance of floor row y, world px (Q16.16); for sprite scaling (M1).
pub fn z_of_row(y: usize) i32 {
    return row_z[y];
}
pub fn scale_of_row(y: usize) i32 {
    return row_scale[y];
}

/// Whole frame: horizon strip, horizon row, floor.
pub fn draw() void {
    const cam = camera.cam;
    if (cam.height != rows_height) build_rows(cam.height);
    draw_horizon(cam.yaw);
    draw_floor(cam);
}

/// Two-layer parallax strip over rows 0..31, the fog colour on row 32.
fn draw_horizon(yaw: fixed.Turn) void {
    const front = league.horizon_front();
    const back = league.horizon_back();
    const scroll_f: u32 = @as(u32, yaw) >> 7; // 512 px per turn
    const scroll_b: u32 = @as(u32, yaw) >> 8; // 256 px per turn, half rate
    for (0..@intCast(screen_w)) |x| {
        const col = &cart.framebuffer[x];
        const sxf: usize = @intCast((@as(u32, @intCast(x)) + scroll_f) & 511);
        const sxb: usize = @intCast((@as(u32, @intCast(x)) + scroll_b) & 255);
        const shf: u3 = if (sxf & 1 == 1) 4 else 0;
        const shb: u3 = if (sxb & 1 == 1) 4 else 0;
        for (0..32) |y| {
            const f: u8 = (front[y * 256 + (sxf >> 1)] >> shf) & 15;
            if (f != 0) {
                col[y] = front_pal[f];
            } else {
                col[y] = back_pal[(back[y * 128 + (sxb >> 1)] >> shb) & 15];
            }
        }
        col[@intCast(horizon_y)] = fog_pixel;
    }
}

/// Row tables for this frame, then the inner loop chosen by -Dzero_floor.
fn draw_floor(cam: camera.Cam) void {
    const c = fixed.cos(cam.yaw);
    const s = fixed.sin(cam.yaw);
    const half_w: i32 = screen_w / 2;
    for (floor_y0..128) |y| {
        const z = row_z[y];
        const sc = row_scale[y];
        // forward * z, right * scale (right = (-sin, cos))
        const fx = fixed.mul(c, z);
        const fy = fixed.mul(s, z);
        const rx = fixed.mul(-s, sc);
        const ry = fixed.mul(c, sc);
        row_x0[y] = cam.x +% fx -% rx * half_w;
        row_y0[y] = cam.y +% fy -% ry * half_w;
        row_dx[y] = rx;
        row_dy[y] = ry;
    }
    switch (build_options.floor_loop) {
        .column => floor_columns(),
        .row => floor_rows(),
    }
}

/// Column loop: for each screen column, walk down the floor rows writing
/// sequential halfwords; two multiply-accumulates per pixel.
fn floor_columns() void {
    const map = current.map;
    const tiles = league.tiles;
    var x: usize = 0;
    while (x < @as(usize, @intCast(screen_w))) : (x += 1) {
        const col = &cart.framebuffer[x];
        const xi: i32 = @intCast(x);
        var y: usize = floor_y0;
        while (y < 128) : (y += 1) {
            const wx: u32 = @bitCast(row_x0[y] +% xi *% row_dx[y]);
            const wy: u32 = @bitCast(row_y0[y] +% xi *% row_dy[y]);
            const t: usize = map[((wy >> 19) & 127) << 7 | ((wx >> 19) & 127)];
            const idx: usize = tiles[t << 6 | ((wy >> 16) & 7) << 3 | ((wx >> 16) & 7)];
            col[y] = row_fog[y][idx];
        }
    }
}

/// Row loop: incremental adds along each screen row, writes at a 256-byte
/// stride (SPEC 18 comparison).
fn floor_rows() void {
    const map = current.map;
    const tiles = league.tiles;
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
