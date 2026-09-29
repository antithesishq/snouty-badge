//! Screensaver state machine (SPEC section 8, PLAN.md M2 "State machine"):
//! left-hand wall follower walk with eased turns, then the finish sequence
//! PAUSE -> RISE -> OVERHEAD (maze swap) -> DESCEND -> WALK, plus the M3
//! actor effects: the smiley's 180 degree roll (`flip`) and the sphere's
//! TELEPORT (fade out, move, fade in), and the M4 joystick takeover
//! (MANUAL: grid-locked moves, idle return to WALK). Drives `camera.cam`.
//! No cart API: main feeds the stick through `stick()`, so this stays
//! host-testable (tests below, pulled in through camera.zig and actors.zig).
const std = @import("std");
const math = @import("math.zig");
const rng = @import("rng.zig");
const maze = @import("maze.zig");
const camera = @import("camera.zig");
const actors = @import("actors.zig");
const Vec3 = math.Vec3;
const Angle = math.Angle;
const Dir = maze.Dir;

/// Values are stable: `debug_state` returns them and the harness scripts
/// compare against them. walk = 0, turn = 1, pause = 2, rise = 3,
/// overhead = 4, descend = 5, teleport = 6 (M3), fly = 7 (debug),
/// manual = 8 (M4 takeover). Append new states only.
pub const State = enum(u32) { walk, turn, pause, rise, overhead, descend, teleport, fly, manual, grow };

pub const walk_ticks_per_cell = 30; // 1/30 cell per tick
pub const turn90_ticks = 20;
pub const turn180_ticks = 36;
pub const pause_ticks = 30;
pub const rise_ticks = 150;
pub const overhead_ticks = 120;
/// OVERHEAD ticks over which the new maze is carved (C4); the rest of
/// OVERHEAD shows it finished.
pub const carve_ticks = 90;
pub const descend_ticks = 150;
/// GROW: ticks over which the maze rises out of the floor around the
/// camera at the start (boot and after DESCEND), as in the original.
pub const grow_ticks = 60;
pub const roll_cap_ticks = 1200;
pub const unroll_ticks = 30;
pub const flip_ticks = 30;
pub const teleport_ticks = 12;
/// TELEPORT tick at which the camera moves (end of the fade out).
pub const teleport_move_tick = 6;
/// MANUAL: ticks without any stick held, at rest, before the autopilot
/// takes over again (5 s).
pub const manual_idle_ticks = 300;

pub var state: State = .walk;
/// Ticks spent in the current state (0 on the tick it was entered).
pub var state_tick: u32 = 0;
/// Autopilot heading (WALK/TURN: the direction walked next).
pub var dir: Dir = .n;
/// Mazes completed (incremented when OVERHEAD swaps the maze).
pub var cycles: u32 = 0;
/// True during OVERHEAD; the overlay draws the name strip.
pub var name_strip_visible: bool = false;
/// Start toggles this: name strip always on.
pub var name_strip_forced: bool = false;

// WALK: current (last reached) cell, ticks walked toward the next one.
var cell: [2]u8 = .{ 0, 0 };
var walk_tick: u32 = 0;

// TURN / RISE / DESCEND interpolation.
var dur: u32 = 1;
var from_yaw: Angle = 0;
var yaw_delta: i32 = 0;
var from_pos: Vec3 = @splat(0);
var to_pos: Vec3 = @splat(0);
var from_pitch: i32 = 0;
var to_pitch: i32 = 0;
var from_roll: i32 = 0;

// Roll animation (smiley flip, cap unroll): from `anim_from` by
// `anim_delta` over `anim_dur` ticks, smoothstep. Cap timer (SPEC decision
// 9) counts only while no animation runs and the roll is non-zero.
var roll_ticks: u32 = 0;
var animating: bool = false;
var anim_tick: u32 = 0;
var anim_dur: u32 = 1;
var anim_from: Angle = 0;
var anim_delta: i32 = 0;

// TELEPORT destination; `tele_manual`: the teleport started in MANUAL
// and returns there.
var tele_dest: [2]u8 = .{ 0, 0 };
var tele_dir: Dir = .n;
var tele_manual: bool = false;

/// Joystick directions, one snapshot per tick (main builds it from input).
pub const Stick = struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,

    fn first(s: Stick) ?Command {
        if (s.up) return .up;
        if (s.down) return .down;
        if (s.left) return .left;
        if (s.right) return .right;
        return null;
    }
};
const Command = enum { up, down, left, right };

// MANUAL (M4 takeover). `cell` / `walk_tick` / `dir` are shared with WALK;
// `dir` is the facing, `move_dir` the direction of motion (dir, or its
// opposite when Down walks back). Turns reuse from_yaw / yaw_delta / dur
// with `mtick` as the counter.
const Phase = enum { rest, walk, turn };
var phase: Phase = .rest;
var move_dir: Dir = .n;
var mtick: u32 = 0;
/// A stick press during a move or pivot, run at the next rest (one slot).
var queued: ?Command = null;
var stick_held: Stick = .{};
/// Ticks since a stick direction was last held (every state; saturates).
pub var manual_idle: u32 = 0;

pub fn cell_centre(x: u8, z: u8) Vec3 {
    return math.vec3(@as(f32, @floatFromInt(x)) + 0.5, camera.eye_height, @as(f32, @floatFromInt(z)) + 0.5);
}

