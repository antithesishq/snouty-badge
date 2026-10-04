//! The bosses (PLAN.md M7, track B2): every boss's movement, fire
//! program and drawing, dispatched from `enemies.update`,
//! `enemies.draw_enemy` and `enemies.damage` for `.boss` enemies.
//! `Enemy.variant` is the `BossId`.
//!
//! The common frame: HP-gated phases (`Phase`), each with a time limit.
//! A phase whose HP runs out (but never before `min_phase` ticks: the HP
//! holds at the phase's threshold until then) breaks: every enemy bullet
//! is cancelled, one crate drops and the boss holds fire for `rest_ticks`
//! (bolts are absorbed, no damage). A non-final phase that times out
//! moves on the same way without the crate; the final phase timing out
//! makes the boss escape off the right edge (`waves.boss_escaped`). Death
//! cancels every bullet, then the M3 explosion sequence and
//! `waves.boss_cleared`.
//!
//! Positions: a boss's (x, y) is the top-left of its collision box (the
//! body, ASSETS.md "M7 sheets"), so the collision passes and `center()`
//! see the body only; `Box` gives its offset in the 48x48 cell. The wave
//! spawns the boss by its cell position; the first update converts it.
//!
//! Enemy fields as a boss uses them: `timer` movement clock (Heisenbug:
//! ticks in its teleport step), `fire_tick` countdown A (the phase's heavy
//! volley; the alt cell telegraphs it for its last `telegraph` ticks),
//! `aux` the packed `Aux` (HP phase, phase clock, rest, countdown B,
//! flags), `ring_phase` countdown C or a second angle, `spiral_angle` an
//! angle, `aux2` per boss (Mandelbug unused, Schrodinbug the side of the
//! real body, Bohrbug the wall gap y). Countdowns reload with
//! `rank.interval(base)` at the boss's pace (`boss_pace`) when they fire.
//! Bullet speeds are base speeds; `bullets.spawn_shot` scales them by
//! rank.
//!
//! The Schrodinbug's second body is a second `.boss` enemy (same variant)
//! with `Aux.phantom` set; the real body moves it and fires its mirrored
//! patterns, `enemies.boss()` skips it.
const cart = @import("cart-api");
const gfx = @import("gfx");
const draw = @import("draw.zig");
const bullets = @import("bullets.zig");
const enemies = @import("enemies.zig");
const fx = @import("fx.zig");
const patterns = @import("patterns.zig");
const pickups = @import("pickups.zig");
const player = @import("player.zig");
const rank = @import("rank.zig");
const rng = @import("rng.zig");
const waves = @import("waves.zig");
const world = @import("world.zig");
const boss_hp = @import("boss_hp.zig");

const Enemy = enemies.Enemy;
const BossId = boss_hp.BossId;
const Shot = bullets.Shot;

/// Boss state packed into `Enemy.aux`.
const Aux = packed struct(u32) {
    /// HP phase index into the boss's `phases`.
    stage: u3 = 0,
    /// Schrodinbug: this body is the phantom.
    phantom: bool = false,
    /// Ticks of no fire (and no damage) left after a phase break.
    rest: u6 = 0,
    /// Ticks in the current HP phase (the time limit).
    clock: u12 = 0,
    /// Countdown B.
    cd: u8 = 0,
    /// Schrodinbug real body: collapsed (touched this phase). Mandelbug
    /// and Bohrbug: the side of the next wall's gap (`weave_gap`).
    flag: bool = false,
    /// The first update has run (cell -> box position, phantom flag).
    init: bool = false,
};

fn aux_of(e: Enemy) Aux {
    return @bitCast(e.aux);
}

/// One HP phase: it ends when HP falls to `end_pct` percent of the max,
/// or after `limit` ticks. `heavy`: countdown A is a telegraphed volley.
const Phase = struct {
    end_pct: u8,
    limit: u16,
    heavy: bool = false,
};

/// Every phase lasts at least this long (6 s), however strong the ship:
/// the HP holds at the threshold until then.
const min_phase: u32 = 360;
/// No fire (and no damage) for this long after a break.
const rest_ticks: u6 = 60;
/// The alt cell shows for the last this many ticks of a heavy countdown.
const telegraph: u32 = 24;
/// No bullet is spawned this close (px) to the ship's hitbox center.
const min_spawn_dist: f32 = 18;

const s20: u16 = 20 * 60;
const s30: u16 = 30 * 60;

const heisen_phases = [_]Phase{
    .{ .end_pct = 66, .limit = s20 },
    .{ .end_pct = 33, .limit = s20 },
    .{ .end_pct = 0, .limit = s30 },
};
const mandel_phases = [_]Phase{
    .{ .end_pct = 75, .limit = s20, .heavy = true },
    .{ .end_pct = 50, .limit = s20, .heavy = true },
    .{ .end_pct = 25, .limit = s20, .heavy = true },
    .{ .end_pct = 0, .limit = s30, .heavy = true },
};
const schrod_phases = [_]Phase{
    .{ .end_pct = 75, .limit = s20, .heavy = true },
    .{ .end_pct = 50, .limit = s20, .heavy = true },
    .{ .end_pct = 25, .limit = s20, .heavy = true },
    .{ .end_pct = 0, .limit = s30, .heavy = true },
};
const bohr_phases = [_]Phase{
    .{ .end_pct = 80, .limit = s20, .heavy = true },
    .{ .end_pct = 60, .limit = s20 },
    .{ .end_pct = 40, .limit = s20, .heavy = true },
    .{ .end_pct = 20, .limit = s20, .heavy = true },
    .{ .end_pct = 0, .limit = s30, .heavy = true },
};

