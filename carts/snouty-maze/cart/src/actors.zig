//! Actor logic (SPEC section 7, PLAN.md M3): Snouty wandering the maze, the
//! smiley that flips the view, the sphere that teleports, the spinning Zig
//! mark, the Start button. Pure state, no cart API: host-testable. The
//! renderer (`render/scene.zig`) reads the pub data below every frame.
//!
//! Spawn rule (every actor, every placement): a random cell that is not the
//! start, not the finish, not the camera's cell and not another actor's
//! cell. The smiley prefers dead ends (three walls), the logo junctions (at
//! most one wall); both fall back to any allowed cell.
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
/// Bob period in ticks (sin_turns(t / 120)).
pub const sphere_bob_ticks: u32 = 120;
/// How far the Start button sits behind the start camera, in cells.

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

// Snouty's last reached cell and ticks walked toward the next one; the
// phase counter runs continuously (0 .. 2 * snouty_phase_ticks - 1).
var snouty_cell: [2]u8 = .{ 1, 1 };
var snouty_tick: u32 = 0;
var phase_tick: u32 = 0;
// Sphere cell and bob clock (0 .. sphere_bob_ticks - 1).
var sphere_cell: [2]u8 = .{ 1, 2 };
var bob_tick: u32 = 0;

// Spawn candidates (.bss, no allocation).
var candidates: [maze.max_cells][2]u8 = undefined;

const Pref = enum { any, dead_end, junction };

/// Cell of an actor (floor of x, z), for the debug exports and tests.
pub fn cell_of(p: Vec3) [2]u8 {
    return .{ @intFromFloat(@max(0, p[0])), @intFromFloat(@max(0, p[2])) };
}

pub fn snouty_cell_now() [2]u8 {
    return snouty_cell;
}
pub fn sphere_cell_now() [2]u8 {
    return sphere_cell;
}

fn eq(a: [2]u8, b: [2]u8) bool {
    return a[0] == b[0] and a[1] == b[1];
}

fn centre(c: [2]u8, y: f32) Vec3 {
    return math.vec3(@as(f32, @floatFromInt(c[0])) + 0.5, y, @as(f32, @floatFromInt(c[1])) + 0.5);
}

fn wall_count(m: *const maze.Maze, x: u8, z: u8) u32 {
    var n: u32 = 0;
    for ([_]Dir{ .n, .e, .s, .w }) |d| n += @intFromBool(m.has_wall(x, z, d));
    return n;
}

fn matches(m: *const maze.Maze, x: u8, z: u8, pref: Pref) bool {
    return switch (pref) {
        .any => true,
        .dead_end => wall_count(m, x, z) == 3,
        .junction => wall_count(m, x, z) <= 1,
    };
}

/// A random allowed cell (spawn rule), preferring `pref`; `excl` are the
/// extra cells to avoid (camera, other actors). Start and finish are always
/// excluded. Falls back to the start cell only if nothing else is allowed
/// (impossible for a maze of at least 2x2 with the four actors placed).
fn spawn(m: *const maze.Maze, r: *rng.Xorshift, pref: Pref, excl: []const [2]u8) [2]u8 {
    var tries: u32 = 0;
    var p = pref;
    while (tries < 2) : (tries += 1) {
        var n: u32 = 0;
        var z: u8 = 0;
        while (z < m.h) : (z += 1) {
            var x: u8 = 0;
            cell: while (x < m.w) : (x += 1) {
                const c: [2]u8 = .{ x, z };
                if (eq(c, m.start) or eq(c, m.finish)) continue;
                for (excl) |e| if (eq(c, e)) continue :cell;
                if (!matches(m, x, z, p)) continue;
                candidates[n] = c;
                n += 1;
            }
        }
        if (n > 0) return candidates[r.below(n)];
        p = .any;
    }
    return m.start;
}

