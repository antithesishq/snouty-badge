//! Camera state: where the floor is looked at from. M0: a free camera on the
//! d-pad (PLAN.md M0); M1 adds the follow mode behind the player's machine.
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const input = @import("input.zig");

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

/// M0 free flight: Left/Right yaw, A forward, B back, Up/Down height.
pub fn free_fly() void {
    if (input.held(.left)) cam.yaw -%= @intCast(tuning.free_yaw_rate);
    if (input.held(.right)) cam.yaw +%= @intCast(tuning.free_yaw_rate);
    var speed: i32 = 0;
    if (input.held(.a)) speed += tuning.free_speed;
    if (input.held(.b)) speed -= tuning.free_speed;
    if (speed != 0) {
        cam.x = (cam.x + fixed.mul(fixed.cos(cam.yaw), speed)) & world_mask;
        cam.y = (cam.y + fixed.mul(fixed.sin(cam.yaw), speed)) & world_mask;
    }
    if (input.held(.up) and cam.height < tuning.free_height_max) cam.height += 1;
    if (input.held(.down) and cam.height > tuning.free_height_min) cam.height -= 1;
}
