//! Track B: the screensaver state machine (SPEC.md sections 3, 5, 6). Each
//! tick it advances the pipes and leaves a list of draw commands for main.zig
//! to run through the renderer. Pure logic, host-tested, no cart API.
//!
//! Timing is in quarters: a pipe grows one cell per 4 quarters and draws one
//! quarter of a cell's path (an s range of 0.25) per quarter. At speed 1x a
//! tick is one quarter (15 cells/s per pipe); Up/Down give 2x/4x/8x.
//!
//! A cell is drawn one cell behind its pipe's head: its exit is known only
//! once the next step is taken. When a pipe is boxed in, its head is drawn
//! as an end cell and the slot respawns `respawn_quarters` later. Every cell
//! that starts drawing also goes into the history ring, in draw order, so an
//! orbit (state `rebuild`) can redraw the scene from another angle and a
//! steered pipe (M3) can rewind.
const std = @import("std");
const grid = @import("grid.zig");
const camera = @import("camera.zig");
const rng = @import("rng.zig");
const draw = @import("render/draw.zig");

/// Stable numbers: debug_state returns these.
pub const State = enum(u8) { boot = 0, grow = 1, dissolve = 2, rebuild = 3 };

pub const Cmd = union(enum) {
    cell: struct { p: grid.Prim, s0: f32, s1: f32 },
    clear_all,
    clear_blocks: struct { from: u16, to: u16 },
};

/// Buttons as main.zig sees them this tick (held and rising edge).
pub const Input = struct {
    a: bool = false,
    b: bool = false,
    start: bool = false,
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
};

/// How turns are drawn (B cycles it). Mixed is the original's default:
/// elbows with a ball now and then, and the rare teapot.
pub const JointStyle = enum(u2) { mixed, elbow, ball };

// ---------------------------------------------------------------------------
// Knobs (SPEC sections 3, 5, 6, 7).

/// Pipes growing at once (SPEC decision 3).
pub const max_pipes = 3;
/// Quarters between a pipe's end cell finishing and its slot respawning
/// (20 ticks at 1x).
pub const respawn_quarters = 20;
/// Scene ends when this many cells are filled (45%).
pub const fill_end = grid.cell_count * 45 / 100;
/// ... or after this many failed spawn attempts in a row ...
pub const max_spawn_fails = 6;
/// ... or after this many growing ticks (75 s).
pub const scene_ticks = 75 * 60;
/// The block wipe between scenes (SPEC decision 5).
pub const dissolve_ticks = 60;
/// The name strip shows for this many ticks after a reset.
pub const boot_ticks = 120;
/// Mixed joints: 1 turn in `ball_odds` is a ball, the rest elbows.
pub const ball_odds = 4;
/// Mixed joints: 1 turn in `teapot_odds` is a teapot, at most one per scene.
pub const teapot_odds = 300;
/// Speeds 1x, 2x, 4x, 8x: quarters per tick = 1 << speed.
pub const max_speed = 3;
/// Orbit rebuild: history cells redrawn per tick (whole cells, each a few
/// hundred pixels at most; about 650 cells in a full scene).
pub const rebuild_cells_per_tick = 16;
/// History ring size (Prims). A scene never holds more than `cell_count`
/// cells, so the current scene is always whole in the ring.
pub const history_len = 2048;

pub const max_cmds = 64;

comptime {
    std.debug.assert(grid.cell_count <= history_len);
    std.debug.assert(history_len & (history_len - 1) == 0);
    std.debug.assert(max_pipes * (1 << max_speed) / 4 * 2 + 2 <= max_cmds);
    std.debug.assert(rebuild_cells_per_tick + 2 <= max_cmds);
}

// ---------------------------------------------------------------------------
// State.

const Status = enum(u2) {
    /// Counting `wait` down to a spawn attempt.
    waiting,
    /// The walker's head is live.
    alive,
    /// Boxed in: the end cell is still drawing.
    dying,
};

const Slot = struct {
    walker: grid.Pipe = .{},
    status: Status = .waiting,
    /// Quarters to wait before the next spawn attempt.
    wait: u16 = 0,
    /// The cell being drawn and how many of its quarters are done (4 = none
    /// left; the next quarter steps the walker).
    cell: grid.Prim = @bitCast(@as(u32, 0)),
    cell_q: u3 = 4,
    /// The cell was already drawn whole by a rebuild: skip its quarters.
    cell_drawn: bool = false,
};

pub var state: State = .boot;
pub var cam: camera.Camera = undefined;

