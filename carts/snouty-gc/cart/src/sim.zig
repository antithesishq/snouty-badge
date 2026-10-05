//! Forked from snouty-zero/cart/src/sim.zig at f8f6962.
//! One race tick (SPEC 5, 11): wheeled driving with the auto-throttle,
//! tile attributes under the footprint, walls, wrecks and respawn, car
//! contacts, laps and sectors, rank, the countdown; from M1 armor, damage
//! and kill credit, ramming, wall damage, hulks, and the weapons
//! (`weapons.zig`) and AI aim (`ai.zig`) it drives; from M2 the pickups
//! (`pickups.zig`: crates, rolls, status effects); from M3 the track
//! hazards and service bays (`hazards.zig`) and the race rules of
//! GARBAGE COLLECTION and attract (`gc_mode.zig`).
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
const weapons = @import("weapons.zig");
const pickups = @import("pickups.zig");
const hazards = @import("hazards.zig");
const gc_mode = @import("gc_mode.zig");
const battle = @import("battle.zig");
const hunt = @import("hunt.zig");

const World = world.World;
const Car = world.Car;
const Input = world.Input;

const world_mask: i32 = (1024 << fixed.Q) - 1;

/// The track (or in BATTLE the arena) the World runs on.
pub fn track_of(w: *const World) *const track.Track {
    return table_of(w.mode, w.track);
}

/// `Setup.track` / `World.track` indexes `track.arenas` in battle,
/// `track.tracks` otherwise.
pub fn table_of(mode: world.Mode, i: u8) *const track.Track {
    // M7: the loaded pack track or arena (pack.zig).
    if (i >= track.pack_base) return &track.pack_track;
    if (mode == .battle) return track.arenas[i % track.arenas.len];
    return track.tracks[i % track.tracks.len];
}

