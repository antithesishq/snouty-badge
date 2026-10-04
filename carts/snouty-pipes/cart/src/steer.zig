//! Steer mode (M3) helpers that need no director state: the screen-relative
//! control mapping and the buffered turn queue. director.zig runs the game.
//! Pure logic, host-tested, no cart API.
const std = @import("std");
const math = @import("math.zig");
const grid = @import("grid.zig");
const camera = @import("camera.zig");

/// The six steering inputs. A dives into the screen, B comes out of it.
pub const Control = enum(u3) { up, down, left, right, into, out };

/// Grid direction for each `Control`, indexed by its backing integer.
pub const Map = [6]grid.Dir;

/// The screen-relative mapping for camera `cam` (PLAN.md M3): the grid axis
/// most aligned with `fwd` is depth (into = along `fwd`), of the other two
/// the one most aligned with `right` is Left/Right and the last Up/Down.
/// Signs come from the projection: at the screen centre a step along a grid
/// axis moves the image along `right`/`up` by its dot product with them, so
/// Right is the direction with a positive `right` component, Up the one
/// with a positive `up` component. Ties go to the lower axis.
pub fn map_for(cam: *const camera.Camera) Map {
    const f = [3]f32{ cam.fwd[0], cam.fwd[1], cam.fwd[2] };
    const rt = [3]f32{ cam.right[0], cam.right[1], cam.right[2] };
    const u = [3]f32{ cam.up[0], cam.up[1], cam.up[2] };
    var depth: usize = 0;
    for (1..3) |a| {
        if (@abs(f[a]) > @abs(f[depth])) depth = a;
    }
    const o1: usize = if (depth == 0) 1 else 0;
    const o2: usize = 3 - depth - o1;
    const across: usize = if (@abs(rt[o2]) > @abs(rt[o1])) o2 else o1;
    const vertical: usize = 3 - depth - across;
    const up_dir = axis_dir(vertical, u[vertical] >= 0);
    const right_dir = axis_dir(across, rt[across] >= 0);
    const into_dir = axis_dir(depth, f[depth] >= 0);
    return .{ up_dir, up_dir.opposite(), right_dir.opposite(), right_dir, into_dir, into_dir.opposite() };
}

fn axis_dir(axis: usize, positive: bool) grid.Dir {
    return @fromBackingInt(@intCast(axis * 2 + @intFromBool(!positive)));
}

/// The map in 18 bits, 3 per control in `Control` order (debug_steer_map).
pub fn pack(m: Map) u32 {
    var v: u32 = 0;
    for (m, 0..) |d, i| v |= @as(u32, @backingInt(d)) << @intCast(3 * i);
    return v;
}

/// Turns pressed ahead of the pipe, applied one per cell at its centre.
/// Two deep, so a quick Up-then-Left makes a tight U. A press that repeats
/// the direction the pipe will be going, or reverses it, is dropped.
pub const TurnQueue = struct {
    dirs: [2]grid.Dir = .{ .none, .none },
    len: u2 = 0,

    /// Queues `d` given `heading`, the direction the pipe will leave its
    /// current cell by (or enter the next one by) if nothing else is queued.
    pub fn press(q: *TurnQueue, d: grid.Dir, heading: grid.Dir) void {
        const last = if (q.len > 0) q.dirs[q.len - 1] else heading;
        if (d == last or d == last.opposite() or q.len >= q.dirs.len) return;
        q.dirs[q.len] = d;
        q.len += 1;
    }

    /// The oldest queued turn, removed, or null.
    pub fn take(q: *TurnQueue) ?grid.Dir {
        if (q.len == 0) return null;
        const d = q.dirs[0];
        q.dirs[0] = q.dirs[1];
        q.dirs[1] = .none;
        q.len -= 1;
        return d;
    }

    pub fn clear(q: *TurnQueue) void {
        q.* = .{};
    }
};

// ---------------------------------------------------------------------------
// Tests.

const testing = std.testing;

fn expect_permutation(m: Map) !void {
    var seen: u8 = 0;
    for (m) |d| {
        try testing.expect(d != .none);
        seen |= @as(u8, 1) << @backingInt(d);
    }
    try testing.expectEqual(@as(u8, 0x3F), seen);
    // Opposite controls get opposite directions.
    try testing.expectEqual(m[0].opposite(), m[1]);
    try testing.expectEqual(m[2].opposite(), m[3]);
    try testing.expectEqual(m[4].opposite(), m[5]);
}

test "the mapping is a permutation of the six directions for every view and orbit" {
    for (0..camera.views.len) |i| {
        for (0..8) |o| {
            const cam = camera.view(i, @intCast(o));
            try expect_permutation(map_for(&cam));
        }
    }
    for (0..camera.steer_views.len) |i| {
        const cam = camera.steer_view(i, .{ 4, 4, 4 });
        try expect_permutation(map_for(&cam));
    }
}

test "steer views: each control moves the head the way its name says" {
    for (0..camera.steer_views.len) |i| {
        const cam = camera.steer_view(i, .{ 4, 4, 4 });
        const m = map_for(&cam);
        const c = math.splat(0);
        const p0 = cam.project(c);
        const moved = struct {
            fn f(cm: *const camera.Camera, d: grid.Dir) [3]f32 {
                return cm.project(d.vec() * math.splat(0.5));
            }
        }.f;
        const up = moved(&cam, m[@backingInt(Control.up)]);
        const right = moved(&cam, m[@backingInt(Control.right)]);
        const into = moved(&cam, m[@backingInt(Control.into)]);
        // Up goes up the screen more than sideways, Right goes right more than
        // up or down, Into goes away from the eye.
        try testing.expect(up[1] < p0[1] - 2 and @abs(up[1] - p0[1]) > @abs(up[0] - p0[0]));
        try testing.expect(right[0] > p0[0] + 2 and @abs(right[0] - p0[0]) > @abs(right[1] - p0[1]));
        try testing.expect(into[2] > p0[2] + 0.3);
        // The depth axis is clearly the most aligned with fwd, so A and B
        // never feel like Up or Left.
        const f = cam.fwd;
        const fd = @abs(math.dot(m[@backingInt(Control.into)].vec(), f));
        try testing.expect(fd > 0.7);
        try testing.expect(@abs(math.dot(m[@backingInt(Control.up)].vec(), f)) < fd - 0.2);
        try testing.expect(@abs(math.dot(m[@backingInt(Control.right)].vec(), f)) < fd - 0.2);
    }
}

test "pack keeps three bits per control" {
    const cam = camera.steer_view(0, .{ 4, 4, 4 });
    const m = map_for(&cam);
    const v = pack(m);
    for (m, 0..) |d, i| try testing.expectEqual(@as(u32, @backingInt(d)), (v >> @intCast(3 * i)) & 7);
    try testing.expect(v < (1 << 18));
}

test "turn queue drops repeats and reversals, keeps two" {
    var q: TurnQueue = .{};
    q.press(.px, .px);
    q.press(.nx, .px);
    try testing.expectEqual(@as(u2, 0), q.len);
    q.press(.py, .px);
    q.press(.py, .px);
    q.press(.ny, .px); // reverses the queued Up
    q.press(.nx, .px); // fine after Up: a U turn
    q.press(.pz, .px); // full
    try testing.expectEqual(@as(?grid.Dir, .py), q.take());
    try testing.expectEqual(@as(?grid.Dir, .nx), q.take());
    try testing.expectEqual(@as(?grid.Dir, null), q.take());
}