var r: rng.Xorshift = rng.Xorshift.init(1);
var occ: grid.Occupancy = .{};
var slots: [max_pipes]Slot = @splat(.{});

/// Ticks since `reset`, frozen while paused (drives the name strip).
var life_tick: u32 = 0;
/// Growing ticks this scene (boot and grow states).
var scene_tick: u32 = 0;
var fail_streak: u8 = 0;
var teapot_this_scene: bool = false;
var dissolve_tick: u32 = 0;
/// Next history index the rebuild redraws.
var rebuild_pos: u32 = 0;

/// Scenes started since reset (1 after reset).
pub var scene: u32 = 0;
/// Pipes started this scene.
pub var pipes_started: u32 = 0;
/// Teapots drawn since boot (not cleared by reset).
pub var teapots: u32 = 0;
/// View index of the current scene and the orbit in eighths of a turn.
pub var view_index: u32 = 0;
pub var orbit: i32 = 0;
pub var joint_style: JointStyle = .mixed;
pub var speed: u2 = 0;
pub var paused: bool = false;
/// Debug: the next turn is a teapot, whatever the style and the cap.
pub var force_teapot: bool = false;

var hist: [history_len]grid.Prim = undefined;
/// Cells pushed since reset (the ring index is this mod `history_len`).
var hist_head: u32 = 0;
/// `hist_head` when the current scene started.
var scene_start: u32 = 0;

var cmds: [max_cmds]Cmd = undefined;
var cmd_len: usize = 0;

/// Restarts from a cleared screen: boot state, scene 1, seed-derived view.
/// Keeps the speed and joint style the viewer picked.
pub fn reset(seed: u32) void {
    r = rng.Xorshift.init(seed);
    life_tick = 0;
    scene = 0;
    hist_head = 0;
    paused = false;
    force_teapot = false;
    cmd_len = 0;
    view_index = r.below(camera.views.len);
    push(.clear_all);
    begin_scene();
    state = .boot;
}

/// Advances one 1/60 s tick. `pressed` holds rising edges.
pub fn step(held: Input, pressed: Input) void {
    _ = held;
    if (pressed.start) paused = !paused;
    if (paused) return;

    if (pressed.b) joint_style = @fromBackingInt(@intCast((@as(u8, @backingInt(joint_style)) + 1) % 3));
    if (pressed.up and speed < max_speed) speed += 1;
    if (pressed.down and speed > 0) speed -= 1;
    if (state != .dissolve) {
        if (pressed.a) {
            start_dissolve();
        } else if (pressed.left != pressed.right) {
            start_rebuild(if (pressed.left) -1 else 1);
        }
    }

    switch (state) {
        .boot, .grow => grow_tick(),
        .dissolve => dissolve_step(),
        .rebuild => rebuild_step(),
    }
    life_tick +%= 1;
    if (state == .boot and life_tick >= boot_ticks) state = .grow;
}

/// This tick's draw commands, in order.
pub fn commands() []const Cmd {
    return cmds[0..cmd_len];
}

/// Called by main.zig after running commands().
pub fn commands_done() void {
    cmd_len = 0;
}

/// True while the boot name strip is on screen.
pub fn name_strip() bool {
    return life_tick < boot_ticks;
}

/// Cells filled this scene.
pub fn filled() u32 {
    return occ.filled;
}

/// Pipes alive (growing or drawing their end cell).
pub fn alive() u32 {
    var n: u32 = 0;
    for (&slots) |*s| {
        if (s.status != .waiting) n += 1;
    }
    return n;
}

/// Cells of the current scene in the history ring, oldest first.
pub fn history_count() u32 {
    return hist_head - scene_start;
}

/// Cell `i` (0 = oldest) of the current scene.
pub fn history_at(i: u32) grid.Prim {
    return hist[(scene_start + i) & (history_len - 1)];
}

// ---------------------------------------------------------------------------
// Scenes.

fn begin_scene() void {
    scene += 1;
    occ.clear();
    // Staggered first spawns spread the pipes' steps over the quarters.
    for (&slots, 0..) |*s, i| s.* = .{ .wait = @intCast(i) };
    scene_tick = 0;
    fail_streak = 0;
    teapot_this_scene = false;
    pipes_started = 0;
    orbit = 0;
    scene_start = hist_head;
    cam = camera.view(view_index, orbit);
    state = if (life_tick < boot_ticks) .boot else .grow;
}

fn start_dissolve() void {
    state = .dissolve;
    dissolve_tick = 0;
}