fn phases(id: BossId) []const Phase {
    return switch (id) {
        .heisenbug => &heisen_phases,
        .mandelbug => &mandel_phases,
        .schrodinbug => &schrod_phases,
        .bohrbug => &bohr_phases,
    };
}

/// The collision box inside the 48x48 cell (ASSETS.md "M7 sheets"; the
/// Heisenbug keeps its M3 whole-cell box).
const Box = struct { ox: f32, oy: f32, w: f32, h: f32 };

fn box(id: BossId) Box {
    return switch (id) {
        .heisenbug => .{ .ox = 0, .oy = 0, .w = 48, .h = 48 },
        .mandelbug => .{ .ox = 14, .oy = 12, .w = 32, .h = 25 },
        .schrodinbug => .{ .ox = 8, .oy = 10, .w = 35, .h = 35 },
        .bohrbug => .{ .ox = 6, .oy = 13, .w = 40, .h = 33 },
    };
}

pub fn id_of(e: Enemy) BossId {
    return boss_hp.for_stage(e.variant);
}

/// `Enemy.size` of a boss: its collision box.
pub fn size(e: Enemy) [2]f32 {
    const b = box(id_of(e));
    return .{ b.w, b.h };
}

/// Whether bolts (and the ship) can touch it: not while teleporting,
/// vanished, dying, escaping or (a phantom) reforming.
pub fn hittable(e: Enemy) bool {
    return switch (e.phase) {
        .flicker, .vanished, .dying, .leave, .pause => false,
        else => true,
    };
}

pub fn is_phantom(e: Enemy) bool {
    return aux_of(e).phantom;
}

/// The HP phase of a boss (0-based), for the tests.
pub fn phase_index(e: Enemy) u32 {
    return aux_of(e).stage;
}

/// Test and bench hooks, not World state (constant through a run, like
/// god mode): the boss id the next boss is (>= 4: the stage's own), and
/// the HP phase it starts in. Exported so badge-bench can `--poke` them.
export var bugs_force_boss: u8 = 0xFF;
export var bugs_force_phase: u8 = 0;

// --------------------------------------------------------------- movement

const enter_speed: f32 = 1.0;
const leave_speed: f32 = 1.5;
/// An escaping boss is gone once its cell is this far right.
const leave_x: f32 = 168;
/// Small death explosions are centered this far inside the 48x48 cell.
const blast_margin = 8;
const dying_ticks: u32 = 60;
const blast_every: u32 = 10;
const frame_ticks = 6;
const idle_frames = 4;
const alt_cell = 4;

fn stop_x(id: BossId) f32 {
    return switch (id) {
        .heisenbug, .mandelbug, .schrodinbug => 104,
        .bohrbug => 108,
    };
}

/// Top-left of the 48x48 cell.
fn cell(e: *const Enemy) [2]f32 {
    const b = box(id_of(e.*));
    return .{ e.x - b.ox, e.y - b.oy };
}

fn place(e: *Enemy, c: [2]f32) void {
    const b = box(id_of(e.*));
    e.x = c[0] + b.ox;
    e.y = c[1] + b.oy;
}

/// A point of the cell (an emitter), in screen coordinates.
fn at(e: *const Enemy, px: f32, py: f32) [2]f32 {
    const c = cell(e);
    return .{ c[0] + px, c[1] + py };
}

/// sin(2 pi t / period) from the table.
fn wave(t: u32, period: u32) f32 {
    return enemies.sin_table[(t % period) * 256 / period];
}

fn threshold(e: *const Enemy, a: Aux) u16 {
    const d = phases(id_of(e.*))[a.stage];
    const max = enemies.boss_max_hp_of(e.*);
    return @intCast(max * d.end_pct / 100);
}

fn is_final(e: *const Enemy, a: Aux) bool {
    return @as(usize, a.stage) + 1 >= phases(id_of(e.*)).len;
}

/// The other body of a Schrodinbug (the phantom), if any.
fn phantom_of() ?*Enemy {
    for (&world.w.enemies) |*p| {
        if (p.active and p.kind == .boss and aux_of(p.*).phantom) return p;
    }
    return null;
}

/// The real body (the HP holder), if any.
fn real_body() ?*Enemy {
    for (&world.w.enemies) |*p| {
        if (p.active and p.kind == .boss and !aux_of(p.*).phantom) return p;
    }
    return null;
}

pub fn update(e: *Enemy) void {
    var a = aux_of(e.*);
    if (!a.init) init(e, &a);
    if (a.phantom) {
        update_phantom(e);
    } else switch (e.phase) {
        .enter => enter(e, &a),
        .dying => update_dying(e),
        .leave => update_leave(e),
        else => fight(e, &a),
    }
    e.aux = @bitCast(a);
}

/// First update: the forced id / phase (test hooks), and the cell
/// position the wave gave becomes the box position.
fn init(e: *Enemy, a: *Aux) void {
    a.init = true;
    if (bugs_force_boss < 4) {
        e.variant = bugs_force_boss;
        e.hp = @intCast(enemies.boss_max_hp_of(e.*));
    }
    const n: u8 = @intCast(phases(id_of(e.*)).len);
    if (bugs_force_phase > 0) {
        const k: u3 = @intCast(@min(bugs_force_phase, n - 1));
        a.stage = k - 1;
        e.hp = threshold(e, a.*);
        a.stage = k;
    }
    e.base_y = e.y;
    place(e, .{ e.x, e.y });
    e.aux2 = 0;
    if (id_of(e.*) == .schrodinbug) e.aux2 = 1;
}

