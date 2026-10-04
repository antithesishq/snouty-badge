//! Forked from snouty-zero/cart/src/ai.zig at f8f6962.
//! Driving by the centerline (Zero SPEC 5.3): the AI racers and the
//! autopilot steer toward a look-ahead sample with a lane offset and hold a
//! speed target from the curvature ahead. With the auto-throttle (SPEC 5.1)
//! the AI slows by braking, not by lifting. Every AI car produces the same
//! input byte a human does, so it obeys the same rules. Pure: reads the
//! World it is given, no globals, no cart API.
//!
//! Physics multipliers moved out of the characters into the cars' chassis
//! (SPEC 4.2); a `Crew` here is only how a racer drives. M1 adds aim,
//! drops and pickups (SPEC 4.3, 6.5).
const std = @import("std");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const track = @import("track.zig");
const sim = @import("sim.zig");

const World = world.World;
const Car = world.Car;
const Input = world.Input;

pub const Crew = struct {
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
    /// Powerslide when the steering error exceeds this.
    slide_turn: i32 = 3000,
    /// The crew's own speed cap in 1/255 of the car's top speed.
    speed_pct: u8 = 255,
    /// Lane wander: offset amplitude, px, and phase step per tick in turn
    /// units (65536 / period in ticks); 0 = none.
    wander_px: i32 = 0,
    wander_rate: i32 = 0,
    /// BURST on a straight: when the heading change over the next
    /// `burst_window` samples is under `burst_curve`.
    burst_ahead: bool = true,
    burst_window: u8 = 24,
    burst_curve: i32 = 6000,
    /// Pass slower cars ahead.
    avoid: bool = true,
};

/// Per racer, SPEC 4.1 order. Driving style only, for M0; M1 widens these
/// into SPEC 4.3's crews. SNOUTY is also the autopilot (attract, tests).
pub const crews = [6]Crew{
    .{}, // SNOUTY: patient, the line
    .{ .lane = -10, .min_speed_pct = 66, .full_brake_turn = 12000, .avoid = false }, // LEGACY: slow, holds its line, pushes
    .{ .lane = 10, .min_speed_pct = 78, .slide_turn = 2400 }, // KIDDIE: fast in, slides
    .{ .lookahead = 7, .min_speed_pct = 76 }, // SYSADMIN: clean lines
    .{ .lane = 6, .wander_px = 14, .wander_rate = 65536 / 300 }, // ROOTKIT: drifts across the lane
    .{ .lane = -6, .wander_px = 20, .wander_rate = 65536 / 200, .speed_pct = 245 }, // BOTNET: a committee at the wheel
};

pub fn crew_of(c: *const Car) *const Crew {
    return &crews[c.racer % crews.len];
}

/// One tick of input for car `i`, from its crew (the autopilot for a human
/// slot uses the same call).
pub fn drive(w: *const World, i: usize) Input {
    const c = &w.cars[i];
    return drive_crew(w, i, crew_of(c));
}

/// Lane offset this tick, px.
fn lane_of(w: *const World, cr: *const Crew, i: usize) i32 {
    var lane = cr.lane;
    if (cr.wander_px != 0) {
        const phase: u16 = @truncate(w.tick *% @as(u32, @intCast(cr.wander_rate)) +% @as(u32, @intCast(i)) *% 16384);
        lane += (fixed.sin(phase) * cr.wander_px) >> fixed.Q;
    }
    return lane;
}

