//! One race tick (SPEC 5): hover physics, tile attributes under the
//! footprint, rails, laps and sectors, the countdown. Deterministic and
//! integer-only; no cart API, so it runs in host tests. `simulate` is the
//! only writer of `world.w` during a race.
const std = @import("std");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const track = @import("track.zig");
const world = @import("world.zig");
const ai = @import("ai.zig");

const W = world.World;
const Machine = world.Machine;
const Buttons = world.Buttons;

pub var current: *const track.Track = &track.cold_aisle;

const world_mask: i32 = (1024 << fixed.Q) - 1;

/// Puts `count` machines on the track and starts the countdown: the
/// rivals (1..4) on a two-column grid behind the start line, the player
/// behind them (F-Zero style), the traffic (5..10) already cruising around
/// the lap, two per third. Deterministic.
/// Machine select (M5): the machine the player drives, an index into
/// `ai.player_machines` (0 ANTEATER = the base tuning) and the sprite drawn.
/// Meta-state set by the menu before `reset`.
pub var player_character: u8 = 0;

/// A solo race: the player in machine 0 on `player_character`.
pub fn reset(t: *const track.Track, count: u8) void {
    reset_humans(t, count, .{ world.player, world.no_human }, .{ player_character, 0 });
}

/// A link race (M6): the host's human in machine 0, the guest's in
/// machine 1 (a rival's slot), side by side in the back grid row.
pub fn reset_link(t: *const track.Track, picks: [2]u8) void {
    reset_humans(t, world.machine_count, .{ world.player, world.guest }, picks);
}

fn reset_humans(t: *const track.Track, count: u8, humans: [2]u8, picks: [2]u8) void {
    current = t;
    track.select(t);
    world.w = .{};
    world.w.humans = humans;
    world.w.picks = .{ picks[0] % @as(u8, ai.player_machines.len), picks[1] % @as(u8, ai.player_machines.len) };
    world.w.active_count = count;
    world.w.countdown = 4 * tuning.countdown_step;
    world.w.msg = @splat(.provisioning);
    world.w.msg_ticks = @splat(@intCast(tuning.countdown_step));
    world.w.lap_px = @intCast(lap_length(t));
    const n: usize = count;
    const ranked: usize = @min(n, tuning.traffic_first);
    var human_n: usize = 0;
    for (0..ranked) |i| human_n += @intFromBool(world.w.slot_of(i) != null);
    const rivals: usize = ranked - human_n;
    var rival_k: usize = 0;
    for (0..n) |i| {
        const m = &world.w.machines[i];
        m.* = .{};
        if (i < tuning.traffic_first) {
            // Grid: rival k (0-based) in row k / 2, column left/right; the
            // player one row behind the last rival row, in the middle (two
            // humans: side by side there, the host on the left).
            var row: i32 = undefined;
            var side: i32 = 0;
            if (world.w.slot_of(i)) |s| {
                row = @intCast((rivals + 1) / 2);
                if (human_n > 1) side = if (s == 0) -tuning.grid_side else tuning.grid_side;
            } else {
                row = @intCast(rival_k / 2);
                side = if (rival_k % 2 == 0) -tuning.grid_side else tuning.grid_side;
                rival_k += 1;
            }
            const p = line_point_behind(t, tuning.grid_first_row + row * tuning.grid_row_gap);
            place(m, p, side, 0);
            m.progress = nearest_sample(m, 0);
        } else {
            const k = i - tuning.traffic_first;
            const si = tuning.traffic_samples[k % tuning.traffic_samples.len];
            const s = t.sample(si);
            const c = ai.character(i);
            const lane = if (c.alternate_lane and (i & 1) != 0) -c.lane else c.lane;
            const cruise = @divTrunc(tuning.top_speed * @as(i32, c.speed_pct), 255);
            place(m, .{ .x = @as(i32, s.x) << fixed.Q, .y = @as(i32, s.y) << fixed.Q, .tangent = s.tangent }, lane, cruise);
            m.progress = si;
            m.thermal = tuning.traffic_thermal;
        }
        m.active = true;
    }
    for (n..world.machine_count) |i| world.w.machines[i].active = false;
    update_ranks();
}

const LinePoint = struct { x: i32, y: i32, tangent: fixed.Turn };

/// Length of segment i -> i+1 in Q8 world px.
fn segment_q8(t: *const track.Track, i: usize) i32 {
    const a = t.sample(i);
    const b = t.sample(i + 1);
    const dx = wrap_px(@as(i32, b.x) - @as(i32, a.x));
    const dy = wrap_px(@as(i32, b.y) - @as(i32, a.y));
    return @intCast(fixed.isqrt(@intCast((dx * dx + dy * dy) << 16)));
}

/// Lap length in world px: the sum of the 256 centerline segments.
pub fn lap_length(t: *const track.Track) i32 {
    var sum: i32 = 0;
    for (0..256) |i| sum += segment_q8(t, i);
    return sum >> 8;
}

/// The centerline point `dist` px behind sample 0 (interpolated), Q16.
fn line_point_behind(t: *const track.Track, dist: i32) LinePoint {
    var left: i32 = dist << 8;
    var i: usize = 0;
    while (true) {
        const prev = (i + 255) & 255;
        const seg = segment_q8(t, prev);
        if (left <= seg or seg == 0) {
            const a = t.sample(i);
            const b = t.sample(prev);
            const dx = wrap_px(@as(i32, b.x) - @as(i32, a.x));
            const dy = wrap_px(@as(i32, b.y) - @as(i32, a.y));
            const f: i64 = if (seg == 0) 0 else @divTrunc(@as(i64, left) << 16, seg); // Q16 fraction
            return .{
                .x = (@as(i32, a.x) << fixed.Q) + @as(i32, @intCast((dx * f))),
                .y = (@as(i32, a.y) << fixed.Q) + @as(i32, @intCast((dy * f))),
                .tangent = b.tangent +% @as(u16, @bitCast(@as(i16, @intCast((fixed.turn_diff(b.tangent, a.tangent) * (65536 - f)) >> 16)))),
            };
        }
        left -= seg;
        i = prev;
    }
}

/// Put a machine at a line point, `side` px to the right, moving at `spd` (Q16).
fn place(m: *Machine, p: LinePoint, side: i32, spd: i32) void {
    const tx = fixed.cos(p.tangent);
    const ty = fixed.sin(p.tangent);
    m.x = (p.x + (-ty) * side) & world_mask;
    m.y = (p.y + tx * side) & world_mask;
    m.heading = p.tangent;
    m.vx = fixed.mul(tx, spd);
    m.vy = fixed.mul(ty, spd);
}

inline fn wrap_px(d: i32) i32 {
    return ((d + 512) & 1023) - 512;
}

/// Simulate one solo tick with the player's buttons. Rivals drive themselves.
pub fn simulate(buttons: Buttons) void {
    simulate_humans(.{ buttons, .{} });
}

/// One tick of the World `w` (M6, the lockstep's `simulate`): the same
/// tick as `simulate_humans`, on any World (swapped through `world.w`, so
/// two badges' Worlds can run side by side in the host tests).
pub fn simulate_world(w: *W, inputs: [2]Buttons) void {
    if (w == &world.w) return simulate_humans(inputs);
    const saved = world.w;
    world.w = w.*;
    simulate_humans(inputs);
    w.* = world.w;
    world.w = saved;
}