fn enter(e: *Enemy, a: *Aux) void {
    const id = id_of(e.*);
    var c = cell(e);
    c[0] -= enter_speed;
    if (c[0] <= stop_x(id)) {
        c[0] = stop_x(id);
        e.phase = .fight;
        e.timer = 0;
        a.clock = 0;
        reload(e, a);
    }
    place(e, c);
    if (id == .schrodinbug) schrod_bodies(e);
}

/// The countdowns at the start of a phase (they do not run during rest).
fn reload(e: *Enemy, a: *Aux) void {
    e.fire_tick = 50;
    a.cd = 20;
    e.ring_phase = 35;
}

fn fight(e: *Enemy, a: *Aux) void {
    const ps = phases(id_of(e.*));
    a.clock +|= 1;
    if (a.rest > 0) a.rest -= 1;
    const p = ps[a.stage];
    if (is_final(e, a.*)) {
        if (a.clock >= p.limit) return escape(e);
    } else if (a.clock >= min_phase and e.hp <= threshold(e, a.*)) {
        next_phase(e, a, true);
    } else if (a.clock >= p.limit) {
        e.hp = @min(e.hp, threshold(e, a.*));
        next_phase(e, a, false);
    }
    switch (id_of(e.*)) {
        .heisenbug => heisen(e, a),
        .mandelbug => mandel(e, a),
        .schrodinbug => schrod(e, a),
        .bohrbug => bohr(e, a),
    }
}

/// A phase break: cancel every bullet, a crate when it was earned (not a
/// timeout), rest, the next phase's countdowns.
fn next_phase(e: *Enemy, a: *Aux, earned: bool) void {
    _ = bullets.cancel_all();
    if (earned) {
        const c = e.center();
        pickups.spawn_drop(c[0], c[1]);
    }
    a.stage += 1;
    a.clock = 0;
    a.rest = rest_ticks;
    reload(e, a);
    if (id_of(e.*) == .schrodinbug) schrod_superpose(e, a);
}

/// The final phase timed out: fly off the right edge (no fire, no hits).
fn escape(e: *Enemy) void {
    e.phase = .leave;
    e.timer = 0;
    if (phantom_of()) |p| p.phase = .leave;
}

fn update_leave(e: *Enemy) void {
    var c = cell(e);
    c[0] += leave_speed;
    place(e, c);
    if (phantom_of()) |p| p.x += leave_speed;
    if (c[0] >= leave_x) {
        if (phantom_of()) |p| p.active = false;
        e.active = false;
        waves.boss_escaped();
    }
}

/// 60 ticks of small explosions across the cell, then the big one, the
/// points and the clear.
fn update_dying(e: *Enemy) void {
    const c = cell(e);
    if (e.timer >= dying_ticks) {
        fx.spawn(.big_explosion, @intFromFloat(@floor(c[0] + 24)), @intFromFloat(@floor(c[1] + 24)));
        player.add_score(e.points());
        e.active = false;
        waves.boss_cleared();
        return;
    }
    if (e.timer % blast_every == 0) {
        const ox = rng.range(blast_margin, 48 - blast_margin);
        const oy = rng.range(blast_margin, 48 - blast_margin);
        const bx: i32 = @intFromFloat(@floor(c[0]));
        const by: i32 = @intFromFloat(@floor(c[1]));
        fx.spawn(.explosion, bx + ox, by + oy);
        e.flash = 2;
    }
    e.timer += 1;
}

/// `enemies.damage` for a boss. Absorbed (no HP lost) while resting; a
/// non-final phase's HP stops at its threshold, and the break comes now
/// if the phase is old enough (else when it is, in `fight`). A phantom
/// bursts instead. Zero HP in the final phase starts the death.
pub fn damage(e: *Enemy, amount: u16) enemies.DamageResult {
    if (e.phase == .dying) return .boss_dying;
    var a = aux_of(e.*);
    defer e.aux = @bitCast(a);
    if (a.phantom) {
        phantom_burst(e);
        return .alive;
    }
    if (id_of(e.*) == .schrodinbug) a.flag = true;
    if (a.rest > 0) return .alive;
    if (is_final(e, a)) {
        e.hp -|= amount;
        if (e.hp > 0) return .alive;
        start_dying(e);
        return .boss_dying;
    }
    const thr: u32 = threshold(e, a);
    const hp: u32 = e.hp;
    e.hp = @intCast(if (hp > thr + amount) hp - amount else thr);
    if (e.hp <= thr and a.clock >= min_phase and e.phase != .enter) next_phase(e, &a, true);
    return .alive;
}

fn start_dying(e: *Enemy) void {
    _ = bullets.cancel_all();
    e.phase = .dying;
    e.timer = 0;
    e.flash = 0;
    if (phantom_of()) |p| {
        const c = p.center();
        fx.spawn(.explosion, @intFromFloat(@floor(c[0])), @intFromFloat(@floor(c[1])));
        p.active = false;
    }
}

// ----------------------------------------------------------------- firing

fn shot(speed: f32, shape: bullets.Shape) Shot {
    return .{ .speed = speed, .shape = shape, .source = .boss };
}

