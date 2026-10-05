//! Forked from snouty-zero/cart/src/ai.zig at f8f6962.
//! Driving by the centerline (Zero SPEC 5.3): the AI racers and the
//! autopilot steer toward a look-ahead sample with a lane offset and hold a
//! speed target from the curvature ahead. With the auto-throttle (SPEC 5.1)
//! the AI slows by braking, not by lifting. Every AI car produces the same
//! input byte a human does, so it obeys the same rules. Pure: reads the
//! World it is given, no globals, no cart API.
//!
//! Physics multipliers moved out of the characters into the cars' chassis
//! (SPEC 4.2); a `Crew` here is how a racer drives and fights (SPEC 4.3,
//! 6.5): target preference, reaction delay, aim noise, when to drop, and
//! LEGACY's ramming, ROOTKIT's stalking, and from M2 the pickup policy
//! (SPEC 4.3, 6.5 item 3: when to press B, and how long a CAPTCHA takes).
//!
//! `drive` reads the World only. The one piece of AI state, the aim and
//! its reaction counter (`Car.aim`, `aim_ticks`), is kept by `sim` through
//! `update_aim`, which draws its aim noise from the world PRNG.
const std = @import("std");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const track = @import("track.zig");
const sim = @import("sim.zig");
const weapons = @import("weapons.zig");
const pickups = @import("pickups.zig");

const World = world.World;
const Car = world.Car;
const Input = world.Input;
const no_car = world.no_car;

/// Whom a crew shoots at, among the cars in its weapon's reach (SPEC 4.3).
pub const Target = enum(u8) { nearest, leader, human };

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
    /// Combat (SPEC 4.3, 6.5). Target preference among cars in reach.
    target: Target = .nearest,
    /// Ticks a target must stay in reach (SPEAR PHISH: locked) before the
    /// crew fires.
    reaction: u8 = 8,
    /// Aim noise, px: the reach test's half width moves by a world-PRNG
    /// amount in [-jitter / 2, jitter] each tick, so a sloppy crew fires
    /// off the line (and misses) and sometimes hesitates.
    jitter: i32 = 4,
    /// Rear drops: also into corners with any car behind (SNOUTY's mines);
    /// with a car further off the line behind (LEGACY's firewall).
    drop_corners: bool = false,
    drop_wide: bool = false,
    /// Steer into a car alongside (LEGACY).
    rammer: bool = false,
    /// Sit behind the aimed-at car instead of passing it (ROOTKIT).
    stalk: bool = false,
    /// Pickups (SPEC 4.3, 6.5). Use every pickup the tick the roulette
    /// stops (KIDDIE); otherwise each waits for its trigger (`want_use`).
    pickup_now: bool = false,
    /// Save HEISENBUG and RACE CONDITION for the last lap (ROOTKIT).
    save_last_lap: bool = false,
    /// Save KERNEL PANIC and DDOS for whoever is 1st (BOTNET).
    save_for_leader: bool = false,
    /// Ticks this crew takes to "solve" a CAPTCHA (SPEC 6.3: 60 to 120,
    /// KIDDIE slowest).
    captcha_solve: u8 = 90,
};