fn dissolve_step() void {
    const n: u32 = draw.block_count;
    push(.{ .clear_blocks = .{
        .from = @intCast(dissolve_tick * n / dissolve_ticks),
        .to = @intCast((dissolve_tick + 1) * n / dissolve_ticks),
    } });
    dissolve_tick += 1;
    if (dissolve_tick >= dissolve_ticks) {
        // A new view, never the one just shown.
        const v = r.below(camera.views.len - 1);
        view_index = if (v >= view_index) v + 1 else v;
        begin_scene();
    }
}

/// Orbit by `delta` eighths of a turn and redraw the scene from the history
/// ring, `rebuild_cells_per_tick` cells a tick, growth paused meanwhile.
fn start_rebuild(delta: i32) void {
    orbit = @mod(orbit + delta, 8);
    cam = camera.view(view_index, orbit);
    push(.clear_all);
    rebuild_pos = scene_start;
    state = .rebuild;
}

fn rebuild_step() void {
    var n: u32 = 0;
    while (n < rebuild_cells_per_tick and rebuild_pos != hist_head) : (n += 1) {
        push(.{ .cell = .{ .p = hist[rebuild_pos & (history_len - 1)], .s0 = 0, .s1 = 1 } });
        rebuild_pos += 1;
    }
    if (rebuild_pos == hist_head) {
        // The cells still drawing are in the history, so they are whole now.
        for (&slots) |*s| s.cell_drawn = true;
        state = if (life_tick < boot_ticks) .boot else .grow;
    }
}

// ---------------------------------------------------------------------------
// Growth.

fn grow_tick() void {
    const quarters: u32 = @as(u32, 1) << speed;
    var ending = false;
    for (&slots) |*s| {
        for (0..quarters) |_| {
            if (!quarter(s)) {
                ending = true;
                break;
            }
        }
        if (ending) break;
    }
    scene_tick += 1;
    if (ending or occ.filled >= fill_end or scene_tick >= scene_ticks) start_dissolve();
}

/// One quarter of slot `s`. False if the scene must end (spawns keep failing).
fn quarter(s: *Slot) bool {
    switch (s.status) {
        .waiting => {
            if (s.wait > 0) {
                s.wait -= 1;
                return true;
            }
            if (!respawn(s)) return false;
        },
        .alive => if (s.cell_q >= 4) {
            const p = &s.walker;
            if (p.choose(&occ, &r, grid.turn_odds)) |d| {
                begin_cell(s, p.advance(&occ, d, if (p.turns(d)) pick_joint() else .ball));
            } else {
                begin_cell(s, p.head(.none, .ball));
                s.status = .dying;
            }
        },
        .dying => if (s.cell_q >= 4) {
            s.status = .waiting;
            s.wait = respawn_quarters - 1;
            return true;
        },
    }
    emit_quarter(s);
    return true;
}

/// Starts a pipe in slot `s` and takes its first step, so it has a start
/// cell to draw. Retries until a spawn works or `max_spawn_fails` in a row
/// have failed (false: the box is full enough, end the scene).
fn respawn(s: *Slot) bool {
    const color = pick_color();
    while (true) {
        if (grid.spawn(&occ, &r, color)) |p| {
            fail_streak = 0;
            pipes_started += 1;
            s.walker = p;
            s.status = .alive;
            const d = s.walker.choose(&occ, &r, grid.turn_odds).?; // spawn checked a free neighbour
            begin_cell(s, s.walker.advance(&occ, d, .ball));
            return true;
        }
        fail_streak += 1;
        if (fail_streak >= max_spawn_fails) return false;
    }
}

/// A colour no living pipe has, and if possible not a neighbour on the hue
/// wheel of one either (palette entries 0..12 are a wheel), so the pipes on
/// screen at once read as different colours.
fn pick_color() u4 {
    var used: u16 = 0;
    for (&slots) |*s| {
        if (s.status != .waiting) used |= @as(u16, 1) << s.walker.color;
    }
    var near = used;
    for (0..hue_wheel) |i| {
        if (used & (@as(u16, 1) << @intCast(i)) == 0) continue;
        near |= @as(u16, 1) << @intCast((i + 1) % hue_wheel);
        near |= @as(u16, 1) << @intCast((i + hue_wheel - 1) % hue_wheel);
    }
    if (@popCount(near) < 16) used = near;
    var k = r.below(16 - @popCount(used));
    var c: u5 = 0;
    while (c < 16) : (c += 1) {
        if (used & (@as(u16, 1) << @intCast(c)) != 0) continue;
        if (k == 0) break;
        k -= 1;
    }
    return @intCast(c);
}