/// The emitter is far enough from the ship to fire from.
fn clear_of_ship(p: [2]f32) bool {
    const hb = player.hitbox();
    const dx = p[0] - (hb[0] + hb[2] / 2);
    const dy = p[1] - (hb[1] + hb[3] / 2);
    return dx * dx + dy * dy >= min_spawn_dist * min_spawn_dist;
}

/// Sixteenths of every fire interval by boss, on top of the rank (the
/// probe's tuning knob, PLAN.md M7 "Tuning"); from the second loop on
/// `loop_pace` sixteenths of that again.
const boss_pace = [4]u32{ 40, 24, 24, 40 };
const loop_pace: u32 = 12;

/// A countdown's reload: `rank.interval(base)` at this boss's pace.
fn paced(e: *const Enemy, base: u32) u32 {
    var k = boss_pace[@backingInt(id_of(e.*))];
    if (world.w.waves.loop > 0) k = k * loop_pace / 16;
    return @max(rank.interval(base) * k / 16, 1);
}

/// Countdown A: true when it fires (then reloaded at rank).
fn due_a(e: *Enemy, base: u32) bool {
    if (e.fire_tick > 1) {
        e.fire_tick -= 1;
        return false;
    }
    e.fire_tick = paced(e, base);
    return true;
}

/// Countdown B (in `Aux.cd`).
fn due_b(e: *const Enemy, a: *Aux, base: u32) bool {
    if (a.cd > 1) {
        a.cd -= 1;
        return false;
    }
    a.cd = @intCast(@min(paced(e, base), 255));
    return true;
}

/// Countdown C (in `Enemy.ring_phase`).
fn due_c(e: *Enemy, base: u32) bool {
    if (e.ring_phase > 1) {
        e.ring_phase -= 1;
        return false;
    }
    e.ring_phase = @intCast(@min(paced(e, base), 255));
    return true;
}

/// A vertical wall of `n` bullets at x from y 12 to 124 moving left,
/// leaving out those within `gap_half` of `gap_y` and any that would
/// appear on the ship.
fn wall(x: f32, n: u32, gap_y: f32, gap_half: f32, s: Shot) void {
    const top: f32 = 12;
    const bottom: f32 = 124;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const y = top + (bottom - top) * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1));
        if (@abs(y - gap_y) < gap_half) continue;
        if (!clear_of_ship(.{ x, y })) continue;
        _ = bullets.spawn_shot(x, y, .{ -1, 0 }, s);
    }
}

/// The gap of the next wall (in `aux2`): it tracks the ship but sits
/// `gap_lead` px above it, then below it, alternating wall by wall
/// (`Aux.flag`), moving at most `gap_step` px from the last gap and kept
/// inside the field. So a ship that sits still meets the wall, and
/// consecutive walls make a corridor that weaves after it.
fn weave_gap(e: *Enemy, a: *Aux) f32 {
    if (e.aux2 == 0) e.aux2 = ship_y();
    a.flag = !a.flag;
    const target = ship_y() + if (a.flag) -gap_lead else gap_lead;
    const dy = target - e.aux2;
    e.aux2 = @min(@max(e.aux2 + @max(-gap_step, @min(gap_step, dy)), gap_min_y), gap_max_y);
    return e.aux2;
}
const gap_lead: f32 = 20;
const gap_step: f32 = 30;
const gap_min_y: f32 = 22;
const gap_max_y: f32 = 114;

fn ship_y() f32 {
    const hb = player.hitbox();
    return hb[1] + hb[3] / 2;
}

// -------------------------------------------------------------- Heisenbug

// Stage 1 (SPEC.md section 7 plus M7): it bobs and teleports. P1 a
// rotating ring and an aimed needle line; P2 a counter-rotating double
// spiral and a ring at each reappearance; P3 teleports every 120 ticks,
// a pellet ring and a sniper line at each reappearance, aimed fans.
const heisen_bob_amplitude: f32 = 32;
const heisen_bob_period: u32 = 240;
const heisen_min_y: f32 = 8;
const heisen_max_y: f32 = 80;
const heisen_flicker: u32 = 20;
const heisen_vanish: u32 = 20;
const heisen_materialize: u32 = 16;
const heisen_min_x = 96;
const heisen_max_x = 112;
const heisen_min_base_y = 24;
const heisen_max_base_y = 56;

fn heisen_teleport_every(stage: u3) u32 {
    return switch (stage) {
        0 => 300,
        1 => 240,
        else => 120,
    };
}

fn heisen(e: *Enemy, a: *Aux) void {
    switch (e.phase) {
        .fight => {
            const i = (e.timer % heisen_bob_period) * 256 / heisen_bob_period;
            const y = e.base_y + heisen_bob_amplitude * enemies.sin_table[i];
            e.y = @min(@max(y, heisen_min_y), heisen_max_y);
            if (a.rest == 0) heisen_fire(e, a);
            e.timer += 1;
            if (e.timer >= heisen_teleport_every(a.stage)) {
                e.phase = .flicker;
                e.timer = 0;
            }
        },
        .flicker => {
            e.timer += 1;
            if (e.timer >= heisen_flicker) {
                e.phase = .vanished;
                e.timer = 0;
            }
        },
        .vanished => {
            e.timer += 1;
            if (e.timer >= heisen_vanish) {
                e.x = @floatFromInt(rng.range(heisen_min_x, heisen_max_x));
                e.base_y = @floatFromInt(rng.range(heisen_min_base_y, heisen_max_base_y));
                e.y = e.base_y;
                e.phase = .pause;
                e.timer = 0;
            }
        },
        .pause => {
            // Materializing (drawn as the flicker ghost, not hittable).
            e.timer += 1;
            if (e.timer >= heisen_materialize) {
                e.phase = .fight;
                e.timer = 0;
                if (a.rest == 0) heisen_reappear(e, a);
            }
        },
        else => {},
    }
}

