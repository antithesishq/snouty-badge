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

/// Puts `count` machines on the grid behind the start line (player first)
/// and starts the countdown.
pub fn reset(t: *const track.Track, count: u8) void {
    current = t;
    world.w = .{};
    world.w.active_count = count;
    world.w.countdown = 4 * tuning.countdown_step;
    world.w.msg = .provisioning;
    world.w.msg_ticks = @intCast(tuning.countdown_step);
    const s0 = t.sample(0);
    // Grid: two columns, rows 28 px apart behind the line; the player at the back
    // of the first pair? No: F-Zero puts the player last on the grid. Player
    // goes at the back row, rivals ahead in finishing order of the previous race.
    for (0..count) |i| {
        const m = &world.w.machines[i];
        m.* = .{};
        const row: i32 = @intCast(i / 2);
        const col: i32 = if (i % 2 == 0) -1 else 1;
        // Player (0) is at the back: rows counted from the back.
        const back = 20 + row * 28;
        const side = col * 18;
        const tx = fixed.cos(s0.tangent);
        const ty = fixed.sin(s0.tangent);
        m.x = ((@as(i32, s0.x) << fixed.Q) - tx * back + (-ty) * side) & world_mask;
        m.y = ((@as(i32, s0.y) << fixed.Q) - ty * back + tx * side) & world_mask;
        m.heading = s0.tangent;
        m.progress = nearest_sample(m, 0);
        m.active = true;
    }
    for (count..world.machine_count) |i| world.w.machines[i].active = false;
}

/// Simulate one tick with the player's buttons. Rivals drive themselves.
pub fn simulate(buttons: Buttons) void {
    var w = &world.w;
    w.rng = step_rng(w.rng);
    if (w.msg_ticks > 0) {
        w.msg_ticks -= 1;
        if (w.msg_ticks == 0) w.msg = .none;
    }
    switch (w.phase) {
        .countdown => {
            w.countdown -= 1;
            const step = tuning.countdown_step;
            if (w.countdown == 3 * step) set_msg(.three, step) else if (w.countdown == 2 * step) set_msg(.two, step) else if (w.countdown == step) set_msg(.one, step) else if (w.countdown == 0) {
                w.phase = .racing;
                set_msg(.deploy, tuning.message_ticks);
            }
            // Machines sit still; the player may lean.
            w.machines[0].steer = steer_of(buttons);
        },
        .racing, .finished => {
            w.tick +%= 1;
            for (0..w.active_count) |i| {
                const m = &w.machines[i];
                if (!m.active) continue;
                const b: Buttons = if (i == world.player and w.phase == .racing) buttons else ai.drive(m, i);
                step_machine(m, b, i);
            }
        },
    }
}

fn set_msg(msg: world.Message, ticks: u32) void {
    world.w.msg = msg;
    world.w.msg_ticks = @intCast(ticks);
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
    if (m.hitstop > 0) {
        m.hitstop -= 1;
        if (m.hitstop == 0) recover(m);
        return;
    }
    if (m.immune > 0) m.immune -= 1;
    if (m.shake > 0) m.shake -= 1;
    if (m.boost > 0) m.boost -= 1;
    const in_air = m.hop > 0;
    if (in_air) m.hop -= 1;

    const hx = fixed.cos(m.heading);
    const hy = fixed.sin(m.heading);
    const spd = speed(m);
    m.steer = steer_of(b);

    // 1. Thrust and brake.
    if (b.a and !m.finished) {
        var a = tuning.accel;
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
        const g = if (m.on_throttled) tuning.grip_throttled else if (tight) tuning.grip_tight else tuning.grip;
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

/// Start the hit-stop; M3 turns this into the rewind decision.
pub fn crash(m: *Machine, cause: world.Crash) void {
    m.crash = cause;
    m.hitstop = tuning.hitstop_ticks;
    m.vx = 0;
    m.vy = 0;
    if (m == &world.w.machines[world.player]) {
        set_msg(switch (cause) {
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
            if (m.sectors == 3 and !m.finished) {
                const lap_time = world.w.tick -% m.lap_start;
                if (m.best_lap == 0 or lap_time < m.best_lap) m.best_lap = lap_time;
                m.lap_start = world.w.tick;
                m.lap += 1;
                if (index == world.player) {
                    if (m.lap == tuning.laps - 1) set_msg(.final_lap, tuning.message_ticks);
                }
                if (m.lap >= tuning.laps) {
                    m.finished = true;
                    m.finish_tick = world.w.tick;
                    if (index == world.player) {
                        world.w.phase = .finished;
                        set_msg(.committed, 120);
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