/// Left-hand wall follower: left if open, else straight, else right, else back.
pub fn follow(m: *const maze.Maze, x: u8, z: u8, d: Dir) Dir {
    for ([_]Dir{ d.left(), d, d.right() }) |c| {
        if (!m.has_wall(x, z, c)) return c;
    }
    return d.opposite();
}

/// Short-way signed difference b - a; exactly 180 degrees goes clockwise
/// (increasing yaw).
fn short_delta(a: Angle, b: Angle) i32 {
    const d: i32 = @as(i16, @bitCast(b -% a));
    return if (d == -32768) 32768 else d;
}

fn signed(a: Angle) i32 {
    return @as(i16, @bitCast(a));
}

fn angle_at(from: Angle, delta: i32, t: f32) Angle {
    const off: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(delta)) * t));
    return from +% @as(Angle, @truncate(@as(u32, @bitCast(off))));
}

fn signed_at(from: i32, to: i32, t: f32) Angle {
    const v: i32 = from + @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(to - from)) * t)));
    return @bitCast(@as(i16, @intCast(std.math.clamp(v, -32768, 32767))));
}

fn enter(s: State) void {
    state = s;
    state_tick = 0;
}

/// Begin at the maze's start cell, camera already reset there: the maze
/// rises (GROW), then the walk starts.
pub fn begin_walk(m: *const maze.Maze) void {
    cell = m.start;
    dir = camera.start_facing(m);
    walk_tick = 0;
    enter(.grow);
}

/// Vertical scale of the maze: 0 -> 1 over GROW, 1 in every other state.
pub fn grow_scale() f32 {
    if (state != .grow) return 1.0;
    return @as(f32, @floatFromInt(@min(state_tick, grow_ticks))) * (1.0 / @as(f32, grow_ticks));
}

/// Leave FLY: snap to the nearest cell centre (clamped into the maze) at
/// eye height, heading = nearest quadrant, level, then WALK.
pub fn resume_walk(m: *const maze.Maze) void {
    const c = &camera.cam;
    const fx = std.math.clamp(@floor(c.pos[0]), 0, @as(f32, @floatFromInt(m.w - 1)));
    const fz = std.math.clamp(@floor(c.pos[2]), 0, @as(f32, @floatFromInt(m.h - 1)));
    cell = .{ @intFromFloat(fx), @intFromFloat(fz) };
    dir = camera.heading(c.yaw);
    c.* = .{ .pos = cell_centre(cell[0], cell[1]), .yaw = camera.dir_yaw(dir) };
    walk_tick = 0;
    animating = false;
    roll_ticks = 0;
    enter(.walk);
    decide(m);
}

pub fn toggle_fly(m: *const maze.Maze) void {
    if (state == .fly) {
        resume_walk(m);
    } else {
        name_strip_visible = false;
        enter(.fly);
    }
}

/// A / debug_skip: jump to PAUSE from wherever the camera is (GROW too,
/// so the intro can be cut short).
pub fn skip() void {
    if (walking() or state == .grow) enter(.pause);
}

/// WALK, TURN or MANUAL: the states where A skips and the smiley and the
/// sphere trigger.
pub fn walking() bool {
    return state == .walk or state == .turn or state == .manual;
}

pub fn set_roll(r: Angle) void {
    camera.cam.roll = r;
    roll_ticks = 0;
    animating = false;
}

fn start_roll(to: Angle, ticks: u32) void {
    anim_from = camera.cam.roll;
    anim_delta = short_delta(anim_from, to);
    anim_dur = ticks;
    anim_tick = 0;
    animating = true;
    roll_ticks = 0;
}

/// Smiley: roll the view by +180 degrees over flip_ticks (a flip while
/// rolled 180 rights the view again). Only in WALK, TURN and MANUAL; a flip
/// during a running roll animation adds 180 to where that animation was
/// heading.
pub fn flip() void {
    if (!walking()) return;
    const target = if (animating) anim_from +% @as(Angle, @truncate(@as(u32, @bitCast(anim_delta)))) else camera.cam.roll;
    start_roll(target +% math.deg(180), flip_ticks);
}

/// Sphere: fade out, move the camera to `dest` facing `d`, fade in, then
/// WALK (or MANUAL at rest if it started in MANUAL). Only from WALK, TURN
/// and MANUAL.
pub fn begin_teleport(dest: [2]u8, d: Dir) void {
    if (!walking()) return;
    tele_dest = dest;
    tele_dir = d;
    tele_manual = state == .manual;
    enter(.teleport);
}

/// Feeds this tick's stick (`held`, and `pressed` = went down this tick);
/// call before `step`, in every state but FLY. A press in WALK or TURN
/// takes over (MANUAL); in PAUSE, RISE, OVERHEAD, DESCEND and TELEPORT the
/// stick is ignored.
pub fn stick(m: *const maze.Maze, held: Stick, pressed: Stick) void {
    stick_held = held;
    if (held.first() != null) manual_idle = 0 else manual_idle +|= 1;
    const cmd = pressed.first() orelse return;
    switch (state) {
        .walk, .turn => enter_manual(m, cmd),
        .manual => manual_press(m, cmd),
        else => {},
    }
}

/// Takeover. From TURN the pivot finishes first; from WALK mid-cell the
/// camera keeps going to the next centre (Down reverses it back to the
/// cell it left, Up needs nothing more); at a centre the press runs at once.
fn enter_manual(m: *const maze.Maze, cmd: Command) void {
    const was = state;
    const t = state_tick;
    enter(.manual);
    queued = null;
    manual_idle = 0;
    if (was == .turn) {
        phase = .turn;
        mtick = t;
    } else if (walk_tick > 0) {
        phase = .walk;
        move_dir = dir;
        if (cmd == .up) return;
    } else {
        phase = .rest;
    }
    manual_press(m, cmd);
}

