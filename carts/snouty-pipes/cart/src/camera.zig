//! Perspective camera, fixed for a whole scene (SPEC.md section 4). One
//! primary ray per pixel: `ray(x, y)` has unit length along `fwd`, so the ray
//! parameter t of a hit IS its view depth, which is what the z buffer keeps.
const std = @import("std");
const math = @import("math.zig");
const grid = @import("grid.zig");

const Vec3 = math.Vec3;

pub const screen_w = 160;
pub const screen_h = 128;
const cx: f32 = screen_w / 2;
const cy: f32 = screen_h / 2;

/// Focal length in pixels: about 62 degrees across the 160 px width.
pub const focal: f32 = 135.0;

/// Inclusive-exclusive pixel rectangle, already clipped to the screen.
pub const Rect = struct {
    x0: u8,
    y0: u8,
    x1: u8,
    y1: u8,

    pub const empty: Rect = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
    pub const full: Rect = .{ .x0 = 0, .y0 = 0, .x1 = screen_w, .y1 = screen_h };

    pub fn is_empty(r: Rect) bool {
        return r.x1 <= r.x0 or r.y1 <= r.y0;
    }
};

pub const Camera = struct {
    eye: Vec3,
    right: Vec3,
    up: Vec3,
    fwd: Vec3,

    /// Camera at `eye` looking at `target`, `up_hint` roughly up.
    pub fn look_at(eye: Vec3, target: Vec3, up_hint: Vec3) Camera {
        const fwd = math.normalize(target - eye);
        const right = math.normalize(math.cross(fwd, up_hint));
        const up = math.cross(right, fwd);
        return .{ .eye = eye, .right = right, .up = up, .fwd = fwd };
    }

    /// Direction of the primary ray through pixel centre (x, y); its
    /// component along `fwd` is 1, so hit t = view depth.
    pub inline fn ray(self: *const Camera, x: f32, y: f32) Vec3 {
        const u = (x + 0.5 - cx) * (1.0 / focal);
        const v = (y + 0.5 - cy) * (1.0 / focal);
        return self.fwd + self.right * math.splat(u) - self.up * math.splat(v);
    }

    /// Screen position (sx, sy) and view depth z of a world point. z <= 0
    /// means behind the camera (sx, sy are then meaningless).
    pub fn project(self: *const Camera, p: Vec3) [3]f32 {
        const v = p - self.eye;
        const z = math.dot(v, self.fwd);
        if (z <= 1e-3) return .{ 0, 0, z };
        const inv = focal / z;
        return .{ cx + math.dot(v, self.right) * inv, cy - math.dot(v, self.up) * inv, z };
    }

    /// Pixel rectangle covering a world-space axis-aligned box, clipped to
    /// the screen. Any corner behind the camera gives the full screen (never
    /// happens with the fitted views: the camera is always outside the grid).
    pub fn screen_rect(self: *const Camera, lo: Vec3, hi: Vec3) Rect {
        var x0: f32 = std.math.floatMax(f32);
        var y0: f32 = std.math.floatMax(f32);
        var x1: f32 = -std.math.floatMax(f32);
        var y1: f32 = -std.math.floatMax(f32);
        for (0..8) |i| {
            const p = math.vec3(
                if (i & 1 != 0) hi[0] else lo[0],
                if (i & 2 != 0) hi[1] else lo[1],
                if (i & 4 != 0) hi[2] else lo[2],
            );
            const s = self.project(p);
            if (s[2] <= 1e-3) return .full;
            x0 = @min(x0, s[0]);
            y0 = @min(y0, s[1]);
            x1 = @max(x1, s[0]);
            y1 = @max(y1, s[1]);
        }
        return clip_rect(x0, y0, x1, y1);
    }
};

fn clip_rect(x0: f32, y0: f32, x1: f32, y1: f32) Rect {
    const fx0 = std.math.clamp(@floor(x0), 0, screen_w);
    const fy0 = std.math.clamp(@floor(y0), 0, screen_h);
    const fx1 = std.math.clamp(@ceil(x1) + 1, 0, screen_w);
    const fy1 = std.math.clamp(@ceil(y1) + 1, 0, screen_h);
    return .{
        .x0 = @intFromFloat(fx0),
        .y0 = @intFromFloat(fy0),
        .x1 = @intFromFloat(fx1),
        .y1 = @intFromFloat(fy1),
    };
}

