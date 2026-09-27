//! Actor logic (SPEC section 7, PLAN.md M3): Snouty wandering the maze, the
//! smiley that flips the view, the sphere that teleports, the spinning Zig
//! mark, the Start button. Pure state, no cart API: host-testable. The
//! renderer (`render/scene.zig`) reads the pub data below every frame.
//!
//! M3 stub: the declarations are the contract between tracks; Track B3
//! fills in the logic.
const std = @import("std");
const math = @import("math.zig");
const rng = @import("rng.zig");
const maze = @import("maze.zig");
const camera = @import("camera.zig");
const autopilot = @import("autopilot.zig");

const Vec3 = math.Vec3;
const Angle = math.Angle;
const Dir = maze.Dir;

/// Snouty's billboard height and width, in cells.
pub const snouty_size: f32 = 0.55;
pub const sphere_radius: f32 = 0.25;
/// Half size of the smiley, logo and Start button quads.
pub const quad_half: f32 = 0.2;

pub const snouty_ticks_per_cell: u32 = 40; // 1.5 cells/s
pub const snouty_phase_ticks: u32 = 10;
pub const smiley_spin: Angle = 546; // 1 turn per 2 s
pub const logo_spin: Angle = 364; // 1 turn per 3 s
pub const start_spin: Angle = 273; // 1 turn per 4 s
pub const sphere_bob: f32 = 0.05;

pub const Kind = enum(u8) { snouty, smiley, sphere, logo };

/// Snouty: feet centre on the floor, movement direction, walk phase.
pub const Wanderer = struct {
    pos: Vec3 = math.vec3(1.5, 0, 1.5),
    dir: Dir = .e,
    /// Frame within the facing pair (toggles every snouty_phase_ticks).
    phase: u1 = 0,
};

/// A textured quad spinning about the vertical axis; `pos` is its centre.
pub const Spinner = struct {
    pos: Vec3 = math.vec3(2.5, camera.eye_height, 1.5),
    angle: Angle = 0,
};

/// The sphere; `pos` is the centre including the bob.
pub const Bobber = struct {
    pos: Vec3 = math.vec3(1.5, camera.eye_height, 2.5),
};

pub var snouty: Wanderer = .{};
pub var smiley: Spinner = .{};
pub var logo: Spinner = .{};
pub var sphere: Bobber = .{};
/// Start button centre (eye height, 0.3 cells behind the start camera).
pub var start_button: Vec3 = math.vec3(0.5, camera.eye_height, 0.5);
pub var start_angle: Angle = 0;

/// Event counters: the LEDs and the harness watch them change.
pub var flips: u32 = 0;
pub var teleports: u32 = 0;

/// Cell of an actor (floor of x, z), for the debug exports and tests.
pub fn cell_of(p: Vec3) [2]u8 {
    return .{ @intFromFloat(@max(0, p[0])), @intFromFloat(@max(0, p[2])) };
}

/// Place every actor for a fresh maze. `avoid` is the camera's cell.
pub fn reset(m: *const maze.Maze, r: *rng.Xorshift, avoid: [2]u8) void {
    _ = m;
    _ = r;
    _ = avoid;
}

/// One tick. `cam_cell` is the camera's cell; `triggers` is true only in
/// WALK and TURN (the smiley and sphere fire when the camera enters their
/// cell).
pub fn step(m: *const maze.Maze, r: *rng.Xorshift, cam_cell: [2]u8, triggers: bool) void {
    _ = m;
    _ = r;
    _ = cam_cell;
    _ = triggers;
    smiley.angle +%= smiley_spin;
    logo.angle +%= logo_spin;
    start_angle +%= start_spin;
}

/// Debug hook: move one actor to cell (x, z) (clamped into the maze).
pub fn place(m: *const maze.Maze, kind: Kind, x: u8, z: u8) void {
    _ = m;
    _ = kind;
    _ = x;
    _ = z;
}

test {
    _ = std;
    _ = autopilot;
}
