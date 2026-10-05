//! The BATTLE hunter (SPEC 8.3, M6): how an AI crew drives and fights in
//! an arena, where there is no centerline to follow. New for Snouty GC.
//!
//! Each tick the crew picks a goal (`goal_of`): its target car (the
//! nearest, biased by crew to the human and to the kill leader, toward
//! the hurt and the one already aimed at), or a service bay when its armor
//! is low, or with nobody to hunt the nearest RMA crate. It drives straight
//! at the goal when it has a clear ground line to it (`clear`: no wall,
//! pit, ramp or kicker on the way), else along the arena's navigation
//! field: `Car.nav` is the waypoint it heads for, kept by `update_nav`
//! (called by `sim` for every car each battle tick, like `ai.update_aim`),
//! moving on to the next hop toward the goal's node as it arrives or sees
//! past it, and over a jump edge (a kicker or a gap jump) as a committed
//! leg (`jump_bit`): straight at the landing node, BURST if it has one.
//! It fires in the weapon cone with its race habits (`ai.arm`), drops rear
//! weapons on a chaser, uses pickups by its policy (`ai.want_use`, whose
//! "ahead" is the arena's cone), and keeps off the Sweeper's path.
//!
//! `drive` is pure in the World (and the arena cache); `update_nav` writes
//! only `Car.nav`. No globals written, no cart API.
const std = @import("std");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const track = @import("track.zig");
const sim = @import("sim.zig");
const ai = @import("ai.zig");
const hazards = @import("hazards.zig");
const pickups = @import("pickups.zig");

const World = world.World;
const Car = world.Car;
const Input = world.Input;
const no_car = world.no_car;
const no_node = track.no_node;

/// `Car.nav` with this bit set: the car is on a committed jump leg toward
/// that node (the line to it crosses a pit, so no clear-line test).
pub const jump_bit: u8 = 0x80;

/// A world point, whole px (wrapping like cars).
const Pt = struct { x: i32, y: i32 };

fn pos(c: *const Car) Pt {
    return .{ .x = c.x >> fixed.Q, .y = c.y >> fixed.Q };
}

fn node_pt(k: u8) Pt {
    const n = track.arena.nodes[k % track.nav_max];
    return .{ .x = n.x, .y = n.y };
}

inline fn wrap_px(d: i32) i32 {
    return ((d + 512) & 1023) - 512;
}

fn dist2(a: Pt, b: Pt) i32 {
    const dx = wrap_px(b.x - a.x);
    const dy = wrap_px(b.y - a.y);
    return dx * dx + dy * dy;
}

fn dist(a: Pt, b: Pt) i32 {
    return @intCast(fixed.isqrt(@intCast(dist2(a, b))));
}

/// Floor a car may cross on the ground on purpose: no wall, no pit, no
/// ramp or kicker (those launch it).
fn ground(a: track.Attr) bool {
    return switch (a) {
        .surface, .coolant, .bay, .vent, .start, .sector1, .sector2 => true,
        else => false,
    };
}

/// A clear ground line for a car from `a` to `b`: three rays (the line and
/// `tuning.hunt_clear_px` either side), sampled every `hunt_ray_step` px.
pub fn clear(w: *const World, a: Pt, b: Pt) bool {
    const t = sim.track_of(w);
    const dx = wrap_px(b.x - a.x);
    const dy = wrap_px(b.y - a.y);
    const len: i32 = @intCast(fixed.isqrt(@intCast(dx * dx + dy * dy)));
    if (len == 0) return true;
    const ux = @divTrunc(dx << fixed.Q, len);
    const uy = @divTrunc(dy << fixed.Q, len);
    const ox = (-uy * tuning.hunt_clear_px) >> fixed.Q;
    const oy = (ux * tuning.hunt_clear_px) >> fixed.Q;
    var s: i32 = 0;
    while (s <= len) : (s += tuning.hunt_ray_step) {
        const x = a.x + ((ux * s) >> fixed.Q);
        const y = a.y + ((uy * s) >> fixed.Q);
        if (!ground(t.attr_at(x, y)) or !ground(t.attr_at(x + ox, y + oy)) or !ground(t.attr_at(x - ox, y - oy))) return false;
    }
    return true;
}

// --- The goal ---------------------------------------------------------------------

pub const Goal = struct {
    /// Where to go, px.
    at: Pt,
    /// The car hunted (`no_car` for a bay or a crate).
    car: u8 = no_car,
    /// Going to (or holding at) a service bay.
    bay: bool = false,
};