/// A random open direction of cell c.
fn random_open(m: *const maze.Maze, r: *rng.Xorshift, c: [2]u8) Dir {
    var opts: [4]Dir = undefined;
    var n: u32 = 0;
    for ([_]Dir{ .n, .e, .s, .w }) |d| {
        if (!m.has_wall(c[0], c[1], d)) {
            opts[n] = d;
            n += 1;
        }
    }
    if (n == 0) return .n;
    return opts[r.below(n)];
}

fn first_open(m: *const maze.Maze, c: [2]u8) Dir {
    for ([_]Dir{ .n, .e, .s, .w }) |d| {
        if (!m.has_wall(c[0], c[1], d)) return d;
    }
    return .n;
}

/// Snouty's next heading at a centre: a random open side, never the
/// reverse unless the cell is a dead end.
fn wander_dir(m: *const maze.Maze, r: *rng.Xorshift, c: [2]u8, d: Dir) Dir {
    var opts: [3]Dir = undefined;
    var n: u32 = 0;
    for ([_]Dir{ d.left(), d, d.right() }) |o| {
        if (!m.has_wall(c[0], c[1], o)) {
            opts[n] = o;
            n += 1;
        }
    }
    if (n == 0) return d.opposite();
    return opts[r.below(n)];
}

fn set_snouty(c: [2]u8, d: Dir) void {
    snouty_cell = c;
    snouty_tick = 0;
    snouty.dir = d;
    snouty.pos = centre(c, 0);
}

fn set_sphere(c: [2]u8) void {
    sphere_cell = c;
    update_sphere_pos();
}

fn update_sphere_pos() void {
    const t = @as(f32, @floatFromInt(bob_tick)) * (1.0 / @as(f32, @floatFromInt(sphere_bob_ticks)));
    sphere.pos = centre(sphere_cell, camera.eye_height + sphere_bob * math.sin_turns(t));
}

/// Place every actor for a fresh maze. `avoid` is the camera's cell.
pub fn reset(m: *const maze.Maze, r: *rng.Xorshift, avoid: [2]u8) void {
    // The Start button floats in the cell the camera faces at the start
    // (the original's SX1, SY1), so it is the first thing seen as the maze
    // rises and the walker passes through it; no other actor spawns there.
    const sb = m.neighbour(m.start[0], m.start[1], camera.start_facing(m)) orelse m.start;
    start_button = centre(sb, camera.eye_height);
    const s = spawn(m, r, .any, &.{ avoid, sb });
    set_snouty(s, random_open(m, r, s));
    phase_tick = 0;
    snouty.phase = 0;
    const sm = spawn(m, r, .dead_end, &.{ avoid, sb, s });
    smiley.pos = centre(sm, camera.eye_height);
    const sp = spawn(m, r, .any, &.{ avoid, sb, s, sm });
    set_sphere(sp);
    const lg = spawn(m, r, .junction, &.{ avoid, sb, s, sm, sp });
    logo.pos = centre(lg, camera.eye_height);
}

