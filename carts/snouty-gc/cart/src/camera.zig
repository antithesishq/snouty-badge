//! Forked from snouty-zero/cart/src/camera.zig at f8f6962.
//! Camera state: where the floor is looked at from, following the car this
//! badge draws (main.zig `follow`). Zero's M0 free camera is gone.
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const hills = @import("hills.zig");

pub const Cam = struct {
    /// World position, Q16.16 (wraps at 1024).
    x: i32,
    y: i32,
    /// Heading, u16 turn.
    yaw: fixed.Turn,
    /// Height over the floor, world px.
    height: i32,
};

pub var cam: Cam = .{ .x = 0, .y = 0, .yaw = 0, .height = tuning.cam_height };

const world_mask: i32 = (1024 << 16) - 1;

pub fn init(x: i32, y: i32, yaw: fixed.Turn) void {
    cam = .{ .x = x & world_mask, .y = y & world_mask, .yaw = yaw, .height = tuning.cam_height };
}

/// Follow mode (Zero SPEC 6.2): yaw eases toward the car's heading by 1/8
/// per tick, the camera sits `cam_behind` world px behind it along that yaw.
pub fn follow(mx: i32, my: i32, heading: fixed.Turn, snap: bool) void {
    if (snap) {
        cam.yaw = heading;
    } else {
        const d = fixed.turn_diff(cam.yaw, heading);
        cam.yaw +%= @bitCast(@as(i16, @intCast(d >> tuning.cam_lag_shift)));
    }
    cam.x = (mx -% fixed.cos(cam.yaw) * tuning.cam_behind) & world_mask;
    cam.y = (my -% fixed.sin(cam.yaw) * tuning.cam_behind) & world_mask;
    cam.height = tuning.cam_height;
}

/// Projection of a world point onto the screen for the current camera.
pub const Projected = struct {
    /// Screen x of the point and the floor row under it.
    sx: i32,
    sy: i32,
    /// Forward distance, world px.
    zf: i32,
    /// Sprite scale in 1/256 (256 at the followed car's distance).
    scale: u32,
};

/// Null when the point is behind or too near the camera.
pub fn project(wx: i32, wy: i32) ?Projected {
    var dx = (wx -% cam.x) & world_mask;
    var dy = (wy -% cam.y) & world_mask;
    // Shortest wrap: to -512..511 world px.
    if (dx >= 512 << fixed.Q) dx -= 1024 << fixed.Q;
    if (dy >= 512 << fixed.Q) dy -= 1024 << fixed.Q;
    const c = fixed.cos(cam.yaw);
    const s = fixed.sin(cam.yaw);
    const zf = (fixed.mul(dx, c) + fixed.mul(dy, s)) >> fixed.Q;
    const xl = (fixed.mul(dx, -s) + fixed.mul(dy, c)) >> fixed.Q;
    if (zf < 8) return null;
    const h = hills.height_ahead(zf, tuning.cam_behind);
    const sy = tuning.horizon_y + @max(1, @divTrunc((cam.height - h) * tuning.focal, zf));
    const sx = 80 + @divTrunc(xl * tuning.focal, zf);
    return .{ .sx = sx, .sy = sy, .zf = zf, .scale = @intCast(@divTrunc(256 * tuning.cam_behind, zf)) };
}
