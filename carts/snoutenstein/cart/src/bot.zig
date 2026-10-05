//! A stand-in deathmatch player (M7) for the host tests, the previews and
//! the bench, and (M8) the player a party leaver hands its slot to
//! (`match.hand_over`). Reads only the World, so every badge running the
//! same match computes the same bot input; fixed point only, no cart-api.
//!
//! Its target is the nearest visible living foe (another team's player in
//! a team mode): the `look` nearest living foes by distance are tested for
//! line of sight, nearest first. With a target it picks a weapon by range
//! (M9, `pick`) and presses Select (every other tick, so each press is an
//! edge) until that weapon comes up, turns to face the target, fires once
//! aimed and safe (no rocket, Debugger bolt or fork bomb at point blank),
//! holds the range its weapon wants (`tune`) and now and then strafes.
//! Without a target it walks, turning away from walls (which way changes
//! every 1.5 s) and every few seconds toward the nearest foe's bearing;
//! holding only the starting zapper and swatter it instead heads for the
//! nearest present weapon pad: straight at it when in sight, else homing
//! on its bearing now and then. Cost per bot per tick: at most `look` + 1
//! rays (16 bots on Data Hall stay inside the bench gate).
const std = @import("std");
const fixed = @import("fixed.zig");
const state = @import("state.zig");
const levels = @import("levels.zig");
const sim = @import("sim.zig");
const match = @import("match.zig");
const arsenal = @import("arsenal.zig");

const Fixed = fixed.Fixed;
const Buttons = state.Buttons;
const Weapon = state.Weapon;

/// Can `slot` fire `wp` (owned, with ammo; campaign weapons as sim.zig
/// counts them).
const has_ammo = arsenal.has_ammo;

fn mix(a: u32) u32 {
    var x = a *% 0x9E37_79B9;
    x ^= x >> 15;
    x *%= 0x85EB_CA6B;
    x ^= x >> 13;
    return x;
}

fn steer(b: *Buttons, d: i16) void {
    const dead_zone: i16 = @intCast(sim.turn_speed / 2);
    if (d > dead_zone) b.right = true else if (d < -dead_zone) b.left = true;
}

/// Distances are compared squared, in 1/256 cell^2 (`d2 >> 24` of the
/// fixed-point square): one 32-bit compare each.
fn sq(comptime c: f32) u32 {
    return @intFromFloat(c * c * 256.0);
}
fn within(dd: u32, s: u32) bool {
    return dd < s;
}

/// Line-of-sight tests per bot per tick (the nearest living foes first).
pub const look = 3;

/// The weapon `slot` wants against a foe at squared distance `dd`. Close:
/// the Garbage Collector (from 2.5 cells, spinning up while it closes in),
/// else the swatter inside its reach. Mid range: SHIP IT from 2.25 cells
/// (2 while held: its splash reaches 1.75), now and then a fork bomb at
/// 2..4.5 cells, the spray inside 3.5, the Fuzzer, the Debugger beyond its
/// 1.5-cell burst, the zapper. Far: Fuzzer, Debugger, zapper, SHIP IT.
pub fn pick(m: *const state.Match, slot: usize, dd: u32, t: u32) Weapon {
    const cur = m.players[slot].weapon;
    const salt: u32 = @intCast(slot);
    if (has_ammo(m, slot, .gc) and within(dd, sq(2.5))) return .gc;
    if (within(dd, if (cur == .swatter) sq(1.5) else sq(1.1))) {
        return if (has_ammo(m, slot, .spray)) .spray else .swatter;
    }
    const rocket_min = if (cur == .ship_it) sq(2.0) else sq(2.25);
    if (within(dd, sq(6))) {
        if (has_ammo(m, slot, .fork_bomb) and !within(dd, sq(2)) and within(dd, sq(4.5)) and
            ((t >> 6) +% salt) % 4 == 0) return .fork_bomb;
        if (has_ammo(m, slot, .ship_it) and !within(dd, rocket_min)) return .ship_it;
        if (has_ammo(m, slot, .spray) and within(dd, sq(3.5))) return .spray;
        if (has_ammo(m, slot, .fuzzer)) return .fuzzer;
        if (has_ammo(m, slot, .debugger) and !within(dd, sq(2.25))) return .debugger;
        if (has_ammo(m, slot, .zapper)) return .zapper;
        return .swatter;
    }
    const far = [_]Weapon{ .fuzzer, .debugger, .zapper, .ship_it };
    for (far) |wp| if (has_ammo(m, slot, wp)) return wp;
    return .swatter;
}

/// Per weapon, in `state.Weapon` order: the range it wants (walk in
/// beyond `hi`, back off inside `lo`) and when to fire it: aimed within
/// `aim`, at least `min` away (the splash weapons) and at most `max`.
const Tune = struct { lo: u32, hi: u32, aim: fixed.Angle, min: u32, max: u32 };
const any_range = sq(24);
const tune = [8]Tune{
    .{ .lo = 0, .hi = sq(0.7), .aim = fixed.deg(10), .min = 0, .max = sq(1.2) }, // swatter
    .{ .lo = sq(1.5), .hi = sq(3), .aim = fixed.deg(5), .min = 0, .max = any_range }, // zapper
    .{ .lo = sq(1.0), .hi = sq(2.5), .aim = fixed.deg(8), .min = 0, .max = any_range }, // spray
    .{ .lo = sq(2.5), .hi = sq(5), .aim = fixed.deg(4), .min = sq(1.75), .max = any_range }, // debugger
    .{ .lo = sq(1.5), .hi = sq(3), .aim = fixed.deg(5), .min = 0, .max = any_range }, // fuzzer
    .{ .lo = sq(3), .hi = sq(4.5), .aim = fixed.deg(10), .min = sq(1.75), .max = any_range }, // fork bomb
    .{ .lo = sq(2.5), .hi = sq(5), .aim = fixed.deg(4), .min = sq(2.0), .max = any_range }, // ship it
    // Garbage Collector: hold A from 2.5 cells to spin up while closing in.
    .{ .lo = 0, .hi = sq(0.7), .aim = fixed.deg(180), .min = 0, .max = sq(2.5) }, // gc
};