const hue_wheel = 13;

fn pick_joint() grid.Joint {
    if (force_teapot) {
        force_teapot = false;
        return .teapot;
    }
    return switch (joint_style) {
        .elbow => .elbow,
        .ball => .ball,
        .mixed => blk: {
            const roll = r.below(teapot_odds);
            if (roll == 0 and !teapot_this_scene) break :blk .teapot;
            break :blk if (r.below(ball_odds) == 0) .ball else .elbow;
        },
    };
}

fn begin_cell(s: *Slot, p: grid.Prim) void {
    s.cell = p;
    s.cell_q = 0;
    s.cell_drawn = false;
    hist[hist_head & (history_len - 1)] = p;
    hist_head +%= 1;
    if (p.is_turn() and p.joint == .teapot) {
        teapot_this_scene = true;
        teapots += 1;
    }
}

/// Emits the next quarter of the slot's cell, merged into the previous
/// command when that was the same cell's preceding quarter (speeds > 1x).
fn emit_quarter(s: *Slot) void {
    const q = s.cell_q;
    s.cell_q += 1;
    if (s.cell_drawn) return;
    const s0 = @as(f32, @floatFromInt(q)) * 0.25;
    const s1 = @as(f32, @floatFromInt(q + 1)) * 0.25;
    if (cmd_len > 0) switch (cmds[cmd_len - 1]) {
        .cell => |*c| if (@as(u32, @bitCast(c.p)) == @as(u32, @bitCast(s.cell)) and c.s1 == s0) {
            c.s1 = s1;
            return;
        },
        else => {},
    };
    push(.{ .cell = .{ .p = s.cell, .s0 = s0, .s1 = s1 } });
}

fn push(c: Cmd) void {
    if (cmd_len < max_cmds) {
        cmds[cmd_len] = c;
        cmd_len += 1;
    }
}

// ---------------------------------------------------------------------------
// Tests.

const testing = std.testing;
const no_input: Input = .{};

fn run_ticks(n: u32) void {
    for (0..n) |_| {
        step(no_input, no_input);
        commands_done();
    }
}

/// Runs until `state` is `want` or `limit` ticks pass; false on timeout.
fn run_until(want: State, limit: u32) bool {
    for (0..limit) |_| {
        step(no_input, no_input);
        commands_done();
        if (state == want) return true;
    }
    return false;
}

test "boot shows the strip, grows, then hands over to grow" {
    reset(1);
    try testing.expectEqual(State.boot, state);
    try testing.expect(commands().len == 1 and commands()[0] == .clear_all);
    commands_done();
    try testing.expect(name_strip());
    run_ticks(boot_ticks);
    try testing.expectEqual(State.grow, state);
    try testing.expect(!name_strip());
    try testing.expectEqual(@as(u32, 1), scene);
    try testing.expectEqual(@as(u32, max_pipes), alive());
    try testing.expect(filled() > 60);
}

test "each tick draws consecutive quarters, one cell behind the head" {
    reset(3);
    commands_done();
    var last: [grid.cell_count]f32 = @splat(0);
    for (0..400) |_| {
        step(no_input, no_input);
        for (commands()) |c| switch (c) {
            .cell => |cell| {
                const i = grid.Occupancy.index(cell.p.x, cell.p.y, cell.p.z);
                try testing.expectEqual(last[i], cell.s0);
                try testing.expectEqual(cell.s0 + 0.25, cell.s1);
                last[i] = cell.s1;
                // Drawn cells are occupied and are never the start-and-end ball.
                try testing.expect(occ.get(cell.p.x, cell.p.y, cell.p.z));
                try testing.expect(cell.p.din != .none or cell.p.dout != .none);
            },
            else => {},
        };
        commands_done();
        if (state != .boot and state != .grow) break;
    }
}

test "the same seed gives the same history" {
    var a: [600]u32 = undefined;
    reset(42);
    run_ticks(600);
    const n = @min(history_count(), a.len);
    for (0..n) |i| a[i] = @bitCast(history_at(@intCast(i)));
    reset(42);
    run_ticks(600);
    try testing.expect(n > 100);
    for (0..n) |i| try testing.expectEqual(a[i], @as(u32, @bitCast(history_at(@intCast(i)))));
    reset(43);
    run_ticks(600);
    var differ = false;
    for (0..@min(n, history_count())) |i| differ = differ or a[i] != @as(u32, @bitCast(history_at(@intCast(i))));
    try testing.expect(differ);
}