/// Per racer, SPEC 4.1 order. Driving style only, for M0; M1 widens these
/// into SPEC 4.3's crews. SNOUTY is also the autopilot (attract, tests).
pub const crews = [6]Crew{
    // SNOUTY: patient, the line; waits for a lock, mines the corners.
    .{ .reaction = 12, .jitter = 2, .drop_corners = true, .captcha_solve = 75 },
    // LEGACY: slow, holds its line, pushes; rams anything beside it,
    // walls of fire for anyone behind.
    .{ .lane = -10, .min_speed_pct = 66, .full_brake_turn = 12000, .avoid = false, .reaction = 4, .jitter = 10, .rammer = true, .drop_wide = true, .captcha_solve = 100 },
    // KIDDIE: fast in, slides; sprays at anything the moment it is there.
    .{ .lane = 10, .min_speed_pct = 78, .slide_turn = 2400, .reaction = 1, .jitter = 14, .pickup_now = true, .captcha_solve = 120 },
    // SYSADMIN: clean lines, long snipes, hunts the humans first.
    .{ .lookahead = 7, .min_speed_pct = 76, .reaction = 6, .jitter = 2, .target = .human, .captcha_solve = 60 },
    // ROOTKIT: drifts across the lane, sits behind its mark and snipes.
    .{ .lane = 6, .wander_px = 14, .wander_rate = 65536 / 300, .reaction = 8, .jitter = 4, .stalk = true, .save_last_lap = true, .captcha_solve = 80 },
    // BOTNET: a committee at the wheel; always goes for the leader.
    .{ .lane = -6, .wander_px = 20, .wander_rate = 65536 / 200, .speed_pct = 245, .reaction = 6, .jitter = 8, .target = .leader, .save_for_leader = true, .captcha_solve = 110 },
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
    const fight = w.combat and w.phase == .racing and !c.finished and c.wreck == .none;
    const stalking = fight and cr.stalk and stalk(w, i, &lane, &block_spd);
    if (cr.avoid and !stalking) avoid(w, i, &lane, &block_spd);
    if (fight and cr.rammer) ram(w, i, &lane);
    if (w.combat) dodge_firewalls(w, i, &lane);
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
    if (fight) arm(w, i, cr, &b, curve);
    if (fight) switch (want_use(w, i, cr, curve)) {
        .no => {},
        .forward => {
            b.b = true;
            b.down = false;
        },
        .back => {
            b.b = true;
            b.down = true;
            b.a = false;
        },
    };
    // BIT FLIP: the crew steers against the flip, late: for the first
    // `ai_flip_lag` ticks of every 32 its hands follow the old habit, so it
    // weaves on the line (SPEC 6.3).
    if (c.bit_flip > 0 and c.bit_flip % 32 >= tuning.ai_flip_lag) {
        const l = b.left;
        b.left = b.right;
        b.right = l;
    }
    return b;
}

const Use = enum { no, forward, back };

/// When to press B (SPEC 4.3, 6.5 item 3): KIDDIE at once; everyone else
/// on the pickup's trigger. Tier C at once, except BOTNET's KERNEL PANIC
/// and DDOS (only at the leader) and ROOTKIT's last-lap HEISENBUG and RACE
/// CONDITION.
fn want_use(w: *const World, i: usize, cr: *const Crew, curve: i32) Use {
    const c = &w.cars[i];
    if (c.pickup == .none or c.roll_ticks > 0 or c.b_was or c.frozen > 0) return .no;
    const last_lap = c.lap + 1 >= tuning.laps;
    const behind = car_behind(w, i, tuning.ai_drop_behind, tuning.ai_drop_lat * 2);
    if (cr.pickup_now) {
        return if ((c.pickup == .honeypot or c.pickup == .spaghetti) and behind) .back else .forward;
    }
    const yes = switch (c.pickup) {
        .none => false,
        .prefetch => c.burst == 0 and curve < cr.burst_curve,
        .honeypot, .spaghetti => {
            if (behind) return .back;
            return if (car_ahead_on_line(w, i)) .forward else .no;
        },
        .duck => pickups.threatened(w, i),
        .hot_patch => @as(u32, c.armor) * 100 < @as(u32, c.armor_max) * tuning.ai_patch_pct or c.bit_flip > 0 or c.chain_ticks > 0,
        .fork_bomb => {
            return if (car_behind(w, i, tuning.ai_fork_behind, std.math.maxInt(i32))) .back else .no;
        },
        .bit_flip, .deadlock => pickups.ahead(w, i, tuning.ahead_range, true, no_car) != no_car,
        .ddos => blk: {
            const t = pickups.ahead(w, i, std.math.maxInt(i32), true, no_car);
            break :blk t != no_car and (!cr.save_for_leader or w.cars[t].rank == 1);
        },
        .heisenbug => !cr.save_last_lap or last_lap,
        .race_condition => last_lap and pickups.ahead(w, i, tuning.ai_race_px, true, no_car) != no_car,
        .kernel_panic => !cr.save_for_leader or c.rank != 1,
        .captcha, .sudo, .prompt_injection => true,
        .zero_day => pickups.ahead(w, i, std.math.maxInt(i32), false, no_car) != no_car,
    };
    return if (yes) .forward else .no;
}

/// A car on the ground within `dist` px behind and `lat` px of the line.
fn car_behind(w: *const World, i: usize, dist: i32, lat: i32) bool {
    const c = &w.cars[i];
    for (&w.cars, 0..) |*o, j| {
        if (j == i or !weapons.targetable(o) or o.hop != 0 or o.heisen > 0) continue;
        const r = weapons.rel(c, o);
        if (r.along < 0 and r.along >= -dist and @abs(r.lat) <= lat) return true;
    }
    return false;
}