/// A press in MANUAL: while walking, the opposite of the motion reverses
/// it back to the cell it came from; anything else waits for the next rest.
fn manual_press(m: *const maze.Maze, cmd: Command) void {
    if (phase == .walk) {
        const fwd = move_dir == dir;
        if ((cmd == .down and fwd) or (cmd == .up and !fwd)) {
            cell = m.neighbour(cell[0], cell[1], move_dir) orelse cell;
            move_dir = move_dir.opposite();
            walk_tick = walk_ticks_per_cell - walk_tick;
            queued = null;
            return;
        }
    }
    queued = cmd;
}

/// MANUAL at a cell centre, level on a quadrant: run the queued press or
/// the held direction (held buttons repeat), a wall in the way is no move;
/// with nothing to do and `manual_idle_ticks` idle, back to WALK.
fn manual_rest(m: *const maze.Maze) void {
    phase = .rest;
    const cmd = queued orelse stick_held.first() orelse {
        if (manual_idle >= manual_idle_ticks) {
            walk_tick = 0;
            enter(.walk);
            decide(m);
        }
        return;
    };
    queued = null;
    switch (cmd) {
        .up, .down => {
            const md = if (cmd == .up) dir else dir.opposite();
            if (m.has_wall(cell[0], cell[1], md)) return;
            move_dir = md;
            walk_tick = 0;
            phase = .walk;
        },
        .left, .right => {
            const nd = if (cmd == .left) dir.left() else dir.right();
            from_yaw = camera.cam.yaw;
            yaw_delta = short_delta(from_yaw, camera.dir_yaw(nd));
            dur = turn90_ticks;
            dir = nd;
            mtick = 0;
            phase = .turn;
        },
    }
}

/// Reached a centre in MANUAL (walk, or teleport): finish -> PAUSE.
fn manual_arrive(m: *const maze.Maze) void {
    if (cell[0] == m.finish[0] and cell[1] == m.finish[1]) {
        enter(.pause);
        return;
    }
    manual_rest(m);
}

fn step_manual(m: *const maze.Maze) void {
    const c = &camera.cam;
    state_tick += 1;
    // A move started at rest takes its first step on the same tick, so a
    // press moves the camera at once and held moves never stall.
    if (phase == .rest) {
        manual_rest(m);
        if (state != .manual or phase == .rest) return;
    }
    switch (phase) {
        .walk => {
            walk_tick += 1;
            const s = @as(f32, @floatFromInt(walk_tick)) * (1.0 / @as(f32, walk_ticks_per_cell));
            const base = cell_centre(cell[0], cell[1]);
            c.pos = base + math.vec3(@floatFromInt(move_dir.dx()), 0, @floatFromInt(move_dir.dz())) * @as(Vec3, @splat(s));
            if (walk_tick >= walk_ticks_per_cell) {
                cell = m.neighbour(cell[0], cell[1], move_dir) orelse cell;
                c.pos = cell_centre(cell[0], cell[1]);
                walk_tick = 0;
                manual_arrive(m);
            }
        },
        .turn => {
            mtick += 1;
            const t = math.smoothstep01(@as(f32, @floatFromInt(mtick)) / @as(f32, @floatFromInt(dur)));
            c.yaw = angle_at(from_yaw, yaw_delta, t);
            if (mtick >= dur) {
                c.yaw = camera.dir_yaw(dir);
                manual_rest(m);
            }
        },
        .rest => {},
    }
}

pub fn teleport_dest() [2]u8 {
    return tele_dest;
}

/// Frame dissolve level 0..16 for overlay.fade: ramps up over TELEPORT
/// ticks 1..6 and back down over 7..12; 0 in every other state.
pub fn fade_level() u8 {
    if (state != .teleport) return 0;
    const t: u32 = @min(state_tick, teleport_ticks);
    const v = if (t <= teleport_move_tick) t * 16 / teleport_move_tick else 16 - (t - teleport_move_tick) * 16 / (teleport_ticks - teleport_move_tick);
    return @intCast(v);
}

/// At a cell centre: finish -> PAUSE, else pick the next heading.
fn decide(m: *const maze.Maze) void {
    if (cell[0] == m.finish[0] and cell[1] == m.finish[1]) {
        enter(.pause);
        return;
    }
    const nd = follow(m, cell[0], cell[1], dir);
    if (nd == dir) return;
    from_yaw = camera.cam.yaw;
    yaw_delta = short_delta(from_yaw, camera.dir_yaw(nd));
    dur = if (nd == dir.opposite()) turn180_ticks else turn90_ticks;
    dir = nd;
    enter(.turn);
}

