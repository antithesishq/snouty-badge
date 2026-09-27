//! One ray through the grid (Lode Vandevenne's DDA) with Wolf3D-style thin
//! sliding doors. Pure geometry: no framebuffer access.
const std = @import("std");
const state = @import("../state.zig");
const levels = @import("../levels.zig");
const Level = levels.Level;
const textures = @import("textures.zig");

/// Beyond this perpendicular distance (cells) a ray gives up: fog.
pub const range: f32 = 24.0;

pub const Hit = struct {
    /// Perpendicular (camera-plane) distance in cells. `range` for fog.
    dist: f32,
    /// Index into `textures.tex`.
    tex: u8,
    /// Texture column 0..31.
    tx: u5,
    /// 0 = x face (lit), 1 = y face (dark). Unused for fog.
    side: u1,
    fog: bool,
};

const fog_hit: Hit = .{ .dist = range, .tex = 0, .tx = 0, .side = 0, .fog = true };

/// Casts from (px, py) along (rdx, rdy). The ray direction is not
/// normalised: it is `dir + plane * camera_x` with a unit `dir`, so the ray
/// parameter `t` at a hit is the perpendicular distance directly.
pub fn cast(s: *const state.GameState, level: *const Level, px: f32, py: f32, rdx: f32, rdy: f32) Hit {
    var mx: i32 = @intFromFloat(@floor(px));
    var my: i32 = @intFromFloat(@floor(py));
    const big: f32 = 1e30;
    const ddx: f32 = if (rdx == 0) big else @abs(1.0 / rdx);
    const ddy: f32 = if (rdy == 0) big else @abs(1.0 / rdy);
    const step_x: i32 = if (rdx < 0) -1 else 1;
    const step_y: i32 = if (rdy < 0) -1 else 1;
    const fmx: f32 = @floatFromInt(mx);
    const fmy: f32 = @floatFromInt(my);
    var sdx: f32 = if (rdx < 0) (px - fmx) * ddx else (fmx + 1.0 - px) * ddx;
    var sdy: f32 = if (rdy < 0) (py - fmy) * ddy else (fmy + 1.0 - py) * ddy;

    // Standing inside a door cell: its panel may still be ahead.
    {
        const c = level.cell(mx, my);
        if (Level.is_door(c)) {
            if (door_hit(s, level, c, mx, my, px, py, rdx, rdy)) |h| return h;
        }
    }

    while (true) {
        var t: f32 = undefined;
        var side: u1 = undefined;
        if (sdx < sdy) {
            t = sdx;
            sdx += ddx;
            mx += step_x;
            side = 0;
        } else {
            t = sdy;
            sdy += ddy;
            my += step_y;
            side = 1;
        }
        if (t > range) return fog_hit;
        const c = level.cell(mx, my);
        if (c == 0) continue;
        if (Level.is_door(c)) {
            if (door_hit(s, level, c, mx, my, px, py, rdx, rdy)) |h| return h;
            continue;
        }
        // Wall (1..63), or a reserved value treated as wall.
        var u: f32 = undefined;
        if (side == 0) {
            const hy = py + t * rdy;
            u = hy - @floor(hy);
            if (rdx < 0) u = 1.0 - u;
        } else {
            const hx = px + t * rdx;
            u = hx - @floor(hx);
            if (rdy > 0) u = 1.0 - u;
        }
        const id: u8 = if (c >= 1 and c <= textures.wall_count) c - 1 else (c -% 1) % textures.wall_count;
        return .{ .dist = t, .tex = id, .tx = tex_col(u), .side = side, .fog = false };
    }
}

/// Tests the door panel of cell (mx, my). The panel lies on the cell's
/// midline (x + 0.5 when vertical, y + 0.5 otherwise) and is slid by
/// open/255 cells toward +y (vertical) or +x (horizontal); the ray passes
/// through the part of the midline the panel has vacated.
fn door_hit(s: *const state.GameState, level: *const Level, c: u8, mx: i32, my: i32, px: f32, py: f32, rdx: f32, rdy: f32) ?Hit {
    const i = Level.door_index(c);
    if (i >= level.doors.len) return null;
    const def = level.doors[i];
    const open: f32 = @as(f32, @floatFromInt(s.doors[i].open)) * (1.0 / 255.0);
    const fmx: f32 = @floatFromInt(mx);
    const fmy: f32 = @floatFromInt(my);
    var t: f32 = undefined;
    var f: f32 = undefined;
    if (def.vertical) {
        if (rdx == 0) return null;
        t = (fmx + 0.5 - px) / rdx;
        f = py + t * rdy - fmy;
    } else {
        if (rdy == 0) return null;
        t = (fmy + 0.5 - py) / rdy;
        f = px + t * rdx - fmx;
    }
    if (t <= 0 or f < open or f >= 1.0) return null;
    if (t > range) return fog_hit;
    return .{
        .dist = t,
        .tex = textures.door_tex_base + @backingInt(def.kind),
        .tx = tex_col(f - open),
        .side = if (def.vertical) 0 else 1,
        .fog = false,
    };
}

inline fn tex_col(u: f32) u5 {
    const v: i32 = @intFromFloat(u * @as(f32, textures.tex_size));
    return @intCast(std.math.clamp(v, 0, textures.tex_size - 1));
}