/// A car ahead in a thrown HONEYPOT's or SPAGHETTI's landing zone.
fn car_ahead_on_line(w: *const World, i: usize) bool {
    const c = &w.cars[i];
    for (&w.cars, 0..) |*o, j| {
        if (j == i or !weapons.targetable(o) or o.heisen > 0) continue;
        const r = weapons.rel(c, o);
        if (r.along >= tuning.ai_throw_min and r.along <= tuning.ai_throw_max and @abs(r.lat) <= tuning.ai_throw_lat) return true;
    }
    return false;
}

/// Fire and drop (SPEC 6.5) on top of the driving input `b`. The rear
/// weapon is Down+A on a press edge; the front weapon is A without Down,
/// so a tick that brakes does not fire (the brake wins, except that a held
/// LANCE is let go: fired if charged, fizzled if not).
fn arm(w: *const World, i: usize, cr: *const Crew, b: *Input, curve: i32) void {
    const c = &w.cars[i];
    if (c.ammo_rear > 0 and c.rear_cd == 0 and !c.rear_was and want_drop(w, i, cr, curve)) {
        b.down = true;
        b.a = true;
        return;
    }
    const braking = b.down;
    switch (c.front) {
        .lance => {
            if (c.charge > 0) {
                const fire_now = c.charge >= tuning.lance_charge and c.aim_ticks >= cr.reaction;
                b.a = !(fire_now or braking);
            } else if (!braking and c.ammo_front > 0 and c.fire_cd == 0) {
                // Charge only on a straight.
                const t = sim.track_of(w);
                b.a = curve + curvature(t, @as(usize, c.progress) + cr.curve_ahead, cr.burst_window - cr.curve_ahead) < tuning.ai_lance_straight;
            }
        },
        else => b.a = !braking and c.ammo_front > 0 and c.aim_ticks >= cr.reaction,
    }
}

/// A car behind on the line (SPEC 6.5), or, for a `drop_corners` crew, any
/// car behind going into a corner.
fn want_drop(w: *const World, i: usize, cr: *const Crew, curve: i32) bool {
    const c = &w.cars[i];
    const lat_lim = if (cr.drop_wide) tuning.ai_drop_wide_lat else tuning.ai_drop_lat;
    for (&w.cars, 0..) |*o, j| {
        if (j == i or !weapons.targetable(o) or o.hop != 0 or o.heisen > 0) continue;
        const r = weapons.rel(c, o);
        if (r.along >= 0 or r.along < -tuning.ai_drop_behind) continue;
        if (@abs(r.lat) <= lat_lim) return true;
        if (cr.drop_corners and curve >= tuning.ai_drop_corner) return true;
    }
    return false;
}

/// The car the crew would shoot this tick: in the front weapon's reach
/// (widened or narrowed by `jit` px), by the crew's preference; `no_car`.
fn pick_target(w: *const World, i: usize, cr: *const Crew, jit: i32) u8 {
    const c = &w.cars[i];
    var best: u8 = no_car;
    var best_key: i32 = std.math.maxInt(i32);
    for (&w.cars, 0..) |*o, j| {
        if (j == i or !weapons.targetable(o) or o.hop != 0 or o.immune != 0 or o.heisen > 0) continue;
        const r = weapons.rel(c, o);
        if (r.along <= 0) continue;
        const reach: i32, const half: i32 = switch (c.front) {
            .ping => .{ @as(i32, tuning.ping_ttl) * 5, tuning.car_radius + tuning.shot_radius },
            .broadcast => .{ @as(i32, tuning.broadcast_ttl) * 5, tuning.car_radius + ((r.along * 93) >> 8) },
            .lance => .{ tuning.lance_range, tuning.car_radius + ((r.along * tuning.lance_spread_q8) >> 8) },
            .phish => .{ tuning.phish_range, tuning.car_radius + ((r.along * tuning.phish_spread_q8) >> 8) },
        };
        if (r.along > reach or @abs(r.lat) > half + jit) continue;
        const key: i32 = switch (cr.target) {
            .nearest => r.along,
            .leader => @as(i32, o.rank) * 1024 + r.along,
            .human => (if (o.human == world.no_human) @as(i32, 1024) else 0) + r.along,
        };
        if (key < best_key) {
            best_key = key;
            best = @intCast(j);
        }
    }
    return best;
}

