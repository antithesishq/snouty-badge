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
//! steered pipe can rewind.
//!
//! Steer mode (M3, the "Steer mode" section below): Select dissolves into a
//! run where one pipe is the player's, steered screen-relative, with two
//! autopilot pipes; a crash rewinds once, the second ends the run.
const std = @import("std");
const math = @import("math.zig");
const grid = @import("grid.zig");
const camera = @import("camera.zig");
const rng = @import("rng.zig");
const steer = @import("steer.zig");
const draw = @import("render/draw.zig");

/// Stable numbers: debug_state returns these. steer, rewind and game_over
/// are steer mode's (M3).
pub const State = enum(u8) { boot = 0, grow = 1, dissolve = 2, rebuild = 3, steer = 4, rewind = 5, game_over = 6 };

pub const Cmd = union(enum) {
    cell: struct { p: grid.Prim, s0: f32, s1: f32 },
    clear_all,
    clear_blocks: struct { from: u16, to: u16 },
    /// Steer mode: outline the back edges of the play box (world corners).
    frame: struct { lo: [3]f32, hi: [3]f32 },
};

/// Buttons as main.zig sees them this tick (held and rising edge).
pub const Input = struct {
    a: bool = false,
    b: bool = false,
    start: bool = false,
    select: bool = false,
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
};

/// How turns are drawn. Mixed is the original's default: elbows with a ball
/// now and then, and the rare teapot (mixed scenes only). Each screensaver
/// scene picks one at random, like the original's "Cycle" joint type
/// (Adrian, 2026-10-04: no button sets it; B is the nametag since M3).
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

/// Ticks since `reset`, frozen while paused (drives the boot state).
var life_tick: u32 = 0;
/// Ticks since the current screensaver scene started (the name strip shows
/// for the first `boot_ticks` of every scene, so people find steer mode).
var strip_tick: u32 = 0;
/// Where the running dissolve leads: a steer run or a screensaver scene.
var to_steer: bool = false;
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
/// Each scene draws `joint_style` from `style_rng` (tests turn this off to
/// pin a style). A separate stream, and `pick_joint` makes the same `r`
/// draws in every style, so a seed walks, colours and frames its scenes the
/// same whatever style each scene gets.
pub var random_style: bool = true;
var style_rng: rng.Xorshift = rng.Xorshift.init(1);
pub var speed: u2 = 0;
pub var paused: bool = false;
/// The nametag strip is up (B in the screensaver toggles it; it stays
/// through new scenes, wipes, orbits and speed changes, and entering steer
/// mode hides it).
pub var nametag: bool = false;
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
/// Keeps the speed the viewer picked.
pub fn reset(seed: u32) void {
    r = rng.Xorshift.init(seed);
    style_rng = rng.Xorshift.init(seed ^ 0x5bd1e995);
    life_tick = 0;
    scene = 0;
    hist_head = 0;
    paused = false;
    force_teapot = false;
    to_steer = false;
    cmd_len = 0;
    view_index = r.below(camera.views.len);
    push(.clear_all);
    begin_scene();
    state = .boot;
}