/// One tick of the autopilot (every state but FLY, which main drives).
/// `r` regenerates the maze at OVERHEAD; `focal` is raster.focal.
pub fn step(m: *maze.Maze, r: *rng.Xorshift, focal: f32) void {
    const c = &camera.cam;
    switch (state) {
        .walk => {
            walk_tick += 1;
            const s = @as(f32, @floatFromInt(walk_tick)) * (1.0 / @as(f32, walk_ticks_per_cell));
            const base = cell_centre(cell[0], cell[1]);
            c.pos = base + math.vec3(@floatFromInt(dir.dx()), 0, @floatFromInt(dir.dz())) * @as(Vec3, @splat(s));
            if (walk_tick == walk_ticks_per_cell) {
                cell = m.neighbour(cell[0], cell[1], dir) orelse cell;
                c.pos = cell_centre(cell[0], cell[1]);
                walk_tick = 0;
                decide(m);
            }
        },
        .turn => {
            state_tick += 1;
            const t = math.smoothstep01(@as(f32, @floatFromInt(state_tick)) / @as(f32, @floatFromInt(dur)));
            c.yaw = angle_at(from_yaw, yaw_delta, t);
            if (state_tick >= dur) {
                c.yaw = camera.dir_yaw(dir);
                enter(.walk);
            }
        },
        .pause => {
            state_tick += 1;
            if (state_tick >= pause_ticks) enter_rise(m, focal);
        },
        .rise, .descend => {
            state_tick += 1;
            const t = math.smoothstep01(@as(f32, @floatFromInt(state_tick)) / @as(f32, @floatFromInt(dur)));
            c.pos = math.lerp(from_pos, to_pos, t);
            c.pitch = signed_at(from_pitch, to_pitch, t);
            c.roll = signed_at(from_roll, 0, t);
            c.yaw = angle_at(from_yaw, yaw_delta, t);
            if (state_tick >= dur) {
                c.pos = to_pos;
                c.pitch = @bitCast(@as(i16, @intCast(to_pitch)));
                c.roll = 0;
                c.yaw = from_yaw +% @as(Angle, @truncate(@as(u32, @bitCast(yaw_delta))));
                if (state == .rise) enter_overhead(m, r) else begin_walk(m);
            }
        },
        .grow => {
            state_tick += 1;
            if (state_tick >= grow_ticks) {
                enter(.walk);
                decide(m);
            }
        },
        .overhead => {
            state_tick += 1;
            m.reveal(@intCast(@min(@as(u32, m.carve_count), @as(u32, m.carve_count) * state_tick / carve_ticks)));
            if (state_tick >= overhead_ticks) enter_descend(m);
        },
        .teleport => {
            state_tick += 1;
            if (state_tick == teleport_move_tick) {
                cell = tele_dest;
                dir = tele_dir;
                walk_tick = 0;
                c.pos = cell_centre(cell[0], cell[1]);
                c.yaw = camera.dir_yaw(dir);
                c.pitch = 0;
            }
            if (state_tick >= teleport_ticks) {
                if (tele_manual) {
                    enter(.manual);
                    queued = null;
                    manual_idle = 0;
                    manual_arrive(m);
                } else {
                    enter(.walk);
                    decide(m);
                }
            }
        },
        .manual => step_manual(m),
        .fly => {},
    }
    if (walking() or state == .pause or state == .teleport) roll_cap();
}

/// Where RISE ends: the wall tops (y = 1, the nearest and so largest part
/// of the maze) fill a 96 px square at y = 4..100 on the 160x128 screen,
/// axis-aligned for yaw `y` (a multiple of 90 degrees).
pub fn overhead_point(m: *const maze.Maze, y: Angle, focal: f32) Vec3 {
    const w: f32 = @floatFromInt(m.w);
    const hc: f32 = @floatFromInt(m.h);
    const h = 1.0 + @max(w, hc) * 0.5 * focal / 48.0;
    const d = camera.heading(y);
    const shift = 12.0 * (h - 1.0) / focal;
    return math.vec3(w * 0.5 - @as(f32, @floatFromInt(d.dx())) * shift, h, hc * 0.5 - @as(f32, @floatFromInt(d.dz())) * shift);
}

fn enter_rise(m: *const maze.Maze, focal: f32) void {
    const c = &camera.cam;
    animating = false;
    roll_ticks = 0;
    from_pos = c.pos;
    from_pitch = signed(c.pitch);
    to_pitch = signed(math.deg(90));
    from_roll = signed(c.roll);
    from_yaw = c.yaw;
    // Yaw is unchanged unless A interrupted a TURN: then settle on the
    // nearest quadrant so the overhead view stays axis-aligned.
    const target_yaw = camera.dir_yaw(camera.heading(c.yaw));
    yaw_delta = short_delta(from_yaw, target_yaw);
    to_pos = overhead_point(m, target_yaw, focal);
    dur = rise_ticks;
    enter(.rise);
}

fn enter_overhead(m: *maze.Maze, r: *rng.Xorshift) void {
    m.generate(m.w, m.h, r);
    m.reveal(0);
    actors.reset(m, r, actors.cell_of(camera.cam.pos));
    cycles += 1;
    name_strip_visible = true;
    enter(.overhead);
}

fn enter_descend(m: *const maze.Maze) void {
    const c = &camera.cam;
    name_strip_visible = false;
    dir = camera.start_facing(m);
    from_pos = c.pos;
    to_pos = cell_centre(m.start[0], m.start[1]);
    from_pitch = signed(c.pitch);
    to_pitch = 0;
    from_roll = signed(c.roll);
    from_yaw = c.yaw;
    yaw_delta = short_delta(from_yaw, camera.dir_yaw(dir));
    dur = descend_ticks;
    enter(.descend);
}