/// Simulate one tick with each human slot's buttons (`World.humans`;
/// slot 1 is unused solo). Rivals and traffic drive themselves, and so
/// does a human's machine once it has finished or its partner left.
pub fn simulate_humans(inputs: [2]Buttons) void {
    var w = &world.w;
    w.rng = step_rng(w.rng);
    for (&w.msg, &w.msg_ticks) |*msg, *ticks| {
        if (ticks.* > 0) {
            ticks.* -= 1;
            if (ticks.* == 0) msg.* = .none;
        }
    }
    switch (w.phase) {
        .countdown => {
            w.countdown -= 1;
            const step = tuning.countdown_step;
            if (w.countdown == 3 * step) set_msg_all(.three, step) else if (w.countdown == 2 * step) set_msg_all(.two, step) else if (w.countdown == step) set_msg_all(.one, step) else if (w.countdown == 0) {
                w.phase = .racing;
                set_msg_all(.deploy, tuning.message_ticks);
            }
            // Machines sit still; the humans may lean. Up held through
            // DEPLOY does not fire an Overclock on the first tick.
            for (w.humans, 0..) |h, s| {
                if (h == world.no_human) continue;
                const b: Buttons = if (w.ai_drives[s]) .{} else inputs[s];
                w.machines[h].steer = steer_of(b);
                w.machines[h].up_was = b.up;
            }
        },
        .racing, .finished => {
            w.tick +%= 1;
            for (0..w.active_count) |i| {
                const m = &w.machines[i];
                if (!m.active) continue;
                var b: Buttons = undefined;
                if (w.slot_of(i)) |s| {
                    b = if (!m.finished and !w.ai_drives[s]) inputs[s] else ai.drive_human(m, i);
                } else b = ai.drive(m, i);
                step_machine(m, b, i);
            }
            collide_all();
            update_ranks();
        },
    }
}

/// The message bar of human slot `s`.
fn set_msg(s: u1, msg: world.Message, ticks: u32) void {
    world.w.msg[s] = msg;
    world.w.msg_ticks[s] = @intCast(ticks);
}

fn set_msg_all(msg: world.Message, ticks: u32) void {
    set_msg(0, msg, ticks);
    set_msg(1, msg, ticks);
}

/// The machine select character of human slot `s`.
fn human_char(s: u1) *const ai.Character {
    return &ai.player_machines[world.w.picks[s] % ai.player_machines.len];
}

/// The physics of machine `i`: a human's pick, or the AI character.
fn char_of(i: usize) *const ai.Character {
    return if (world.w.slot_of(i)) |s| human_char(s) else ai.character(i);
}

fn index_of(m: *const Machine) usize {
    return (@intFromPtr(m) - @intFromPtr(&world.w.machines[0])) / @sizeOf(Machine);
}

/// Every human's machine has finished (the race phase ends).
fn humans_finished() bool {
    for (world.w.humans) |h| {
        if (h != world.no_human and !world.w.machines[h].finished) return false;
    }
    return true;
}

fn step_rng(s: u32) u32 {
    var x = s;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return x;
}

fn steer_of(b: Buttons) i8 {
    return @as(i8, @intFromBool(b.right)) - @as(i8, @intFromBool(b.left));
}

/// Speed along the heading plus the lateral part, Q16.16.
pub fn speed(m: *const Machine) i32 {
    const vx64: i64 = m.vx;
    const vy64: i64 = m.vy;
    // sqrt(v^2) in Q16: sqrt((v^2) >> 16) << 8.
    const q: u32 = @intCast(@min((vx64 * vx64 + vy64 * vy64) >> fixed.Q, 0xFFFF_FFFF));
    return @intCast(fixed.isqrt(q) << 8);
}

/// Physics for one machine (SPEC 5.1 steps 1..5).
fn step_machine(m: *Machine, b: Buttons, index: usize) void {
    const up_edge = b.up and !m.up_was;
    m.up_was = b.up;
    if (m.hitstop > 0) {
        m.hitstop -= 1;
        if (m.hitstop == 0) {
            // A knockout leaves the race after its wreck (SPEC 5.5).
            if (m.ko) m.active = false else recover(m);
        }
        return;
    }
    if (m.immune > 0) m.immune -= 1;
    if (m.hit_by_player > 0) m.hit_by_player -= 1;
    if (m.shake > 0) m.shake -= 1;
    if (m.boost > 0) m.boost -= 1;
    // Overclock (SPEC 4, 5.2): the press edge, enough thermal, no boost running.
    if (up_edge and m.boost == 0 and m.thermal >= tuning.thermal_overclock_min) {
        // Floor at 1: Overclock alone never melts the machine down.
        m.thermal = @intCast(@max(1, @as(i32, m.thermal) - tuning.thermal_overclock));
        m.boost = tuning.overclock_ticks;
    }
    // A human drives the selected machine; rivals and traffic use their character.
    const human = world.w.slot_of(index) != null;
    const c = char_of(index);
    const in_air = m.hop > 0;
    if (in_air) m.hop -= 1;

    const hx = fixed.cos(m.heading);
    const hy = fixed.sin(m.heading);
    const spd = speed(m);
    m.steer = steer_of(b);

    // 1. Thrust and brake.
    if (b.a and (!m.finished or !human)) {
        var a = tuning.accel;
        if (c.top_q8 != 256) a = (a * c.top_q8) >> 8;
        if (m.boost > 0) a = @divTrunc(a * tuning.overclock_thrust, 256);
        m.vx += fixed.mul(hx, a);
        m.vy += fixed.mul(hy, a);
    }
    if (b.down and !in_air) {
        m.vx -= fixed.mul(m.vx, tuning.brake);
        m.vy -= fixed.mul(m.vy, tuning.brake);
    }
    // 2. Drag toward the terminal speed.
    const keep = if (m.boost > 0) tuning.drag_keep_overclock else tuning.drag_keep;
    m.vx = fixed.mul(m.vx, keep);
    m.vy = fixed.mul(m.vy, keep);
    if (m.on_throttled) {
        m.vx = fixed.mul(m.vx, tuning.throttled_keep);
        m.vy = fixed.mul(m.vy, tuning.throttled_keep);
    }
    // 3. Grip: along = v . h, lateral = v . right (right = (-hy, hx)).
    if (!in_air) {
        const along = fixed.mul(m.vx, hx) + fixed.mul(m.vy, hy);
        var lat = fixed.mul(m.vx, -hy) + fixed.mul(m.vy, hx);
        const tight = b.down and m.steer != 0;
        var g = if (m.on_throttled) tuning.grip_throttled else if (tight) tuning.grip_tight else tuning.grip;
        if (c.grip_q8 != 256) g = fixed.one - (((fixed.one - g) * c.grip_q8) >> 8);
        lat = fixed.mul(lat, g);
        m.vx = fixed.mul(along, hx) + fixed.mul(lat, -hy);
        m.vy = fixed.mul(along, hy) + fixed.mul(lat, hx);
        // 4. Yaw.
        if (m.steer != 0) {
            var rate = tuning.steer_rate;
            if (spd > tuning.steer_full_below) {
                // 100% at steer_full_below falling to steer_min_pct at top_speed.
                const span = tuning.top_speed - tuning.steer_full_below;
                const over = @min(spd - tuning.steer_full_below, span);
                const pct = 100 - @divTrunc((100 - tuning.steer_min_pct) * over, span);
                rate = @divTrunc(rate * pct, 100);
            }
            if (tight) rate = @divTrunc(rate * tuning.steer_tight_num, tuning.steer_tight_den);
            if (c.steer_q8 != 256) rate = (rate * c.steer_q8) >> 8;
            const d: i32 = rate * m.steer;
            m.heading +%= @bitCast(@as(i16, @intCast(d)));
        }
    }
    // 5. Move, then the floor under the four corners.
    const old_x = m.x;
    const old_y = m.y;
    m.x = (m.x +% m.vx) & world_mask;
    m.y = (m.y +% m.vy) & world_mask;
    m.on_throttled = false;
    m.on_cold = false;
    if (!in_air) resolve_tiles(m, old_x, old_y);
    update_progress(m, index);
}

/// Corner offsets of the 24x12 footprint for a heading, world px (not Q16).
fn corners(m: *const Machine) [4][2]i32 {
    const hx = fixed.cos(m.heading);
    const hy = fixed.sin(m.heading);
    const ax = (hx * tuning.half_len) >> fixed.Q;
    const ay = (hy * tuning.half_len) >> fixed.Q;
    const lx = (-hy * tuning.half_wid) >> fixed.Q;
    const ly = (hx * tuning.half_wid) >> fixed.Q;
    return .{
        .{ ax + lx, ay + ly },
        .{ ax - lx, ay - ly },
        .{ -ax + lx, -ay + ly },
        .{ -ax - lx, -ay - ly },
    };
}