fn heisen_fire(e: *Enemy, a: *Aux) void {
    const c = e.center();
    if (!clear_of_ship(c)) return;
    switch (a.stage) {
        0 => {
            if (due_a(e, 34)) {
                patterns.ring(c[0], c[1], 12 + rank.extra(4), e.spiral_angle, shot(0.8, .round));
                e.spiral_angle +%= 11;
            }
            if (due_b(e, a, 100)) patterns.line(c[0], c[1], 3, 0.25, shot(1.3, .needle));
        },
        1 => if (due_b(e, a, 7)) {
            // Two arms each way, one turning clockwise, one counter.
            const cw: i32 = e.spiral_angle;
            const ccw: i32 = e.ring_phase;
            patterns.at_angle(c[0], c[1], cw, shot(0.95, .pellet));
            patterns.at_angle(c[0], c[1], cw + 128, shot(0.95, .pellet));
            patterns.at_angle(c[0], c[1], ccw, shot(0.8, .round));
            patterns.at_angle(c[0], c[1], ccw + 128, shot(0.8, .round));
            e.spiral_angle +%= 9;
            e.ring_phase -%= 9;
        },
        else => if (due_b(e, a, 80)) {
            patterns.fan(c[0], c[1], 3 + rank.extra(2), 14, shot(0.9, .round));
        },
    }
}

fn heisen_reappear(e: *Enemy, a: *Aux) void {
    const c = e.center();
    if (!clear_of_ship(c)) return;
    switch (a.stage) {
        0 => {},
        1 => patterns.ring_aimed(c[0], c[1], 12 + rank.extra(4), shot(0.8, .round)),
        else => {
            patterns.ring(c[0], c[1], 16 + rank.extra(4), e.spiral_angle, shot(0.9, .pellet));
            e.spiral_angle +%= 8;
            patterns.line(c[0], c[1], 5, 0.2, shot(1.2, .needle));
        },
    }
}

// -------------------------------------------------------------- Mandelbug

// Stage 2: fractal. P1 aimed orbs that split into 6; P2 orbs whose
// splits split again (gen 1); P3 aimed walls and rings that split; final
// everything splits. Emitters (cell): the head (19, 24), the proboscis
// tip (3, 24), the core (39, 24).
fn mandel(e: *Enemy, a: *Aux) void {
    e.timer += 1;
    const amp: f32 = @min(@as(f32, @floatFromInt(e.timer)) / 60, 1);
    place(e, .{
        stop_x(.mandelbug) + 6 * amp * wave(e.timer, 500),
        40 + 12 * amp * wave(e.timer, 360),
    });
    if (a.rest > 0) return;
    const head = at(e, 19, 24);
    const tip = at(e, 3, 24);
    const core = at(e, 39, 24);
    if (!clear_of_ship(head)) return;
    switch (a.stage) {
        0 => {
            if (due_a(e, 70)) patterns.fan(head[0], head[1], 3, 22, .{
                .speed = 0.8,
                .shape = .orb,
                .source = .boss,
                .event = .split,
                .event_at = 45,
                .ev_n = 6 + @as(u8, @intCast(rank.extra(2))),
                .ev_speed = 14,
            });
            if (due_b(e, a, 80)) patterns.fan(head[0], head[1], 3, 12, shot(1.1, .pellet));
            if (due_c(e, 60)) patterns.line(tip[0], tip[1], 2, 0.3, shot(1.2, .pellet));
        },
        1 => {
            if (due_a(e, 90)) patterns.fan(head[0], head[1], 3, 36, .{
                .speed = 0.75,
                .shape = .orb,
                .source = .boss,
                .event = .split,
                .event_at = 40,
                .ev_n = 4,
                .ev_speed = 13,
                .gen = 1,
            });
            if (due_b(e, a, 70)) patterns.fan(head[0], head[1], 5 + rank.extra(2), 14, shot(0.9, .round));
            if (due_c(e, 60)) patterns.line(tip[0], tip[1], 2, 0.3, shot(1.2, .pellet));
        },
        2 => {
            if (due_a(e, 80)) wall(cell(e)[0] + 10, 17, weave_gap(e, a), 12, shot(0.85, .round));
            if (due_b(e, a, 70)) {
                patterns.ring(core[0], core[1], 8 + rank.extra(4), e.spiral_angle, .{
                    .speed = 0.75,
                    .shape = .pellet,
                    .source = .boss,
                    .event = .split,
                    .event_at = 50,
                    .ev_n = 3,
                    .ev_speed = 13,
                });
                e.spiral_angle +%= 16;
            }
            if (due_c(e, 50)) patterns.aimed(tip[0], tip[1], shot(1.3, .pellet));
        },
        else => {
            if (due_a(e, 80)) patterns.fan(head[0], head[1], 2, 40, .{
                .speed = 0.8,
                .shape = .orb,
                .source = .boss,
                .event = .split,
                .event_at = 36,
                .ev_n = 3,
                .ev_speed = 14,
                .gen = 1,
            });
            if (due_b(e, a, 50)) {
                patterns.ring(core[0], core[1], 8 + rank.extra(2), e.spiral_angle, .{
                    .speed = 0.75,
                    .shape = .pellet,
                    .source = .boss,
                    .event = .split,
                    .event_at = 50,
                    .ev_n = 3,
                    .ev_speed = 13,
                });
                e.spiral_angle +%= 16;
            }
            if (due_c(e, 50)) patterns.fan(tip[0], tip[1], 3, 10, shot(1.2, .pellet));
        },
    }
}

