//! The 3D view (y 0..103): per column, ceiling fill, one textured wall or
//! door slice, floor fill (SPEC.md section 5, PLAN.md M1 track A).
//! Geometry lives in raycast.zig, texels and palettes in textures.zig,
//! the ceiling/floor tables in floor.zig.
const std = @import("std");
const cart = @import("cart-api");
const state = @import("../state.zig");
const levels = @import("../levels.zig");
const fixed = @import("../fixed.zig");
const raycast = @import("raycast.zig");
const floor = @import("floor.zig");
const textures = @import("textures.zig");

pub const view_h: u32 = 104;
pub const view_w: u32 = cart.screen_width;

/// Perpendicular wall distance per column (cells), for sprite clipping.
pub var depth: [view_w]f32 = @splat(raycast.range);

/// When set, every slice this frame uses that palette set (0..5):
/// 4 = rewind (Iris tint), 5 = hurt (red tint).
pub var shade_override: ?u8 = null;

const fov_deg = 66.0;

/// Camera-plane offset per column: tan(fov/2) * (2 (x + 0.5) / w - 1).
const cam_x: [view_w]f32 = blk: {
    var t: [view_w]f32 = undefined;
    const k = @tan(fov_deg * 0.5 * std.math.pi / 180.0);
    for (&t, 0..) |*v, x| {
        const fx: comptime_float = @floatFromInt(x);
        v.* = @floatCast(k * ((2.0 * fx + 1.0) / @as(comptime_float, view_w) - 1.0));
    }
    break :blk t;
};

/// Unit view direction from the shared 1,024-entry fixed sin table
/// (fixed.zig, the one the sim moves with), linearly interpolated between
/// entries so turning is smooth. Avoids libm sinf/cosf, which pull in
/// soft-f64 code on the single-precision M33 FPU.
fn direction(angle: fixed.Angle) struct { f32, f32 } {
    const step: fixed.Angle = 64; // 65,536 / 1,024
    const base = angle & ~(step - 1);
    const w: f32 = @as(f32, @floatFromInt(angle & (step - 1))) * (1.0 / 64.0);
    const c0 = fixed.to_f32(fixed.cos(base));
    const c1 = fixed.to_f32(fixed.cos(base +% step));
    const s0 = fixed.to_f32(fixed.sin(base));
    const s1 = fixed.to_f32(fixed.sin(base +% step));
    return .{ c0 + (c1 - c0) * w, s0 + (s1 - s0) * w };
}

pub fn init() void {
    textures.init();
}

pub fn draw(s: *const state.GameState, level: *const levels.Level) void {
    const px = fixed.to_f32(s.player.x);
    const py = fixed.to_f32(s.player.y);
    const dx, const dy = direction(s.player.angle);
    const half: f32 = @floatFromInt(view_h / 2);

    for (0..view_w) |x| {
        const cx = cam_x[x];
        // plane = (-dy, dx) * tan(fov/2), already folded into cam_x
        const rdx = dx - dy * cx;
        const rdy = dy + dx * cx;
        const hit = raycast.cast(s, level, px, py, rdx, rdy);
        const dist = @max(hit.dist, 1.0 / 64.0);
        depth[x] = dist;

        // Slice [top_f, 104 - top_f); pixel y is covered when its centre
        // y + 0.5 is inside, so the first row is ceil(top_f - 0.5).
        const h = @as(f32, @floatFromInt(view_h)) / dist;
        const top_f = half - h * 0.5;
        const y0: usize = if (top_f <= 0.5) 0 else @intFromFloat(@ceil(top_f - 0.5));
        const y1: usize = view_h - y0;
        // Columns are 256 bytes each in a 0x2000-aligned framebuffer.
        const col: *align(4) [cart.screen_height]cart.Pixel = @alignCast(&cart.framebuffer[x]);
        floor.fill(col, y0, y1);
        if (y0 == y1) continue;

        if (hit.fog) {
            @memset(col[y0..y1], floor.fog);
            continue;
        }
        const set: u8 = if (shade_override) |o| @min(o, textures.set_count - 1) else if (dist > 10) 3 else if (dist > 6) 2 else @as(u8, hit.side);
        const pal = &textures.shade[set];
        const texcol = &textures.tex[hit.tex][hit.tx];
        // 16.16 texel step and start (texel rows per screen row = 32 / h).
        const stepf = @as(f32, textures.tex_size) / h;
        const step: u32 = @intFromFloat(stepf * 65536.0);
        const start = (@as(f32, @floatFromInt(y0)) + 0.5 - top_f) * stepf;
        var ty: u32 = @intFromFloat(@max(start, 0) * 65536.0);
        for (col[y0..y1]) |*p| {
            p.* = pal[texcol[@as(u5, @truncate(ty >> 16))]];
            ty +%= step;
        }
    }
}