/// Runs the roll animation; with none running, counts the ticks the roll
/// has been non-zero and after roll_cap_ticks unrolls over unroll_ticks
/// (short way, smoothstep).
fn roll_cap() void {
    const c = &camera.cam;
    if (animating) {
        anim_tick += 1;
        const t = math.smoothstep01(@as(f32, @floatFromInt(anim_tick)) / @as(f32, @floatFromInt(anim_dur)));
        c.roll = angle_at(anim_from, anim_delta, t);
        if (anim_tick >= anim_dur) {
            c.roll = anim_from +% @as(Angle, @truncate(@as(u32, @bitCast(anim_delta))));
            animating = false;
            roll_ticks = 0;
        }
        return;
    }
    if (c.roll == 0) {
        roll_ticks = 0;
        return;
    }
    roll_ticks += 1;
    if (roll_ticks >= roll_cap_ticks) start_roll(0, unroll_ticks);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const test_focal: f32 = 123.2; // raster.focal (raster.zig imports the cart API)

fn test_maze(seed: u32, n: u8) maze.Maze {
    var r = rng.Xorshift.init(seed);
    var m: maze.Maze = .{};
    m.generate(n, n, &r);
    return m;
}

/// Tests: begin at the start cell with the GROW intro already over.
fn begin_walk_now(m: *const maze.Maze) void {
    begin_walk(m);
    enter(.walk);
    decide(m);
}

test "GROW: the maze rises for 60 ticks at the start, then the walk begins; A cuts it short" {
    var m: maze.Maze = undefined;
    var r = rng.Xorshift.init(5);
    m.generate(8, 8, &r);
    camera.reset(&m);
    begin_walk(&m);
    try testing.expectEqual(State.grow, state);
    try testing.expectEqual(@as(f32, 0), grow_scale());
    const p0 = camera.cam.pos;
    for (0..grow_ticks / 2) |_| step(&m, &r, test_focal);
    try testing.expectEqual(State.grow, state);
    try testing.expectApproxEqAbs(@as(f32, 0.5), grow_scale(), 1e-6);
    try testing.expectEqual(p0, camera.cam.pos);
    for (0..grow_ticks / 2) |_| step(&m, &r, test_focal);
    try testing.expect(state == .walk or state == .turn);
    try testing.expectEqual(@as(f32, 1), grow_scale());
    camera.reset(&m);
    begin_walk(&m);
    skip();
    try testing.expectEqual(State.pause, state);
    try testing.expectEqual(@as(f32, 1), grow_scale());
}

test "wall follower reaches the finish within 2*(w*h-1) moves" {
    for (1..21) |seed| {
        const m = test_maze(@intCast(seed), 12);
        var x = m.start[0];
        var z = m.start[1];
        var d = camera.start_facing(&m);
        var moves: u32 = 0;
        while (!(x == m.finish[0] and z == m.finish[1])) {
            d = follow(&m, x, z, d);
            const nb = m.neighbour(x, z, d).?;
            x = nb[0];
            z = nb[1];
            moves += 1;
            try testing.expect(moves <= 2 * (12 * 12 - 1));
        }
    }
}

test "walk/turn simulation ends on the finish centre without drift" {
    var m = test_maze(1, 12);
    var r = rng.Xorshift.init(99);
    camera.reset(&m);
    begin_walk_now(&m);
    var moves: u32 = 0;
    var ticks: u32 = 0;
    var prev = state;
    while (state == .walk or state == .turn) : (ticks += 1) {
        const was_cell = cell;
        step(&m, &r, test_focal);
        if (cell[0] != was_cell[0] or cell[1] != was_cell[1]) moves += 1;
        // Every decision (entering TURN or PAUSE) happens exactly on a centre
        // with the yaw exactly on a quadrant.
        if (state != prev and state != .walk) {
            try testing.expectEqual(cell_centre(cell[0], cell[1]), camera.cam.pos);
        }
        if (state == .walk and walk_tick == 0) {
            try testing.expectEqual(cell_centre(cell[0], cell[1]), camera.cam.pos);
            try testing.expectEqual(camera.dir_yaw(dir), camera.cam.yaw);
        }
        prev = state;
        try testing.expect(ticks < 100_000);
    }
    try testing.expectEqual(State.pause, state);
    try testing.expectEqual(m.finish, cell);
    try testing.expectEqual(cell_centre(m.finish[0], m.finish[1]), camera.cam.pos);
    try testing.expect(moves <= 2 * (12 * 12 - 1));
}

test "turns: 90 in 20 ticks, 180 clockwise in 36" {
    try testing.expectEqual(@as(i32, 16384), short_delta(0, math.deg(90)));
    try testing.expectEqual(@as(i32, -16384), short_delta(0, math.deg(270)));
    try testing.expectEqual(@as(i32, 32768), short_delta(math.deg(90), math.deg(270)));
    try testing.expectEqual(@as(i32, 32768), short_delta(math.deg(270), math.deg(90)));
    try testing.expectEqual(math.deg(270), angle_at(0, -16384, 1.0));
}

fn project(c: *const camera.Camera, p: Vec3) [2]f32 {
    const v = c.to_view(c.basis(), p);
    return .{ 80 + test_focal * v[0] / v[2], 64 - test_focal * v[1] / v[2] };
}

test "rise and descend endpoints" {
    for ([_]u8{ 12, 16 }) |n| {
        var m = test_maze(1, n);
        var r = rng.Xorshift.init(5);
        camera.reset(&m);
        begin_walk_now(&m);
        var guard: u32 = 0;
        while (state != .rise) : (guard += 1) {
            step(&m, &r, test_focal);
            try testing.expect(guard < 100_000);
        }
        const yaw = camera.cam.yaw;
        try testing.expectEqual(@as(u16, 0), yaw & 0x3fff);
        for (0..rise_ticks) |_| step(&m, &r, test_focal);
        try testing.expectEqual(State.overhead, state);
        try testing.expect(name_strip_visible);
        try testing.expectEqual(overhead_point(&m, yaw, test_focal), camera.cam.pos);
        try testing.expectEqual(math.deg(90), camera.cam.pitch);
        try testing.expectEqual(yaw, camera.cam.yaw);
        const hexp: f32 = 1.0 + @as(f32, @floatFromInt(n)) * 0.5 * test_focal / 48.0;
        try testing.expectApproxEqAbs(hexp, camera.cam.pos[1], 1e-4);
        // The wall-top square lands on x = 32..128, y = 4..100.
        var lo: [2]f32 = .{ 1e9, 1e9 };
        var hi: [2]f32 = .{ -1e9, -1e9 };
        const fw: f32 = @floatFromInt(n);
        for ([_][2]f32{ .{ 0, 0 }, .{ fw, 0 }, .{ 0, fw }, .{ fw, fw } }) |q| {
            const s = project(&camera.cam, math.vec3(q[0], 1, q[1]));
            for (0..2) |i| {
                lo[i] = @min(lo[i], s[i]);
                hi[i] = @max(hi[i], s[i]);
            }
        }
        try testing.expectApproxEqAbs(@as(f32, 32), lo[0], 0.05);
        try testing.expectApproxEqAbs(@as(f32, 128), hi[0], 0.05);
        try testing.expectApproxEqAbs(@as(f32, 4), lo[1], 0.05);
        try testing.expectApproxEqAbs(@as(f32, 100), hi[1], 0.05);
        const c0 = cycles;
        for (0..overhead_ticks) |_| step(&m, &r, test_focal);
        try testing.expectEqual(State.descend, state);
        try testing.expect(!name_strip_visible);
        for (0..descend_ticks) |_| step(&m, &r, test_focal);
        try testing.expectEqual(State.grow, state);
        try testing.expectEqual(@as(f32, 0), grow_scale());
        for (0..grow_ticks) |_| step(&m, &r, test_focal);
        try testing.expect(state == .walk or state == .turn);
        try testing.expectEqual(@as(f32, 1), grow_scale());
        try testing.expectEqual(c0, cycles);
        try testing.expectEqual(cell_centre(m.start[0], m.start[1]), camera.cam.pos);
        try testing.expectEqual(@as(Angle, 0), camera.cam.pitch);
        try testing.expectEqual(camera.dir_yaw(camera.start_facing(&m)), camera.cam.yaw);
    }
}

test "skip during a turn settles overhead on a quadrant" {
    var m = test_maze(3, 12);
    var r = rng.Xorshift.init(5);
    camera.reset(&m);
    begin_walk_now(&m);
    var guard: u32 = 0;
    while (state != .turn) : (guard += 1) {
        step(&m, &r, test_focal);
        try testing.expect(guard < 100_000);
    }
    for (0..7) |_| step(&m, &r, test_focal);
    skip();
    try testing.expectEqual(State.pause, state);
    for (0..pause_ticks + rise_ticks) |_| step(&m, &r, test_focal);
    try testing.expectEqual(State.overhead, state);
    try testing.expectEqual(@as(u16, 0), camera.cam.yaw & 0x3fff);
}

test "roll cap unrolls after 1200 ticks" {
    camera.cam = .{};
    state = .pause;
    set_roll(math.deg(180));
    for (0..roll_cap_ticks - 1) |_| roll_cap();
    try testing.expectEqual(math.deg(180), camera.cam.roll);
    for (0..unroll_ticks + 1) |_| roll_cap();
    try testing.expectEqual(@as(Angle, 0), camera.cam.roll);
    try testing.expect(!animating);
}

test "flip reaches 180 in 30 ticks, the cap unrolls 1200 later, a second flip rights it" {
    var m = test_maze(1, 12);
    var r = rng.Xorshift.init(5);
    camera.reset(&m);
    begin_walk_now(&m);
    set_roll(0);
    flip();
    for (0..flip_ticks - 1) |_| step(&m, &r, test_focal);
    try testing.expect(camera.cam.roll != math.deg(180));
    step(&m, &r, test_focal);
    try testing.expectEqual(math.deg(180), camera.cam.roll);
    // Isolate the cap timer from the walk (which may reach PAUSE/RISE).
    state = .walk;
    for (0..roll_cap_ticks - 1) |_| roll_cap();
    try testing.expectEqual(math.deg(180), camera.cam.roll);
    for (0..unroll_ticks + 1) |_| roll_cap();
    try testing.expectEqual(@as(Angle, 0), camera.cam.roll);

    // Flip, then flip again at 180: back to 0 after another 30 ticks.
    flip();
    for (0..flip_ticks) |_| roll_cap();
    try testing.expectEqual(math.deg(180), camera.cam.roll);
    flip();
    for (0..flip_ticks - 1) |_| roll_cap();
    try testing.expect(camera.cam.roll != 0);
    roll_cap();
    try testing.expectEqual(@as(Angle, 0), camera.cam.roll);
    try testing.expect(!animating);

    // Ignored outside WALK/TURN.
    state = .pause;
    flip();
    try testing.expect(!animating);
}

test "teleport fades out, moves at tick 6, fades in and walks on" {
    var m = test_maze(1, 12);
    var r = rng.Xorshift.init(5);
    camera.reset(&m);
    begin_walk_now(&m);
    for (0..7) |_| step(&m, &r, test_focal);
    set_roll(math.deg(180));
    const dest: [2]u8 = .{ 5, 6 };
    var d: Dir = .n;
    for ([_]Dir{ .n, .e, .s, .w }) |o| {
        if (!m.has_wall(dest[0], dest[1], o)) d = o;
    }
    begin_teleport(dest, d);
    try testing.expectEqual(State.teleport, state);
    const want = [_]u8{ 0, 2, 5, 8, 10, 13, 16 };
    try testing.expectEqual(want[0], fade_level());
    for (want[1..], 1..) |lvl, t| {
        step(&m, &r, test_focal);
        try testing.expectEqual(lvl, fade_level());
        if (t < teleport_move_tick) try testing.expect(!std.meta.eql(cell_centre(dest[0], dest[1]), camera.cam.pos));
    }
    try testing.expectEqual(cell_centre(dest[0], dest[1]), camera.cam.pos);
    try testing.expectEqual(camera.dir_yaw(d), camera.cam.yaw);
    try testing.expectEqual(@as(Angle, 0), camera.cam.pitch);
    try testing.expectEqual(math.deg(180), camera.cam.roll);
    for (0..5) |_| step(&m, &r, test_focal);
    try testing.expectEqual(State.teleport, state);
    try testing.expectEqual(@as(u8, 3), fade_level());
    step(&m, &r, test_focal);
    try testing.expectEqual(@as(u8, 0), fade_level());
    try testing.expect(state == .walk or state == .turn);
    // A teleport request outside WALK/TURN is ignored.
    state = .pause;
    begin_teleport(dest, d);
    try testing.expectEqual(State.pause, state);
}

test "fly resume snaps to a centre and quadrant" {
    var m = test_maze(1, 12);
    camera.cam = .{ .pos = math.vec3(3.7, 2.0, 5.2), .yaw = math.deg(100), .pitch = math.deg(30) };
    state = .fly;
    toggle_fly(&m);
    try testing.expect(state == .walk or state == .turn);
    try testing.expectEqual(cell_centre(3, 5), camera.cam.pos);
    try testing.expectEqual(@as(Angle, 0), camera.cam.pitch);
}

// M4 takeover (MANUAL).

fn tick_stick(m: *maze.Maze, r: *rng.Xorshift, held: Stick, pressed: Stick) void {
    stick(m, held, pressed);
    step(m, r, test_focal);
}

/// MANUAL at rest in cell `c` facing `d`, idle timer at 0.
fn manual_at(c: [2]u8, d: Dir) void {
    cell = c;
    dir = d;
    walk_tick = 0;
    camera.cam = .{ .pos = cell_centre(c[0], c[1]), .yaw = camera.dir_yaw(d) };
    animating = false;
    queued = null;
    stick_held = .{};
    manual_idle = 0;
    phase = .rest;
    enter(.manual);
}

/// Steps the autopilot (no stick) until WALK with `walk_tick == k`.
fn walk_until(m: *maze.Maze, r: *rng.Xorshift, k: u32) void {
    var guard: u32 = 0;
    while (!(state == .walk and walk_tick == k)) : (guard += 1) {
        tick_stick(m, r, .{}, .{});
        std.debug.assert(guard < 100_000);
    }
}

test "takeover from WALK mid-cell continues to the next centre" {
    var m = test_maze(1, 12);
    var r = rng.Xorshift.init(5);
    camera.reset(&m);
    begin_walk_now(&m);
    walk_until(&m, &r, 10);
    const d = dir;
    const next = m.neighbour(cell[0], cell[1], d).?;
    tick_stick(&m, &r, .{ .left = true }, .{ .left = true });
    try testing.expectEqual(State.manual, state);
    for (0..19) |_| tick_stick(&m, &r, .{}, .{});
    // Arrived on tick 20 and the queued Left starts the pivot there.
    try testing.expectEqual(next, cell);
    try testing.expectEqual(cell_centre(next[0], next[1]), camera.cam.pos);
    try testing.expectEqual(State.manual, state);
    try testing.expectEqual(Phase.turn, phase);
    for (0..turn90_ticks) |_| tick_stick(&m, &r, .{}, .{});
    try testing.expectEqual(d.left(), dir);
    try testing.expectEqual(camera.dir_yaw(d.left()), camera.cam.yaw);
    try testing.expectEqual(cell_centre(next[0], next[1]), camera.cam.pos);
    try testing.expectEqual(Phase.rest, phase);
}

test "takeover during TURN finishes the turn first" {
    var m = test_maze(1, 12);
    var r = rng.Xorshift.init(5);
    camera.reset(&m);
    begin_walk_now(&m);
    var guard: u32 = 0;
    while (!(state == .turn and state_tick == 5)) : (guard += 1) {
        tick_stick(&m, &r, .{}, .{});
        try testing.expect(guard < 100_000);
    }
    const target = dir;
    const left = dur - 5;
    const pos = camera.cam.pos;
    tick_stick(&m, &r, .{ .up = true }, .{ .up = true });
    try testing.expectEqual(State.manual, state);
    for (1..left) |_| tick_stick(&m, &r, .{}, .{});
    try testing.expectEqual(camera.dir_yaw(target), camera.cam.yaw);
    try testing.expectEqual(pos, camera.cam.pos);
    // The queued Up walks forward (the follower chose an open heading).
    try testing.expectEqual(Phase.walk, phase);
    try testing.expectEqual(target, move_dir);
}

test "Down while walking reverses back to the cell it left, facing forward" {
    var m = test_maze(1, 12);
    var r = rng.Xorshift.init(5);
    camera.reset(&m);
    begin_walk_now(&m);
    walk_until(&m, &r, 10);
    const c0 = cell;
    const d = dir;
    tick_stick(&m, &r, .{ .down = true }, .{ .down = true });
    try testing.expectEqual(State.manual, state);
    for (0..8) |_| tick_stick(&m, &r, .{ .down = true }, .{});
    // Still moving: 9 of the 10 ticks back (the press tick moved one).
    try testing.expect(!std.meta.eql(cell_centre(c0[0], c0[1]), camera.cam.pos));
    tick_stick(&m, &r, .{}, .{});
    try testing.expectEqual(c0, cell);
    try testing.expectEqual(cell_centre(c0[0], c0[1]), camera.cam.pos);
    try testing.expectEqual(camera.dir_yaw(d), camera.cam.yaw);
    try testing.expectEqual(d, dir);
    try testing.expectEqual(Phase.rest, phase);
}

test "a wall blocks Up; held Up repeats through open cells" {
    var m = test_maze(1, 12);
    var r = rng.Xorshift.init(5);
    // A cell and heading with a wall ahead.
    var wc: [2]u8 = .{ 0, 0 };
    var wd: Dir = .n;
    for ([_]Dir{ .n, .e, .s, .w }) |o| {
        if (m.has_wall(wc[0], wc[1], o)) wd = o;
    }
    manual_at(wc, wd);
    for (0..60) |_| tick_stick(&m, &r, .{ .up = true }, .{});
    try testing.expectEqual(State.manual, state);
    try testing.expectEqual(cell_centre(wc[0], wc[1]), camera.cam.pos);
    try testing.expectEqual(camera.dir_yaw(wd), camera.cam.yaw);

    // Find a straight run of three open cells and walk it with Up held.
    found: for (0..12) |zi| {
        for (0..12) |xi| {
            for ([_]Dir{ .n, .e, .s, .w }) |o| {
                const x: u8 = @intCast(xi);
                const z: u8 = @intCast(zi);
                if (m.has_wall(x, z, o)) continue;
                const n1 = m.neighbour(x, z, o).?;
                if (m.has_wall(n1[0], n1[1], o)) continue;
                const n2 = m.neighbour(n1[0], n1[1], o).?;
                if (std.meta.eql(n1, m.finish) or std.meta.eql(n2, m.finish)) continue;
                wc = .{ x, z };
                wd = o;
                break :found;
            }
        }
    }
    manual_at(wc, wd);
    for (0..2 * walk_ticks_per_cell) |_| tick_stick(&m, &r, .{ .up = true }, .{});
    const n1 = m.neighbour(wc[0], wc[1], wd).?;
    const n2 = m.neighbour(n1[0], n1[1], wd).?;
    try testing.expectEqual(n2, cell);
    try testing.expectEqual(cell_centre(n2[0], n2[1]), camera.cam.pos);
}

test "idle return: 300 ticks without the stick, back to the wall follower" {
    var m = test_maze(1, 12);
    var r = rng.Xorshift.init(5);
    manual_at(m.start, camera.start_facing(&m));
    for (0..manual_idle_ticks - 1) |_| tick_stick(&m, &r, .{}, .{});
    try testing.expectEqual(State.manual, state);
    try testing.expectEqual(@as(u32, manual_idle_ticks - 1), manual_idle);
    tick_stick(&m, &r, .{}, .{});
    try testing.expect(state == .walk or state == .turn);
    // A held direction keeps the timer at 0.
    manual_at(m.start, camera.start_facing(&m));
    for (0..manual_idle_ticks + 50) |_| tick_stick(&m, &r, .{ .left = true }, .{});
    try testing.expectEqual(State.manual, state);
}

test "walking into the finish in MANUAL starts PAUSE" {
    var m = test_maze(1, 12);
    var r = rng.Xorshift.init(5);
    var o: Dir = .n;
    for ([_]Dir{ .n, .e, .s, .w }) |c| {
        if (!m.has_wall(m.finish[0], m.finish[1], c)) o = c;
    }
    const from = m.neighbour(m.finish[0], m.finish[1], o).?;
    manual_at(from, o.opposite());
    tick_stick(&m, &r, .{ .up = true }, .{ .up = true });
    for (1..walk_ticks_per_cell) |_| tick_stick(&m, &r, .{}, .{});
    try testing.expectEqual(State.pause, state);
    try testing.expectEqual(m.finish, cell);
    // A skips from MANUAL too.
    manual_at(m.start, camera.start_facing(&m));
    skip();
    try testing.expectEqual(State.pause, state);
}

test "a teleport from MANUAL returns to MANUAL with the idle timer restarted" {
    var m = test_maze(1, 12);
    var r = rng.Xorshift.init(5);
    manual_at(m.start, camera.start_facing(&m));
    for (0..100) |_| tick_stick(&m, &r, .{}, .{});
    const dest: [2]u8 = .{ 5, 6 };
    var d: Dir = .n;
    for ([_]Dir{ .n, .e, .s, .w }) |o| {
        if (!m.has_wall(dest[0], dest[1], o)) d = o;
    }
    begin_teleport(dest, d);
    try testing.expectEqual(State.teleport, state);
    for (0..teleport_ticks) |_| tick_stick(&m, &r, .{}, .{});
    try testing.expectEqual(State.manual, state);
    try testing.expectEqual(dest, cell);
    try testing.expectEqual(camera.dir_yaw(d), camera.cam.yaw);
    try testing.expect(manual_idle < 20);
    // The full idle wait again before the follower resumes.
    for (0..manual_idle_ticks - 1) |_| tick_stick(&m, &r, .{}, .{});
    try testing.expectEqual(State.manual, state);
    // flip() works in MANUAL.
    flip();
    try testing.expect(animating);
}