/// Heading change summed over `n` samples from `from`, turn units.
fn curvature(t: *const track.Track, from: usize, n: u8) i32 {
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

/// Rubber band scale in 1/1000 (Zero SPEC 5.3), keyed on the leading human
/// (GC SPEC 6.5): 1000 + clamp(gap / 1500). 1000 with no human racing.
pub fn rubber_permille(w: *const World, c: *const Car) i32 {
    var lead: ?i32 = null;
    for (&w.cars) |*h| {
        if (h.human == world.no_human or !h.active) continue;
        const p = sim.progress_px(w, h);
        lead = if (lead) |l| @max(l, p) else p;
    }
    const target = lead orelse return 1000;
    const adj = @divTrunc((target - sim.progress_px(w, c)) * 1000, tuning.rubber_px);
    return 1000 + @max(tuning.rubber_min_permille, @min(tuning.rubber_max_permille, adj));
}

fn drive_crew(w: *const World, i: usize, cr: *const Crew) Input {
    var b: Input = .{};
    const c = &w.cars[i];
    const t = sim.track_of(w);
    const target = t.sample((@as(usize, c.progress) + cr.lookahead) & 255);
    // Lane offset along the target's right vector.
    var lane = lane_of(w, cr, i);
    var block_spd: i32 = std.math.maxInt(i32);
    if (cr.avoid) avoid(w, i, &lane, &block_spd);
    const tx = fixed.cos(target.tangent);
    const ty = fixed.sin(target.tangent);
    const gx = @as(i32, target.x) + ((-ty * lane) >> fixed.Q);
    const gy = @as(i32, target.y) + ((tx * lane) >> fixed.Q);
    var dx = gx - (c.x >> fixed.Q);
    var dy = gy - (c.y >> fixed.Q);
    dx = wrap_px(dx);
    dy = wrap_px(dy);
    const want = fixed.atan2(dy, dx);
    const err = fixed.turn_diff(c.heading, want);
    if (err > 400) b.right = true;
    if (err < -400) b.left = true;
    // Speed target from the curvature ahead.
    const curve = curvature(t, c.progress, cr.curve_ahead);
    const top = sim.top_of(c);
    const cap = @divTrunc(top * @as(i32, cr.speed_pct), 255);
    const slow = @min(curve, cr.full_brake_turn);
    const pct: i32 = 255 - @divTrunc((255 - @as(i32, cr.min_speed_pct)) * slow, cr.full_brake_turn);
    var want_spd = @divTrunc(cap * pct, 255);
    if (c.human == world.no_human) want_spd = @divTrunc(want_spd * rubber_permille(w, c), 1000);
    want_spd = @min(want_spd, block_spd);
    const spd = sim.speed(c);
    // Auto-throttle: brake when over the target; powerslide on a big
    // heading error at speed.
    if (spd > want_spd + @divTrunc(want_spd, 16)) b.down = true;
    if (@abs(err) > cr.slide_turn and spd > @divTrunc(tuning.top_speed, 4)) b.down = true;
    // BURST on a straight: a fresh press with a charge to spend. The near
    // window is already summed; scan the rest only when it is straight.
    if (cr.burst_ahead and c.burst == 0 and !c.up_was and c.burst_charges > 0 and
        w.phase == .racing and !c.finished and curve < cr.burst_curve and
        curve + curvature(t, @as(usize, c.progress) + cr.curve_ahead, cr.burst_window - cr.curve_ahead) < cr.burst_curve)
    {
        b.up = true;
    }
    return b;
}

/// Pass a slower car ahead: aim at a lane beside it, on the side with room
/// inside the track's half width; ease off when right behind it.
fn avoid(w: *const World, i: usize, lane: *i32, block_spd: *i32) void {
    const c = &w.cars[i];
    const hx = fixed.cos(c.heading);
    const hy = fixed.sin(c.heading);
    const s = sim.track_of(w).sample(c.progress);
    const half: i32 = s.half;
    // Own offset from the centerline (right of travel positive).
    const sx = fixed.cos(s.tangent);
    const sy = fixed.sin(s.tangent);
    const ox = wrap_px((c.x >> fixed.Q) - @as(i32, s.x));
    const oy = wrap_px((c.y >> fixed.Q) - @as(i32, s.y));
    const own_lat = (ox * -sy + oy * sx) >> fixed.Q;
    var nearest: i32 = tuning.avoid_ahead;
    for (&w.cars, 0..) |*o, j| {
        if (j == i) continue;
        if (!o.active or o.hop != 0 or o.wreck != .none) continue;
        const dx = wrap_px((o.x - c.x) >> fixed.Q);
        const dy = wrap_px((o.y - c.y) >> fixed.Q);
        if (@abs(dx) >= tuning.avoid_ahead or @abs(dy) >= tuning.avoid_ahead) continue;
        const along = (dx * hx + dy * hy) >> fixed.Q;
        if (along <= 0 or along >= nearest) continue;
        const lat = (dx * -hy + dy * hx) >> fixed.Q;
        if (@abs(lat) >= tuning.avoid_width) continue;
        // Only cars we are catching.
        const closing = (fixed.mul(c.vx - o.vx, hx) + fixed.mul(c.vy - o.vy, hy));
        if (closing <= 0) continue;
        nearest = along;
        const o_lat = own_lat + lat;
        const room = half - tuning.avoid_margin;
        var pass = if (o_lat > 0) o_lat - tuning.avoid_pass else o_lat + tuning.avoid_pass;
        if (pass < -room or pass > room) pass = if (o_lat > 0) o_lat + tuning.avoid_pass else o_lat - tuning.avoid_pass;
        lane.* = @max(-room, @min(room, pass));
        if (along < tuning.avoid_brake and @abs(lat) < tuning.avoid_brake_width) block_spd.* = sim.speed(o);
    }
}

inline fn wrap_px(d: i32) i32 {
    return ((d + 512) & 1023) - 512;
}