pub fn think(w: *const match.World, level: *const levels.Level, slot: usize) Buttons {
    const m = &w.m;
    const me = &m.players[slot];
    var b: Buttons = .{};
    if (!m.alive(slot)) return b;
    const t = w.gs.tick;
    const salt: u32 = @intCast(slot);
    if (!has_ammo(m, slot, me.weapon)) b.select = t & 1 == 0;
    // The `look` nearest living foes, nearest first (lower slot on a tie).
    var near: [look]u8 = undefined;
    var near_d: [look]i64 = undefined;
    var nn: usize = 0;
    for (0..state.max_players) |j| {
        if (!m.foes(slot, j) or !m.alive(j)) continue;
        const o = &m.players[j];
        const dx: i64 = o.x - me.x;
        const dy: i64 = o.y - me.y;
        const d2 = dx * dx + dy * dy;
        var k: usize = nn;
        while (k > 0 and near_d[k - 1] > d2) : (k -= 1) {
            if (k < look) {
                near[k] = near[k - 1];
                near_d[k] = near_d[k - 1];
            }
        }
        if (k < look) {
            near[k] = @intCast(j);
            near_d[k] = d2;
            if (nn < look) nn += 1;
        }
    }
    var target: ?usize = null;
    var target_d2: i64 = 0;
    for (near[0..nn], near_d[0..nn]) |j, d2| {
        const o = &m.players[j];
        if (sim.line_of_sight(&w.gs, level, me.x, me.y, o.x, o.y)) {
            target = j;
            target_d2 = d2;
            break;
        }
    }
    if (target) |j| {
        const o = &m.players[j];
        const d = fixed.angle_diff(fixed.atan2(o.y - me.y, o.x - me.x), me.angle);
        const ad: i32 = if (d < 0) -@as(i32, d) else d;
        const dd: u32 = @intCast(target_d2 >> 24);
        const want = pick(m, slot, dd, t);
        if (want != me.weapon) b.select = t & 1 == 0;
        const r = tune[@backingInt(me.weapon)];
        if (!within(dd, r.hi)) b.up = true else if (within(dd, r.lo)) b.down = true;
        if (ad < fixed.deg(10) and (t / 40 +% salt) % 3 == 0) {
            b.b = true;
            if ((t / 40) & 1 == 0) b.left = true else b.right = true;
        } else {
            steer(&b, d);
        }
        // The fork bomb pulses A (an edge every 8 ticks).
        if (ad < r.aim and !within(dd, r.min) and within(dd, r.max) and
            (me.weapon != .fork_bomb or t & 7 < 4)) b.a = true;
        return b;
    }
    // Only the starting zapper and swatter: head for the nearest present
    // weapon pad, straight at it if it is in sight (one ray), else its
    // bearing in the wander's homing phase below. Never the Debugger: the
    // bots do not know where the secret walls are.
    var home = false;
    var hx: Fixed = 0;
    var hy: Fixed = 0;
    if (m.owned[slot] == 0 and !has_ammo(m, slot, .spray) and !has_ammo(m, slot, .debugger)) {
        var best_d2: i64 = std.math.maxInt(i64);
        const np = @min(level.pickups.len, state.max_match_pickups);
        for (level.pickups[0..np], 0..) |pk, k| {
            if (pk.kind != .pad or !state.pickup_present(&w.gs, k)) continue;
            const px = fixed.from_int(pk.x) + fixed.half;
            const py = fixed.from_int(pk.y) + fixed.half;
            const dx: i64 = px - me.x;
            const dy: i64 = py - me.y;
            const d2 = dx * dx + dy * dy;
            if (d2 < best_d2) {
                home = true;
                best_d2 = d2;
                hx = px;
                hy = py;
            }
        }
        if (home and sim.line_of_sight(&w.gs, level, me.x, me.y, hx, hy)) {
            const d = fixed.angle_diff(fixed.atan2(hy - me.y, hx - me.x), me.angle);
            steer(&b, d);
            const ad: i32 = if (d < 0) -@as(i32, d) else d;
            if (ad < fixed.deg(45)) b.up = true;
            return b;
        }
    }
    const ahead = sim.wall_distance(&w.gs, level, me.x, me.y, me.angle);
    if (ahead < fixed.one) {
        if (mix(t / 90 +% salt *% 7) & 1 == 0) b.right = true else b.left = true;
        return b;
    }
    b.up = true;
    if ((t / 120 +% salt) % 2 == 0 and (home or nn > 0)) {
        if (!home) {
            hx = m.players[near[0]].x;
            hy = m.players[near[0]].y;
        }
        steer(&b, fixed.angle_diff(fixed.atan2(hy - me.y, hx - me.x), me.angle));
    }
    return b;
}