/// A new race from a shared setup (SPEC 7.3): car i is racer i with its
/// chassis; the humans' racers take their input slots; the grid is two
/// columns behind the start line, AI cars in front in an order shuffled
/// from the seed, humans at the back. Deterministic.
pub fn reset(w: *World, setup: world.Setup) void {
    const t = table_of(setup.mode, setup.track);
    track.select(t);
    w.* = .{};
    w.track = setup.track;
    w.combat = setup.combat;
    w.rng = if (setup.seed == 0) 1 else setup.seed;
    w.countdown = 4 * tuning.countdown_step;
    w.msg = .ready;
    w.msg_ticks = @intCast(tuning.countdown_step);
    w.lap_px = @intCast(lap_length(t));
    w.mode = setup.mode;
    w.laps = t.laps;
    for (track.hazard_specs[0..track.hazard_n], 0..) |*h, k| {
        w.hazards[k] = .{ .kind = h.kind, .timer = h.phase % h.period, .x = h.x0 << fixed.Q, .y = h.y0 << fixed.Q };
    }
    w.chips_on = setup.chips;
    if (setup.mode == .battle) battle.init(w, setup);
    for (&w.cars, 0..) |*c, i| {
        c.* = .{ .racer = @intCast(i) };
        equip(c, setup.loadouts[i]);
        weapons.refill(c);
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
    // CREWS (M4): the AI cars past the first `setup.crews` of the shuffle
    // stay off the grid; the humans move up behind the ones kept.
    const keep = @min(n, setup.crews);
    for (order[keep..n]) |ci| w.cars[ci].active = false;
    n = keep;
    for (0..2) |slot| {
        for (w.cars, 0..) |c, i| {
            if (c.human != slot) continue;
            order[n] = @intCast(i);
            n += 1;
        }
    }
    // BATTLE: the cars start on the arena's spawn pads.
    if (setup.mode == .battle) {
        battle.place(w, order[0..n]);
        update_ranks(w);
        return;
    }
    for (order[0..n], 0..) |ci, slot| {
        const c = &w.cars[ci];
        const row: i32 = @intCast(slot / 2);
        const side: i32 = if (slot % 2 == 0) -tuning.grid_side else tuning.grid_side;
        const p = line_point_behind(t, tuning.grid_first_row + row * tuning.grid_row_gap);
        place(c, p, side, 0);
        c.progress = nearest_sample(t, c, 0);
    }
    update_ranks(w);
}

/// The car's chassis (SPEC 4.2) and its garage upgrades (SPEC 9.2, M5):
/// the stock `Loadout` gives the stock car exactly.
pub fn equip(c: *Car, lo: world.Loadout) void {
    const ch = racers.chassis_of(c.racer);
    const stock = racers.roster[c.racer % racers.count];
    const top = @min(lo.clock, tuning.level_max);
    const plating = @min(lo.plating, tuning.level_max);
    c.top_q8 = @intCast(@as(u32, ch.top_q8) * (100 + tuning.clock_pct * top) / 100);
    c.accel_q8 = ch.accel_q8;
    c.grip_q8 = ch.grip_q8 + tuning.traction_q8 * @min(lo.traction, tuning.level_max);
    c.mass_q8 = ch.mass_q8;
    c.armor_max = ch.armor + tuning.plating_armor * plating;
    c.armor = c.armor_max;
    c.ecc = plating >= tuning.plating_ecc;
    c.burst_max = tuning.burst_per_lap + @min(lo.burst, tuning.level_max);
    c.burst_charges = c.burst_max;
    c.watchdog = tuning.watchdog_levels[@min(lo.watchdog, tuning.level_max)];
    c.front = lo.front orelse stock.front;
    c.rear = lo.rear orelse stock.rear;
    c.front_level = std.math.clamp(lo.front_level, 1, tuning.level_max);
    c.rear_level = std.math.clamp(lo.rear_level, 1, tuning.level_max);
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
                c.a_was = in.a and !in.down;
                c.rear_was = in.a and in.down;
            }
        },
        .racing, .finished => {
            w.tick +%= 1;
            // All inputs first (the AI reads the world as it was at the top
            // of the tick, whatever the car order), then the moves.
            var ins: [world.car_count]Input = @splat(.{});
            for (&w.cars, 0..) |*c, i| {
                if (!c.active) continue;
                ins[i] = if (c.human < 2 and !c.finished) .of(inputs[c.human]) else ai.drive(w, i);
            }
            for (&w.cars, 0..) |*c, i| {
                if (!c.active) continue;
                const in = pickups.filter(w, i, ins[i]);
                step_car(w, i, in);
                pickups.control(w, i, in);
                weapons.fire(w, i, in);
            }
            collide_all(w);
            hazards.update(w);
            weapons.update(w);
            pickups.update(w);
            if (w.chips_on) update_chips(w);
            update_ranks(w);
            battle.update(w);
            gc_mode.update(w);
            gc_mode.script(w);
            // The lock and the AI aim for the next tick (what the reticle
            // shows is what the next A fires at).
            for (0..world.car_count) |i| {
                weapons.update_lock(w, i);
                ai.update_aim(w, i);
                // BATTLE: the hunter's waypoint (hunt.zig).
                if (w.mode == .battle) hunt.update_nav(w, i);
            }
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

pub fn step_rng(s: u32) u32 {
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
fn step_car(w: *World, i: usize, in: Input) void {
    const c = &w.cars[i];
    const up_edge = in.up and !c.up_was;
    c.up_was = in.up;
    if (c.shake > 0) c.shake -= 1;
    if (c.hit_flash > 0) c.hit_flash -= 1;
    if (c.hitstop > 0) c.hitstop -= 1;
    c.last_hit_ticks +|= 1;
    if (c.wreck != .none) {
        c.wreck_ticks -|= 1;
        if (c.wreck_ticks == 0) respawn(w, i);
        return;
    }
    if (c.immune > 0) c.immune -= 1;
    if (c.safe > 0) c.safe -= 1;
    if (c.burst > 0) c.burst -= 1;
    if (c.rot_ticks > 0) c.rot_ticks -= 1;
    // BURST (Up): the press edge, a charge left, none running.
    if (up_edge and c.burst == 0 and c.burst_charges > 0 and !c.finished) {
        c.burst_charges -= 1;
        c.burst = tuning.burst_ticks;
    }
    const in_air = c.hop > 0;
    if (in_air) c.hop -= 1;
    // BATTLE's stunts (SPEC 8.3) on the tick the car touches down.
    const landing = in_air and c.hop == 0 and w.mode == .battle;

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
    a = (a * pickups.thrust_q8(w, i)) >> 8;
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
    // BIT ROT: over 80% of the top speed, shed speed as a brake does.
    if (c.rot_ticks > 0 and spd > (top_of(c) * tuning.rot_top_q8) >> 8) {
        c.vx -= fixed.mul(c.vx, tuning.brake);
        c.vy -= fixed.mul(c.vy, tuning.brake);
    }
    // 3. Grip: along = v . h, lateral = v . right (right = (-hy, hx)).
    if (!in_air) {
        const along = fixed.mul(c.vx, hx) + fixed.mul(c.vy, hy);
        var lat = fixed.mul(c.vx, -hy) + fixed.mul(c.vy, hx);
        var g = if (c.on_coolant or c.on_leak) tuning.grip_coolant else if (c.slide) tuning.grip_slide else tuning.grip;
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
    // Pickups: the HONEYPOT spin, and speed held down by a freeze, a
    // CAPTCHA, a DEADLOCK chain or a SPAGHETTI tangle.
    pickups.limit(c);
    // 5. Move, then the floor under the four corners.
    const old_x = c.x;
    const old_y = c.y;
    c.x = (c.x +% c.vx) & world_mask;
    c.y = (c.y +% c.vy) & world_mask;
    c.on_coolant = false;
    c.on_bay = false;
    // The touchdown tick reads the floor too in battle, so a landing in a
    // pit or on a wall is resolved on the tick the stunt is scored.
    const wall = if (!in_air or landing) resolve_tiles(w, i, old_x, old_y) else false;
    if (track.prop_reach > 0 and !in_air and c.wreck == .none) prop_contact(w, i);
    if (landing) land(w, i, wall);
    if (c.wreck == .none and w.mode != .battle) update_progress(w, i);
}

/// BATTLE's stunts on touching down (SPEC 8.3). STACK SMASH: landing on a
/// car on the ground deals it `tuning.smash_damage` and a ram bounce away
/// from the lander, a hit that counts for the elimination. CLEAN LANDING:
/// a landing clear of the walls (and of a pit: the car is still up) gives
/// back one burst charge. A car in SAFE MODE smashes nobody.
fn land(w: *World, i: usize, wall: bool) void {
    const c = &w.cars[i];
    if (c.wreck != .none or !c.active) return;
    var smashed = false;
    if (c.safe == 0) {
        const reach: i32 = 2 * tuning.car_radius;
        for (&w.cars, 0..) |*o, j| {
            if (j == i or !can_collide(o) or o.immune > 0) continue;
            const dx = wrap_px((o.x - c.x) >> fixed.Q);
            const dy = wrap_px((o.y - c.y) >> fixed.Q);
            const d2 = dx * dx + dy * dy;
            if (d2 >= reach * reach) continue;
            const n = normal_of(dx << 8, dy << 8, d2 << 16);
            o.vx += fixed.mul(n.nx, tuning.smash_bounce);
            o.vy += fixed.mul(n.ny, tuning.smash_bounce);
            o.shake = 8;
            weapons.emit(w, .stack_smash, @intCast(i), @intCast(j), tuning.smash_damage, o.x, o.y);
            hurt(w, j, @intCast(i), @divTrunc(@as(i32, tuning.smash_damage) * 100 + tuning.battle_damage_pct - 1, tuning.battle_damage_pct), true);
            smashed = true;
        }
    }
    if (smashed or wall) return;
    if (c.burst_charges < c.burst_max) {
        c.burst_charges += 1;
        weapons.emit(w, .clean_landing, @intCast(i), c.burst_charges, 0, c.x, c.y);
    }
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
/// True when a corner was in a wall.
fn resolve_tiles(w: *World, i: usize, old_x: i32, old_y: i32) bool {
    const c = &w.cars[i];
    const t = track_of(w);
    const cs = corners(c);
    var off_count: u8 = 0;
    var wall_hit = false;
    var nx: i32 = 0;
    var ny: i32 = 0;
    for (cs) |k| {
        const px = (c.x >> fixed.Q) + k[0];
        const py = (c.y >> fixed.Q) + k[1];
        const attr = t.attr_at(px, py);
        switch (attr) {
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
            // M7: breakable crust is floor until its region breaks.
            .crust => if (hazards.crust_broken(w, px, py)) {
                off_count += 1;
            },
            .ramp => if (c.hop == 0) {
                c.hop = tuning.ramp_ticks;
                c.air = tuning.ramp_ticks;
            },
            // The arena's one-way ramps (M6): only a car moving the way the
            // tile faces takes off.
            .kicker, .jump => if (c.hop == 0) {
                const f = track.facing(t.tile_at(px, py));
                if (f[0] * c.vx + f[1] * c.vy > 0) {
                    c.hop = if (attr == .kicker) tuning.kicker_ticks else tuning.ramp_ticks;
                    c.air = c.hop;
                }
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
        // Reflect the normal velocity component with restitution; lose
        // speed. v -= (1 + e) (v . n) n / |n|^2: the diagonal normal (1, 1)
        // has |n|^2 = 2. (Zero subtracts (1 + e) vn from both components
        // whatever the normal, which also flings the car along the wall;
        // fixed here, not in Zero.)
        const diagonal = nxq != 0 and nyq != 0;
        var vn = fixed.mul(c.vx, nxq) + fixed.mul(c.vy, nyq);
        if (diagonal) vn = @divTrunc(vn, 2);
        if (vn < 0) {
            const k = fixed.mul(vn, (256 + tuning.wall_restitution) << 8);
            c.vx -= fixed.mul(k, nxq);
            c.vy -= fixed.mul(k, nyq);
            c.vx = fixed.mul(c.vx, tuning.wall_speed_keep);
            c.vy = fixed.mul(c.vy, tuning.wall_speed_keep);
            c.shake = 4;
            // Impact speed along the unit normal (diagonal: |vn| x sqrt 2).
            const impact = if (diagonal) fixed.mul(-vn, 92682) else -vn;
            // PREFETCH halves wall damage.
            const dmg = wall_damage(impact);
            damage(w, i, world.no_car, if (c.prefetch > 0) dmg >> 1 else dmg);
        }
    }
    if (off_count == 4 and c.immune == 0 and c.wreck == .none) wreck(w, i, .fall);
    return wall_hit;
}

/// Wall (and hulk) impact damage for a normal speed into it, Q16.
fn wall_damage(vn: i32) i32 {
    if (vn <= tuning.wall_dmg_min) return 0;
    return ((vn - tuning.wall_dmg_min) * tuning.wall_dmg) >> fixed.Q;
}

fn any_wall(t: *const track.Track, c: *const Car) bool {
    for (corners(c)) |k| {
        if (t.attr_at((c.x >> fixed.Q) + k[0], (c.y >> fixed.Q) + k[1]) == .wall) return true;
    }
    return false;
}

/// Damage (SPEC 5.3): armor falls by `amount`; at 0 the car is wrecked.
/// `attacker` is the car responsible or `no_car` (a wall); a rival's hit
/// starts the kill-credit window. Wrecked, immune (respawn), root (SUDO)
/// and finished cars take none, and nothing is dealt with combat off.
pub fn damage(w: *World, victim: usize, attacker: u8, amount: i32) void {
    hurt(w, victim, attacker, amount, true);
}

/// `damage`, where `weapon` says whether a landed hit by `attacker` counts
/// as a weapon hit (GARBAGE COLLECTION's tag passes the mark on; rams do
/// not).
fn hurt(w: *World, victim: usize, attacker: u8, amount_in: i32, weapon: bool) void {
    if (!w.combat or amount_in <= 0) return;
    // BATTLE scales the race's damage, carrying the fraction in the car
    // (`Car.dmg_frac`, hundredths) so a 4-point PING is not rounded up.
    var amount = amount_in;
    if (w.mode == .battle) {
        const c = &w.cars[victim];
        const total = amount_in * tuning.battle_damage_pct + c.dmg_frac;
        amount = @divTrunc(total, 100);
        if (amount <= 0 or !c.active or c.wreck != .none or c.immune > 0 or c.finished or c.sudo > 0) {
            if (c.active and c.wreck == .none and c.immune == 0 and c.sudo == 0) c.dmg_frac = @intCast(@min(total, 99));
            if (amount <= 0) return;
        } else c.dmg_frac = @intCast(@mod(total, 100));
    }
    const c = &w.cars[victim];
    // ECC (PLATING L3) corrects single-bit errors: small hits do nothing.
    if (c.ecc and amount <= tuning.ecc_ignore) return;
    if (!c.active or c.wreck != .none or c.immune > 0 or c.finished or c.sudo > 0) return;
    const dmg: u8 = @intCast(@min(amount, 255));
    if (attacker != world.no_car and attacker != victim) {
        c.last_hit_by = attacker;
        c.last_hit_ticks = 0;
        if (weapon) gc_mode.on_hit(w, attacker, victim);
    }
    if (c.hit_flash == 0 or dmg >= tuning.hit_event_min) {
        weapons.emit(w, .hit, attacker, @intCast(victim), dmg, c.x, c.y);
    }
    c.hit_flash = tuning.hit_flash_ticks;
    if (dmg >= c.armor) {
        c.armor = 0;
        wreck(w, victim, .armor);
    } else c.armor -= dmg;
}

/// A wrecked car (armor or ZERO-DAY, not a fall) is a burning hulk that
/// blocks like a wall for the first `hulk_ticks` of its WATCHDOG delay (all
/// of a shorter one: WATCHDOG L2 and L3).
pub fn is_hulk(c: *const Car) bool {
    return c.active and (c.wreck == .armor or c.wreck == .zero_day) and
        @as(i32, c.wreck_ticks) > @as(i32, c.watchdog) - tuning.hulk_ticks;
}

/// Wreck a car (SPEC 5.3): it stops and is out for the WATCHDOG delay,
/// frozen for its hit-stop. The kill goes to the last rival to hit it
/// within `credit_ticks` (a fall too), else to nobody.
pub fn wreck(w: *World, i: usize, cause: world.Wreck) void {
    const c = &w.cars[i];
    if (c.wreck != .none) return;
    const killer: u8 = if (c.last_hit_by != world.no_car and c.last_hit_by != i and
        c.last_hit_ticks < tuning.credit_ticks) c.last_hit_by else world.no_car;
    c.wreck = cause;
    c.wreck_ticks = c.watchdog;
    c.vx = 0;
    c.vy = 0;
    c.hop = 0;
    c.burst = 0;
    c.shake = 8;
    c.charge = 0;
    c.lock = world.no_car;
    c.rot_ticks = 0;
    c.on_leak = false;
    c.last_hit_by = world.no_car;
    pickups.on_wreck(w, i);
    c.wrecks +|= 1;
    if (killer != world.no_car) w.cars[killer].kills +|= 1;
    weapons.emit(w, .wreck, @intCast(i), killer, @backingInt(cause), c.x, c.y);
    if (cause != .fall) {
        c.hitstop = tuning.hitstop_ticks;
        weapons.emit(w, .explode, @intCast(i), tuning.wreck_blast_px, 0, c.x, c.y);
    }
    car_msg(c, switch (cause) {
        .fall => .fall,
        // The presentation reads armor and ZERO-DAY wrecks from the event.
        .none, .armor, .zero_day => .none,
    }, tuning.message_ticks);
    // GARBAGE COLLECTION: a wreck while marked is a collection.
    gc_mode.on_wreck(w, i);
    // BATTLE: the elimination, a life, out of lives.
    if (w.mode == .battle) battle.on_wreck(w, i, killer);
}

/// After the WATCHDOG delay: back on the centerline sample nearest the
/// wreck (or the last one before it with floor under it, so a car that
/// fell into a ramp pit comes back before the ramp), facing along it,
/// stopped, immune.
fn respawn(w: *World, i: usize) void {
    if (w.mode == .battle) return battle.respawn(w, i);
    const c = &w.cars[i];
    const t = track_of(w);
    var k: u8 = 0;
    while (k < 32 and pit_at(w, t, t.sample(c.progress).x, t.sample(c.progress).y)) : (k += 1) c.progress -%= 1;
    const s = t.sample(c.progress);
    c.x = @as(i32, s.x) << fixed.Q;
    c.y = @as(i32, s.y) << fixed.Q;
    c.heading = s.tangent;
    c.vx = 0;
    c.vy = 0;
    c.immune = tuning.respawn_immune;
    c.wreck = .none;
    c.hitstop = 0;
    // Full armor, kept ammo (SPEC 5.3).
    c.armor = c.armor_max;
    weapons.emit(w, .respawn, @intCast(i), 0, 0, c.x, c.y);
}

/// No floor at world px (x, y): off-track, or (M7) broken crust.
pub fn pit_at(w: *const World, t: *const track.Track, x: i32, y: i32) bool {
    return switch (t.attr_at(x, y)) {
        .off => true,
        .crust => hazards.crust_broken(w, x, y),
        else => false,
    };
}

/// M7, the solid props (SPEC 19.3): a car on the ground whose centre comes
/// within a prop's radius plus `tuning.car_radius` is pushed out of it and
/// loses its speed into it as at a wall (with the wall's damage).
fn prop_contact(w: *World, i: usize) void {
    const c = &w.cars[i];
    for (0..track.prop_n) |pk| {
        const pr = track.prop(pk);
        if (pr.radius == 0) continue;
        const reach: i32 = @as(i32, pr.radius) + tuning.car_radius;
        const dx = wrap_px((c.x >> fixed.Q) - @as(i32, pr.x));
        const dy = wrap_px((c.y >> fixed.Q) - @as(i32, pr.y));
        if (@abs(dx) >= reach or @abs(dy) >= reach) continue;
        const d2 = dx * dx + dy * dy;
        if (d2 >= reach * reach) continue;
        const d: i32 = @intCast(fixed.isqrt(@intCast(d2)));
        // Unit normal from the prop to the car (Q16; east when the car sits
        // on the prop's centre).
        const nx: i32 = if (d == 0) fixed.one else @divTrunc(dx << fixed.Q, d);
        const ny: i32 = if (d == 0) 0 else @divTrunc(dy << fixed.Q, d);
        nudge(w, c, nx * (reach - d), ny * (reach - d));
        const vn = fixed.mul(c.vx, nx) + fixed.mul(c.vy, ny);
        if (vn >= 0) continue;
        const k = fixed.mul(vn, (256 + tuning.wall_restitution) << 8);
        c.vx = fixed.mul(c.vx - fixed.mul(k, nx), tuning.wall_speed_keep);
        c.vy = fixed.mul(c.vy - fixed.mul(k, ny), tuning.wall_speed_keep);
        c.shake = 4;
        const dmg = wall_damage(-vn);
        damage(w, i, world.no_car, if (c.prefetch > 0) dmg >> 1 else dmg);
    }
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
fn update_progress(w: *World, i: usize) void {
    const c = &w.cars[i];
    const t = track_of(w);
    const old = c.progress;
    const new = nearest_sample(t, c, old);
    c.progress = new;
    // Off its leg: further from the centerline than any road reaches (it
    // was pushed through a wall onto another part of the track). A fall
    // puts it back (SEGMENT FAULT), credited to whoever pushed it.
    const off = @as(i32, t.sample(new).half) + tuning.off_leg_px;
    if (c.hop == 0 and c.immune == 0 and dist2_to_sample(t, c, new) > off * off) {
        wreck(w, i, .fall);
        return;
    }
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
                c.burst_charges = c.burst_max;
                // Ammo refills on the line (SPEC 6).
                weapons.refill(c);
                // GARBAGE COLLECTION has no lap limit: the sweeps end it.
                const gc = w.mode == .gc;
                if (!gc and c.lap == w.laps - 1) car_msg(c, .final_lap, tuning.message_ticks);
                if (!gc and c.lap >= w.laps) {
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

/// Cycle chips (M5, SPEC 9.1): a car on the ground and in the race takes
/// a chip its centre comes within `tuning.chip_touch` of (`Car.chips`, a
/// `chip` event); every taken chip comes back each `tuning.chip_respawn`
/// ticks. Only with `World.chips_on` (the CIRCUIT).
fn update_chips(w: *World) void {
    w.chip_clock +%= 1;
    if (w.chip_clock >= tuning.chip_respawn) {
        w.chip_clock = 0;
        w.chips = 0;
    }
    const r2 = tuning.chip_touch * tuning.chip_touch;
    for (&w.cars, 0..) |*c, i| {
        if (!c.active or c.wreck != .none or c.hop != 0 or c.finished) continue;
        const cx = c.x >> fixed.Q;
        const cy = c.y >> fixed.Q;
        for (track.chip_spots[0..track.chip_n], 0..) |sp, k| {
            const bit = @as(u32, 1) << @intCast(k);
            if (w.chips & bit != 0) continue;
            const dx = wrap_px(cx - @as(i32, sp.x));
            const dy = wrap_px(cy - @as(i32, sp.y));
            if (dx * dx + dy * dy > r2) continue;
            w.chips |= bit;
            c.chips +|= 1;
            weapons.emit(w, .chip, @intCast(i), @intCast(k), 0, @as(i32, sp.x) << fixed.Q, @as(i32, sp.y) << fixed.Q);
        }
    }
}

/// The race is over when every human has finished, or, in an AI-only race
/// (attract, tests), when the leader has; in GARBAGE COLLECTION when one
/// car is left.
fn check_finished(w: *World) void {
    if (w.phase != .racing or w.mode == .battle) return;
    if (w.mode == .gc) {
        if (w.gc.survivor != world.no_car) w.phase = .finished;
        return;
    }
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

// --- Car against car (Zero SPEC 5.3, GC SPEC 5.3) ------------------------------

/// A HEISENBUG car passes through cars (and hulks).
fn can_collide(c: *const Car) bool {
    return c.active and c.hop == 0 and c.wreck == .none and c.heisen == 0;
}

/// Circles of radius `car_radius`: push apart by half the penetration
/// each, exchange 30% of the closing normal velocity, split by mass, and
/// ram damage both ways. A hulk is a wall: the live car alone is pushed
/// out and bounces.
pub fn collide_all(w: *World) void {
    const r2: i32 = 2 * tuning.car_radius;
    const reach: i32 = r2 << fixed.Q;
    const lim: i32 = (r2 << 8) * (r2 << 8);
    const half: i32 = 512 << fixed.Q;
    var i: usize = 0;
    while (i < world.car_count) : (i += 1) {
        const a = &w.cars[i];
        const a_hulk = is_hulk(a);
        if (!can_collide(a) and !a_hulk) continue;
        var j = i + 1;
        while (j < world.car_count) : (j += 1) {
            const b = &w.cars[j];
            const b_hulk = is_hulk(b);
            if (!can_collide(b) and !b_hulk) continue;
            if (a_hulk and b_hulk) continue;
            if (a.heisen > 0 or b.heisen > 0) continue;
            const dx = ((b.x -% a.x +% half) & world_mask) - half;
            const dy = ((b.y -% a.y +% half) & world_mask) - half;
            if (dx >= reach or dx <= -reach or dy >= reach or dy <= -reach) continue;
            const dx8 = dx >> 8;
            const dy8 = dy >> 8;
            const d2 = dx8 * dx8 + dy8 * dy8;
            if (d2 >= lim) continue;
            // (dx, dy) points from a to b; hulk_contact wants hulk -> car.
            if (a_hulk) {
                hulk_contact(w, j, dx8, dy8, d2);
            } else if (b_hulk) {
                hulk_contact(w, i, -dx8, -dy8, d2);
            } else contact(w, i, j, dx8, dy8, d2);
        }
    }
}

/// Move a car by (dx, dy) Q16 unless that puts a corner in a wall: a
/// contact never shoves a car through a wreckage wall onto the next leg
/// (the velocity exchange still parts them).
pub fn nudge(w: *const World, c: *Car, dx: i32, dy: i32) void {
    const ox = c.x;
    const oy = c.y;
    c.x = (c.x +% dx) & world_mask;
    c.y = (c.y +% dy) & world_mask;
    if (any_wall(track_of(w), c)) {
        c.x = ox;
        c.y = oy;
    }
}

/// Unit normal (Q16) along (dx8, dy8) of length sqrt(d2) (Q8), and that length.
const Normal = struct { nx: i32, ny: i32, dist: i32 };
fn normal_of(dx8: i32, dy8: i32, d2: i32) Normal {
    const dist: i32 = @intCast(fixed.isqrt(@intCast(d2))); // Q8
    if (dist == 0) return .{ .nx = fixed.one, .ny = 0, .dist = 0 };
    return .{ .nx = @divTrunc(dx8 << 16, dist), .ny = @divTrunc(dy8 << 16, dist), .dist = dist };
}

/// Car `i` against a hulk; (dx8, dy8) points from the hulk to the car.
fn hulk_contact(w: *World, i: usize, dx8: i32, dy8: i32, d2: i32) void {
    const c = &w.cars[i];
    const n = normal_of(dx8, dy8, d2);
    const pen8 = (2 * tuning.car_radius << 8) - n.dist;
    nudge(w, c, fixed.mul(n.nx, pen8 << 8), fixed.mul(n.ny, pen8 << 8));
    const vn = fixed.mul(c.vx, n.nx) + fixed.mul(c.vy, n.ny);
    if (vn >= 0) return;
    const k = fixed.mul(vn, (256 + tuning.wall_restitution) << 8);
    c.vx -= fixed.mul(k, n.nx);
    c.vy -= fixed.mul(k, n.ny);
    c.vx = fixed.mul(c.vx, tuning.wall_speed_keep);
    c.vy = fixed.mul(c.vy, tuning.wall_speed_keep);
    c.shake = 4;
    damage(w, i, world.no_car, wall_damage(-vn));
}

/// Ram damage to `victim` from `attacker` closing at `closing` (Q16
/// px/tick) along the normal `n` from attacker to victim (SPEC 5.3).
fn ram_damage(attacker: *const Car, victim: *const Car, closing: i32, nx: i32, ny: i32) i32 {
    var dmg: i64 = @as(i64, closing) * tuning.ram_dmg * attacker.mass_q8;
    dmg = @divTrunc(dmg, victim.mass_q8);
    if (racers.roster[attacker.racer % racers.count].chassis == .mainframe) {
        // The plough: the victim in the front quarter.
        const facing = fixed.mul(fixed.cos(attacker.heading), nx) + fixed.mul(fixed.sin(attacker.heading), ny);
        if (facing >= tuning.plough_cos) dmg *= tuning.plough_mul;
    }
    return @intCast(@min(dmg >> fixed.Q, 255));
}

fn contact(w: *World, ia: usize, ib: usize, dx8: i32, dy8: i32, d2: i32) void {
    const a = &w.cars[ia];
    const b = &w.cars[ib];
    // Unit normal from a to b, Q16 (straight along +x when centred).
    const n = normal_of(dx8, dy8, d2);
    const nx = n.nx;
    const ny = n.ny;
    // Push apart: half the penetration each.
    const pen8 = (2 * tuning.car_radius << 8) - n.dist;
    const push = pen8 << 7; // Q16, half of pen8 << 8
    const px = fixed.mul(nx, push);
    const py = fixed.mul(ny, push);
    nudge(w, a, -px, -py);
    nudge(w, b, px, py);
    // A DEADLOCK pair that touches goes free.
    pickups.touched(w, ia, ib);
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
    // Ramming: each car rams the other (SPEC 5.3).
    if (closing >= tuning.ram_min_speed) {
        // SUDO: a root car's ram deals 40 and bounces the victim away.
        const to_b = if (a.sudo > 0) tuning.sudo_ram else ram_damage(a, b, closing, nx, ny);
        const to_a = if (b.sudo > 0) tuning.sudo_ram else ram_damage(b, a, closing, -nx, -ny);
        if (a.sudo > 0 and b.sudo == 0) {
            b.vx += fixed.mul(nx, tuning.sudo_bounce);
            b.vy += fixed.mul(ny, tuning.sudo_bounce);
        }
        if (b.sudo > 0 and a.sudo == 0) {
            a.vx -= fixed.mul(nx, tuning.sudo_bounce);
            a.vy -= fixed.mul(ny, tuning.sudo_bounce);
        }
        // SAFE MODE (BATTLE): a car that cannot be hit cannot ram either.
        hurt(w, ib, @intCast(ia), if (a.safe > 0) 0 else to_b, false);
        hurt(w, ia, @intCast(ib), if (b.safe > 0) 0 else to_a, false);
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

/// The car's last stretch: its last lap, or in GARBAGE COLLECTION the
/// final three cars (the AI saves its last-lap pickups for it).
pub fn last_lap(w: *const World, c: *const Car) bool {
    return switch (w.mode) {
        .gc => gc_mode.active_count(w) <= 3,
        .battle => battle.final_stretch(w, c),
        .race, .attract => c.lap + 1 >= w.laps,
    };
}

/// Progress in world px along the centerline (the rubber band's measure).
pub fn progress_px(w: *const World, c: *const Car) i32 {
    return @intCast((@as(i64, fine_progress(w, c)) * w.lap_px) >> 16);
}

/// Ranks 1..6: finished cars first in finish order, then by fine progress,
/// ties to the lower index. A finished car's rank is final, and so is a
/// collected car's (GARBAGE COLLECTION: its place when it went out); the
/// cars still running rank 1..n among themselves.
pub fn update_ranks(w: *World) void {
    if (w.mode == .battle) return battle.update_ranks(w);
    var fine: [world.car_count]i32 = undefined;
    for (&w.cars, 0..) |*c, i| fine[i] = if (c.finished or !c.active) 0 else fine_progress(w, c);
    for (&w.cars, 0..) |*c, i| {
        if (!c.active) {
            if (w.gc.collected & (@as(u8, 1) << @intCast(i)) == 0) c.rank = 0;
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