/// The crew's battle character (SPEC 4.3, 8.3): its bias in px toward the
/// human and the kill leader, and the armor share under which it retreats
/// to a bay (0: never; KIDDIE never reads the docs).
pub const Hunter = struct { human_px: i32 = 60, leader_px: i32 = 40, retreat_pct: u32 = 30 };
pub const hunters = [6]Hunter{
    // SNOUTY: patient; a little drawn to whoever leads.
    .{ .human_px = 40, .leader_px = 80 },
    // LEGACY: spiteful; whoever is nearest, retreats late.
    .{ .human_px = 20, .leader_px = 0, .retreat_pct = 20 },
    // KIDDIE: goes for the human, never retreats.
    .{ .human_px = 120, .leader_px = 0, .retreat_pct = 0 },
    // SYSADMIN: hunts the humans first.
    .{ .human_px = 260, .leader_px = 40 },
    // ROOTKIT: the nearest, from behind; careful.
    .{ .human_px = 60, .leader_px = 40, .retreat_pct = 40 },
    // BOTNET: always the kill leader.
    .{ .human_px = 40, .leader_px = 260 },
};

pub fn hunter_of(c: *const Car) *const Hunter {
    return &hunters[c.racer % hunters.len];
}

/// May car `o` be hunted: in the round, on the floor or in the air, not
/// wrecked, observable, not in SAFE MODE.
fn huntable(o: *const Car) bool {
    return o.active and o.wreck == .none and !o.finished and o.heisen == 0 and o.immune == 0;
}

/// Is the car retreating to a bay: below its crew's armor share, or on a
/// bay and not yet repaired to `tuning.hunt_repaired_pct`.
fn retreating(c: *const Car, h: *const Hunter) bool {
    if (h.retreat_pct == 0 or track.arena.node_n == 0) return false;
    const armor = @as(u32, c.armor) * 100;
    const max = @as(u32, c.armor_max);
    return armor < max * h.retreat_pct or (c.on_bay and armor < max * tuning.hunt_repaired_pct);
}

/// This tick's goal for car `i`.
pub fn goal_of(w: *const World, i: usize) Goal {
    const c = &w.cars[i];
    const h = hunter_of(c);
    const me = pos(c);
    const a = &track.arena;
    if (retreating(c, h)) {
        var best: u8 = no_node;
        var best_d: i32 = std.math.maxInt(i32);
        for (a.nodes[0..a.node_n], 0..) |n, k| {
            if (n.flags & track.node_bay == 0) continue;
            const d = dist2(me, .{ .x = n.x, .y = n.y });
            if (d < best_d) {
                best_d = d;
                best = @intCast(k);
            }
        }
        if (best != no_node) return .{ .at = node_pt(best), .bay = true };
    }
    var best: u8 = no_car;
    var best_key: i32 = std.math.maxInt(i32);
    for (&w.cars, 0..) |*o, j| {
        if (j == i or !huntable(o)) continue;
        var key = dist(me, pos(o));
        if (o.human != world.no_human) key -= h.human_px;
        if (j == w.battle.leader) key -= h.leader_px;
        if (j == c.aim) key -= tuning.hunt_stick_px;
        key -= @as(i32, o.armor_max) - o.armor;
        if (key < best_key) {
            best_key = key;
            best = @intCast(j);
        }
    }
    if (best != no_car) {
        const o = &w.cars[best];
        // Lead the target by where it will be.
        const lead = tuning.hunt_lead_ticks;
        return .{ .at = .{ .x = (o.x + o.vx * lead) >> fixed.Q, .y = (o.y + o.vy * lead) >> fixed.Q }, .car = best };
    }
    // Nobody to hunt: the nearest RMA crate that is there.
    var crate: Pt = me;
    var crate_d: i32 = std.math.maxInt(i32);
    for (track.crate_spots[0..track.crate_n], 0..) |s, k| {
        if (w.crates[k] != 0) continue;
        const p = Pt{ .x = s.x, .y = s.y };
        const d = dist2(me, p);
        if (d < crate_d) {
            crate_d = d;
            crate = p;
        }
    }
    return .{ .at = crate };
}

// --- The waypoint (sim writes it) -------------------------------------------------

/// The nearest node with a clear ground line from `p` (`no_node` if none).
fn visible_node(w: *const World, p: Pt) u8 {
    const a = &track.arena;
    var tried: u64 = 0;
    // Nearest first: up to `hunt_scan` tries.
    var n: u8 = 0;
    while (n < tuning.hunt_scan) : (n += 1) {
        var best: u8 = no_node;
        var best_d: i32 = std.math.maxInt(i32);
        for (a.nodes[0..a.node_n], 0..) |nd, k| {
            if (tried & (@as(u64, 1) << @intCast(k)) != 0) continue;
            const d = dist2(p, .{ .x = nd.x, .y = nd.y });
            if (d < best_d) {
                best_d = d;
                best = @intCast(k);
            }
        }
        if (best == no_node) return no_node;
        if (clear(w, p, node_pt(best))) return best;
        tried |= @as(u64, 1) << @intCast(best);
    }
    return a.cell_node(p.x, p.y);
}

