//! Driving by the centerline (SPEC 5.3): the rivals, the traffic and the
//! attract autopilot steer toward a look-ahead sample with a lane offset
//! and throttle by the curvature ahead. Each machine has a `Character`
//! (SPEC 3): the driving style here plus the physics multipliers that
//! `sim.step_machine` applies. Integer-only, no cart API.
const std = @import("std");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const sim = @import("sim.zig");

pub const Character = struct {
    /// Lane offset from the centerline, world px (positive = right of travel).
    lane: i32 = 0,
    /// Samples ahead to aim at.
    lookahead: u8 = 6,
    /// Curvature window: the heading change over the next `curve_ahead`
    /// samples sets the speed target: top speed at 0, `min_speed_pct` at
    /// `full_brake_turn` turn units and beyond.
    curve_ahead: u8 = 8,
    full_brake_turn: i32 = 14000,
    min_speed_pct: u8 = 72,
    /// Use the tight turn when the steering error exceeds this.
    tight_turn: i32 = 3000,
    /// Top speed scale in 1/255 (the character's own cap, applied by easing off A).
    speed_pct: u8 = 255,

    // --- Physics multipliers, 1/256 (256 = the base tuning) ---------------
    /// Thrust, so the terminal speed scales with it (terminal = accel / drag).
    top_q8: i32 = 256,
    /// Yaw rate.
    steer_q8: i32 = 256,
    /// Lateral slip removed per tick: keep' = 1 - (1 - grip) * grip_q8 / 256.
    grip_q8: i32 = 256,

    // --- Style ----------------------------------------------------------------
    /// Lane wander (DROPOUT): offset amplitude, px, and phase step per tick
    /// in turn units (65536 / period in ticks); 0 = none.
    wander_px: i32 = 0,
    wander_rate: i32 = 0,
    /// Traffic: the lane sign alternates with the machine index.
    alternate_lane: bool = false,
    /// Overclock on straights: when the heading change over the next
    /// `overclock_window` samples is under `overclock_curve` and the thermal
    /// bar stays at `overclock_reserve` or more after paying for it.
    overclock_ahead: bool = false,
    overclock_window: u8 = 24,
    overclock_curve: i32 = 6000,
    overclock_reserve: i32 = 500,
    /// Rubber band toward the player (SPEC 5.3).
    rubber: bool = false,
    /// Pass slower machines ahead (rivals and traffic); OVERFIT does not,
    /// it holds its line and takes the hit.
    avoid: bool = true,
    /// Contact: thermal damage multiplier and extra speed kept (Q16) per hit.
    damage_mul: i32 = 1,
    contact_keep: i32 = fixed.one,
};

/// SNOUTY: balanced, the attract autopilot and the completable test driver.
/// Its physics multipliers are neutral (the player keeps the base tuning).
pub const snouty = Character{};

/// ARGMAX: fastest in a straight line, slow turning (brakes earlier).
pub const argmax = Character{
    .lane = -12,
    .top_q8 = 276, // 1.08x
    .steer_q8 = 218, // 0.85x
    .min_speed_pct = 66,
    .full_brake_turn = 12000,
    .tight_turn = 2600,
    .overclock_ahead = true,
    .overclock_reserve = 500,
    .rubber = true,
};

/// DROPOUT: average speed, the lane wanders across the track.
pub const dropout = Character{
    .wander_px = 22,
    .wander_rate = 65536 / 240, // 4 s period
    .overclock_ahead = true,
    .overclock_reserve = 600,
    .rubber = true,
};

/// BACKPROP: best cornering, lower top speed.
pub const backprop = Character{
    .lane = 12,
    .top_q8 = 241, // 0.94x
    .steer_q8 = 300, // 1.17x
    .grip_q8 = 320, // 1.25x the slip removed
    .min_speed_pct = 82,
    .overclock_ahead = true,
    .overclock_reserve = 450,
    .rubber = true,
};

/// OVERFIT: hugs the ideal line exactly, brittle to contact.
pub const overfit = Character{
    .lookahead = 5,
    .top_q8 = 264, // 1.03x
    .overclock_ahead = true,
    .overclock_reserve = 400,
    .rubber = true,
    .avoid = false,
    .damage_mul = 2,
    .contact_keep = 55705, // 0.85: loses 15% more speed per hit
};

/// Batch jobs (traffic): the line at 55% speed, a small lane offset that
/// alternates left/right by index; never rank, never boost.
pub const traffic = Character{
    .lane = 8,
    .lookahead = 4,
    .alternate_lane = true,
    .speed_pct = 140, // 55%
    .min_speed_pct = 85,
};