/// Tile attributes under the corners: rails push back and reflect, a fully
/// off-track footprint is a fall, features flag the machine (SPEC 7).
fn resolve_tiles(m: *Machine, old_x: i32, old_y: i32) void {
    const cs = corners(m);
    var off_count: u8 = 0;
    var rail_hit = false;
    var nx: i32 = 0;
    var ny: i32 = 0;
    for (cs) |c| {
        const px = (m.x >> fixed.Q) + c[0];
        const py = (m.y >> fixed.Q) + c[1];
        const a = current.attr_at(px, py);
        switch (a) {
            .off => off_count += 1,
            .rail => {
                rail_hit = true;
                // Normal from the tile crossing of this corner since last tick.
                const ox = (old_x >> fixed.Q) + c[0];
                const oy = (old_y >> fixed.Q) + c[1];
                const crossed_x = (ox >> 3) != (px >> 3);
                const crossed_y = (oy >> 3) != (py >> 3);
                if (crossed_x and !crossed_y) {
                    nx += if (px > ox) -1 else 1;
                } else if (crossed_y and !crossed_x) {
                    ny += if (py > oy) -1 else 1;
                } else {
                    // Diagonal or no crossing (spawned inside): push away from the corner.
                    nx -= @as(i32, std.math.sign(c[0]));
                    ny -= @as(i32, std.math.sign(c[1]));
                }
            },
            .throttled => m.on_throttled = true,
            .cold => m.on_cold = true,
            .pad => if (m.boost < tuning.pad_ticks) {
                m.boost = tuning.pad_ticks;
            },
            .hop => if (m.hop == 0) {
                m.hop = tuning.hop_ticks;
            },
            .hot => if (m.immune == 0) {
                m.immune = tuning.immune_ticks;
                m.thermal -= @intCast(tuning.thermal_hot);
                m.shake = 6;
                // Knock sideways.
                const hx = fixed.cos(m.heading);
                const hy = fixed.sin(m.heading);
                const side: i32 = if ((world.w.rng & 1) == 0) 1 else -1;
                m.vx += fixed.mul(-hy, side << 15);
                m.vy += fixed.mul(hx, side << 15);
            },
            else => {},
        }
    }
    if (rail_hit) {
        if (nx == 0 and ny == 0) nx = 1;
        // Unit-ish normal (axis aligned or diagonal).
        const nxq: i32 = @as(i32, std.math.sign(nx)) << fixed.Q;
        const nyq: i32 = @as(i32, std.math.sign(ny)) << fixed.Q;
        // Back out of the rail: step along the normal until no corner is in a rail (max 8 px).
        var steps: u8 = 0;
        while (steps < 8 and any_rail(m)) : (steps += 1) {
            m.x = (m.x +% nxq) & world_mask;
            m.y = (m.y +% nyq) & world_mask;
        }
        // Reflect the normal velocity component with restitution; lose speed.
        const vn = fixed.mul(m.vx, nxq) + fixed.mul(m.vy, nyq);
        if (vn < 0) {
            const impact = -vn;
            m.vx -= fixed.mul(vn, (256 + tuning.rail_restitution) << 8);
            m.vy -= fixed.mul(vn, (256 + tuning.rail_restitution) << 8);
            m.vx = fixed.mul(m.vx, tuning.rail_speed_keep);
            m.vy = fixed.mul(m.vy, tuning.rail_speed_keep);
            m.thermal -= @intCast(@min(tuning.thermal_max, (impact * tuning.thermal_rail_per_speed) >> fixed.Q));
            m.shake = 4;
        }
    }
    if (off_count == 4) crash(m, .fall);
    if (m.on_cold) m.thermal = @intCast(@min(tuning.thermal_max, @as(i32, m.thermal) + tuning.thermal_cold_refill));
    if (m.thermal <= 0 and m.crash == .none) {
        m.thermal = 0;
        crash(m, .meltdown);
    }
}

fn any_rail(m: *const Machine) bool {
    for (corners(m)) |c| {
        if (current.attr_at((m.x >> fixed.Q) + c[0], (m.y >> fixed.Q) + c[1]) == .rail) return true;
    }
    return false;
}

/// Start the hit-stop; M3 turns this into the rewind decision. Another
/// machine a human hit within the credit window, still racing, is
/// knocked out instead (SPEC 5.5): it wrecks through the hit-stop and
/// leaves the race. Humans are never knocked out.
pub fn crash(m: *Machine, cause: world.Crash) void {
    const w = &world.w;
    m.crash = cause;
    m.hitstop = tuning.hitstop_ticks;
    m.vx = 0;
    m.vy = 0;
    const index = index_of(m);
    const slot = w.slot_of(index);
    if (slot == null and m.hit_by_player > 0 and !m.finished and !m.ko) {
        m.ko = true;
        m.boost = 0;
        const s: u1 = @intCast(m.hit_by & 1);
        w.kos[s] +|= 1;
        const h = w.humans[s];
        if (h != world.no_human and w.machines[h].crash == .none) {
            w.msg_who[s] = @intCast(index);
            set_msg(s, .ko, tuning.message_ticks);
        }
    }
    if (slot) |s| {
        set_msg(s, switch (cause) {
            .fall => .fall,
            .meltdown => .meltdown,
            .collision => .collision,
            .none => .none,
        }, tuning.message_ticks);
    }
}

/// After the hit-stop (M1/M2 without rewind): back on the centerline at
/// the current progress, stopped, immune, thermal topped up to a third.
fn recover(m: *Machine) void {
    const s = current.sample(m.progress);
    m.x = @as(i32, s.x) << fixed.Q;
    m.y = @as(i32, s.y) << fixed.Q;
    m.heading = s.tangent;
    m.vx = 0;
    m.vy = 0;
    m.hop = 0;
    m.boost = 0;
    m.immune = tuning.immune_ticks * 2;
    if (m.thermal < 334) m.thermal = 334;
    m.crash = .none;
}

/// Squared distance from the machine to sample i, in world px^2 (wrapping).
fn dist2_to_sample(m: *const Machine, i: usize) i32 {
    const s = current.sample(i);
    var dx = (m.x >> fixed.Q) - @as(i32, s.x);
    var dy = (m.y >> fixed.Q) - @as(i32, s.y);
    dx = ((dx + 512) & 1023) - 512;
    dy = ((dy + 512) & 1023) - 512;
    return dx * dx + dy * dy;
}