/// Is car `c` still on its jump leg from node `from` to node `to`: ahead of
/// the approach along the line, before the landing, near the line, moving
/// along it.
fn on_leg(c: *const Car, from: u8, to: u8) bool {
    const a = node_pt(from);
    const b = node_pt(to);
    const p = pos(c);
    const ex = wrap_px(b.x - a.x);
    const ey = wrap_px(b.y - a.y);
    const len: i32 = @intCast(fixed.isqrt(@intCast(ex * ex + ey * ey)));
    if (len == 0) return false;
    const px = wrap_px(p.x - a.x);
    const py = wrap_px(p.y - a.y);
    const along = @divTrunc(px * ex + py * ey, len);
    const lat = @divTrunc(px * ey - py * ex, len);
    const moving = fixed.mul(c.vx, ex << 8) + fixed.mul(c.vy, ey << 8) > 0;
    return along > -tuning.hunt_reach and along < len and @abs(lat) <= tuning.hunt_leg_lat and (moving or c.hop > 0);
}

/// Keep car `i`'s waypoint (`Car.nav`) for the next tick (battle only;
/// called by `sim` for every car in the round).
pub fn update_nav(w: *World, i: usize) void {
    const c = &w.cars[i];
    const a = &track.arena;
    if (a.node_n == 0 or !c.active or c.wreck != .none) {
        c.nav = no_node;
        return;
    }
    const me = pos(c);
    const g = goal_of(w, i);
    const gn = a.cell_node(g.at.x, g.at.y);
    var nav = c.nav;
    // A jump leg holds until the car is down past it or off its line.
    if (nav != no_node and nav & jump_bit != 0) {
        const to = nav & ~jump_bit;
        if (c.hop > 0) return;
        if (dist2(me, node_pt(to)) > tuning.hunt_reach * tuning.hunt_reach and heading_to(c, node_pt(to))) return;
        nav = to;
    }
    // Staggered (one car in four a tick): check the waypoint is still in
    // sight, and look past it.
    const due = (w.tick +% @as(u32, @intCast(i))) % tuning.hunt_every == 0;
    if (nav >= a.node_n) {
        nav = visible_node(w, me);
    } else if (due and c.hop == 0 and !clear(w, me, node_pt(nav))) {
        nav = visible_node(w, me);
    }
    if (nav == no_node or gn == no_node) {
        c.nav = nav;
        return;
    }
    // Arrived: on to the next hop (over its jump when that is the way).
    var k: u8 = 0;
    while (k < 2 and nav != gn) : (k += 1) {
        var next = a.hop(nav, gn);
        if (next == no_node) break;
        const here = dist2(me, node_pt(nav)) <= tuning.hunt_reach * tuning.hunt_reach;
        if (a.nodes[nav].jump == next) {
            // Over the jump only at its run-up speed (a little under with a
            // BURST to spend); too slow, the ground way.
            const need = a.nodes[nav].need();
            const spd = along_speed(c, node_pt(nav), node_pt(next));
            const fast = spd >= need or (c.burst_charges > 0 and spd * 5 >= need * 4);
            if (fast) {
                if (here or on_leg(c, nav, next)) nav = next | jump_bit;
                break;
            }
            next = a.ground_hop(nav, gn);
            if (next == no_node) break;
        }
        if (here or (due and clear(w, me, node_pt(next)))) {
            nav = next;
        } else break;
    }
    c.nav = nav;
}

/// The car's speed along the line from `a` to `b`, Q16 px/tick.
fn along_speed(c: *const Car, a: Pt, b: Pt) i32 {
    const ex = wrap_px(b.x - a.x);
    const ey = wrap_px(b.y - a.y);
    const len: i32 = @intCast(fixed.isqrt(@intCast(ex * ex + ey * ey)));
    if (len == 0) return 0;
    return @divTrunc(fixed.mul(c.vx, ex << fixed.Q) + fixed.mul(c.vy, ey << fixed.Q), len);
}

/// Is the car heading for `p` (within `hunt_leg_turn` of the bearing)?
fn heading_to(c: *const Car, p: Pt) bool {
    const me = pos(c);
    const want = fixed.atan2(wrap_px(p.y - me.y), wrap_px(p.x - me.x));
    return @abs(fixed.turn_diff(c.heading, want)) < tuning.hunt_leg_turn;
}