/// One tick. `cam_cell` is the camera's cell; `triggers` is true only in
/// WALK, TURN and MANUAL (`autopilot.walking()`; the smiley and sphere
/// fire when the camera enters their cell).
pub fn step(m: *const maze.Maze, r: *rng.Xorshift, cam_cell: [2]u8, triggers: bool) void {
    smiley.angle +%= smiley_spin;
    logo.angle +%= logo_spin;
    start_angle +%= start_spin;

    // Snouty walks in every state.
    snouty_tick += 1;
    const s = @as(f32, @floatFromInt(snouty_tick)) * (1.0 / @as(f32, @floatFromInt(snouty_ticks_per_cell)));
    const d = snouty.dir;
    snouty.pos = centre(snouty_cell, 0) + math.vec3(@floatFromInt(d.dx()), 0, @floatFromInt(d.dz())) * math.splat(s);
    if (snouty_tick >= snouty_ticks_per_cell) {
        const nc = if (m.has_wall(snouty_cell[0], snouty_cell[1], d)) snouty_cell else m.neighbour(snouty_cell[0], snouty_cell[1], d) orelse snouty_cell;
        set_snouty(nc, wander_dir(m, r, nc, d));
    }
    phase_tick += 1;
    if (phase_tick >= 2 * snouty_phase_ticks) phase_tick = 0;
    snouty.phase = @intCast(phase_tick / snouty_phase_ticks);

    bob_tick += 1;
    if (bob_tick >= sphere_bob_ticks) bob_tick = 0;
    update_sphere_pos();

    if (!triggers) return;
    const sn = snouty_cell;
    const sm = cell_of(smiley.pos);
    const lg = cell_of(logo.pos);
    if (eq(cam_cell, sm)) {
        autopilot.flip();
        flips += 1;
        const nc = spawn(m, r, .dead_end, &.{ cam_cell, sn, sphere_cell, lg });
        smiley.pos = centre(nc, camera.eye_height);
    } else if (eq(cam_cell, sphere_cell)) {
        // Jump forward along the follower's own path (never restart it
        // from a random cell: that made a 12x12 maze take 11 minutes).
        if (forward_hop(m, r, cam_cell, autopilot.dir, &.{ sn, sm, lg })) |hop| {
            autopilot.begin_teleport(hop.cell, hop.dir);
            teleports += 1;
            set_sphere(spawn(m, r, .any, &.{ cam_cell, hop.cell, sn, sm, lg }));
        } else {
            set_sphere(spawn(m, r, .any, &.{ cam_cell, sn, sm, lg }));
        }
    }
}

/// Wall-follower moves from `c` (arrived heading `d`) to the finish.
pub fn remaining(m: *const maze.Maze, c: [2]u8, d: Dir) u32 {
    var cur = c;
    var dir = d;
    var n: u32 = 0;
    while (!eq(cur, m.finish) and n < 4 * maze.max_cells) {
        dir = autopilot.follow(m, cur[0], cur[1], dir);
        cur = m.neighbour(cur[0], cur[1], dir) orelse cur;
        n += 1;
    }
    return n;
}

const Hop = struct { cell: [2]u8, dir: Dir };

/// The cell and arrival heading `k` follower moves after `c`.
fn along_path(m: *const maze.Maze, c: [2]u8, d: Dir, k: u32) Hop {
    var cur = c;
    var dir = d;
    for (0..k) |_| {
        dir = autopilot.follow(m, cur[0], cur[1], dir);
        cur = m.neighbour(cur[0], cur[1], dir) orelse cur;
    }
    return .{ .cell = cur, .dir = dir };
}

/// Teleport destination: a random point in the second half of the
/// follower's remaining path (never the finish itself), so every hop
/// shortens the walk. Avoids `excl` (other actors) when it can. Null when
/// the finish is too close for a hop.
fn forward_hop(m: *const maze.Maze, r: *rng.Xorshift, c: [2]u8, d: Dir, excl: []const [2]u8) ?Hop {
    const rem = remaining(m, c, d);
    if (rem < 3) return null;
    const lo = rem / 2;
    const span = rem - 1 - lo; // k in [lo, rem - 1)
    var tries: u32 = 0;
    var hop: Hop = undefined;
    while (tries < 4) : (tries += 1) {
        hop = along_path(m, c, d, lo + r.below(span));
        var clash = false;
        for (excl) |e| clash = clash or eq(hop.cell, e);
        if (!clash) break;
    }
    return hop;
}