/// Advances one 1/60 s tick. `pressed` holds rising edges.
pub fn step(held: Input, pressed: Input) void {
    if (pressed.start) paused = !paused;
    if (paused) return;
    if (pressed.select) toggle_steer();
    if (steering()) {
        steer_step(held, pressed);
        return;
    }

    if (pressed.b) nametag = !nametag;
    if (pressed.up and speed < max_speed) speed += 1;
    if (pressed.down and speed > 0) speed -= 1;
    if (state != .dissolve) {
        if (pressed.a) {
            start_dissolve(false);
        } else if (pressed.left != pressed.right) {
            start_rebuild(if (pressed.left) -1 else 1);
        }
    }

    switch (state) {
        .boot, .grow => grow_tick(),
        .dissolve => dissolve_step(),
        .rebuild => rebuild_step(),
        .steer, .rewind, .game_over => unreachable,
    }
    life_tick +%= 1;
    strip_tick +%= 1;
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

/// True while the name strip is on screen: the first `boot_ticks` of every
/// screensaver scene (with "SELECT: STEER" under the title).
pub fn name_strip() bool {
    return strip_tick < boot_ticks and !steering() and !in_run and !nametag;
}

/// Cells filled this scene (or this steer run, walls not counted).
pub fn filled() u32 {
    return occ.filled - walls;
}

/// Pipes alive (growing or drawing their end cell; in a steer run, the
/// player and the living autopilots).
pub fn alive() u32 {
    var n: u32 = 0;
    if (in_run) {
        for (&run.runners) |*rn| {
            if (rn.live) n += 1;
        }
        return n;
    }
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
    strip_tick = 0;
    in_run = false;
    walls = 0;
    occ.clear();
    // Staggered first spawns spread the pipes' steps over the quarters.
    for (&slots, 0..) |*s, i| s.* = .{ .wait = @intCast(i) };
    scene_tick = 0;
    fail_streak = 0;
    teapot_this_scene = false;
    pipes_started = 0;
    orbit = 0;
    scene_start = hist_head;
    if (random_style) joint_style = @fromBackingInt(@intCast(style_rng.below(3)));
    cam = camera.view(view_index, orbit);
    state = if (life_tick < boot_ticks) .boot else .grow;
}

/// Starts the block wipe; at its end a steer run begins if `steer_next`,
/// else the next screensaver scene.
fn start_dissolve(steer_next: bool) void {
    state = .dissolve;
    dissolve_tick = 0;
    to_steer = steer_next;
}

fn dissolve_step() void {
    const n: u32 = draw.block_count;
    push(.{ .clear_blocks = .{
        .from = @intCast(dissolve_tick * n / dissolve_ticks),
        .to = @intCast((dissolve_tick + 1) * n / dissolve_ticks),
    } });
    dissolve_tick += 1;
    if (dissolve_tick >= dissolve_ticks) {
        if (to_steer) return begin_run();
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
    if (ending or occ.filled >= fill_end or scene_tick >= scene_ticks) start_dissolve(false);
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
    // Both rolls happen in every style so `r` advances the same way
    // whatever the scene's style (see `random_style`).
    const teapot_roll = r.below(teapot_odds);
    const ball_roll = r.below(ball_odds);
    return switch (joint_style) {
        .elbow => .elbow,
        .ball => .ball,
        .mixed => if (teapot_roll == 0 and !teapot_this_scene)
            .teapot
        else if (ball_roll == 0) .ball else .elbow,
    };
}

fn begin_cell(s: *Slot, p: grid.Prim) void {
    s.cell = p;
    s.cell_q = 0;
    s.cell_drawn = false;
    push_hist(p);
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

fn push_hist(p: grid.Prim) void {
    hist[hist_head & (history_len - 1)] = p;
    hist_head +%= 1;
}

fn push(c: Cmd) void {
    if (cmd_len < max_cmds) {
        cmds[cmd_len] = c;
        cmd_len += 1;
    }
}

// ---------------------------------------------------------------------------
// Steer mode (M3, PLAN.md "Plan: M3 (steer mode)").
//
// A run happens in a play box in the middle of the grid; the cells around
// it are walls (occupied from the start, never drawn; the box's back edges
// are outlined instead). Three runners grow through it: the player's pipe
// (runner 0, silver) and two autopilots. A runner moves continuously,
// `cell_units` per cell: it draws its head cell's in-half as it goes,
// picks the exit at the centre (the player: a buffered turn, a held
// direction or straight on; an autopilot: the walk), reserves the next
// cell and draws the out-half into it. So the drawn tip is exactly where
// the pipe is, with no cell of lag, and every turn is a ball joint (the
// in-half is straight whatever the exit). An exit into an occupied cell or
// the wall dooms the player: the out-half still grows to the face, then
// the run crashes. The first crash rewinds `rewind_cells` player cells
// (restore a snapshot, clear, regrow the scene from the history ring); the
// second ends the run.

/// The play box, cells [steer_lo, steer_hi): an 8-cube in the middle of the
/// grid, small enough that the whole box fills the screen with fat pipes.
pub const steer_lo = [3]u5{ 2, 1, 2 };
pub const steer_hi = [3]u5{ 10, 9, 10 };
pub const steer_cells: u32 = @as(u32, steer_hi[0] - steer_lo[0]) * (steer_hi[1] - steer_lo[1]) * (steer_hi[2] - steer_lo[2]);
const wall_cells: u16 = grid.cell_count - steer_cells;
/// Half extents of the play box in cells (the steer camera frames it).
const steer_half = [3]f32{
    @as(f32, steer_hi[0] - steer_lo[0]) * 0.5,
    @as(f32, steer_hi[1] - steer_lo[1]) * 0.5,
    @as(f32, steer_hi[2] - steer_lo[2]) * 0.5,
};
/// Progress units per cell; the exit is picked at `half_units`, the centre.
pub const cell_units: u16 = 240;
const half_units = cell_units / 2;
/// Player speed in cells per second: `start_rate`, +1 every `rate_step`
/// cells of score, at most `max_rate`. The autopilots keep the same pace.
pub const start_rate = 3;
pub const rate_step = 15;
pub const max_rate = 8;
/// Autopilot pipes beside the player's.
pub const autopilots = 2;
/// Autopilots stop respawning once this many cells of the box are filled,
/// so the player keeps some room.
pub const autopilot_fill = steer_cells * 40 / 100;
/// Ticks before an autopilot first spawns (times its index) and respawns.
pub const autopilot_wait = 40;
/// An autopilot never spawns within this many cells (city block) of the
/// player's head, so a pipe never appears right under the player's nose.
pub const spawn_clearance = 3;
/// The player's colour (silver), which no autopilot takes.
pub const player_color: u4 = 13;
/// A crash rewinds this many player cells.
pub const rewind_cells = 6;
/// Ticks the scene freezes on a crash before the rewind or the card.
pub const crash_ticks = 45;
/// Ticks everything holds before the player moves (run start, after a rewind).
pub const ready_ticks = 50;
/// The rewind regrow takes about this many ticks (between 1 and
/// `rebuild_cells_per_tick` cells a tick).
pub const regrow_ticks = 40;

comptime {
    std.debug.assert(@as(u32, max_rate) * cell_units / 60 < half_units);
    std.debug.assert((autopilots + 1) * 3 + 2 <= max_cmds);
}

const Event = enum { none, entered, crashed, died };

/// A pipe growing with no lag (steer mode).
const Runner = struct {
    walker: grid.Pipe = .{},
    live: bool = false,
    /// Progress through the head cell, 0..cell_units (the centre is half).
    pos: u16 = 0,
    /// The head cell's exit, picked at its centre (`none` before).
    exit: grid.Dir = .none,
    /// Player: the exit leads into an occupied cell or the wall.
    doomed: bool = false,
    /// Autopilot: ticks to the next spawn attempt.
    wait: u16 = 0,
};

/// Everything a rewind restores, besides occupancy, rng and history.
const Run = struct {
    /// 0 is the player.
    runners: [autopilots + 1]Runner = @splat(.{}),
    /// Cells the player has entered.
    score: u32 = 0,
    /// Ticks left before anything moves (READY).
    hold: u16 = 0,
};

/// The state at one of the player's cell entries.
const Snap = struct {
    occ: grid.Occupancy,
    r: rng.Xorshift,
    hist_head: u32,
    run: Run,
};

const snap_ring = rewind_cells + 1;

var run: Run = .{};
/// A steer run is on screen (from its start until the next screensaver
/// scene); main.zig draws with steer mode's fatter pipes meanwhile.
pub var in_run: bool = false;
/// Wall cells counted in `occ.filled` (steer runs only).
var walls: u16 = 0;
var queue: steer.TurnQueue = .{};
/// Controls held this tick, bit per `steer.Control`.
var held_ctrl: u8 = 0;
var snaps: [snap_ring]Snap = undefined;
/// Snapshots taken this run (the latest is the head cell's entry).
var snap_count: u32 = 0;
/// Ticks into the crash, rewind or game over sequence.
var phase_tick: u32 = 0;
var regrow_pos: u32 = 0;
var regrow_rate: u32 = 0;
/// Ticks since the run started (blinking).
var run_tick: u32 = 0;

/// The steer view of the current run and its control mapping.
pub var steer_view: u32 = 0;
pub var map: steer.Map = @splat(.none);
/// Crashes this run, rewinds left this run, best score this session.
pub var crashes: u32 = 0;
pub var rewinds_left: u32 = 0;
pub var best: u32 = 0;

/// True in steer mode's states and in the dissolve leading into a run.
pub fn steering() bool {
    return switch (state) {
        .steer, .rewind, .game_over => true,
        .dissolve => to_steer,
        else => false,
    };
}

/// Player cells this run.
pub fn score() u32 {
    return run.score;
}

/// The player's head cell.
pub fn head_cell() [3]u5 {
    const w = &run.runners[0].walker;
    return .{ w.x, w.y, w.z };
}

/// The direction the player is travelling: the head cell's exit once
/// picked, else the way it came in.
pub fn heading() grid.Dir {
    const pl = &run.runners[0];
    return if (pl.exit != .none) pl.exit else pl.walker.din;
}

/// True if cell (x, y, z) is occupied (walls included); for the steer bot.
pub fn occupied(x: u32, y: u32, z: u32) bool {
    if (x >= grid.nx or y >= grid.ny or z >= grid.nz) return true;
    return occ.get(x, y, z);
}

/// Select: into a steer run from the screensaver, back out from a run.
/// During a wipe it flips where the wipe leads.
fn toggle_steer() void {
    if (state == .dissolve) {
        to_steer = !to_steer;
    } else {
        start_dissolve(!steering());
    }
    if (to_steer) nametag = false;
}

fn steer_step(held: Input, pressed: Input) void {
    switch (state) {
        .dissolve => dissolve_step(),
        .steer => steer_tick(held, pressed),
        .rewind => rewind_tick(),
        .game_over => if (phase_tick < crash_ticks) {
            phase_tick += 1;
        } else if (pressed.a) start_dissolve(true),
        else => unreachable,
    }
    run_tick +%= 1;
    life_tick +%= 1;
}

fn begin_run() void {
    in_run = true;
    occ.clear();
    grid.fill_outside(&occ, steer_lo, steer_hi);
    walls = wall_cells;
    steer_view = r.below(camera.steer_views.len);
    cam = camera.steer_view(steer_view, steer_half);
    map = steer.map_for(&cam);
    scene_start = hist_head;
    pipes_started = 0;
    run = .{};
    crashes = 0;
    rewinds_left = 1;
    queue.clear();
    run_tick = 0;
    phase_tick = 0;
    push(.clear_all);
    push(frame_cmd());
    spawn_player();
    for (run.runners[1..], 1..) |*rn, i| rn.wait = @intCast(autopilot_wait * i);
    run.hold = ready_ticks;
    snap_count = 0;
    take_snapshot();
    state = .steer;
}

fn frame_cmd() Cmd {
    const lo = grid.cell_center(steer_lo[0], steer_lo[1], steer_lo[2]) - math.splat(0.5);
    const hi = grid.cell_center(steer_hi[0] - 1, steer_hi[1] - 1, steer_hi[2] - 1) + math.splat(0.5);
    return .{ .frame = .{ .lo = .{ lo[0], lo[1], lo[2] }, .hi = .{ hi[0], hi[1], hi[2] } } };
}

/// The player starts one cell in from the box's left side (as seen on
/// screen), centred on the other two axes, heading right.
fn spawn_player() void {
    const d = map[@backingInt(steer.Control.right)];
    var c: [3]u5 = undefined;
    for (0..3) |a| c[a] = (steer_lo[a] + steer_hi[a]) / 2;
    const a = d.axis();
    c[a] = if (d.sign() > 0) steer_lo[a] + 1 else steer_hi[a] - 2;
    const w: grid.Pipe = .{ .x = c[0], .y = c[1], .z = c[2], .heading = d, .color = player_color };
    occ.set(c[0], c[1], c[2]);
    start_runner(&run.runners[0], w, d);
}

/// Puts a fresh pipe `w` (its cell already occupied) in `rn`, leaving by
/// `d` (free): the start cell is half a cell long, centre to face.
fn start_runner(rn: *Runner, w: grid.Pipe, d: grid.Dir) void {
    rn.* = .{ .walker = w, .live = true, .pos = half_units, .exit = d };
    const n = w.neighbour(d).?;
    occ.set(n[0], n[1], n[2]);
    pipes_started += 1;
    const p = head_prim(rn);
    push_hist(p);
    // The start ball shows at once, even during READY.
    push(.{ .cell = .{ .p = p, .s0 = 0, .s1 = 0 } });
}

/// The head cell as drawn: straight until the exit is known (only the
/// in-half is drawn then), every turn a ball.
fn head_prim(rn: *const Runner) grid.Prim {
    const w = &rn.walker;
    return w.head(if (rn.exit != .none) rn.exit else w.din, .ball);
}

/// The draw parameter s of progress `pos` in cell `p`: a start cell runs
/// from the centre (s = 0) to the face.
fn s_at(p: grid.Prim, pos: u16) f32 {
    if (p.din == .none) return @as(f32, @floatFromInt(pos -| half_units)) * (1.0 / @as(f32, half_units));
    return @as(f32, @floatFromInt(pos)) * (1.0 / @as(f32, cell_units));
}

fn emit_range(rn: *const Runner, p0: u16, p1: u16) void {
    if (p1 <= p0) return;
    const p = head_prim(rn);
    push(.{ .cell = .{ .p = p, .s0 = s_at(p, p0), .s1 = s_at(p, p1) } });
}

/// Moves runner `rn` on by `rate` units, drawing what it covers.
fn advance_runner(rn: *Runner, player: bool, rate: u16) Event {
    var p0 = rn.pos;
    const p1 = p0 + rate;
    if (rn.exit == .none and p1 >= half_units) {
        emit_range(rn, p0, half_units);
        p0 = half_units;
        const d = if (player) player_choice() else rn.walker.choose(&occ, &r, grid.turn_odds);
        if (d) |dir| {
            rn.exit = dir;
            if (rn.walker.neighbour(dir)) |n| {
                if (occ.get(n[0], n[1], n[2])) rn.doomed = true else occ.set(n[0], n[1], n[2]);
            } else rn.doomed = true;
            push_hist(head_prim(rn));
        } else {
            // Boxed in: the pipe ends with a ball at the centre.
            const end = rn.walker.head(.none, .ball);
            push_hist(end);
            push(.{ .cell = .{ .p = end, .s0 = 1, .s1 = 1 } });
            rn.pos = half_units;
            rn.live = false;
            rn.wait = autopilot_wait;
            return .died;
        }
    }
    if (p1 >= cell_units) {
        emit_range(rn, p0, cell_units);
        rn.pos = cell_units;
        if (rn.doomed) return .crashed;
        _ = rn.walker.advance(&occ, rn.exit, .ball);
        rn.exit = .none;
        rn.pos = p1 - cell_units;
        emit_range(rn, 0, rn.pos);
        return .entered;
    }
    emit_range(rn, p0, p1);
    rn.pos = p1;
    return .none;
}

/// The player's exit at a centre: the oldest buffered turn, else a held
/// direction that turns, else straight on. Reversals never happen.
fn player_choice() ?grid.Dir {
    const din = run.runners[0].walker.din;
    while (queue.take()) |d| {
        if (d != din.opposite()) return d;
    }
    for (map, 0..) |d, i| {
        if (held_ctrl & (@as(u8, 1) << @intCast(i)) == 0) continue;
        if (d != din and d != din.opposite()) return d;
    }
    return din;
}

/// Player speed in progress units per tick.
pub fn player_rate() u16 {
    const cps: u16 = @intCast(@min(max_rate, start_rate + run.score / rate_step));
    return cps * (cell_units / 60);
}

fn controls(in: Input) [6]bool {
    return .{ in.up, in.down, in.left, in.right, in.a, in.b };
}

fn steer_tick(held: Input, pressed: Input) void {
    const pl = &run.runners[0];
    for (controls(pressed), 0..) |p, i| {
        if (p) queue.press(map[i], heading());
    }
    held_ctrl = 0;
    for (controls(held), 0..) |h, i| {
        if (h) held_ctrl |= @as(u8, 1) << @intCast(i);
    }
    if (run.hold > 0) {
        run.hold -= 1;
        return;
    }
    const rate = player_rate();
    var entered = false;
    switch (advance_runner(pl, true, rate)) {
        .crashed => return on_crash(),
        .entered => {
            run.score += 1;
            entered = true;
        },
        else => {},
    }
    for (run.runners[1..]) |*rn| autopilot_tick(rn, rate);
    if (entered) take_snapshot();
}

fn autopilot_tick(rn: *Runner, rate: u16) void {
    if (rn.live) {
        _ = advance_runner(rn, false, rate);
        return;
    }
    if (rn.wait > 0) {
        rn.wait -= 1;
        return;
    }
    if (filled() >= autopilot_fill) return;
    // One attempt a tick; a miss (taken, boxed in, too near) retries next tick.
    const w = grid.spawn_in(&occ, &r, autopilot_color(), steer_lo, steer_hi) orelse return;
    const h = head_cell();
    const dist = @abs(@as(i32, w.x) - h[0]) + @abs(@as(i32, w.y) - h[1]) + @abs(@as(i32, w.z) - h[2]);
    if (dist <= spawn_clearance) {
        occ.unset(w.x, w.y, w.z);
        return;
    }
    const d = w.choose(&occ, &r, grid.turn_odds).?; // spawn checked a free neighbour
    start_runner(rn, w, d);
}

/// A hue-wheel colour (never the player's silver) that no living autopilot
/// has, nor its neighbours on the wheel.
fn autopilot_color() u4 {
    var used: u16 = 0;
    for (run.runners[1..]) |*rn| {
        if (!rn.live) continue;
        const c: u16 = rn.walker.color;
        used |= @as(u16, 1) << @intCast(c);
        used |= @as(u16, 1) << @intCast((c + 1) % hue_wheel);
        used |= @as(u16, 1) << @intCast((c + hue_wheel - 1) % hue_wheel);
    }
    const free: u32 = hue_wheel - @popCount(used & ((1 << hue_wheel) - 1));
    var k = r.below(free);
    var c: u5 = 0;
    while (c < hue_wheel) : (c += 1) {
        if (used & (@as(u16, 1) << @intCast(c)) != 0) continue;
        if (k == 0) break;
        k -= 1;
    }
    return @intCast(c);
}

fn take_snapshot() void {
    snaps[snap_count % snap_ring] = .{ .occ = occ, .r = r, .hist_head = hist_head, .run = run };
    snap_count += 1;
}

fn on_crash() void {
    crashes += 1;
    phase_tick = 0;
    queue.clear();
    if (rewinds_left > 0) {
        state = .rewind;
    } else {
        best = @max(best, run.score);
        state = .game_over;
    }
}

/// Freeze on the crash, then restore the snapshot from `rewind_cells`
/// player cells ago, clear and regrow the scene from the history ring (the
/// visible rewind), then READY and play on.
fn rewind_tick() void {
    phase_tick += 1;
    if (phase_tick < crash_ticks) return;
    if (phase_tick == crash_ticks) {
        restore_snapshot();
        push(.clear_all);
        push(frame_cmd());
        regrow_pos = scene_start;
        regrow_rate = std.math.clamp((history_count() + regrow_ticks - 1) / regrow_ticks, 1, rebuild_cells_per_tick);
    }
    var n: u32 = 0;
    while (n < regrow_rate and regrow_pos != hist_head) : (n += 1) {
        const p = hist[regrow_pos & (history_len - 1)];
        regrow_pos += 1;
        push(.{ .cell = .{ .p = p, .s0 = 0, .s1 = drawn_s(p) } });
    }
    if (regrow_pos != hist_head) return;
    // Heads whose exit is not picked yet are not in the history: their
    // in-halves so far.
    for (&run.runners) |*rn| {
        if (rn.live and rn.exit == .none) emit_range(rn, 0, rn.pos);
    }
    run.hold = ready_ticks;
    state = .steer;
}

/// How much of history cell `p` the regrow draws: all of it, unless it is
/// a runner's head cell, which is drawn as far as that runner has got.
fn drawn_s(p: grid.Prim) f32 {
    for (&run.runners) |*rn| {
        const w = &rn.walker;
        if (rn.live and rn.exit != .none and w.x == p.x and w.y == p.y and w.z == p.z) return s_at(p, rn.pos);
    }
    return 1;
}

fn restore_snapshot() void {
    const k = snap_count - 1;
    const t = if (k >= rewind_cells) k - rewind_cells else 0;
    const s = &snaps[t % snap_ring];
    occ = s.occ;
    r = s.r;
    hist_head = s.hist_head;
    run = s.run;
    snap_count = t + 1;
    rewinds_left -= 1;
    queue.clear();
}

/// What the overlay shows over a steer run.
pub const Banner = enum { none, ready, crash, rewind };
pub const SteerOverlay = struct {
    score: u32,
    rewind_token: bool,
    banner: Banner,
    /// The head marker's screen position (null = hidden this tick).
    marker: ?[2]i32,
    /// Where the head is over the floor: a spot on the floor straight
    /// under the tip (null = hidden).
    shadow: ?[2]i32,
    /// The marker shows the crash (red).
    crash: bool,
    /// The game-over card (score, best).
    card: bool,
    best: u32,
};

/// The overlay for this tick, null outside a run (and in the wipes).
pub fn steer_overlay() ?SteerOverlay {
    if (!in_run or state == .dissolve) return null;
    var o: SteerOverlay = .{
        .score = run.score,
        .rewind_token = rewinds_left > 0,
        .banner = .none,
        .marker = null,
        .shadow = null,
        .crash = false,
        .card = false,
        .best = best,
    };
    var show_marker = false;
    var show_shadow = true;
    switch (state) {
        .steer => {
            if (run.hold > 0) o.banner = .ready;
            // On 2/3 of the time; steady while READY so the head is easy to find.
            show_marker = run.hold > 0 or run_tick % 24 < 16;
        },
        .rewind => if (phase_tick < crash_ticks) {
            o.banner = .crash;
            o.crash = true;
            show_marker = run_tick % 8 < 5;
        } else {
            o.banner = .rewind;
            show_shadow = false;
        },
        .game_over => if (phase_tick < crash_ticks) {
            o.banner = .crash;
            o.crash = true;
            show_marker = run_tick % 8 < 5;
        } else {
            o.card = true;
            show_shadow = false;
        },
        else => {},
    }
    const tip = head_tip();
    if (show_marker) o.marker = screen_point(tip);
    if (show_shadow) {
        // Down to the floor: the play box face opposite Up.
        const up = map[@backingInt(steer.Control.up)];
        const uv = up.vec();
        o.shadow = screen_point(tip - uv * math.splat(math.dot(tip, uv) + steer_half[up.axis()]));
    }
    return o;
}

fn screen_point(p: math.Vec3) ?[2]i32 {
    const s = cam.project(p);
    if (s[2] <= 0 or @abs(s[0]) > 1000 or @abs(s[1]) > 1000) return null;
    return .{ @intFromFloat(@round(s[0])), @intFromFloat(@round(s[1])) };
}

/// World position of the tip of the player's pipe.
fn head_tip() math.Vec3 {
    const pl = &run.runners[0];
    const p = head_prim(pl);
    const d = if (pl.exit != .none) pl.exit else pl.walker.din;
    const t = @as(f32, @floatFromInt(pl.pos)) * (1.0 / @as(f32, cell_units)) - 0.5;
    return p.center() + d.vec() * math.splat(t);
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
                    .cell, .frame => try testing.expect(false),
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

test "each scene picks a joint style at random; the style never moves the walk" {
    var seen: [3]bool = @splat(false);
    reset(31);
    run_ticks(boot_ticks + 10); // past BOOT, so each wipe ends in GROW
    for (0..12) |_| {
        seen[@backingInt(joint_style)] = true;
        step(no_input, .{ .a = true });
        try testing.expect(run_until(.grow, dissolve_ticks + 1));
    }
    for (seen) |hit| try testing.expect(hit);

    // Same seed, pinned styles: identical cells apart from the joint kind.
    var cells: [3][256]u32 = undefined;
    var counts: [3]u32 = undefined;
    random_style = false;
    defer random_style = true;
    for ([_]JointStyle{ .mixed, .elbow, .ball }, 0..) |js, k| {
        reset(32);
        joint_style = js;
        run_ticks(500);
        counts[k] = @min(history_count(), 256);
        for (0..counts[k]) |i| {
            var p = history_at(@intCast(i));
            p.joint = .ball;
            cells[k][i] = @bitCast(p);
        }
    }
    try testing.expectEqual(counts[0], counts[1]);
    try testing.expectEqual(counts[0], counts[2]);
    try testing.expectEqualSlices(u32, cells[0][0..counts[0]], cells[1][0..counts[1]]);
    try testing.expectEqualSlices(u32, cells[0][0..counts[0]], cells[2][0..counts[2]]);
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

test "A starts a new scene, Start pauses, B toggles the nametag, Up/Down set speed" {
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
    try testing.expect(!nametag);
    const style = joint_style;
    step(no_input, .{ .b = true });
    try testing.expect(nametag and !name_strip());
    try testing.expectEqual(style, joint_style);
    step(no_input, .{ .a = true }); // a new scene keeps it
    try testing.expect(run_until(.grow, dissolve_ticks + 1));
    try testing.expect(nametag);
    step(no_input, .{ .b = true });
    try testing.expect(!nametag);
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

// ---------------------------------------------------------------------------
// Steer mode tests.

/// Resets with `seed`, presses Select after a few ticks and runs the wipe:
/// a steer run in its READY hold.
fn enter_steer(seed: u32) !void {
    reset(seed);
    run_ticks(10);
    step(no_input, .{ .select = true });
    commands_done();
    try testing.expect(run_until(.steer, dissolve_ticks + 1));
}

/// The input that taps the control mapped to `d` (none if no control is).
fn press_dir(d: grid.Dir) Input {
    var in: Input = .{};
    for (map, 0..) |m, i| {
        if (m != d) continue;
        switch (i) {
            0 => in.up = true,
            1 => in.down = true,
            2 => in.left = true,
            3 => in.right = true,
            4 => in.a = true,
            else => in.b = true,
        }
    }
    return in;
}

/// A tiny pilot for tests: on entering a cell whose straight-on neighbour
/// is taken, tap a turn into a free one.
fn pilot_input() Input {
    const pl = &run.runners[0];
    if (pl.exit != .none or pl.pos >= half_units) return .{};
    const h = heading();
    if (pl.walker.can_move(&occ, h)) return .{};
    for (grid.all_dirs) |d| {
        if (d != h.opposite() and pl.walker.can_move(&occ, d)) return press_dir(d);
    }
    return .{};
}

test "Select dissolves into a run: READY, the player in silver, the map a permutation" {
    try enter_steer(31);
    try testing.expect(in_run and steering());
    try testing.expectEqual(@as(u32, 0), score());
    try testing.expectEqual(@as(u32, 1), rewinds_left);
    try testing.expectEqual(player_color, run.runners[0].walker.color);
    try testing.expectEqual(@as(u32, 2), filled()); // the start cell and the one it heads for
    try testing.expectEqual(map[@backingInt(steer.Control.right)], heading());
    var seen: u8 = 0;
    for (map) |d| seen |= @as(u8, 1) << @backingInt(d);
    try testing.expectEqual(@as(u8, 0x3F), seen);
    // Nothing moves while READY.
    const pos = run.runners[0].pos;
    run_ticks(ready_ticks - 1);
    try testing.expectEqual(pos, run.runners[0].pos);
    run_ticks(2);
    try testing.expect(run.runners[0].pos != pos);
    // Select leads back out to the screensaver.
    step(no_input, .{ .select = true });
    try testing.expectEqual(State.dissolve, state);
    try testing.expect(run_until(.grow, dissolve_ticks + 1));
    try testing.expect(!in_run and !steering());
    try testing.expectEqual(@as(u32, 0), walls);
}

test "speed: 3 cells/s, +1 every 15 cells, at most 8" {
    try enter_steer(1);
    for ([_][2]u32{ .{ 0, 3 }, .{ 14, 3 }, .{ 15, 4 }, .{ 74, 7 }, .{ 75, 8 }, .{ 900, 8 } }) |c| {
        run.score = c[0];
        try testing.expectEqual(@as(u16, @intCast(c[1] * cell_units / 60)), player_rate());
    }
}

test "the player's tip is drawn where the pipe is, every tick" {
    try enter_steer(5);
    for (0..600) |_| {
        const held_back = run.hold > 0;
        step(pilot_input(), pilot_input());
        if (state != .steer) break;
        const pl = &run.runners[0];
        var last: ?Cmd = null;
        for (commands()) |c| switch (c) {
            .cell => |cell| if (cell.p.color == player_color) {
                last = c;
            },
            else => {},
        };
        commands_done();
        if (held_back) continue;
        const cell = last.?.cell; // the player moved, so it drew
        if (pl.pos == 0) {
            // Exactly on the face: the cell just left is drawn to its end.
            try testing.expectEqual(@as(f32, 1), cell.s1);
        } else {
            const h = head_cell();
            try testing.expectEqual(h, [3]u5{ cell.p.x, cell.p.y, cell.p.z });
            try testing.expectEqual(s_at(head_prim(pl), pl.pos), cell.s1);
        }
    }
    try testing.expect(score() > 20);
}

test "crash into a pipe: the head grows to the face first; reversals are ignored" {
    try enter_steer(7);
    const h = head_cell();
    const d = heading();
    // A reversal press does nothing.
    step(press_dir(d.opposite()), press_dir(d.opposite()));
    commands_done();
    try testing.expectEqual(@as(u2, 0), queue.len);
    // An obstacle two cells ahead: the player enters the next cell, picks
    // straight on at its centre (doomed), grows to the face and crashes.
    const n2 = grid.step_from(h[0], h[1], h[2], d).?;
    const n3 = grid.step_from(n2[0], n2[1], n2[2], d).?;
    occ.set(n3[0], n3[1], n3[2]);
    var ticks: u32 = 0;
    while (state == .steer and ticks < 400) : (ticks += 1) run_ticks(1);
    try testing.expectEqual(State.rewind, state);
    try testing.expectEqual(@as(u32, 1), score());
    try testing.expectEqual(@as(u32, 1), crashes);
    try testing.expectEqual(cell_units, run.runners[0].pos);
    try testing.expectEqual(n2, head_cell());
}

test "a turn waits for the centre; a held direction turns without a fresh press" {
    try enter_steer(9);
    run_ticks(ready_ticks + 1);
    // Wait for the player to enter a fresh cell.
    while (score() == 0) run_ticks(1);
    const pl = &run.runners[0];
    try testing.expect(pl.pos < half_units);
    const d = heading();
    const up = map[@backingInt(steer.Control.up)];
    try testing.expect(up != d and up != d.opposite());
    step(.{ .up = true }, .{ .up = true });
    commands_done();
    if (pl.pos < half_units) try testing.expectEqual(d, heading()); // not yet
    while (pl.exit == .none) run_ticks(1);
    try testing.expectEqual(up, heading());
    // Held, no edge: at the next centre it turns again.
    const right = map[@backingInt(steer.Control.right)];
    const s0 = score();
    while (score() == s0) {
        step(.{ .right = true }, .{});
        commands_done();
    }
    while (pl.exit == .none) {
        step(.{ .right = true }, .{});
        commands_done();
    }
    try testing.expectEqual(right, heading());
}

/// What a snapshot restores, for comparison.
const Seen = struct { occ: grid.Occupancy, r: u32, hist_head: u32, run: Run };

test "first crash rewinds 6 player cells to the exact snapshot, the second ends the run" {
    try enter_steer(3);
    var at: [128]?Seen = @splat(null);
    at[0] = .{ .occ = occ, .r = r.state, .hist_head = hist_head, .run = run };
    // Fly with the pilot until score 12, then straight on into whatever.
    while (state == .steer) {
        const in = if (score() < 12) pilot_input() else Input{};
        const before = score();
        step(in, in);
        commands_done();
        if (state == .steer and score() != before) at[score()] = .{ .occ = occ, .r = r.state, .hist_head = hist_head, .run = run };
    }
    try testing.expectEqual(State.rewind, state);
    const k = score();
    try testing.expect(k >= 12);
    try testing.expectEqual(@as(u32, 1), rewinds_left);
    // The freeze, then the regrow: a clear, the frame, every history cell.
    var cleared = false;
    var cells: u32 = 0;
    while (state == .rewind) {
        step(no_input, no_input);
        for (commands()) |c| switch (c) {
            .clear_all => cleared = true,
            .cell => cells += 1,
            .frame => try testing.expect(cleared),
            .clear_blocks => try testing.expect(false),
        };
        commands_done();
    }
    try testing.expect(cleared);
    try testing.expectEqual(State.steer, state);
    try testing.expectEqual(k - rewind_cells, score());
    try testing.expectEqual(@as(u32, 0), rewinds_left);
    const want = at[k - rewind_cells].?;
    try testing.expectEqual(want.occ.bits, occ.bits);
    try testing.expectEqual(want.occ.filled, occ.filled);
    try testing.expectEqual(want.r, r.state);
    try testing.expectEqual(want.hist_head, hist_head);
    try testing.expectEqual(want.run.score, run.score);
    for (want.run.runners, run.runners) |a, b| try testing.expectEqual(a, b);
    try testing.expectEqual(@as(u16, ready_ticks), run.hold);
    // Each history cell drawn once, the heads still mid-exit not at all.
    var mid: u32 = 0;
    for (&run.runners) |*rn| {
        if (rn.live and rn.exit == .none and rn.pos > 0) mid += 1;
    }
    try testing.expectEqual(history_count() + mid, cells);
    // No more steering: the second crash ends the run.
    try testing.expect(run_until(.game_over, 2000));
    try testing.expectEqual(@as(u32, 2), crashes);
    // The score rewinds with time: the card shows where the run ended.
    try testing.expectEqual(score(), best);
    const final = score();
    // A during the crash freeze does nothing; after it, A plays again.
    step(no_input, .{ .a = true });
    try testing.expectEqual(State.game_over, state);
    run_ticks(crash_ticks);
    try testing.expect(steer_overlay().?.card);
    step(no_input, .{ .a = true });
    try testing.expectEqual(State.dissolve, state);
    try testing.expect(run_until(.steer, dissolve_ticks + 1));
    try testing.expectEqual(@as(u32, 0), score());
    try testing.expectEqual(@as(u32, 1), rewinds_left);
    try testing.expectEqual(@as(u32, 0), crashes);
    try testing.expectEqual(final, best);
}

test "a long run: cells unique and in the box, autopilots never silver, filled adds up" {
    for ([_]u32{ 2, 4, 6 }) |seed| {
        try enter_steer(seed);
        var ticks: u32 = 0;
        while (state == .steer and ticks < 6000) : (ticks += 1) {
            const in = pilot_input();
            step(in, in);
            commands_done();
            for (run.runners[1..]) |*rn| {
                if (rn.live) try testing.expect(rn.walker.color != player_color and rn.walker.color < hue_wheel);
            }
        }
        try testing.expect(score() > 30);
        var seen: grid.Occupancy = .{};
        for (0..history_count()) |i| {
            const p = history_at(@intCast(i));
            try testing.expect(!seen.get(p.x, p.y, p.z));
            seen.set(p.x, p.y, p.z);
            try testing.expect(p.x >= steer_lo[0] and p.x < steer_hi[0]);
            try testing.expect(p.y >= steer_lo[1] and p.y < steer_hi[1]);
            try testing.expect(p.z >= steer_lo[2] and p.z < steer_hi[2]);
            try testing.expect(!p.is_turn() or p.joint == .ball);
        }
        // Filled = history cells, plus heads not yet in it, plus reserved cells.
        var extra: u32 = 0;
        for (&run.runners) |*rn| {
            if (!rn.live) continue;
            if (rn.exit == .none) extra += 1 else if (!rn.doomed) extra += 1;
        }
        try testing.expectEqual(filled(), history_count() + extra);
    }
}

test "the nametag hides on entering steer and the screensaver's B is the nametag" {
    reset(12);
    run_ticks(130);
    const style = joint_style;
    step(no_input, .{ .b = true });
    try testing.expect(nametag);
    try testing.expectEqual(style, joint_style);
    step(no_input, .{ .right = true }); // an orbit keeps it
    try testing.expect(nametag);
    step(no_input, .{ .select = true });
    try testing.expect(!nametag);
    try testing.expect(run_until(.steer, dissolve_ticks + 1));
    // B in a run is "out of the screen", never the nametag.
    run_ticks(ready_ticks);
    step(.{ .b = true }, .{ .b = true });
    try testing.expect(!nametag);
    commands_done();
}