// ------------------------------------------------------------ Schrodinbug

// Stage 3: two superposed bodies mirrored about y 68, one real (the HP
// holder, on the side `aux2` = +1 below / -1 above). Both drawn dithered
// until a bolt touches one: the real collapses (solid until the next
// phase), a phantom bursts into a ring and reforms (90 ticks, no fire).
// Every pattern is written for a body above the axis; the lower body
// fires the y-flipped copy. P1 stop-and-go arcs; P2 crossing curtains;
// P3 stop-and-go rings and mirrored spirals; final curtains, rings and a
// needle line. Emitter: the chin, cell (24, 24).
const schrod_axis: f32 = 68;
const reform_ticks: u32 = 90;

/// Places both bodies (the real `e` and its phantom) for this tick.
fn schrod_bodies(e: *Enemy) void {
    const side = e.aux2;
    var d: f32 = 0;
    var x = stop_x(.schrodinbug);
    if (e.phase != .enter) {
        const amp: f32 = @min(@as(f32, @floatFromInt(e.timer)) / 60, 1);
        d = amp * (18 + 14 * wave(e.timer, 420));
        x += amp * 4 * wave(e.timer, 300);
    } else {
        x = cell(e)[0];
    }
    place(e, .{ x, schrod_axis + side * d - 24 });
    if (phantom_of()) |p| place(p, .{ x, schrod_axis - side * d - 24 });
}

/// The start of a phase: both bodies superposed again, the real one on a
/// side drawn from the world rng.
fn schrod_superpose(e: *Enemy, a: *Aux) void {
    a.flag = false;
    e.aux2 = if (rng.range(0, 2) == 0) -1 else 1;
}

fn schrod_spawn_phantom(e: *Enemy) void {
    const p = enemies.spawn(.boss, e.x, e.y, 0) orelse return;
    p.variant = e.variant;
    p.phase = .flicker;
    p.timer = reform_ticks / 2;
    p.entered = true;
    p.aux = @bitCast(Aux{ .phantom = true, .init = true });
}

fn update_phantom(e: *Enemy) void {
    if (real_body() == null) {
        e.active = false;
        return;
    }
    if (e.phase == .flicker) {
        e.timer += 1;
        if (e.timer >= reform_ticks) {
            e.phase = .fight;
            e.timer = 0;
        }
    }
}

/// A bolt touched the phantom: it bursts into a ring and reforms.
fn phantom_burst(p: *Enemy) void {
    if (p.phase != .fight) return;
    const c = p.center();
    if (clear_of_ship(c)) patterns.ring_aimed(c[0], c[1], 8 + rank.extra(4), shot(0.8, .pellet));
    p.phase = .flicker;
    p.timer = 0;
}

fn schrod(e: *Enemy, a: *Aux) void {
    e.timer += 1;
    if (phantom_of() == null) schrod_spawn_phantom(e);
    schrod_bodies(e);
    if (a.rest > 0) return;
    const real_flip = e.aux2 > 0;
    const ph = phantom_of();
    const ph_fires = if (ph) |p| p.phase == .fight else false;
    // Which volleys fire this tick (the countdowns run once for both).
    var heavy = false;
    var light = false;
    var third = false;
    switch (a.stage) {
        0 => {
            heavy = due_a(e, 60);
            light = due_b(e, a, 60);
        },
        1 => {
            heavy = due_a(e, 90);
            light = due_b(e, a, 6);
        },
        2 => {
            heavy = due_a(e, 75);
            light = due_b(e, a, 8);
        },
        else => {
            heavy = due_a(e, 90);
            light = due_b(e, a, 7);
            third = due_c(e, 80);
        },
    }
    schrod_volley(e, a.stage, real_flip, heavy, light, third);
    if (ph_fires) schrod_volley(ph.?, a.stage, !real_flip, heavy, light, false);
    if (light and a.stage != 0) e.spiral_angle +%= 13;
}

/// One body's share of the volleys, flipped in y when it is below the axis.
fn schrod_volley(b: *Enemy, stage: u3, flip: bool, heavy: bool, light: bool, third: bool) void {
    const c = at(b, 24, 24);
    if (!clear_of_ship(c)) return;
    switch (stage) {
        0 => {
            if (heavy) {
                var i: i32 = 0;
                while (i < 9) : (i += 1) {
                    const ang = mirror(104 + (i - 4) * 10, flip);
                    patterns.at_angle(c[0], c[1], ang, stop_and_go(1.8, 0.95, 50, 19));
                }
            }
            if (light) patterns.aimed(c[0], c[1], shot(1.2, .round));
        },
        1 => {
            if (heavy) patterns.ring(c[0], c[1], 10 + rank.extra(2), mirror(8, flip), stop_and_go(1.5, 0.94, 45, 20));
            if (light) patterns.at_angle(c[0], c[1], mirror(curtain_angle(), flip), shot(1.0, .round));
        },
        2 => {
            if (heavy) patterns.ring(c[0], c[1], 14 + rank.extra(4), mirror(0, flip), stop_and_go(1.6, 0.94, 45, 19));
            if (light) patterns.at_angle(c[0], c[1], mirror(@as(i32, schrod_angle()), flip), shot(0.9, .round));
        },
        else => {
            if (heavy) patterns.ring(c[0], c[1], 12 + rank.extra(4), mirror(12, flip), stop_and_go(1.6, 0.94, 45, 19));
            if (light) patterns.at_angle(c[0], c[1], mirror(curtain_angle(), flip), shot(1.0, .round));
            if (third) patterns.line(c[0], c[1], 3, 0.25, shot(1.3, .needle));
        },
    }
}