// --- Driving ----------------------------------------------------------------------

/// One tick of input for car `i` in battle, by its crew.
pub fn drive(w: *const World, i: usize, cr: *const ai.Crew) Input {
    var b: Input = .{};
    const c = &w.cars[i];
    if (!c.active or c.wreck != .none) return b;
    const me = pos(c);
    const g = goal_of(w, i);
    var to = g.at;
    var leg = false;
    // Straight at the target when the way is clear and it is near enough
    // to look; else the waypoint.
    const direct = c.hop == 0 and g.car != no_car and dist2(me, g.at) <= tuning.hunt_sight * tuning.hunt_sight and clear(w, me, g.at);
    if (!direct and c.nav != no_node) {
        leg = c.nav & jump_bit != 0;
        to = node_pt(c.nav & ~jump_bit);
    }
    var want = fixed.atan2(wrap_px(to.y - me.y), wrap_px(to.x - me.x));
    // Nose to nose with the target and slow: swing off to the side (cars
    // cannot reverse; two hunters would shove each other forever).
    const close = direct and dist2(me, g.at) < tuning.hunt_close_px * tuning.hunt_close_px and sim.speed(c) < fixed.one;
    if (close and dist2(me, g.at) < tuning.hunt_close_px * tuning.hunt_close_px and sim.speed(c) < fixed.one) {
        // The side with floor ahead (by car index first, so two cars part).
        const first: fixed.Turn = if (i % 2 == 0) 16384 else 49152;
        const t = sim.track_of(w);
        const side = for ([2]fixed.Turn{ first, first +% 32768 }) |s| {
            const d = want +% s;
            const px = me.x + ((fixed.cos(d) * tuning.hunt_close_px) >> fixed.Q);
            const py = me.y + ((fixed.sin(d) * tuning.hunt_close_px) >> fixed.Q);
            if (ground(t.attr_at(px, py))) break s;
        } else first +% 32768;
        want +%= side;
    }
    var err = fixed.turn_diff(c.heading, want);
    // The Sweeper: turn off its path while it would meet the car.
    if (cr.heed_hazards and !leg) {
        if (sweeper_escape(w, c)) |away| err = fixed.turn_diff(c.heading, away);
    }
    // A dogfight: a target close and far off the nose. Two hunters that
    // both turn in circle each other forever, so extend straight out and
    // come back round for a head-on pass.
    const extend = direct and !close and @abs(err) > tuning.hunt_extend_turn and
        dist2(me, g.at) < tuning.hunt_extend_px * tuning.hunt_extend_px and !blocked(w, c);
    if (extend) err = 0;
    // A pit, or a ramp that would launch it, on its course off a jump leg:
    // powerslide toward the side with floor (a brake alone rolls it in).
    const pit_ahead = !leg and c.hop == 0 and (pit_on_course(w, c) or (sim.speed(c) < fixed.one and blocked(w, c) and @abs(err) < 8192));
    if (pit_ahead) {
        const t = sim.track_of(w);
        const right = c.heading +% 16384;
        const rx = me.x + ((fixed.cos(right) * tuning.hunt_close_px) >> fixed.Q);
        const ry = me.y + ((fixed.sin(right) * tuning.hunt_close_px) >> fixed.Q);
        const go_right = if (ground(t.attr_at(rx, ry))) err >= 0 or !ground_left(w, c) else false;
        err = if (go_right) 16384 else -16384;
        // Powerslide only at speed: slow, the steering is sharp enough and
        // the brake would only stall it on the lip.
        b.down = sim.speed(c) > tuning.hunt_slide_speed;
    }
    if (err > 400) b.right = true;
    if (err < -400) b.left = true;
    const spd = sim.speed(c);
    const top = sim.top_of(c);
    if (!leg and !pit_ahead) {
        // Brake into a hard turn; powerslide a wide one at speed.
        if (@abs(err) > tuning.hunt_brake_turn and spd > (top * 2) >> 2) b.down = true;
        if (@abs(err) > cr.slide_turn and spd > top >> 1) b.down = true;
        // Hold at the bay: crawl onto its middle.
        if (g.bay and c.on_bay and spd > top >> 2) b.down = true;
    } else if (c.burst == 0 and !c.up_was and c.burst_charges > 0 and @abs(err) < 2000 and spd < top) {
        // Over the pit: BURST for the run-up.
        b.up = true;
    }
    // BURST to close on a target straight ahead.
    if (direct and !b.up and c.burst == 0 and !c.up_was and c.burst_charges > 1 and @abs(err) < 1500 and
        dist2(me, g.at) > tuning.hunt_burst_px * tuning.hunt_burst_px)
    {
        b.up = true;
    }
    const fight = w.combat and w.phase == .racing and !c.finished and c.safe == 0;
    if (fight and !leg) {
        ai.arm(w, i, cr, &b, 0);
        switch (ai.want_use(w, i, cr, 0)) {
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
        }
    }
    // BIT FLIP: as on a track, the crew steers against it, late.
    if (c.bit_flip > 0 and c.bit_flip % 32 >= tuning.ai_flip_lag) {
        const l = b.left;
        b.left = b.right;
        b.right = l;
    }
    return b;
}

