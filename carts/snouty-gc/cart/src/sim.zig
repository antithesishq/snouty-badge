//! Forked from snouty-zero/cart/src/sim.zig at f8f6962.
//! One race tick (SPEC 5, 11): wheeled driving with the auto-throttle,
//! tile attributes under the footprint, walls, wrecks and respawn, car
//! contacts, laps and sectors, rank, the countdown.
//!
//! `simulate(w, inputs)` is a pure function of `(World, inputs)`: no cart
//! API, no clock, no floats, no globals written (the M4 lockstep rests on
//! it). Humans are car slots whose input comes from `inputs[car.human]`;
//! nothing here knows which car a badge draws. The one outside state read
//! is the unpacked tile map of `track.tracks[w.track]` (`track.select`,
//! called by `reset`), which is a cache of the track data.
const std = @import("std");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const track = @import("track.zig");
const world = @import("world.zig");
const racers = @import("racers.zig");
const ai = @import("ai.zig");

const World = world.World;
const Car = world.Car;
const Input = world.Input;

const world_mask: i32 = (1024 << fixed.Q) - 1;

pub fn track_of(w: *const World) *const track.Track {
    return track.tracks[w.track % track.tracks.len];
}

/// A new race from a shared setup (SPEC 7.3): car i is racer i with its
/// chassis; the humans' racers take their input slots; the grid is two
/// columns behind the start line, AI cars in front in an order shuffled
/// from the seed, humans at the back. Deterministic.
pub fn reset(w: *World, setup: world.Setup) void {
    const t = track.tracks[setup.track % track.tracks.len];
    track.select(t);
    w.* = .{};
    w.track = setup.track;
    w.rng = if (setup.seed == 0) 1 else setup.seed;
    w.countdown = 4 * tuning.countdown_step;
    w.msg = .ready;
    w.msg_ticks = @intCast(tuning.countdown_step);
    w.lap_px = @intCast(lap_length(t));
    for (&w.cars, 0..) |*c, i| {
        const ch = racers.chassis_of(@intCast(i));
        c.* = .{
            .racer = @intCast(i),
            .top_q8 = ch.top_q8,
            .accel_q8 = ch.accel_q8,
            .grip_q8 = ch.grip_q8,
            .mass_q8 = ch.mass_q8,
            .armor_max = ch.armor,
        };
        for (setup.humans, 0..) |r, slot| {
            if (r == i) c.human = @intCast(slot);
        }
    }
    // Grid order: AI cars shuffled by the seed (Fisher-Yates on the world
    // PRNG), then the humans in slot order.
    var order: [world.car_count]u8 = undefined;
    var n: usize = 0;
    for (w.cars, 0..) |c, i| {
        if (c.human != world.no_human) continue;
        order[n] = @intCast(i);
        n += 1;
    }
    var k = n;
    while (k > 1) {
        k -= 1;
        w.rng = step_rng(w.rng);
        const j = w.rng % @as(u32, @intCast(k + 1));
        std.mem.swap(u8, &order[k], &order[j]);
    }
    for (0..2) |slot| {
        for (w.cars, 0..) |c, i| {
            if (c.human != slot) continue;
            order[n] = @intCast(i);
            n += 1;
        }
    }
    for (order, 0..) |ci, slot| {
        const c = &w.cars[ci];
        const row: i32 = @intCast(slot / 2);
        const side: i32 = if (slot % 2 == 0) -tuning.grid_side else tuning.grid_side;
        const p = line_point_behind(t, tuning.grid_first_row + row * tuning.grid_row_gap);
        place(c, p, side, 0);
        c.progress = nearest_sample(t, c, 0);
    }
    update_ranks(w);
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

/// Put a car at a line point, `side` px to the right, moving at `spd` (Q16).
fn place(c: *Car, p: LinePoint, side: i32, spd: i32) void {
    const tx = fixed.cos(p.tangent);
    const ty = fixed.sin(p.tangent);
    c.x = (p.x + (-ty) * side) & world_mask;
    c.y = (p.y + tx * side) & world_mask;
    c.heading = p.tangent;
    c.vx = fixed.mul(tx, spd);
    c.vy = fixed.mul(ty, spd);
}

inline fn wrap_px(d: i32) i32 {
    return ((d + 512) & 1023) - 512;
}

/// One tick. `inputs[k]` drives the car whose `human` is k; AI cars drive
/// themselves. Pure in `(w, inputs)`.
pub fn simulate(w: *World, inputs: [2]u8) void {
    w.rng = step_rng(w.rng);
    if (w.msg_ticks > 0) {
        w.msg_ticks -= 1;
        if (w.msg_ticks == 0) w.msg = .none;
    }
    for (&w.cars) |*c| {
        if (c.msg_ticks > 0) {
            c.msg_ticks -= 1;
            if (c.msg_ticks == 0) c.msg = .none;
        }
    }
    switch (w.phase) {
        .countdown => {
            w.countdown -= 1;
            const step = tuning.countdown_step;
            if (w.countdown == 3 * step) set_msg(w, .three, step) else if (w.countdown == 2 * step) set_msg(w, .two, step) else if (w.countdown == step) set_msg(w, .one, step) else if (w.countdown == 0) {
                w.phase = .racing;
                set_msg(w, .go, tuning.message_ticks);
            }
            // Cars sit still; humans may lean. Up held through GO does not
            // fire a BURST on the first tick.
            for (&w.cars) |*c| {
                const in: Input = if (c.human < 2) .of(inputs[c.human]) else .{};
                c.steer = steer_of(in);
                c.up_was = in.up;
            }
        },
        .racing, .finished => {
            w.tick +%= 1;
            // All inputs first (the AI reads the world as it was at the top
            // of the tick, whatever the car order), then the moves.
            var ins: [world.car_count]Input = undefined;
            for (&w.cars, 0..) |*c, i| {
                ins[i] = if (c.human < 2 and !c.finished) .of(inputs[c.human]) else ai.drive(w, i);
            }
            for (&w.cars, 0..) |*c, i| {
                if (!c.active) continue;
                step_car(w, c, ins[i]);
            }
            collide_all(w);
            update_ranks(w);
            check_finished(w);
        },
    }
}

fn set_msg(w: *World, msg: world.Message, ticks: u32) void {
    w.msg = msg;
    w.msg_ticks = @intCast(ticks);
}

fn car_msg(c: *Car, msg: world.Message, ticks: u32) void {
    c.msg = msg;
    c.msg_ticks = @intCast(ticks);
}

fn step_rng(s: u32) u32 {
    var x = s;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return x;
}

fn steer_of(b: Input) i8 {
    return @as(i8, @intFromBool(b.right)) - @as(i8, @intFromBool(b.left));
}

/// Speed, Q16.16 px/tick.
pub fn speed(c: *const Car) i32 {
    const vx64: i64 = c.vx;
    const vy64: i64 = c.vy;
    // sqrt(v^2) in Q16: sqrt((v^2) >> 16) << 8.
    const q: u32 = @intCast(@min((vx64 * vx64 + vy64 * vy64) >> fixed.Q, 0xFFFF_FFFF));
    return @intCast(fixed.isqrt(q) << 8);
}

/// The car's top speed without BURST, Q16 (accel x top / drag).
pub fn top_of(c: *const Car) i32 {
    return (tuning.top_speed * @as(i32, c.top_q8)) >> 8;
}

/// Thrust per tick for the chassis: base x top x accel (SPEC 4.2).
fn thrust_of(c: *const Car) i32 {
    return (((tuning.accel * @as(i32, c.top_q8)) >> 8) * @as(i32, c.accel_q8)) >> 8;
}

/// Velocity kept per tick against drag: the accel multiplier scales the
/// drag too, so the terminal speed depends on `top_q8` alone.
fn drag_keep_of(c: *const Car) i32 {
    return fixed.one - ((tuning.drag * @as(i32, c.accel_q8)) >> 8);
}

/// Driving for one car (SPEC 5.1, 5.2; Zero SPEC 5.1 steps 1..5).
fn step_car(w: *World, c: *Car, in: Input) void {
    const up_edge = in.up and !c.up_was;
    c.up_was = in.up;
    if (c.shake > 0) c.shake -= 1;
    if (c.wreck != .none) {
        c.wreck_ticks -|= 1;
        if (c.wreck_ticks == 0) respawn(w, c);
        return;
    }
    if (c.immune > 0) c.immune -= 1;
    if (c.burst > 0) c.burst -= 1;
    // BURST (Up): the press edge, a charge left, none running.
    if (up_edge and c.burst == 0 and c.burst_charges > 0 and !c.finished) {
        c.burst_charges -= 1;
        c.burst = tuning.burst_ticks;
    }
    const in_air = c.hop > 0;
    if (in_air) c.hop -= 1;

    const hx = fixed.cos(c.heading);
    const hy = fixed.sin(c.heading);
    const spd = speed(c);
    c.steer = steer_of(in);
    // Down brakes, unless A or B is pressed with it (that tick Down means
    // "aim back", SPEC 5.1); Down with a direction is the powerslide.
    const braking = in.down and !in.a and !in.b and !in_air;
    c.slide = braking and c.steer != 0;

    // 1. Thrust, always on while racing (auto-throttle), and the brake.
    var a = thrust_of(c);
    if (c.burst > 0) a = (a * tuning.burst_thrust_q8) >> 8;
    c.vx += fixed.mul(hx, a);
    c.vy += fixed.mul(hy, a);
    if (braking) {
        c.vx -= fixed.mul(c.vx, tuning.brake);
        c.vy -= fixed.mul(c.vy, tuning.brake);
    }
    // 2. Drag toward the terminal speed.
    const keep = drag_keep_of(c);
    c.vx = fixed.mul(c.vx, keep);
    c.vy = fixed.mul(c.vy, keep);
    // 3. Grip: along = v . h, lateral = v . right (right = (-hy, hx)).
    if (!in_air) {
        const along = fixed.mul(c.vx, hx) + fixed.mul(c.vy, hy);
        var lat = fixed.mul(c.vx, -hy) + fixed.mul(c.vy, hx);
        var g = if (c.on_coolant) tuning.grip_coolant else if (c.slide) tuning.grip_slide else tuning.grip;
        if (c.grip_q8 != 256) g = fixed.one - (((fixed.one - g) * @as(i32, c.grip_q8)) >> 8);
        lat = fixed.mul(lat, g);
        c.vx = fixed.mul(along, hx) + fixed.mul(lat, -hy);
        c.vy = fixed.mul(along, hy) + fixed.mul(lat, hx);
        // 4. Yaw.
        if (c.steer != 0) {
            var rate = tuning.steer_rate;
            if (spd > tuning.steer_full_below) {
                // 100% at steer_full_below falling to steer_min_pct at top speed.
                const span = tuning.top_speed - tuning.steer_full_below;
                const over = @min(spd - tuning.steer_full_below, span);
                const pct = 100 - @divTrunc((100 - tuning.steer_min_pct) * over, span);
                rate = @divTrunc(rate * pct, 100);
            }
            if (c.slide) rate = @divTrunc(rate * tuning.steer_slide_num, tuning.steer_slide_den);
            const d: i32 = rate * c.steer;
            c.heading +%= @bitCast(@as(i16, @intCast(d)));
        }
    }
    // 5. Move, then the floor under the four corners.
    const old_x = c.x;
    const old_y = c.y;
    c.x = (c.x +% c.vx) & world_mask;
    c.y = (c.y +% c.vy) & world_mask;
    c.on_coolant = false;
    c.on_bay = false;
    if (!in_air) resolve_tiles(w, c, old_x, old_y);
    if (c.wreck == .none) update_progress(w, c);
}

/// Corner offsets of the 24x12 footprint for a heading, world px (not Q16).
fn corners(c: *const Car) [4][2]i32 {
    const hx = fixed.cos(c.heading);
    const hy = fixed.sin(c.heading);
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

/// Tile attributes under the corners: walls push back and reflect, a fully
/// off-track footprint is a fall into the pit, features flag the car.
fn resolve_tiles(w: *World, c: *Car, old_x: i32, old_y: i32) void {
    const t = track_of(w);
    const cs = corners(c);
    var off_count: u8 = 0;
    var wall_hit = false;
    var nx: i32 = 0;
    var ny: i32 = 0;
    for (cs) |k| {
        const px = (c.x >> fixed.Q) + k[0];
        const py = (c.y >> fixed.Q) + k[1];
        switch (t.attr_at(px, py)) {
            .off => off_count += 1,
            .wall => {
                wall_hit = true;
                // Normal from the tile crossing of this corner since last tick.
                const ox = (old_x >> fixed.Q) + k[0];
                const oy = (old_y >> fixed.Q) + k[1];
                const crossed_x = (ox >> 3) != (px >> 3);
                const crossed_y = (oy >> 3) != (py >> 3);
                if (crossed_x and !crossed_y) {
                    nx += if (px > ox) -1 else 1;
                } else if (crossed_y and !crossed_x) {
                    ny += if (py > oy) -1 else 1;
                } else {
                    // Diagonal or no crossing (spawned inside): push away from the corner.
                    nx -= @as(i32, std.math.sign(k[0]));
                    ny -= @as(i32, std.math.sign(k[1]));
                }
            },
            .coolant => c.on_coolant = true,
            .bay => c.on_bay = true,
            .ramp => if (c.hop == 0) {
                c.hop = tuning.ramp_ticks;
            },
            else => {},
        }
    }
    if (wall_hit) {
        if (nx == 0 and ny == 0) nx = 1;
        // Unit-ish normal (axis aligned or diagonal).
        const nxq: i32 = @as(i32, std.math.sign(nx)) << fixed.Q;
        const nyq: i32 = @as(i32, std.math.sign(ny)) << fixed.Q;
        // Back out of the wall: step along the normal until no corner is in one (max 8 px).
        var steps: u8 = 0;
        while (steps < 8 and any_wall(t, c)) : (steps += 1) {
            c.x = (c.x +% nxq) & world_mask;
            c.y = (c.y +% nyq) & world_mask;
        }
        // Reflect the normal velocity component with restitution; lose speed.
        const vn = fixed.mul(c.vx, nxq) + fixed.mul(c.vy, nyq);
        if (vn < 0) {
            c.vx -= fixed.mul(vn, (256 + tuning.wall_restitution) << 8);
            c.vy -= fixed.mul(vn, (256 + tuning.wall_restitution) << 8);
            c.vx = fixed.mul(c.vx, tuning.wall_speed_keep);
            c.vy = fixed.mul(c.vy, tuning.wall_speed_keep);
            c.shake = 4;
        }
    }
    if (off_count == 4 and c.immune == 0) wreck(c, .fall);
}

fn any_wall(t: *const track.Track, c: *const Car) bool {
    for (corners(c)) |k| {
        if (t.attr_at((c.x >> fixed.Q) + k[0], (c.y >> fixed.Q) + k[1]) == .wall) return true;
    }
    return false;
}

/// Wreck a car (SPEC 5.3): it stops and is out for the WATCHDOG delay.
pub fn wreck(c: *Car, cause: world.Wreck) void {
    c.wreck = cause;
    c.wreck_ticks = tuning.watchdog_ticks;
    c.vx = 0;
    c.vy = 0;
    c.hop = 0;
    c.burst = 0;
    c.shake = 8;
    car_msg(c, switch (cause) {
        .fall => .fall,
        .none => .none,
    }, tuning.message_ticks);
}

/// After the WATCHDOG delay: back on the centerline sample nearest the
/// wreck (or the last one before it with floor under it, so a car that
/// fell into a ramp pit comes back before the ramp), facing along it,
/// stopped, immune.
fn respawn(w: *const World, c: *Car) void {
    const t = track_of(w);
    var k: u8 = 0;
    while (k < 32 and t.attr_at(t.sample(c.progress).x, t.sample(c.progress).y) == .off) : (k += 1) c.progress -%= 1;
    const s = t.sample(c.progress);
    c.x = @as(i32, s.x) << fixed.Q;
    c.y = @as(i32, s.y) << fixed.Q;
    c.heading = s.tangent;
    c.vx = 0;
    c.vy = 0;
    c.immune = tuning.respawn_immune;
    c.wreck = .none;
}

/// Squared distance from the car to sample i, in world px^2 (wrapping).
fn dist2_to_sample(t: *const track.Track, c: *const Car, i: usize) i32 {
    const s = t.sample(i);
    const dx = wrap_px((c.x >> fixed.Q) - @as(i32, s.x));
    const dy = wrap_px((c.y >> fixed.Q) - @as(i32, s.y));
    return dx * dx + dy * dy;
}

/// Nearest sample within +-10 of `from`.
pub fn nearest_sample(t: *const track.Track, c: *const Car, from: u8) u8 {
    var best: usize = from;
    var best_d: i32 = std.math.maxInt(i32);
    const window: usize = 10;
    var k: usize = 0;
    while (k < 2 * window + 1) : (k += 1) {
        const i = (@as(usize, from) + 256 + k - window) & 255;
        const d = dist2_to_sample(t, c, i);
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    return @intCast(best);
}

/// Progress, sectors and laps from the centerline (Zero SPEC 7). Crossing
/// the line also refills the BURST charges (SPEC 5.1).
fn update_progress(w: *World, c: *Car) void {
    const old = c.progress;
    const new = nearest_sample(track_of(w), c, old);
    c.progress = new;
    const diff: i32 = @as(i32, new) - @as(i32, old);
    // Forward step (allowing the wrap 255 -> 0).
    const forward = (diff > 0 and diff < 128) or diff < -128;
    const backward = (diff < 0 and diff > -128) or diff > 128;
    if (forward) {
        if (old < 85 and new >= 85) c.sectors |= 1;
        if (old < 170 and new >= 170 and (c.sectors & 1) != 0) c.sectors |= 2;
        if (new < old) {
            // Crossed the start line forward.
            if (c.sectors == 3 and !c.finished) {
                const lap_time = w.tick -% c.lap_start;
                if (c.best_lap == 0 or lap_time < c.best_lap) c.best_lap = lap_time;
                c.lap_start = w.tick;
                c.lap += 1;
                c.burst_charges = tuning.burst_per_lap;
                if (c.lap == tuning.laps - 1) car_msg(c, .final_lap, tuning.message_ticks);
                if (c.lap >= tuning.laps) {
                    c.finished = true;
                    c.finish_tick = w.tick;
                    car_msg(c, .finished, 120);
                }
            }
            c.sectors = 0;
        }
    } else if (backward) {
        // Driving backwards over the line: no credit, and a forward recrossing needs the sectors again.
        if (new > old and (new - old) > 128) c.sectors = 0;
    }
}

/// The race is over when every human has finished, or, in an AI-only race
/// (attract, tests), when the leader has.
fn check_finished(w: *World) void {
    if (w.phase != .racing) return;
    var humans: u32 = 0;
    var humans_done: u32 = 0;
    var any_done = false;
    for (&w.cars) |*c| {
        any_done = any_done or c.finished;
        if (c.human == world.no_human) continue;
        humans += 1;
        if (c.finished) humans_done += 1;
    }
    if ((humans > 0 and humans_done == humans) or (humans == 0 and any_done)) w.phase = .finished;
}

// --- Car against car (Zero SPEC 5.3) ------------------------------------------

fn can_collide(c: *const Car) bool {
    return c.active and c.hop == 0 and c.wreck == .none;
}

/// Circles of radius `car_radius`: push apart by half the penetration
/// each, exchange 30% of the closing normal velocity, split by mass.
pub fn collide_all(w: *World) void {
    const r2: i32 = 2 * tuning.car_radius;
    const reach: i32 = r2 << fixed.Q;
    const lim: i32 = (r2 << 8) * (r2 << 8);
    const half: i32 = 512 << fixed.Q;
    var i: usize = 0;
    while (i < world.car_count) : (i += 1) {
        const a = &w.cars[i];
        if (!can_collide(a)) continue;
        var j = i + 1;
        while (j < world.car_count) : (j += 1) {
            const b = &w.cars[j];
            if (!can_collide(b)) continue;
            const dx = ((b.x -% a.x +% half) & world_mask) - half;
            const dy = ((b.y -% a.y +% half) & world_mask) - half;
            if (dx >= reach or dx <= -reach or dy >= reach or dy <= -reach) continue;
            const dx8 = dx >> 8;
            const dy8 = dy >> 8;
            const d2 = dx8 * dx8 + dy8 * dy8;
            if (d2 >= lim) continue;
            contact(a, b, dx8, dy8, d2);
        }
    }
}

fn contact(a: *Car, b: *Car, dx8: i32, dy8: i32, d2: i32) void {
    const dist: i32 = @intCast(fixed.isqrt(@intCast(d2))); // Q8
    // Unit normal from a to b, Q16 (straight along +x when centred).
    var nx: i32 = fixed.one;
    var ny: i32 = 0;
    if (dist > 0) {
        nx = @divTrunc(dx8 << 16, dist);
        ny = @divTrunc(dy8 << 16, dist);
    }
    // Push apart: half the penetration each.
    const pen8 = (2 * tuning.car_radius << 8) - dist;
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
    // Exchange: 2 x 30% of the closing speed in total, the lighter car
    // taking the larger share (equal masses: 30% each, as Zero).
    const dv = (closing * tuning.collision_exchange) >> 8;
    const ma: i32 = a.mass_q8;
    const mb: i32 = b.mass_q8;
    const dva = @divTrunc(dv * 2 * mb, ma + mb);
    const dvb = @divTrunc(dv * 2 * ma, ma + mb);
    a.vx -= fixed.mul(nx, dva);
    a.vy -= fixed.mul(ny, dva);
    b.vx += fixed.mul(nx, dvb);
    b.vy += fixed.mul(ny, dvb);
    if (closing >= tuning.collision_shake_speed) {
        a.shake = 4;
        b.shake = 4;
    }
}

// --- Progress and rank (Zero SPEC 7) -------------------------------------------

/// Fine progress: lap * 65536 + sample * 256 + the fraction (0..255) of the
/// way to the next sample. Before the line is first crossed with sector 2
/// seen (the grid, or a lap in progress at samples >= 170 without sector 2)
/// the sample belongs to the previous lap.
pub fn fine_progress(w: *const World, c: *const Car) i32 {
    const t = track_of(w);
    var base: usize = c.progress;
    var a = t.sample(base);
    var b = t.sample(base + 1);
    var px = wrap_px((c.x >> fixed.Q) - @as(i32, a.x));
    var py = wrap_px((c.y >> fixed.Q) - @as(i32, a.y));
    var ex = wrap_px(@as(i32, b.x) - @as(i32, a.x));
    var ey = wrap_px(@as(i32, b.y) - @as(i32, a.y));
    var proj = px * ex + py * ey;
    if (proj < 0) {
        // Behind the nearest sample: on the previous segment.
        base = (base + 255) & 255;
        b = a;
        a = t.sample(base);
        px = wrap_px((c.x >> fixed.Q) - @as(i32, a.x));
        py = wrap_px((c.y >> fixed.Q) - @as(i32, a.y));
        ex = wrap_px(@as(i32, b.x) - @as(i32, a.x));
        ey = wrap_px(@as(i32, b.y) - @as(i32, a.y));
        proj = px * ex + py * ey;
    }
    const len2 = ex * ex + ey * ey;
    const frac: i32 = if (len2 == 0 or proj <= 0) 0 else @min(255, @divTrunc(proj * 256, len2));
    var lap: i32 = c.lap;
    if (base >= 170 and (c.sectors & 2) == 0) lap -= 1;
    return lap * 65536 + @as(i32, @intCast(base)) * 256 + frac;
}

/// Progress in world px along the centerline (the rubber band's measure).
pub fn progress_px(w: *const World, c: *const Car) i32 {
    return @intCast((@as(i64, fine_progress(w, c)) * w.lap_px) >> 16);
}

/// Ranks 1..6: finished cars first in finish order, then by fine progress,
/// ties to the lower index. A finished car's rank is final.
fn update_ranks(w: *World) void {
    var fine: [world.car_count]i32 = undefined;
    for (&w.cars, 0..) |*c, i| fine[i] = if (c.finished) 0 else fine_progress(w, c);
    for (&w.cars, 0..) |*c, i| {
        if (!c.active) {
            c.rank = 0;
            continue;
        }
        var r: u8 = 1;
        for (&w.cars, 0..) |*o, j| {
            if (j == i or !o.active) continue;
            const ahead = if (o.finished and c.finished)
                o.finish_tick < c.finish_tick or (o.finish_tick == c.finish_tick and j < i)
            else if (o.finished != c.finished)
                o.finished
            else
                fine[j] > fine[i] or (fine[j] == fine[i] and j < i);
            if (ahead) r += 1;
        }
        c.rank = r;
    }
}

/// Field-by-field comparison by comptime reflection (for the determinism
/// tests): padding bytes are never read.
pub fn worlds_equal(a: *const World, b: *const World) bool {
    return eql(World, a, b);
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