/// The real body's spiral angle (the volley helpers fire for both).
fn schrod_angle() u8 {
    return if (real_body()) |r| r.spiral_angle else 0;
}

/// The curtain's direction for a body above the axis: sweeps between
/// down-left (72) and left (128) every 120 ticks of the real body's clock.
fn curtain_angle() i32 {
    const t = if (real_body()) |r| r.timer else 0;
    return 100 + @as(i32, @intFromFloat(28 * wave(t, 120)));
}

fn mirror(angle: i32, flip: bool) i32 {
    return if (flip) -angle else angle;
}

/// Stop-and-go: launched at `speed`, braked by `drag`, re-aimed at the
/// ship at age `at_age` with base speed `ev_speed` / 16.
fn stop_and_go(speed: f32, drag: f32, at_age: u16, ev_speed: u8) Shot {
    return .{
        .speed = speed,
        .shape = .pellet,
        .source = .boss,
        .drag = drag,
        .event = .aim,
        .event_at = at_age,
        .ev_n = 1,
        .ev_speed = ev_speed,
    };
}

// ---------------------------------------------------------------- Bohrbug

// Stage 4, the final exam, totally reproducible (no rng). P1 walls whose
// gap tracks the ship and horn needles; P2 double flowers (two rings, half
// a step apart, fast and slow); P3 stop-and-go rain from the horn; P4
// curving spirals (`turn`), the curl flipping every 4 s; final the wall,
// a two-arm curving spiral and the rain at once. Emitters (cell): the
// nucleus (28, 23), the horn muzzle (5, 6).
const bohr_gap_half: f32 = 11;

fn bohr(e: *Enemy, a: *Aux) void {
    e.timer += 1;
    const amp: f32 = @min(@as(f32, @floatFromInt(e.timer)) / 60, 1);
    place(e, .{
        stop_x(.bohrbug) + 3 * wave(e.timer, 90),
        40 + 16 * amp * wave(e.timer, 600),
    });
    if (a.rest > 0) return;
    const nucleus = at(e, 28, 23);
    const horn = at(e, 5, 6);
    if (!clear_of_ship(nucleus)) return;
    switch (a.stage) {
        0 => {
            if (due_a(e, 60)) bohr_wall(e, a, 0.9);
            if (due_b(e, a, 45)) patterns.aimed(horn[0], horn[1], shot(1.6, .needle));
            if (due_c(e, 80)) patterns.fan(nucleus[0], nucleus[1], 3, 16, shot(1.0, .pellet));
        },
        1 => {
            if (due_b(e, a, 40)) bohr_flower(e, nucleus);
            if (due_c(e, 60)) patterns.aimed(horn[0], horn[1], shot(1.5, .needle));
        },
        2 => {
            if (due_b(e, a, 4)) bohr_rain(e, horn);
            if (due_a(e, 70)) patterns.fan(horn[0], horn[1], 5 + rank.extra(2), 12, shot(1.3, .needle));
        },
        3 => {
            if (due_b(e, a, 5)) bohr_spiral(e, a, nucleus, 3);
            if (due_a(e, 120)) patterns.line(horn[0], horn[1], 4, 0.25, shot(1.2, .needle));
        },
        else => {
            if (due_a(e, 90)) bohr_wall(e, a, 0.85);
            if (due_b(e, a, 7)) bohr_spiral(e, a, nucleus, 2);
            if (due_c(e, 9)) bohr_rain(e, horn);
        },
    }
}

/// A wall of rounds whose gap tracks the ship (`weave_gap`).
fn bohr_wall(e: *Enemy, a: *Aux, speed: f32) void {
    wall(e.x - 4, 17, weave_gap(e, a), bohr_gap_half, shot(speed, .round));
}

fn bohr_flower(e: *Enemy, c: [2]f32) void {
    const n = 12 + rank.extra(4);
    const half: i32 = @intCast(128 / n);
    patterns.ring(c[0], c[1], n, e.spiral_angle, shot(1.1, .pellet));
    patterns.ring(c[0], c[1], n, @as(i32, e.spiral_angle) + half, shot(0.7, .round));
    e.spiral_angle +%= 9;
}

/// One rain drop: thrown left over a cone (96..176) at 1.2..2.2, braked,
/// then re-aimed at the ship at age 64. The cone and speed walk a
/// golden-ratio sequence, so the drops cover the field evenly.
fn bohr_rain(e: *Enemy, horn: [2]f32) void {
    e.spiral_angle +%= 97;
    const sa: u32 = e.spiral_angle;
    const ang: i32 = @intCast(96 + sa * 80 / 256);
    const speed = 1.2 + 0.25 * @as(f32, @floatFromInt(sa % 5));
    patterns.at_angle(horn[0], horn[1], ang, .{
        .speed = speed,
        .shape = .pellet,
        .source = .boss,
        .drag = 0.965,
        .event = .aim,
        .event_at = 64,
        .ev_n = 1,
        .ev_speed = 16,
    });
}