/// Will the car's course (its velocity a quarter, half and all of
/// `hunt_pit_ticks` ahead, at least `hunt_pit_min` px) put its centre over
/// a pit, or over a ramp or kicker that would launch it?
fn pit_on_course(w: *const World, c: *const Car) bool {
    const t = sim.track_of(w);
    const spd = sim.speed(c);
    if (spd < fixed.one / 8) return false;
    // Look at least `hunt_pit_min` px ahead along the velocity.
    const reach = @max(fixed.mul(spd, tuning.hunt_pit_ticks << fixed.Q), tuning.hunt_pit_min << fixed.Q);
    const ux = @divTrunc(c.vx << 8, spd >> 8);
    const uy = @divTrunc(c.vy << 8, spd >> 8);
    for ([3]i32{ 4, 2, 1 }) |d| {
        const run = @divTrunc(reach, d);
        const x = (c.x + fixed.mul(ux, run)) >> fixed.Q;
        const y = (c.y + fixed.mul(uy, run)) >> fixed.Q;
        switch (t.attr_at(x, y)) {
            .off => return true,
            // A ramp it would take off from: fine at the jump's speed (a
            // car that fast clears what is past it), else keep off it.
            .kicker, .jump => |a| {
                const f = track.facing(t.tile_at(x, y));
                const along = f[0] * c.vx + f[1] * c.vy;
                const need = if (a == .kicker) tuning.hunt_kicker_speed else tuning.hunt_jump_speed;
                if (along > 0) return along < need;
            },
            else => {},
        }
    }
    return false;
}

/// A wall or a pit `hunt_close_px` off the nose.
fn blocked(w: *const World, c: *const Car) bool {
    const t = sim.track_of(w);
    return !ground(t.attr_at((c.x >> fixed.Q) + ((fixed.cos(c.heading) * tuning.hunt_close_px) >> fixed.Q), (c.y >> fixed.Q) + ((fixed.sin(c.heading) * tuning.hunt_close_px) >> fixed.Q)));
}

/// Floor on the car's left, `hunt_close_px` off.
fn ground_left(w: *const World, c: *const Car) bool {
    const t = sim.track_of(w);
    const left = c.heading -% 16384;
    return ground(t.attr_at((c.x >> fixed.Q) + ((fixed.cos(left) * tuning.hunt_close_px) >> fixed.Q), (c.y >> fixed.Q) + ((fixed.sin(left) * tuning.hunt_close_px) >> fixed.Q)));
}

/// While a mover (the Sweeper) is crossing toward the car's path: the
/// heading that leaves its path the short way, else null.
fn sweeper_escape(w: *const World, c: *const Car) ?fixed.Turn {
    for (track.hazard_specs[0..track.hazard_n], 0..) |*h, k| {
        if (h.kind != .mover) continue;
        const reach = h.size + tuning.car_radius + tuning.ai_hazard_clear;
        var t: u32 = 0;
        while (t <= tuning.hunt_hazard_ahead) : (t += 6) {
            const p = hazards.future(w, k, t);
            if (p.state != .active) continue;
            const fx = (c.x + c.vx * @as(i32, @intCast(t))) >> fixed.Q;
            const fy = (c.y + c.vy * @as(i32, @intCast(t))) >> fixed.Q;
            const dx = wrap_px(fx - (p.x >> fixed.Q));
            const dy = wrap_px(fy - (p.y >> fixed.Q));
            if (dx * dx + dy * dy > reach * reach) continue;
            // Across the mover's line, away from it.
            const lat = (wrap_px((c.x >> fixed.Q) - h.x0) * -h.uy + wrap_px((c.y >> fixed.Q) - h.y0) * h.ux) >> fixed.Q;
            const side: i32 = if (lat >= 0) 1 else -1;
            return fixed.atan2(side * h.ux, side * -h.uy);
        }
    }
    return null;
}