/// Nearest sample within +-window of `from` (whole ring when window is 0).
pub fn nearest_sample(m: *const Machine, from: u8) u8 {
    var best: usize = from;
    var best_d: i32 = std.math.maxInt(i32);
    const window: usize = 10;
    var k: usize = 0;
    while (k < 2 * window + 1) : (k += 1) {
        const i = (@as(usize, from) + 256 + k - window) & 255;
        const d = dist2_to_sample(m, i);
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    return @intCast(best);
}

/// Progress, sectors and laps from the centerline (SPEC 7).
fn update_progress(m: *Machine, index: usize) void {
    const old = m.progress;
    const new = nearest_sample(m, old);
    m.progress = new;
    const diff: i32 = @as(i32, new) - @as(i32, old);
    // Forward step (allowing the wrap 255 -> 0).
    const forward = (diff > 0 and diff < 128) or diff < -128;
    const backward = (diff < 0 and diff > -128) or diff > 128;
    if (forward) {
        if (old < 85 and new >= 85) m.sectors |= 1;
        if (old < 170 and new >= 170 and (m.sectors & 1) != 0) m.sectors |= 2;
        if (new < old) {
            // Crossed the start line forward.
            if (m.sectors == 3 and !m.finished and index < tuning.traffic_first) {
                const lap_time = world.w.tick -% m.lap_start;
                if (m.best_lap == 0 or lap_time < m.best_lap) m.best_lap = lap_time;
                m.lap_start = world.w.tick;
                m.lap += 1;
                const slot = world.w.slot_of(index);
                if (slot) |s| {
                    if (m.lap == tuning.laps - 1) set_msg(s, .final_lap, tuning.message_ticks);
                }
                if (m.lap >= tuning.laps) {
                    m.finished = true;
                    m.finish_tick = world.w.tick;
                    if (slot) |s| {
                        // The race ends when every human has finished.
                        if (humans_finished()) world.w.phase = .finished;
                        set_msg(s, .committed, 120);
                    }
                }
            }
            m.sectors = 0;
        }
    } else if (backward) {
        // Driving backwards over the line: no credit, and a forward recrossing needs the sectors again.
        if (new > old and (new - old) > 128) m.sectors = 0;
    }
}

// --- Machine against machine (SPEC 5.3) --------------------------------------

fn can_collide(m: *const Machine) bool {
    return m.active and m.hitstop == 0 and m.hop == 0 and m.crash == .none;
}

/// Circles of radius `machine_radius`: push apart by half the penetration
/// each, exchange 30% of the closing normal velocity, thermal damage.
fn collide_all() void {
    const w = &world.w;
    const n: usize = w.active_count;
    const r2: i32 = 2 * tuning.machine_radius;
    const reach: i32 = r2 << fixed.Q;
    const lim: i32 = (r2 << 8) * (r2 << 8);
    const half: i32 = 512 << fixed.Q;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const a = &w.machines[i];
        if (!can_collide(a)) continue;
        var j = i + 1;
        while (j < n) : (j += 1) {
            const b = &w.machines[j];
            if (!can_collide(b)) continue;
            const dx = ((b.x -% a.x +% half) & world_mask) - half;
            const dy = ((b.y -% a.y +% half) & world_mask) - half;
            if (dx >= reach or dx <= -reach or dy >= reach or dy <= -reach) continue;
            const dx8 = dx >> 8;
            const dy8 = dy >> 8;
            const d2 = dx8 * dx8 + dy8 * dy8;
            if (d2 >= lim) continue;
            contact(a, i, b, j, dx8, dy8, d2);
            if (!can_collide(a)) break;
        }
    }
}

fn contact(a: *Machine, ia: usize, b: *Machine, ib: usize, dx8: i32, dy8: i32, d2: i32) void {
    const dist: i32 = @intCast(fixed.isqrt(@intCast(d2))); // Q8
    // Unit normal from a to b, Q16 (straight along +x when centred).
    var nx: i32 = fixed.one;
    var ny: i32 = 0;
    if (dist > 0) {
        nx = @divTrunc(dx8 << 16, dist);
        ny = @divTrunc(dy8 << 16, dist);
    }
    // Push apart: half the penetration each.
    const pen8 = (2 * tuning.machine_radius << 8) - dist;
    const push = pen8 << 7; // Q16, half of pen8 << 8
    const px = fixed.mul(nx, push);
    const py = fixed.mul(ny, push);
    a.x = (a.x -% px) & world_mask;
    a.y = (a.y -% py) & world_mask;
    b.x = (b.x +% px) & world_mask;
    b.y = (b.y +% py) & world_mask;
    // Closing speed along the normal.
    const vna = fixed.mul(a.vx, nx) + fixed.mul(a.vy, ny);
    const vnb = fixed.mul(b.vx, nx) + fixed.mul(b.vy, ny);
    const closing = vna - vnb;
    if (closing <= 0) return;
    // Any push by a human credits a later crash of the other machine to
    // that human (SPEC 5.5). Solo, the player is always `a` (index 0
    // comes first); in a link race either side can be a human.
    const sa = world.w.slot_of(ia);
    const sb = world.w.slot_of(ib);
    if (sa) |s| {
        b.hit_by_player = tuning.ko_credit_ticks;
        b.hit_by = s;
    }
    if (sb) |s| {
        a.hit_by_player = tuning.ko_credit_ticks;
        a.hit_by = s;
    }
    const dv = (closing * tuning.collision_exchange) >> 8;
    a.vx -= fixed.mul(nx, dv);
    a.vy -= fixed.mul(ny, dv);
    b.vx += fixed.mul(nx, dv);
    b.vy += fixed.mul(ny, dv);
    if (closing < tuning.collision_min_speed) return;
    const ca = char_of(ia);
    const cb = char_of(ib);
    // Ram damage on the other machine when a human's own speed into it is
    // at least the other's share of the closing speed.
    var ram_b: i32 = 0;
    if (sa != null and vna >= -vnb) {
        ram_b = (closing * tuning.ram_damage_per_px) >> fixed.Q;
        if (a.boost > 0) ram_b = (ram_b * tuning.ram_overclock_q8) >> 8;
    }
    var ram_a: i32 = 0;
    if (sb != null and -vnb >= vna) {
        ram_a = (closing * tuning.ram_damage_per_px) >> fixed.Q;
        if (b.boost > 0) ram_a = (ram_a * tuning.ram_overclock_q8) >> 8;
    }
    hit(a, ca, ram_a);
    hit(b, cb, ram_b);
    if (sa != null and closing >= tuning.collision_crash_speed) crash(a, .collision);
    if (sb != null and closing >= tuning.collision_crash_speed) crash(b, .collision);
    for ([2]*Machine{ a, b }) |m| {
        if (m.thermal <= 0 and m.crash == .none) {
            m.thermal = 0;
            crash(m, .meltdown);
        }
    }
}

fn hit(m: *Machine, c: *const ai.Character, ram: i32) void {
    if (c.contact_keep != fixed.one) {
        m.vx = fixed.mul(m.vx, c.contact_keep);
        m.vy = fixed.mul(m.vy, c.contact_keep);
    }
    if (m.immune > 0) return;
    m.thermal = @intCast(@max(-tuning.thermal_max, @as(i32, m.thermal) - (tuning.thermal_collision + ram) * c.damage_mul));
    m.immune = tuning.collision_immune_ticks;
    m.shake = 4;
}

// --- Progress and rank (SPEC 7) ---------------------------------------------

/// Fine progress: lap * 65536 + sample * 256 + the fraction (0..255) of the
/// way to the next sample. Before the line is first crossed with sector 2
/// seen (the grid, or a lap in progress at samples >= 170 without sector 2)
/// the sample belongs to the previous lap.
pub fn fine_progress(m: *const Machine) i32 {
    var base: usize = m.progress;
    var a = current.sample(base);
    var b = current.sample(base + 1);
    var px = wrap_px((m.x >> fixed.Q) - @as(i32, a.x));
    var py = wrap_px((m.y >> fixed.Q) - @as(i32, a.y));
    var ex = wrap_px(@as(i32, b.x) - @as(i32, a.x));
    var ey = wrap_px(@as(i32, b.y) - @as(i32, a.y));
    var proj = px * ex + py * ey;
    if (proj < 0) {
        // Behind the nearest sample: on the previous segment.
        base = (base + 255) & 255;
        b = a;
        a = current.sample(base);
        px = wrap_px((m.x >> fixed.Q) - @as(i32, a.x));
        py = wrap_px((m.y >> fixed.Q) - @as(i32, a.y));
        ex = wrap_px(@as(i32, b.x) - @as(i32, a.x));
        ey = wrap_px(@as(i32, b.y) - @as(i32, a.y));
        proj = px * ex + py * ey;
    }
    const len2 = ex * ex + ey * ey;
    const frac: i32 = if (len2 == 0 or proj <= 0) 0 else @min(255, @divTrunc(proj * 256, len2));
    var lap: i32 = m.lap;
    if (base >= 170 and (m.sectors & 2) == 0) lap -= 1;
    return lap * 65536 + @as(i32, @intCast(base)) * 256 + frac;
}

/// Progress in world px along the centerline (the rubber band's measure).
pub fn progress_px(m: *const Machine) i32 {
    return @intCast((@as(i64, fine_progress(m)) * world.w.lap_px) >> 16);
}