/// Index 0 SNOUTY, 1..4 the rivals (SPEC 3 order).
pub const characters = [5]Character{ snouty, argmax, dropout, backprop, overfit };

/// Machine select: the player's handling per menu machine (0 ANTEATER, then
/// the rivals' machines in SPEC 3 order). Physics fields only, stronger than
/// the rivals' own multipliers so the pick is felt in the hands, and kept
/// apart from them so the AI tuning does not move.
pub const player_machines = [5]Character{
    .{}, // ANTEATER: the base tuning
    .{ .top_q8 = 302, .steer_q8 = 192 }, // ARGMAX: 1.18x top speed, 0.75x turn
    .{ .steer_q8 = 320, .grip_q8 = 128 }, // DROPOUT: 1.25x turn, half the grip (slides)
    .{ .top_q8 = 230, .steer_q8 = 333, .grip_q8 = 384 }, // BACKPROP: 0.9x top, 1.3x turn, 1.5x grip
    .{ .top_q8 = 282, .damage_mul = 2, .contact_keep = 52429 }, // OVERFIT: 1.1x top, 2x damage, keeps 0.8 per hit
};

/// The character of machine `i`: 0 SNOUTY, 1..4 rivals, 5..10 traffic.
pub fn character(i: usize) *const Character {
    return if (i < characters.len) &characters[i] else &traffic;
}

/// One tick of buttons for machine `m` (machine index `i` picks the character).
pub fn drive(m: *const world.Machine, i: usize) world.Buttons {
    return drive_index(m, character(i), i);
}

/// Drive with a given character as machine 0 (no rubber band, no lane flip).
pub fn drive_as(m: *const world.Machine, c: *const Character) world.Buttons {
    return drive_index(m, c, 0);
}

/// Lane offset this tick, px.
fn lane_of(c: *const Character, i: usize) i32 {
    var lane = c.lane;
    if (c.alternate_lane and (i & 1) != 0) lane = -lane;
    if (c.wander_px != 0) {
        const phase: u16 = @truncate(world.w.tick *% @as(u32, @intCast(c.wander_rate)) +% @as(u32, @intCast(i)) *% 16384);
        lane += (fixed.sin(phase) * c.wander_px) >> fixed.Q;
    }
    return lane;
}

/// Heading change summed over `n` samples from `from`, turn units.
fn curvature(from: usize, n: u8) i32 {
    const t = sim.current;
    var curve: i32 = 0;
    var prev = t.sample(from & 255).tangent;
    var k: usize = 1;
    while (k <= n) : (k += 1) {
        const a = t.sample((from + k) & 255).tangent;
        curve += @intCast(@abs(fixed.turn_diff(prev, a)));
        prev = a;
    }
    return curve;
}

/// A human's machine driven by the autopilot (after its finish, or when
/// its partner left a link race): SNOUTY's line at its own index, no
/// rubber band. Solo this is `drive(m, 0)`.
pub fn drive_human(m: *const world.Machine, i: usize) world.Buttons {
    return drive_index(m, &snouty, i);
}

/// Rubber band scale in 1/1000 (SPEC 5.3): 1000 + clamp(gap / 1500), the
/// gap to the leading human (solo, the player).
pub fn rubber_permille(m: *const world.Machine) i32 {
    var lead: i32 = std.math.minInt(i32);
    for (world.w.humans) |h| {
        if (h != world.no_human) lead = @max(lead, sim.progress_px(&world.w.machines[h]));
    }
    const gap = lead - sim.progress_px(m);
    const adj = @divTrunc(gap * 1000, tuning.rubber_px);
    return 1000 + @max(tuning.rubber_min_permille, @min(tuning.rubber_max_permille, adj));
}