/// View directions (from the grid centre towards the eye), SPEC section 4:
/// three near-axis views with a slight tilt, then five three-quarter views.
/// Index 5 looks up from below.
pub const views = [_][3]f32{
    .{ 0.12, 0.18, 1.0 },
    .{ 1.0, 0.22, 0.10 },
    .{ 0.15, 1.0, 0.35 },
    .{ 1.0, 0.65, 1.0 },
    .{ -1.0, 0.45, 1.0 },
    .{ 1.0, -0.40, 0.8 },
    .{ -0.8, 0.75, -1.0 },
    .{ 0.55, 0.30, -1.0 },
};

/// Camera for view `index` (wrapped), orbited `orbit` eighths of a turn
/// about the vertical axis (M2's Left/Right), framed so the grid box fills
/// the screen: the eye backs off until the box's projected corners reach
/// `overscan` times the half-screen. Some pipe ends leave the screen, as in
/// the original.
pub fn view(index: usize, orbit: i32) Camera {
    const d0 = views[index % views.len];
    const a = @as(f32, @floatFromInt(@mod(orbit, 8))) * 0.125;
    const c = math.cos_turns(a);
    const s = math.sin_turns(a);
    const dir = math.normalize(math.vec3(d0[0] * c + d0[2] * s, d0[1], -d0[0] * s + d0[2] * c));
    return fitted(dir);
}

const overscan: f32 = 1.08;

fn fitted(dir: Vec3) Camera {
    // Mostly vertical views take +z as up, so the up hint never lines up with fwd.
    const up_hint = if (@abs(dir[1]) > 0.9) math.vec3(0, 0, -1) else math.vec3(0, 1, 0);
    const hx = @as(f32, grid.nx) * 0.5;
    const hy = @as(f32, grid.ny) * 0.5;
    const hz = @as(f32, grid.nz) * 0.5;
    var lo: f32 = 6.0;
    var hi: f32 = 80.0;
    for (0..24) |_| {
        const d = (lo + hi) * 0.5;
        const cam = Camera.look_at(dir * math.splat(d), math.splat(0), up_hint);
        var extent: f32 = 0;
        for (0..8) |i| {
            const p = math.vec3(
                if (i & 1 != 0) hx else -hx,
                if (i & 2 != 0) hy else -hy,
                if (i & 4 != 0) hz else -hz,
            );
            const sp = cam.project(p);
            if (sp[2] <= 0.5) {
                extent = std.math.floatMax(f32);
                break;
            }
            extent = @max(extent, @max(@abs(sp[0] - cx) / cx, @abs(sp[1] - cy) / cy));
        }
        if (extent > overscan) lo = d else hi = d;
    }
    return Camera.look_at(dir * math.splat(hi), math.splat(0), up_hint);
}

test "ray depth equals t and projection round-trips" {
    const cam = view(3, 0);
    const p = math.vec3(1.0, -2.0, 0.5);
    const s = cam.project(p);
    const d = cam.ray(s[0] - 0.5, s[1] - 0.5);
    const q = cam.eye + d * math.splat(s[2]);
    try std.testing.expectApproxEqAbs(p[0], q[0], 1e-3);
    try std.testing.expectApproxEqAbs(p[1], q[1], 1e-3);
    try std.testing.expectApproxEqAbs(p[2], q[2], 1e-3);
}

test "every view keeps the camera outside the grid and the centre on screen" {
    for (0..views.len) |i| {
        for (0..8) |o| {
            const cam = view(i, @intCast(o));
            const s = cam.project(math.splat(0));
            try std.testing.expect(s[2] > 8.0);
            try std.testing.expectApproxEqAbs(@as(f32, cx), s[0], 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, cy), s[1], 0.01);
        }
    }
}