/// The aim and its reaction counter for the next tick (called by `sim`
/// for every car, the humans too, for the autopilot). SPEAR PHISH crews
/// aim at their lock.
pub fn update_aim(w: *World, i: usize) void {
    const c = &w.cars[i];
    const cr = crew_of(c);
    var cand: u8 = no_car;
    if (w.combat and w.phase == .racing and c.wreck == .none and !c.finished and c.ammo_front > 0) {
        if (c.front == .phish) {
            cand = c.lock;
        } else {
            const span: u32 = @intCast(@divTrunc(3 * cr.jitter, 2) + 1);
            const jit = @as(i32, @intCast(weapons.rand(w) % span)) - @divTrunc(cr.jitter, 2);
            cand = pick_target(w, i, cr, jit);
        }
    }
    if (cand != no_car and cand == c.aim) {
        c.aim_ticks +|= 1;
    } else {
        c.aim = cand;
        c.aim_ticks = @intFromBool(cand != no_car);
    }
}

/// The car's lateral offset from the centerline at its sample, px (right
/// of travel positive), and that sample's half width.
fn own_lateral(w: *const World, c: *const Car) struct { lat: i32, half: i32 } {
    const s = sim.track_of(w).sample(c.progress);
    const sx = fixed.cos(s.tangent);
    const sy = fixed.sin(s.tangent);
    const ox = wrap_px((c.x >> fixed.Q) - @as(i32, s.x));
    const oy = wrap_px((c.y >> fixed.Q) - @as(i32, s.y));
    return .{ .lat = (ox * -sy + oy * sx) >> fixed.Q, .half = s.half };
}

/// LEGACY: a car alongside pulls the lane toward it.
fn ram(w: *const World, i: usize, lane: *i32) void {
    const c = &w.cars[i];
    const own = own_lateral(w, c);
    const room = own.half - tuning.avoid_margin;
    for (&w.cars, 0..) |*o, j| {
        if (j == i or !weapons.targetable(o) or o.hop != 0 or o.immune != 0 or o.heisen > 0) continue;
        const r = weapons.rel(c, o);
        if (@abs(r.along) > tuning.ai_ram_along or @abs(r.lat) > tuning.ai_ram_lat) continue;
        lane.* = std.math.clamp(own.lat + r.lat * 2, -room, room);
        return;
    }
}

/// ROOTKIT: sit in the aimed-at car's lane behind it, at its speed when
/// close. True while stalking (no passing then).
fn stalk(w: *const World, i: usize, lane: *i32, block_spd: *i32) bool {
    const c = &w.cars[i];
    if (c.aim == no_car) return false;
    const o = &w.cars[c.aim % world.car_count];
    const r = weapons.rel(c, o);
    if (r.along <= 0 or r.along > tuning.ai_stalk_range) return false;
    const own = own_lateral(w, c);
    const room = own.half - tuning.avoid_margin;
    lane.* = std.math.clamp(own.lat + r.lat, -room, room);
    if (r.along < 2 * tuning.avoid_brake) block_spd.* = sim.speed(o);
    return true;
}

/// Steer round a FIREWALL ahead whose span covers the lane (SPEC 6.2):
/// pass outside its nearer end when there is room on the track.
pub fn dodge_firewalls(w: *const World, i: usize, lane: *i32) void {
    const c = &w.cars[i];
    var own: ?@TypeOf(own_lateral(w, c)) = null;
    for (&w.drops) |*d| {
        if (d.kind != .firewall) continue;
        const dx = wrap_px((d.x - c.x) >> fixed.Q);
        const dy = wrap_px((d.y - c.y) >> fixed.Q);
        const hx = fixed.cos(c.heading);
        const hy = fixed.sin(c.heading);
        const along = (dx * hx + dy * hy) >> fixed.Q;
        if (along <= 0 or along > tuning.ai_firewall_ahead) continue;
        if (own == null) own = own_lateral(w, c);
        const o = own.?;
        const center = o.lat + ((dx * -hy + dy * hx) >> fixed.Q);
        const span: i32 = @as(i32, d.size) + tuning.ai_firewall_pass;
        if (@abs(lane.* - center) > span) continue;
        const room = o.half - tuning.ai_firewall_margin;
        const left = center - span;
        const right = center + span;
        const left_ok = left >= -room;
        const right_ok = right <= room;
        if (left_ok and (!right_ok or lane.* - left <= right - lane.*)) {
            lane.* = left;
        } else if (right_ok) lane.* = right;
    }
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
        if (!o.active or o.hop != 0 or o.wreck != .none or o.heisen > 0) continue;
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