fn drive_index(m: *const world.Machine, c: *const Character, i: usize) world.Buttons {
    var b: world.Buttons = .{};
    const t = sim.current;
    const target = t.sample((@as(usize, m.progress) + c.lookahead) & 255);
    // Lane offset along the target's right vector.
    var lane = lane_of(c, i);
    var block_spd: i32 = std.math.maxInt(i32);
    if (c.avoid) avoid(m, i, &lane, &block_spd);
    const tx = fixed.cos(target.tangent);
    const ty = fixed.sin(target.tangent);
    const gx = @as(i32, target.x) + ((-ty * lane) >> fixed.Q);
    const gy = @as(i32, target.y) + ((tx * lane) >> fixed.Q);
    var dx = gx - (m.x >> fixed.Q);
    var dy = gy - (m.y >> fixed.Q);
    dx = ((dx + 512) & 1023) - 512;
    dy = ((dy + 512) & 1023) - 512;
    const want = fixed.atan2(dy, dx);
    const err = fixed.turn_diff(m.heading, want);
    if (err > 400) b.right = true;
    if (err < -400) b.left = true;
    // Speed target from the curvature ahead.
    const curve = curvature(m.progress, c.curve_ahead);
    const top = @divTrunc(tuning.top_speed * c.top_q8, 256);
    const cap = @divTrunc(top * @as(i32, c.speed_pct), 255);
    const slow = @min(curve, c.full_brake_turn);
    const pct: i32 = 255 - @divTrunc((255 - @as(i32, c.min_speed_pct)) * slow, c.full_brake_turn);
    var want_spd = @divTrunc(cap * pct, 255);
    if (c.rubber and world.w.slot_of(i) == null) want_spd = @divTrunc(want_spd * rubber_permille(m), 1000);
    const spd = sim.speed(m);
    want_spd = @min(want_spd, block_spd);
    b.a = spd < want_spd;
    // Brake when well over the target; tight turn on a big heading error.
    if (spd > want_spd + @divTrunc(want_spd, 6)) b.down = true;
    if (@abs(err) > c.tight_turn and spd > @divTrunc(tuning.top_speed, 4)) b.down = true;
    // Overclock on a straight: a fresh press (edge) with thermal to spare.
    // The near window is already summed; scan the rest only when it is straight.
    if (c.overclock_ahead and m.boost == 0 and !m.f.up_was and
        m.thermal >= c.overclock_reserve + tuning.thermal_overclock and
        world.w.phase != .countdown and !m.f.finished and curve < c.overclock_curve and
        curve + curvature(@as(usize, m.progress) + c.curve_ahead, c.overclock_window - c.curve_ahead) < c.overclock_curve)
    {
        b.up = true;
    }
    return b;
}

/// Pass a slower machine ahead: aim at a lane beside it, on the side with
/// room inside the track's half width; ease off when right behind it.
fn avoid(m: *const world.Machine, i: usize, lane: *i32, block_spd: *i32) void {
    const hx = fixed.cos(m.heading);
    const hy = fixed.sin(m.heading);
    const s = sim.current.sample(m.progress);
    const half: i32 = s.half;
    // Own offset from the centerline (right of travel positive).
    const sx = fixed.cos(s.tangent);
    const sy = fixed.sin(s.tangent);
    const ox = wrap_px((m.x >> fixed.Q) - @as(i32, s.x));
    const oy = wrap_px((m.y >> fixed.Q) - @as(i32, s.y));
    const own_lat = (ox * -sy + oy * sx) >> fixed.Q;
    var nearest: i32 = tuning.avoid_ahead;
    const n: usize = world.w.active_count;
    for (0..n) |j| {
        if (j == i) continue;
        const o = &world.w.machines[j];
        if (!o.f.active or o.hop != 0) continue;
        const dx = wrap_px((o.x - m.x) >> fixed.Q);
        const dy = wrap_px((o.y - m.y) >> fixed.Q);
        if (@abs(dx) >= tuning.avoid_ahead or @abs(dy) >= tuning.avoid_ahead) continue;
        const along = (dx * hx + dy * hy) >> fixed.Q;
        if (along <= 0 or along >= nearest) continue;
        const lat = (dx * -hy + dy * hx) >> fixed.Q;
        if (@abs(lat) >= tuning.avoid_width) continue;
        // Only machines we are catching (or stopped ones).
        const closing = (fixed.mul(m.vx - o.vx, hx) + fixed.mul(m.vy - o.vy, hy));
        if (closing <= 0 and o.hitstop == 0) continue;
        nearest = along;
        const o_lat = own_lat + lat;
        const room = half - tuning.avoid_margin;
        var pass = if (o_lat > 0) o_lat - tuning.avoid_pass else o_lat + tuning.avoid_pass;
        if (pass < -room or pass > room) pass = if (o_lat > 0) o_lat + tuning.avoid_pass else o_lat - tuning.avoid_pass;
        lane.* = @max(-room, @min(room, pass));
        if (along < tuning.avoid_brake and @abs(lat) < tuning.avoid_brake_width) {
            block_spd.* = if (o.hitstop != 0) 0 else sim.speed(o);
        }
    }
}

inline fn wrap_px(d: i32) i32 {
    return ((d + 512) & 1023) - 512;
}