/// Debug hook: move one actor to cell (x, z) (clamped into the maze).
/// Snouty restarts at that centre heading along its first open side.
pub fn place(m: *const maze.Maze, kind: Kind, x: u8, z: u8) void {
    const c: [2]u8 = .{ @min(x, m.w - 1), @min(z, m.h - 1) };
    switch (kind) {
        .snouty => set_snouty(c, first_open(m, c)),
        .smiley => smiley.pos = centre(c, camera.eye_height),
        .sphere => set_sphere(c),
        .logo => logo.pos = centre(c, camera.eye_height),
    }
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn test_maze(seed: u32, n: u8) maze.Maze {
    var r = rng.Xorshift.init(seed);
    var m: maze.Maze = .{};
    m.generate(n, n, &r);
    return m;
}

fn any_cell(m: *const maze.Maze, pref: Pref, excl: []const [2]u8) bool {
    var z: u8 = 0;
    while (z < m.h) : (z += 1) {
        var x: u8 = 0;
        cell: while (x < m.w) : (x += 1) {
            const c: [2]u8 = .{ x, z };
            if (eq(c, m.start) or eq(c, m.finish)) continue;
            for (excl) |e| if (eq(c, e)) continue :cell;
            if (matches(m, x, z, pref)) return true;
        }
    }
    return false;
}

test "spawns respect the exclusion rule and preferences" {
    for (1..51) |seed| {
        const m = test_maze(@intCast(seed), 12);
        var r = rng.Xorshift.init(@intCast(seed * 7 + 3));
        const avoid: [2]u8 = .{ @intCast(seed % 12), @intCast((seed / 3) % 12) };
        reset(&m, &r, avoid);
        const cells = [_][2]u8{ snouty_cell, cell_of(smiley.pos), sphere_cell, cell_of(logo.pos) };
        try testing.expect(eq(cell_of(snouty.pos), snouty_cell));
        try testing.expectEqual(@as(f32, 0), snouty.pos[1]);
        for (cells, 0..) |c, i| {
            try testing.expect(!eq(c, m.start));
            try testing.expect(!eq(c, m.finish));
            try testing.expect(!eq(c, avoid));
            for (cells[i + 1 ..]) |o| try testing.expect(!eq(c, o));
        }
        const sm = cells[1];
        if (any_cell(&m, .dead_end, &.{ avoid, cells[0] })) try testing.expectEqual(@as(u32, 3), wall_count(&m, sm[0], sm[1]));
        const lg = cells[3];
        if (any_cell(&m, .junction, &.{ avoid, cells[0], cells[1], cells[2] })) try testing.expect(wall_count(&m, lg[0], lg[1]) <= 1);
        try testing.expect(!m.has_wall(snouty_cell[0], snouty_cell[1], snouty.dir));
        // Start button at eye height in the centre of the cell the camera
        // faces at the start, and no actor spawned there.
        const sb = m.neighbour(m.start[0], m.start[1], camera.start_facing(&m)).?;
        try testing.expectEqual(centre(sb, camera.eye_height), start_button);
        for (cells) |c| try testing.expect(!eq(c, sb));
        try testing.expectEqual(camera.eye_height, start_button[1]);
    }
}

test "Snouty never walks through a wall and never reverses outside a dead end" {
    for ([_]u32{ 1, 2, 3 }) |seed| {
        const m = test_maze(seed, 12);
        var r = rng.Xorshift.init(seed + 100);
        reset(&m, &r, .{ 0, 0 });
        var prev_cell = snouty_cell;
        var prev_dir = snouty.dir;
        var prev_phase = snouty.phase;
        var phase_changes: u32 = 0;
        for (0..5000) |t| {
            step(&m, &r, .{ 0, 0 }, false);
            if (snouty.phase != prev_phase) phase_changes += 1;
            prev_phase = snouty.phase;
            // Always on the segment between the last cell and its open neighbour.
            try testing.expect(!m.has_wall(snouty_cell[0], snouty_cell[1], snouty.dir));
            if (!eq(snouty_cell, prev_cell)) {
                // Moved exactly one cell through an open side.
                try testing.expectEqual(m.neighbour(prev_cell[0], prev_cell[1], prev_dir).?, snouty_cell);
                try testing.expect(!m.has_wall(prev_cell[0], prev_cell[1], prev_dir));
                try testing.expectEqual(@as(u32, 0), snouty_tick);
                try testing.expectEqual(@as(u32, 0), @as(u32, @intCast((t + 1) % snouty_ticks_per_cell)));
                if (snouty.dir == prev_dir.opposite()) try testing.expectEqual(@as(u32, 3), wall_count(&m, snouty_cell[0], snouty_cell[1]));
                prev_cell = snouty_cell;
                prev_dir = snouty.dir;
            }
            const p = snouty.pos;
            try testing.expect(p[0] > 0 and p[2] > 0 and p[0] < 12 and p[2] < 12);
        }
        try testing.expectEqual(@as(u32, 5000 / snouty_phase_ticks), phase_changes);
    }
}

test "smiley trigger fires once and the smiley moves away" {
    var m = test_maze(1, 12);
    var r = rng.Xorshift.init(9);
    camera.reset(&m);
    autopilot.begin_walk(&m);
    reset(&m, &r, m.start);
    const c: [2]u8 = .{ 3, 4 };
    place(&m, .smiley, c[0], c[1]);
    const f0 = flips;
    autopilot.state = .walk;
    step(&m, &r, c, true);
    try testing.expectEqual(f0 + 1, flips);
    try testing.expect(!eq(cell_of(smiley.pos), c));
    try testing.expect(!eq(cell_of(smiley.pos), m.start));
    try testing.expect(!eq(cell_of(smiley.pos), m.finish));
    for (0..10) |_| step(&m, &r, c, true);
    try testing.expectEqual(f0 + 1, flips);
    // Triggers off (e.g. FLY): nothing fires.
    place(&m, .smiley, c[0], c[1]);
    step(&m, &r, c, false);
    try testing.expectEqual(f0 + 1, flips);
}

test "sphere trigger teleports onto the destination centre" {
    var m = test_maze(1, 12);
    var r = rng.Xorshift.init(11);
    const focal: f32 = 123.2;
    camera.reset(&m);
    autopilot.begin_walk(&m);
    reset(&m, &r, m.start);
    // Walk until the camera enters a fresh cell, put the sphere there.
    var guard: u32 = 0;
    while (eq(cell_of(camera.cam.pos), m.start)) : (guard += 1) {
        autopilot.step(&m, &r, focal);
        try testing.expect(guard < 1000);
    }
    const here = cell_of(camera.cam.pos);
    place(&m, .smiley, 11, 0);
    if (eq(here, .{ 11, 0 })) place(&m, .smiley, 0, 11);
    place(&m, .sphere, here[0], here[1]);
    const t0 = teleports;
    const d0 = autopilot.dir;
    step(&m, &r, here, autopilot.state == .walk or autopilot.state == .turn);
    try testing.expectEqual(t0 + 1, teleports);
    try testing.expectEqual(autopilot.State.teleport, autopilot.state);
    try testing.expect(!eq(sphere_cell, here));
    const dest = autopilot.teleport_dest();
    try testing.expect(!eq(dest, m.finish));
    try testing.expect(!eq(dest, here));
    try testing.expect(!eq(sphere_cell, dest));
    for (0..6) |_| autopilot.step(&m, &r, focal);
    try testing.expectEqual(autopilot.cell_centre(dest[0], dest[1]), camera.cam.pos);
    try testing.expectEqual(camera.eye_height, camera.cam.pos[1]);
    const d = camera.heading(camera.cam.yaw);
    try testing.expectEqual(camera.dir_yaw(d), camera.cam.yaw);
    // Arrived from an open side, and the hop shortened the walk.
    try testing.expect(!m.has_wall(dest[0], dest[1], d.opposite()));
    try testing.expect(remaining(&m, dest, d) < remaining(&m, here, d0));
    for (0..6) |_| autopilot.step(&m, &r, focal);
    try testing.expect(autopilot.state == .walk or autopilot.state == .turn);
}