test "history holds every filled cell of the scene, each once" {
    reset(9);
    run_ticks(500);
    var seen: grid.Occupancy = .{};
    for (0..history_count()) |i| {
        const p = history_at(@intCast(i));
        try testing.expect(!seen.get(p.x, p.y, p.z));
        seen.set(p.x, p.y, p.z);
        try testing.expect(occ.get(p.x, p.y, p.z));
    }
    // Filled = drawn cells plus the live heads not yet drawn.
    var heads: u32 = 0;
    for (&slots) |*s| {
        if (s.status == .alive) heads += 1;
    }
    try testing.expectEqual(@as(u32, occ.filled), history_count() + heads);
}

test "scenes end, dissolve over the whole screen and grow again with a new view" {
    for ([_]u32{ 1, 2, 3, 77 }) |seed| {
        reset(seed);
        commands_done();
        var prev_view = view_index;
        for (0..4) |ku| {
            const k: u32 = @intCast(ku);
            try testing.expect(run_until(.dissolve, scene_ticks + 10));
            try testing.expect(occ.filled <= grid.cell_count);
            try testing.expectEqual(@as(u32, k + 1), scene);
            var next: u32 = 0;
            var ticks: u32 = 0;
            while (state == .dissolve) : (ticks += 1) {
                step(no_input, no_input);
                for (commands()) |c| switch (c) {
                    .clear_blocks => |b| {
                        try testing.expectEqual(next, b.from);
                        next = b.to;
                    },
                    .cell => try testing.expect(false),
                    .clear_all => {},
                };
                commands_done();
            }
            try testing.expectEqual(@as(u32, dissolve_ticks), ticks);
            try testing.expectEqual(@as(u32, draw.block_count), next);
            try testing.expectEqual(State.grow, state);
            try testing.expectEqual(@as(u32, k + 2), scene);
            try testing.expectEqual(@as(u16, 0), occ.filled);
            try testing.expect(view_index != prev_view);
            prev_view = view_index;
        }
    }
}

test "the teapot cap holds and a forced teapot is drawn" {
    var total: u32 = 0;
    for (0..12) |seed| {
        reset(@intCast(seed + 100));
        for (0..6) |_| {
            const before = teapots;
            _ = run_until(.dissolve, scene_ticks + 10);
            try testing.expect(teapots - before <= 1);
            total += teapots - before;
            var n: u32 = 0;
            for (0..history_count()) |i| {
                if (history_at(@intCast(i)).joint == .teapot and history_at(@intCast(i)).is_turn()) n += 1;
            }
            try testing.expectEqual(teapots - before, n);
            _ = run_until(.grow, dissolve_ticks + 1);
        }
    }
    // About 2 scenes in 3 get one with ~200 turns each at 1 in 300.
    try testing.expect(total > 0);

    reset(5);
    joint_style = .elbow;
    const before = teapots;
    force_teapot = true;
    run_ticks(60);
    try testing.expectEqual(before + 1, teapots);
    try testing.expect(!force_teapot);
    joint_style = .mixed;
}

test "joint styles: elbow and ball modes draw only their joint" {
    for ([_]JointStyle{ .elbow, .ball }) |js| {
        reset(11);
        joint_style = js;
        run_ticks(400);
        var turns: u32 = 0;
        for (0..history_count()) |i| {
            const p = history_at(@intCast(i));
            if (!p.is_turn()) continue;
            turns += 1;
            try testing.expectEqual(if (js == .elbow) grid.Joint.elbow else grid.Joint.ball, p.joint);
        }
        try testing.expect(turns > 10);
    }
    joint_style = .mixed;
}

test "living pipes never share a colour" {
    reset(21);
    for (0..2000) |_| {
        run_ticks(1);
        for (0..max_pipes) |i| {
            for (i + 1..max_pipes) |j| {
                if (slots[i].status == .waiting or slots[j].status == .waiting) continue;
                try testing.expect(slots[i].walker.color != slots[j].walker.color);
            }
        }
    }
}

test "speed 8x draws two whole cells per pipe per tick" {
    reset(4);
    speed = max_speed;
    run_ticks(10);
    step(no_input, no_input);
    var quarters: f32 = 0;
    for (commands()) |c| switch (c) {
        .cell => |cell| quarters += (cell.s1 - cell.s0) * 4,
        else => {},
    };
    commands_done();
    try testing.expect(quarters >= 4 * 4 and quarters <= 8 * max_pipes);
    speed = 0;
}