/// Ranks 1..5 for machines 0..4 (never traffic): finished machines first in
/// finish order, then by fine progress, ties to the lower index. A
/// finished machine's rank is final: only machines that finished earlier
/// are ahead of it, so recomputing it gives the same value.
fn update_ranks() void {
    const w = &world.w;
    const n: usize = @min(w.active_count, tuning.ranked_count);
    var fine: [tuning.ranked_count]i32 = undefined;
    for (0..n) |i| fine[i] = if (w.machines[i].finished) 0 else fine_progress(&w.machines[i]);
    for (0..n) |i| {
        const m = &w.machines[i];
        if (!m.active) {
            m.rank = 0;
            continue;
        }
        var r: u8 = 1;
        for (0..n) |j| {
            if (j == i) continue;
            const o = &w.machines[j];
            if (!o.active) continue;
            const ahead = if (o.finished and m.finished)
                o.finish_tick < m.finish_tick or (o.finish_tick == m.finish_tick and j < i)
            else if (o.finished != m.finished)
                o.finished
            else
                fine[j] > fine[i] or (fine[j] == fine[i] and j < i);
            if (ahead) r += 1;
        }
        m.rank = r;
    }
}

/// Field-by-field comparison by comptime reflection (for the determinism
/// and restore tests): padding bytes are never read.
pub fn worlds_equal(a: *const W, b: *const W) bool {
    return eql(W, a, b);
}

fn eql(comptime T: type, a: *const T, b: *const T) bool {
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (s.layout == .@"packed") {
                const I = @Int(.unsigned, @bitSizeOf(T));
                return @as(I, @bitCast(a.*)) == @as(I, @bitCast(b.*));
            }
            inline for (s.field_names, s.field_types) |name, F| {
                if (!eql(F, &@field(a.*, name), &@field(b.*, name))) return false;
            }
            return true;
        },
        .array => |arr| {
            for (a, b) |*x, *y| {
                if (!eql(arr.child, x, y)) return false;
            }
            return true;
        },
        .@"enum", .bool, .int => return a.* == b.*,
        else => @compileError("worlds_equal: unsupported field type " ++ @typeName(T)),
    }
}

// --- Tests -----------------------------------------------------------------

fn run_countdown() void {
    while (world.w.phase == .countdown) simulate(.{});
}

test "simulate is deterministic" {
    reset(&track.cold_aisle, 1);
    run_countdown();
    var buttons: Buttons = .{ .a = true };
    for (0..300) |t| {
        buttons.right = (t / 40) % 3 == 1;
        simulate(buttons);
    }
    const snap = world.w;
    for (0..200) |_| simulate(.{ .a = true, .left = true });
    const end_a = world.w;
    world.w = snap;
    for (0..200) |_| simulate(.{ .a = true, .left = true });
    try std.testing.expect(worlds_equal(&end_a, &world.w));
}

test "terminal speed is near 3.6 px/tick" {
    reset(&track.cold_aisle, 1);
    run_countdown();
    // Thrust in a straight line on a flat test without tiles: use the physics directly.
    var m = world.w.machines[0];
    m.heading = 0;
    for (0..600) |_| {
        m.vx += fixed.mul(fixed.one, tuning.accel);
        m.vx = fixed.mul(m.vx, tuning.drag_keep);
    }
    const s = speed(&m);
    try std.testing.expect(s > 3 * fixed.one and s < 4 * fixed.one);
}

test "autopilot completes three laps of Cold Aisle without a crash" {
    reset(&track.cold_aisle, 1);
    run_countdown();
    var crashes: u32 = 0;
    var ticks: u32 = 0;
    var last_crash: world.Crash = .none;
    while (world.w.phase != .finished and ticks < 60 * 120) : (ticks += 1) {
        const m = &world.w.machines[0];
        simulate(ai.drive(m, 0));
        if (m.crash != .none and last_crash == .none) crashes += 1;
        last_crash = m.crash;
    }
    const m = &world.w.machines[0];
    try std.testing.expectEqual(world.Phase.finished, world.w.phase);
    try std.testing.expectEqual(@as(u32, 0), crashes);
    try std.testing.expect(m.best_lap > 0);
    // A lap is 4135 px; under 40 s each.
    try std.testing.expect(m.finish_tick < 60 * 120);
}

test "lap needs both sectors" {
    reset(&track.cold_aisle, 1);
    run_countdown();
    const m = &world.w.machines[0];
    // Teleport across the start line without sectors: no lap.
    const s = track.cold_aisle.sample(250);
    m.x = @as(i32, s.x) << fixed.Q;
    m.y = @as(i32, s.y) << fixed.Q;
    m.progress = 250;
    m.sectors = 0;
    update_progress(m, 0);
    const s2 = track.cold_aisle.sample(2);
    m.x = @as(i32, s2.x) << fixed.Q;
    m.y = @as(i32, s2.y) << fixed.Q;
    update_progress(m, 0);
    try std.testing.expectEqual(@as(u8, 0), m.lap);
    // With both sectors seen: one lap.
    m.progress = 250;
    m.x = @as(i32, s.x) << fixed.Q;
    m.y = @as(i32, s.y) << fixed.Q;
    update_progress(m, 0);
    m.sectors = 3;
    m.x = @as(i32, s2.x) << fixed.Q;
    m.y = @as(i32, s2.y) << fixed.Q;
    update_progress(m, 0);
    try std.testing.expectEqual(@as(u8, 1), m.lap);
    try std.testing.expectEqual(@as(u8, 0), m.sectors);
}

/// Print the completable-test race summary (finish ticks, crashes, rivals).
const report_race = false;

/// The live ranked machines hold ranks 1..k exactly; knocked-out ones 0.
fn ranks_are_permutation() bool {
    var seen: u8 = 0;
    var live: u3 = 0;
    for (world.w.machines[0..tuning.ranked_count]) |m| {
        if (!m.active) {
            if (m.rank != 0) return false;
            continue;
        }
        if (m.rank < 1 or m.rank > tuning.ranked_count) return false;
        seen |= @as(u8, 1) << @intCast(m.rank - 1);
        live += 1;
    }
    return seen == (@as(u8, 1) << live) - 1;
}

test "grid and traffic placement" {
    reset(&track.cold_aisle, world.machine_count);
    try std.testing.expect(world.w.lap_px > 3800 and world.w.lap_px < 4300);
    const ms = &world.w.machines;
    // Nobody overlaps; everyone on a drivable tile.
    for (0..world.machine_count) |i| {
        try std.testing.expect(ms[i].active);
        const a = current.attr_at(ms[i].x >> fixed.Q, ms[i].y >> fixed.Q);
        try std.testing.expect(a != .off and a != .rail);
        for (i + 1..world.machine_count) |j| {
            const dx = wrap_px((ms[j].x >> fixed.Q) - (ms[i].x >> fixed.Q));
            const dy = wrap_px((ms[j].y >> fixed.Q) - (ms[i].y >> fixed.Q));
            try std.testing.expect(dx * dx + dy * dy >= 4 * tuning.machine_radius * tuning.machine_radius);
        }
    }
    // The player starts last; traffic is moving and never ranks.
    try std.testing.expectEqual(@as(u8, 5), ms[0].rank);
    try std.testing.expect(ranks_are_permutation());
    for (ms[tuning.traffic_first..]) |m| {
        try std.testing.expectEqual(@as(u8, 0), m.rank);
        try std.testing.expect(speed(&m) > fixed.one);
        const d: i32 = m.progress;
        try std.testing.expect(d >= tuning.traffic_clear_samples and d <= 255 - tuning.traffic_clear_samples);
    }
}

test "simulate is deterministic with 11 machines" {
    reset(&track.cold_aisle, world.machine_count);
    run_countdown();
    var buttons: Buttons = .{ .a = true };
    for (0..300) |t| {
        buttons = ai.drive(&world.w.machines[0], 0);
        buttons.up = (t % 97) == 5;
        simulate(buttons);
    }
    const snap = world.w;
    for (0..300) |t| {
        var b = ai.drive(&world.w.machines[0], 0);
        b.left = b.left or (t / 30) % 4 == 1;
        simulate(b);
    }
    const end_a = world.w;
    world.w = snap;
    for (0..300) |t| {
        var b = ai.drive(&world.w.machines[0], 0);
        b.left = b.left or (t / 30) % 4 == 1;
        simulate(b);
    }
    try std.testing.expect(worlds_equal(&end_a, &world.w));
}