/// `arms` curving arms; the curl's sign flips every 240 ticks.
fn bohr_spiral(e: *Enemy, a: *Aux, c: [2]f32, arms: u32) void {
    const curl: i8 = if ((a.clock / 240) % 2 == 0) 2 else -2;
    const n: i32 = @intCast(arms);
    const step: i32 = @divTrunc(256, n);
    var k: i32 = 0;
    while (k < n) : (k += 1) {
        patterns.at_angle(c[0], c[1], @as(i32, e.spiral_angle) + k * step, .{
            .speed = 1.0,
            .shape = .round,
            .source = .boss,
            .turn = curl,
            .turn_left = 40,
        });
    }
    e.spiral_angle +%= 6;
}

// ---------------------------------------------------------------- drawing

/// The boss at its box position (x, y) (floored). `own` already merges
/// the hit flash; the teleport ghost ignores it.
pub fn draw_boss(e: Enemy, x: i32, y: i32, opts: draw.SpriteOpts, own_in: draw.SpriteOpts) void {
    const id = id_of(e);
    // Under steady fire a boss is hit nearly every tick: its white flash
    // shows on one frame in eight at most, so the body (and the alt-cell
    // telegraph) stays readable.
    var own = own_in;
    own.flash_white = opts.flash_white or (e.flash > 0 and (e.phase == .dying or e.age % 8 == 0));
    const b = box(id);
    const cx = x - @as(i32, @intFromFloat(b.ox));
    const cy = y - @as(i32, @intFromFloat(b.oy));
    const idle = (e.age / frame_ticks) % idle_frames;
    switch (id) {
        .heisenbug => switch (e.phase) {
            .flicker, .pause => draw.draw_sprite(gfx.boss, 48, 48, alt_cell, cx, cy, .{ .flash_white = opts.flash_white, .skip_odd = true }),
            else => draw.draw_sprite(gfx.boss, 48, 48, idle, cx, cy, own),
        },
        .mandelbug => draw.draw_sprite(gfx.boss2, 48, 48, if (telegraphing(e)) alt_cell else idle, cx, cy, own),
        .schrodinbug => draw_schrod(e, cx, cy, idle, opts, own),
        .bohrbug => draw.draw_sprite(gfx.boss4, 48, 48, if (telegraphing(e)) alt_cell else idle, cx, cy, own),
    }
}

/// A heavy volley is due within `telegraph` ticks (the alt cell shows).
fn telegraphing(e: Enemy) bool {
    const a = aux_of(e);
    if (e.phase != .fight or a.rest > 0) return false;
    if (!phases(id_of(e))[a.stage].heavy) return false;
    return e.fire_tick <= telegraph;
}

fn draw_schrod(e: Enemy, cx: i32, cy: i32, idle: u32, opts: draw.SpriteOpts, own: draw.SpriteOpts) void {
    const a = aux_of(e);
    const real = if (a.phantom) real_body() else null;
    const tele = if (a.phantom) (if (real) |r| telegraphing(r.*) else false) else telegraphing(e);
    const index = if (tele) alt_cell else idle;
    if (a.phantom) {
        // Reforming: a sparse blink, every other 4 ticks.
        if (e.phase == .flicker and (e.age / 4) % 2 == 0) return;
        draw.draw_sprite(gfx.boss3, 48, 48, index, cx, cy, .{ .flash_white = own.flash_white, .skip_odd = true });
        return;
    }
    const collapsed = (a.flag and e.phase != .enter) or e.phase == .dying;
    draw.draw_sprite(gfx.boss3, 48, 48, index, cx, cy, .{
        .flash_white = own.flash_white,
        .skip_odd = opts.skip_odd or !collapsed,
    });
}

// ------------------------------------------------------------- test hooks

comptime {
    if (cart.is_wasm) {
        @export(&debug_boss, .{ .name = "debug_boss" });
        @export(&debug_boss_id, .{ .name = "debug_boss_id" });
        @export(&debug_boss_phase, .{ .name = "debug_boss_phase" });
        @export(&debug_boss_clock, .{ .name = "debug_boss_clock" });
    }
}

/// Test hook: the next boss to spawn is `n & 15` (>= 4: the stage's own)
/// and starts in HP phase `n >> 4`. Set it before the boss spawns and
/// leave it for the run (it is not World state). Returns `n`.
fn debug_boss(n: u32) callconv(.c) u32 {
    bugs_force_boss = @intCast(n & 15);
    bugs_force_phase = @intCast((n >> 4) & 7);
    return n;
}
/// The active boss's id (255: none).
fn debug_boss_id() callconv(.c) u32 {
    const b = enemies.boss() orelse return 255;
    return @backingInt(id_of(b.*));
}
/// The active boss's HP phase (0-based; 255: none).
fn debug_boss_phase() callconv(.c) u32 {
    const b = enemies.boss() orelse return 255;
    return aux_of(b.*).stage;
}
/// Ticks into the active boss's HP phase (0: none).
fn debug_boss_clock() callconv(.c) u32 {
    const b = enemies.boss() orelse return 0;
    return aux_of(b.*).clock;
}