test "orbit rebuilds the scene from history, then growth resumes" {
    reset(8);
    run_ticks(300);
    const cells = history_count();
    const filled_before = occ.filled;
    step(no_input, .{ .right = true });
    try testing.expectEqual(State.rebuild, state);
    try testing.expectEqual(@as(i32, 1), orbit);
    try testing.expect(commands()[0] == .clear_all);
    var redrawn: u32 = 0;
    for (commands()) |c| switch (c) {
        .cell => |cell| {
            try testing.expect(cell.s0 == 0 and cell.s1 == 1);
            redrawn += 1;
        },
        else => {},
    };
    commands_done();
    while (state == .rebuild) {
        step(no_input, no_input);
        for (commands()) |c| switch (c) {
            .cell => redrawn += 1,
            else => try testing.expect(false),
        };
        commands_done();
    }
    try testing.expectEqual(cells, redrawn);
    try testing.expectEqual(filled_before, occ.filled);
    try testing.expectEqual(State.grow, state);
    run_ticks(30);
    try testing.expect(occ.filled > filled_before);
    step(no_input, .{ .left = true });
    step(no_input, .{ .left = true });
    try testing.expectEqual(@as(i32, 7), orbit);
    commands_done();
}

test "A starts a new scene, Start pauses, B cycles joints, Up/Down set speed" {
    reset(6);
    run_ticks(200);
    step(no_input, .{ .start = true });
    commands_done();
    try testing.expect(paused);
    const f = occ.filled;
    run_ticks(50);
    try testing.expectEqual(f, occ.filled);
    step(no_input, .{ .start = true });
    try testing.expect(!paused);
    step(no_input, .{ .a = true });
    try testing.expectEqual(State.dissolve, state);
    try testing.expect(run_until(.grow, dissolve_ticks + 1));
    try testing.expectEqual(@as(u32, 2), scene);
    step(no_input, .{ .b = true });
    try testing.expectEqual(JointStyle.elbow, joint_style);
    step(no_input, .{ .b = true });
    step(no_input, .{ .b = true });
    try testing.expectEqual(JointStyle.mixed, joint_style);
    for (0..5) |_| step(no_input, .{ .up = true });
    try testing.expectEqual(@as(u2, max_speed), speed);
    for (0..5) |_| step(no_input, .{ .down = true });
    try testing.expectEqual(@as(u2, 0), speed);
    commands_done();
}

test "spawns give up after max_spawn_fails in a row, and the time cap ends a scene" {
    reset(13);
    commands_done();
    var s: Slot = .{};
    @memset(&occ.bits, std.math.maxInt(u32));
    try testing.expect(!respawn(&s));
    try testing.expectEqual(@as(u8, max_spawn_fails), fail_streak);

    reset(13);
    commands_done();
    run_ticks(10);
    scene_tick = scene_ticks - 1;
    run_ticks(1);
    try testing.expectEqual(State.dissolve, state);
}

test "a forced teapot in a rebuild-free run is a turn drawn as a teapot" {
    reset(17);
    run_ticks(130);
    force_teapot = true;
    const before = history_count();
    run_ticks(40);
    var found = false;
    for (before..history_count()) |i| {
        const p = history_at(@intCast(i));
        if (p.joint == .teapot) {
            try testing.expect(p.is_turn());
            found = true;
        }
    }
    try testing.expect(found);
}

test "every drawn cell connects to the cell its exit leads to" {
    reset(19);
    run_ticks(700);
    var din_at: [grid.cell_count]grid.Dir = @splat(.none);
    var in_hist: [grid.cell_count]bool = @splat(false);
    for (0..history_count()) |i| {
        const p = history_at(@intCast(i));
        const k = grid.Occupancy.index(p.x, p.y, p.z);
        in_hist[k] = true;
        din_at[k] = p.din;
    }
    for (&slots) |*s| {
        if (s.status != .alive) continue;
        const w = &s.walker;
        din_at[grid.Occupancy.index(w.x, w.y, w.z)] = w.din;
        in_hist[grid.Occupancy.index(w.x, w.y, w.z)] = true;
    }
    for (0..history_count()) |i| {
        const p = history_at(@intCast(i));
        if (p.dout == .none) continue;
        const n = grid.step_from(p.x, p.y, p.z, p.dout).?;
        const k = grid.Occupancy.index(n[0], n[1], n[2]);
        try testing.expect(in_hist[k]);
        try testing.expectEqual(p.dout, din_at[k]);
    }
}