test "every committed track is completable with the field present" {
    for (track.tracks) |t| {
        reset(t, world.machine_count);
        run_countdown();
        var crashes: u32 = 0;
        var collision_crashes: u32 = 0;
        var ticks: u32 = 0;
        var last_crash: world.Crash = .none;
        while (world.w.phase != .finished and ticks < 60 * 150) : (ticks += 1) {
            const m = &world.w.machines[0];
            simulate(ai.drive(m, 0));
            if (m.crash != .none and last_crash == .none) {
                crashes += 1;
                if (m.crash == .collision) collision_crashes += 1;
            }
            last_crash = m.crash;
            if (ticks % 100 == 0) {
                try std.testing.expect(ranks_are_permutation());
                for (world.w.machines[tuning.traffic_first..]) |tm| try std.testing.expectEqual(@as(u8, 0), tm.rank);
            }
        }
        const p = &world.w.machines[0];
        var rivals_done: u32 = 0;
        for (world.w.machines[1..tuning.traffic_first]) |r| rivals_done += @intFromBool(r.finished);
        if (report_race) {
            std.debug.print("\n{s}: finish {d} ticks, best lap {d}, rank {d}, crashes {d} (collision {d}), thermal {d}, rivals finished {d}\n", .{ t.name, p.finish_tick, p.best_lap, p.rank, crashes, collision_crashes, p.thermal, rivals_done });
            for (world.w.machines[1..tuning.traffic_first], 1..) |r, i| std.debug.print("  rival {d}: lap {d} rank {d} finished {} at {d} thermal {d} best {d}\n", .{ i, r.lap, r.rank, r.finished, r.finish_tick, r.thermal, r.best_lap });
        }
        try std.testing.expectEqual(world.Phase.finished, world.w.phase);
        try std.testing.expectEqual(tuning.laps, p.lap);
        try std.testing.expect(p.finish_tick < 60 * 150);
        try std.testing.expect(crashes <= 1);
        try std.testing.expect(p.rank >= 1 and p.rank <= 5);
        // Run on until the rivals finish: they lap the track too.
        var more: u32 = 0;
        while (more < 60 * 60) : (more += 1) {
            simulate(.{});
            var done = true;
            for (world.w.machines[1..tuning.traffic_first]) |r| done = done and (r.finished or !r.active);
            if (done) break;
        }
        // A rival the autopilot happened to knock out (SPEC 5.5) is out.
        for (world.w.machines[1..tuning.traffic_first]) |r| try std.testing.expect(r.finished or !r.active);
        try std.testing.expect(ranks_are_permutation());
    }
}

test "every machine select pick completes every track" {
    defer player_character = 0;
    try std.testing.expect(eql(ai.Character, &ai.player_machines[0], &ai.Character{}));
    var finish: [ai.player_machines.len]u32 = undefined;
    for (track.tracks) |t| {
        for (0..ai.player_machines.len) |k| {
            player_character = @intCast(k);
            reset(t, 1);
            run_countdown();
            var crashes: u32 = 0;
            var ticks: u32 = 0;
            var last_crash: world.Crash = .none;
            while (world.w.phase != .finished and ticks < 60 * 150) : (ticks += 1) {
                const m = &world.w.machines[0];
                simulate(ai.drive(m, 0));
                if (m.crash != .none and last_crash == .none) crashes += 1;
                last_crash = m.crash;
            }
            const p = &world.w.machines[0];
            if (report_race) std.debug.print("\n{s} machine {d}: finish {d} ticks, best lap {d}, crashes {d}\n", .{ t.name, k, p.finish_tick, p.best_lap, crashes });
            try std.testing.expectEqual(world.Phase.finished, world.w.phase);
            try std.testing.expect(crashes <= 1);
            finish[k] = p.finish_tick;
        }
        // The picks are felt: ARGMAX's top speed beats ANTEATER and BACKPROP
        // under the same autopilot.
        try std.testing.expect(finish[1] < finish[0] and finish[1] < finish[3]);
    }
}

test "machines that overlap head-on are pushed apart and lose thermal" {
    reset(&track.cold_aisle, 2);
    run_countdown();
    const a = &world.w.machines[0];
    const b = &world.w.machines[1];
    const s = current.sample(60);
    a.* = .{ .x = (@as(i32, s.x) - 8) << fixed.Q, .y = @as(i32, s.y) << fixed.Q, .vx = fixed.one, .heading = 0, .progress = 60 };
    b.* = .{ .x = (@as(i32, s.x) + 8) << fixed.Q, .y = @as(i32, s.y) << fixed.Q, .vx = -fixed.one, .heading = 32768, .progress = 60 };
    collide_all();
    const dx = (b.x - a.x) >> fixed.Q;
    try std.testing.expect(dx >= 2 * tuning.machine_radius - 1);
    // The player rams as much as it is rammed: 60 each, plus the ram
    // damage of the 2 px/tick closing on the rival (SPEC 5.5).
    try std.testing.expectEqual(@as(i16, 1000 - 60), a.thermal);
    try std.testing.expectEqual(@as(i16, 1000 - 60 - 400), b.thermal);
    // 30% of the 2 px/tick closing speed exchanged: each now at 0.4 px/tick.
    try std.testing.expect(@abs(a.vx - fixed.one * 2 / 5) < 256);
    try std.testing.expect(@abs(b.vx + fixed.one * 2 / 5) < 256);
    try std.testing.expectEqual(world.Crash.none, a.crash);
    // OVERFIT takes double damage (so this ram knocks it out); a 4 px/tick
    // closing hit on the player is a COLLISION crash.
    reset(&track.cold_aisle, 5);
    run_countdown();
    const p = &world.w.machines[0];
    const o = &world.w.machines[4];
    p.* = .{ .x = (@as(i32, s.x) - 8) << fixed.Q, .y = @as(i32, s.y) << fixed.Q, .vx = 2 * fixed.one, .progress = 60 };
    o.* = .{ .x = (@as(i32, s.x) + 8) << fixed.Q, .y = @as(i32, s.y) << fixed.Q, .vx = -2 * fixed.one, .progress = 60 };
    collide_all();
    try std.testing.expectEqual(@as(i16, 0), o.thermal); // 1000 - 2 * (60 + 800), melted down
    try std.testing.expect(o.ko);
    try std.testing.expectEqual(world.Crash.collision, p.crash);
    try std.testing.expectEqual(world.Message.collision, world.w.msg[0]);
}

test "Overclock on the Up press edge" {
    reset(&track.cold_aisle, 1);
    run_countdown();
    const m = &world.w.machines[0];
    m.thermal = 1000;
    simulate(.{ .up = true });
    try std.testing.expectEqual(tuning.overclock_ticks, m.boost);
    try std.testing.expectEqual(@as(i16, 750), m.thermal);
    // Holding Up does not fire again once the boost ends.
    m.boost = 1;
    simulate(.{ .up = true });
    simulate(.{ .up = true });
    try std.testing.expectEqual(@as(u8, 0), m.boost);
    try std.testing.expectEqual(@as(i16, 750), m.thermal);
    // Too little thermal: nothing.
    simulate(.{});
    m.thermal = 90;
    simulate(.{ .up = true });
    try std.testing.expectEqual(@as(u8, 0), m.boost);
    try std.testing.expectEqual(@as(i16, 90), m.thermal);
}

test "SNOUTY is neutral and the characters differ" {
    const s = ai.characters[0];
    try std.testing.expectEqual(@as(i32, 256), s.top_q8);
    try std.testing.expectEqual(@as(i32, 256), s.steer_q8);
    try std.testing.expectEqual(@as(i32, 256), s.grip_q8);
    try std.testing.expect(ai.characters[1].top_q8 > ai.characters[3].top_q8);
    try std.testing.expect(ai.characters[3].steer_q8 > ai.characters[1].steer_q8);
    try std.testing.expectEqual(@as(i32, 2), ai.characters[4].damage_mul);
    try std.testing.expect(ai.character(7) == &ai.traffic);
}

// --- Knockouts (SPEC 5.5) -----------------------------------------------------

/// Two machines on Cold Aisle's sample 60 heading +x: the player `gap` px
/// behind machine `victim`, at `pv` and `vv` px/tick (Q16).
fn line_up(victim: usize, gap: i32, pv: i32, vv: i32) struct { p: *Machine, v: *Machine } {
    reset(&track.cold_aisle, world.machine_count);
    run_countdown();
    const s = current.sample(60);
    const p = &world.w.machines[0];
    const v = &world.w.machines[victim];
    const th = v.thermal;
    p.* = .{ .x = (@as(i32, s.x) - gap) << fixed.Q, .y = @as(i32, s.y) << fixed.Q, .vx = pv, .progress = 60 };
    v.* = .{ .x = @as(i32, s.x) << fixed.Q, .y = @as(i32, s.y) << fixed.Q, .vx = vv, .progress = 60, .thermal = th };
    return .{ .p = p, .v = v };
}

test "a rear-end ram hurts the victim, a side bump less, the rammer only 60" {
    // Full speed into a batch job at 55%: 1.6 px/tick closing, 320 of ram.
    const rear = line_up(7, 19, 236000, 129792);
    collide_all();
    try std.testing.expectEqual(tuning.traffic_thermal, rear.v.thermal + 60 + ((236000 - 129792) * tuning.ram_damage_per_px >> fixed.Q));
    try std.testing.expectEqual(@as(i16, 1000 - 60), rear.p.thermal);
    try std.testing.expect(rear.v.hit_by_player == tuning.ko_credit_ticks);
    // On a rival (1000 thermal): Overclocked is half as much ram again,
    // a 0.7 px/tick bump much less.
    const plain = line_up(1, 19, 236000, 129792);
    collide_all();
    const plain_left = plain.v.thermal;
    const oc = line_up(1, 19, 236000, 129792);
    oc.p.boost = 10;
    collide_all();
    try std.testing.expect(oc.v.thermal < plain_left - 100);
    const side = line_up(1, 19, 45875, 0);
    collide_all();
    try std.testing.expect(side.v.thermal > plain_left + 100);
    // Rammed from behind by a rival, the player takes only the 60.
    reset(&track.cold_aisle, world.machine_count);
    run_countdown();
    const s = current.sample(60);
    const p = &world.w.machines[0];
    const r = &world.w.machines[1];
    p.* = .{ .x = (@as(i32, s.x) + 19) << fixed.Q, .y = @as(i32, s.y) << fixed.Q, .vx = fixed.one, .progress = 60 };
    r.* = .{ .x = @as(i32, s.x) << fixed.Q, .y = @as(i32, s.y) << fixed.Q, .vx = 3 * fixed.one, .progress = 60 };
    collide_all();
    try std.testing.expectEqual(@as(i16, 1000 - 60), p.thermal);
    try std.testing.expectEqual(@as(i16, 1000 - 60), r.thermal);
}

test "a credited meltdown knocks a rival out of the race" {
    const u = line_up(2, 19, 236000, 129792);
    u.v.thermal = 100;
    collide_all();
    try std.testing.expect(u.v.ko);
    try std.testing.expectEqual(world.Crash.meltdown, u.v.crash);
    try std.testing.expectEqual(@as(u8, 1), world.w.kos[0]);
    try std.testing.expectEqual(world.Message.ko, world.w.msg[0]);
    try std.testing.expectEqual(@as(u8, 2), world.w.msg_who[0]);
    // It wrecks through the hit-stop, then is gone: no rank, no contact.
    for (0..tuning.hitstop_ticks + 1) |_| simulate(.{});
    try std.testing.expect(!u.v.active);
    try std.testing.expectEqual(@as(u8, 0), u.v.rank);
    try std.testing.expect(ranks_are_permutation());
    try std.testing.expect(u.p.rank <= 4);
}

test "an uncredited crash still recovers; credit runs out" {
    reset(&track.cold_aisle, world.machine_count);
    run_countdown();
    const r = &world.w.machines[3];
    crash(r, .meltdown);
    try std.testing.expect(!r.ko);
    for (0..tuning.hitstop_ticks + 1) |_| simulate(.{});
    try std.testing.expect(r.active);
    try std.testing.expectEqual(world.Crash.none, r.crash);
    // Hit by the player, then left alone past the window.
    r.hit_by_player = tuning.ko_credit_ticks;
    for (0..tuning.ko_credit_ticks) |_| simulate(.{});
    crash(r, .fall);
    try std.testing.expect(!r.ko);
    // A credited fall knocks out; a finished machine never is.
    const f = &world.w.machines[4];
    f.hit_by_player = 10;
    crash(f, .fall);
    try std.testing.expect(f.ko);
    const g = &world.w.machines[1];
    g.hit_by_player = 10;
    g.finished = true;
    crash(g, .fall);
    try std.testing.expect(!g.ko);
}

/// Test driver: the autopilot, but when a live machine is ahead within 70
/// px and a 40 px band, steer at it, hold A and Overclock into it.
fn ram_drive(m: *const Machine) Buttons {
    var b = ai.drive(m, 0);
    const hx = fixed.cos(m.heading);
    const hy = fixed.sin(m.heading);
    var best: i32 = 70;
    var target: ?*const Machine = null;
    for (world.w.machines[1..world.w.active_count]) |*o| {
        if (!o.active or o.ko or o.hop != 0) continue;
        const dx = wrap_px((o.x - m.x) >> fixed.Q);
        const dy = wrap_px((o.y - m.y) >> fixed.Q);
        const along = (dx * hx + dy * hy) >> fixed.Q;
        const lat = (dx * -hy + dy * hx) >> fixed.Q;
        if (along > 0 and along < best and @abs(lat) < 40) {
            best = along;
            target = o;
        }
    }
    if (target) |o| {
        const want = fixed.atan2(wrap_px((o.y - m.y) >> fixed.Q), wrap_px((o.x - m.x) >> fixed.Q));
        const err = fixed.turn_diff(m.heading, want);
        b.left = err < -300;
        b.right = err > 300;
        b.a = true;
        b.down = false;
        b.up = !m.up_was and m.boost == 0 and m.thermal > 450;
    }
    return b;
}

test "ramming the field knocks machines out, deterministically" {
    reset(&track.cold_aisle, world.machine_count);
    run_countdown();
    for (0..1800) |_| simulate(ram_drive(&world.w.machines[0]));
    const snap = world.w;
    for (0..1800) |_| simulate(ram_drive(&world.w.machines[0]));
    const end_a = world.w;
    try std.testing.expect(end_a.kos[0] >= 2);
    try std.testing.expect(ranks_are_permutation());
    world.w = snap;
    for (0..1800) |_| simulate(ram_drive(&world.w.machines[0]));
    try std.testing.expect(worlds_equal(&end_a, &world.w));
}

// --- Two humans (M6, the link race) -------------------------------------------

/// A scripted human on machine `i`: the autopilot with taps of its own
/// (lean, brake, Overclock) from `seed`, so the two humans differ.
fn human_drive(i: usize, t: u32, seed: u32) Buttons {
    var b = ai.drive_human(&world.w.machines[i], i);
    const r = step_rng((t *% 2_654_435_761 +% seed) | 1);
    if (r % 53 == 0) b.left = !b.left;
    if (r % 71 == 0) b.right = !b.right;
    if (r % 97 == 0) b.up = true;
    if (r % 131 == 0) b.down = true;
    return b;
}

fn human_inputs(t: u32) [2]Buttons {
    return .{ human_drive(world.w.humans[0], t, 7), human_drive(world.w.humans[1], t, 1234) };
}

test "link grid: both humans on the back row, side by side, the field placed" {
    for (track.tracks) |t| {
        reset_link(t, .{ 0, 3 });
        const ms = &world.w.machines;
        try std.testing.expectEqual(@as(?u1, 0), world.w.slot_of(world.player));
        try std.testing.expectEqual(@as(?u1, 1), world.w.slot_of(world.guest));
        try std.testing.expectEqual(@as(?u1, null), world.w.slot_of(2));
        for (0..world.machine_count) |i| {
            try std.testing.expect(ms[i].active);
            const a = current.attr_at(ms[i].x >> fixed.Q, ms[i].y >> fixed.Q);
            try std.testing.expect(a != .off and a != .rail);
            for (i + 1..world.machine_count) |j| {
                const dx = wrap_px((ms[j].x >> fixed.Q) - (ms[i].x >> fixed.Q));
                const dy = wrap_px((ms[j].y >> fixed.Q) - (ms[i].y >> fixed.Q));
                try std.testing.expect(dx * dx + dy * dy >= 4 * tuning.machine_radius * tuning.machine_radius);
            }
        }
        // The humans start 4th and 5th, level with each other along the line.
        try std.testing.expect(ms[0].rank >= 4 and ms[1].rank >= 4);
        try std.testing.expect(ranks_are_permutation());
        try std.testing.expect(@abs(fine_progress(&ms[0]) - fine_progress(&ms[1])) < 256);
    }
}

test "solo: slot 1's buttons never reach the World" {
    reset(&track.cold_aisle, world.machine_count);
    const start = world.w;
    for (0..900) |k| simulate(human_drive(0, @intCast(k), 7));
    const end_a = world.w;
    world.w = start;
    for (0..900) |k| simulate_humans(.{ human_drive(0, @intCast(k), 7), .{ .a = true, .left = (k & 8) != 0, .up = true } });
    try std.testing.expect(worlds_equal(&end_a, &world.w));
}

test "two humans: deterministic, and simulate_world matches the live World" {
    reset_link(&track.substation_sprint, .{ 1, 2 });
    for (0..400) |k| simulate_humans(human_inputs(@intCast(k)));
    const snap = world.w;
    for (0..1500) |k| simulate_humans(human_inputs(@intCast(400 + k)));
    const end_a = world.w;
    // Again from the snapshot, through a detached World.
    var other = snap;
    world.w = .{};
    for (0..1500) |k| {
        const saved = world.w;
        world.w = other;
        const in = human_inputs(@intCast(400 + k));
        world.w = saved;
        simulate_world(&other, in);
    }
    try std.testing.expect(worlds_equal(&end_a, &other));
    // The global World was left alone meanwhile.
    try std.testing.expect(worlds_equal(&W{}, &world.w));
    // And the humans really did drive differently.
    try std.testing.expect(end_a.machines[0].x != end_a.machines[1].x or end_a.machines[0].y != end_a.machines[1].y);
}

test "two humans race to the finish; the race ends when both have" {
    reset_link(&track.cold_aisle, .{ 0, 1 });
    var ticks: u32 = 0;
    var first_done: ?u32 = null;
    while (world.w.phase != .finished and ticks < 60 * 150) : (ticks += 1) {
        simulate_humans(human_inputs(ticks));
        const done = @as(u8, @intFromBool(world.w.machines[0].finished)) + @intFromBool(world.w.machines[1].finished);
        if (done == 1 and first_done == null) {
            first_done = ticks;
            // One human home: the race goes on, and only that human's bar says so.
            try std.testing.expectEqual(world.Phase.racing, world.w.phase);
            const s: usize = if (world.w.machines[0].finished) 0 else 1;
            try std.testing.expectEqual(world.Message.committed, world.w.msg[s]);
            try std.testing.expect(world.w.msg[s ^ 1] != .committed);
        }
        if (ticks % 100 == 0) try std.testing.expect(ranks_are_permutation());
    }
    try std.testing.expectEqual(world.Phase.finished, world.w.phase);
    for (world.w.machines[0..2]) |m| {
        try std.testing.expect(m.finished);
        try std.testing.expectEqual(tuning.laps, m.lap);
        try std.testing.expect(m.rank >= 1 and m.rank <= 5);
    }
    try std.testing.expect(world.w.machines[0].rank != world.w.machines[1].rank);
}

test "a human's knockout is credited to that human" {
    // The guest rams machine 3 from behind; machine 0 sits elsewhere.
    reset_link(&track.cold_aisle, .{ 0, 0 });
    run_countdown();
    const s = current.sample(60);
    const g = &world.w.machines[world.guest];
    const v = &world.w.machines[3];
    g.* = .{ .x = (@as(i32, s.x) - 19) << fixed.Q, .y = @as(i32, s.y) << fixed.Q, .vx = 236000, .progress = 60 };
    v.* = .{ .x = @as(i32, s.x) << fixed.Q, .y = @as(i32, s.y) << fixed.Q, .vx = 129792, .progress = 60, .thermal = 100 };
    collide_all();
    try std.testing.expect(v.ko);
    try std.testing.expectEqual(@as(u8, 1), v.hit_by);
    try std.testing.expectEqual([2]u8{ 0, 1 }, world.w.kos);
    try std.testing.expectEqual(world.Message.ko, world.w.msg[1]);
    try std.testing.expect(world.w.msg[0] != .ko);
    try std.testing.expectEqual(@as(u8, 3), world.w.msg_who[1]);
    // The host's own knockout goes to the host.
    const w4 = &world.w.machines[4];
    w4.hit_by_player = 10;
    w4.hit_by = 0;
    crash(w4, .fall);
    try std.testing.expectEqual([2]u8{ 1, 1 }, world.w.kos);
}

test "humans ram each other alike and are never knocked out" {
    reset_link(&track.cold_aisle, .{ 0, 0 });
    run_countdown();
    const s = current.sample(60);
    const h = &world.w.machines[world.player];
    const g = &world.w.machines[world.guest];
    // Head-on at 1 px/tick each: the same damage on both (60 + the ram).
    h.* = .{ .x = (@as(i32, s.x) - 8) << fixed.Q, .y = @as(i32, s.y) << fixed.Q, .vx = fixed.one, .progress = 60 };
    g.* = .{ .x = (@as(i32, s.x) + 8) << fixed.Q, .y = @as(i32, s.y) << fixed.Q, .vx = -fixed.one, .heading = 32768, .progress = 60 };
    collide_all();
    try std.testing.expectEqual(h.thermal, g.thermal);
    try std.testing.expectEqual(@as(i16, 1000 - 60 - 400), g.thermal);
    // A meltdown with the other human's credit is a crash, not a knockout.
    g.thermal = 0;
    g.hit_by_player = 50;
    g.hit_by = 0;
    crash(g, .meltdown);
    try std.testing.expect(!g.ko);
    try std.testing.expectEqual(world.Message.meltdown, world.w.msg[1]);
    for (0..tuning.hitstop_ticks + 1) |_| simulate_humans(.{ .{}, .{} });
    try std.testing.expect(g.active);
    try std.testing.expectEqual(world.Crash.none, g.crash);
}

test "a human handed to the AI drives on to the finish" {
    reset_link(&track.rack_row_7, .{ 4, 2 });
    var ticks: u32 = 0;
    while (ticks < 900) : (ticks += 1) simulate_humans(human_inputs(ticks));
    // The guest's partner leaves: its machine goes to the AI, and its
    // byte is ignored from then on.
    world.w.ai_drives[1] = true;
    while (world.w.phase != .finished and ticks < 60 * 150) : (ticks += 1) {
        simulate_humans(.{ human_drive(0, ticks, 7), .{ .left = true, .down = true } });
    }
    try std.testing.expectEqual(world.Phase.finished, world.w.phase);
    try std.testing.expect(world.w.machines[1].finished);
    try std.testing.expect(world.w.machines[1].active);
    // Still the guest's: its pick, its slot.
    try std.testing.expectEqual(@as(?u1, 1), world.w.slot_of(world.guest));
    try std.testing.expectEqual(@as(u8, 2), world.w.picks[1]);
}

test "the World with two humans stays under the keyframe bound" {
    try std.testing.expect(@sizeOf(W) <= 640);
}
