//! Enemy pool (`world.w.enemies`) and the per-kind movement and fire
//! programs (SPEC.md sections 6 and 7, PLAN.md M7 "Stages" and "Deviations
//! (B1)"). Every program is plain data in `Enemy`; the only randomness is
//! the world rng, drawn in `spawn` (spider hang y) and in `update` (moth
//! targets, boss teleport and death explosions, in pool order), so the rng
//! call order per tick is deterministic. Fire programs run on countdowns
//! in `aux` (and `fire_tick`), reloaded with `rank.interval(base)` when they
//! fire, so a rising rank never shifts a modulus; bullet speeds are base
//! speeds that `bullets.spawn_shot` scales; regular enemy HP is scaled by
//! rank at spawn (PLAN.md M7). `pattern` picks one of a kind's movement /
//! fire programs (the stage tables in `waves.zig` choose it).
const cart = @import("cart-api");
const gfx = @import("gfx");
const draw = @import("draw.zig");
const fx = @import("fx.zig");
const patterns = @import("patterns.zig");
const player = @import("player.zig");
const rng = @import("rng.zig");
const waves = @import("waves.zig");
const world = @import("world.zig");
const boss_hp = @import("boss_hp.zig");
const pickups = @import("pickups.zig");
const bosses = @import("bosses.zig");
const rank = @import("rank.zig");
const formations = @import("formations.zig");
const bullets = @import("bullets.zig");

/// The bugs (PLAN.md M7 "Kinds"). `herd` is the Thundering Herd midboss.
pub const Kind = enum(u8) { gnat, wasp, beetle, spider, moth, boss, centipede, flea, ladybug, mite, zombie, herd };

/// `Enemy.variant` of a `.boss` (defined in the pure `boss_hp.zig`).
pub const BossId = boss_hp.BossId;

/// Where an enemy is in its movement program. Which values a kind uses:
/// wasp enter/pause/charge, beetle enter/sit/leave, spider drop/hang/climb,
/// moth wander, boss enter/fight/flicker/vanished/dying, flea
/// warn/jump/land, ladybug enter/loop/leave, zombie enter/husk, herd
/// enter/hold/leave; gnat, centipede and mite none.
pub const Phase = enum(u8) { enter, pause, charge, sit, leave, drop, hang, climb, wander, fight, flicker, vanished, dying, warn, jump, land, loop, husk, hold };

/// The edge an enemy enters from (`waves.Entry.edge`). Wasps and ladybugs
/// use top and bottom; fleas always come from the left (behind the ship).
pub const Edge = enum(u8) { right, top, bottom, left };

pub const Enemy = struct {
    active: bool = false,
    kind: Kind = .gnat,
    /// Ticks before the enemy appears (used to space out strings).
    delay: u32 = 0,
    /// Cell top-left.
    x: f32 = 0,
    y: f32 = 0,
    /// Gnat: wobble center line. Boss: bob center line.
    base_y: f32 = 0,
    /// Ticks since it appeared (animation, gnat wobble, moth fire clock).
    age: u32 = 0,
    /// u16 since M7 (bosses go to the thousands).
    hp: u16 = 1,
    /// Ticks of white hit flash left.
    flash: u8 = 0,
    phase: Phase = .enter,
    /// Ticks spent in the current phase (moth: ticks since first on screen;
    /// boss: also the bob clock while fighting).
    timer: u32 = 0,
    /// Wasp charge velocity.
    vx: f32 = 0,
    vy: f32 = 0,
    /// Moth: current target. Spider: `target_y` is the hang y.
    target_x: f32 = 0,
    target_y: f32 = 0,
    /// Has overlapped the screen at least once; off-screen culling only
    /// applies after that.
    entered: bool = false,
    /// Boss: fighting ticks so far (drives the fire phase), and the ring
    /// and spiral angles in 1/256 turns.
    fire_tick: u32 = 0,
    ring_phase: u8 = 0,
    spiral_angle: u8 = 0,
    /// Boss: its `BossId`. Centipede: 0 = head, 1 = segment. Free for
    /// other kinds (PLAN.md M7).
    variant: u8 = 0,
    /// The formation it belongs to (`formations.zig`), 0 = none.
    formation: u8 = 0,
    /// Free per-kind state. Regular kinds: `aux` is the main fire
    /// countdown (ticks to the next volley), `fire_tick` the second one.
    aux: u32 = 0,
    aux2: f32 = 0,
    /// Regular kinds: which movement / fire program (`waves.Entry.pattern`).
    pattern: u8 = 0,
    /// The edge it entered from.
    edge: Edge = .right,

    /// Spawned and on the field (collidable, drawn). A vanished boss is not.
    pub fn live(e: Enemy) bool {
        return e.active and e.delay == 0 and !(e.kind == .boss and e.phase == .vanished);
    }

    pub fn size(e: Enemy) [2]f32 {
        return switch (e.kind) {
            .gnat => .{ 8, 8 },
            .wasp, .beetle, .spider, .moth => .{ 16, 16 },
            .centipede, .flea, .ladybug, .mite, .zombie => .{ 16, 16 },
            .herd => .{ 32, 32 },
            .boss => bosses.size(e),
        };
    }

    pub fn points(e: Enemy) u32 {
        return switch (e.kind) {
            .gnat => 10,
            .wasp => 30,
            .beetle => 50,
            .spider, .moth => 40,
            .boss => 500,
            .centipede => if (e.variant == 0) 100 else 20,
            .flea => 40,
            .ladybug => 30,
            .zombie => 50,
            .mite => 60,
            .herd => 1000,
        };
    }

    /// Whether player shots can hit it: a boss decides (`bosses.hittable`:
    /// not while it teleports, is vanished, dying or escaping).
    pub fn hittable(e: Enemy) bool {
        // A flea behind its warning chevron and a zombie's husk are
        // neither shot nor rammed (and seekers ignore them).
        if (e.kind == .flea and e.phase == .warn) return false;
        if (e.kind == .zombie and e.phase == .husk) return false;
        if (e.kind != .boss) return true;
        return bosses.hittable(e);
    }

    /// Cell center: the emitter position for its bullets.
    pub fn center(e: Enemy) [2]f32 {
        const s = e.size();
        return .{ e.x + s[0] / 2, e.y + s[1] / 2 };
    }
};

/// sin(2 pi i / 256) for i in 0..256, built at comptime (no libm at runtime).
pub const sin_table: [256]f32 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [256]f32 = undefined;
    for (&t, 0..) |*v, i| {
        const a: f32 = @as(f32, @floatFromInt(i)) * (2.0 * std_pi / 256.0);
        v.* = @sin(a);
    }
    break :blk t;
};
const std_pi: f32 = 3.14159265358979;

pub const spawn_x: f32 = 168.0;
pub const gnat_spawn_x: f32 = spawn_x;

// ---------------------------------------------------------------- knobs
// Every movement and fire number of the regular kinds, in one place
// (PLAN.md M7 "Deviations (B1)" has the table). Fire intervals are base
// (rank 0) ticks, shortened by `rank.interval`; speeds are base px per
// tick, scaled by `bullets.spawn_shot`.

/// No volley is fired while the emitter is this close to the ship's
/// hitbox center (bullets never spawn on top of the ship).
const safe_radius: f32 = 22;

const gnat_speed: f32 = 1.0;
const gnat_amplitude: f32 = 8.0;
/// Pattern 2 gnats wobble wider.
const gnat_amplitude_wide: f32 = 14.0;
const gnat_period: u32 = 40;
const string_len = 5;
const string_spacing = 12;
/// Pattern 1 gnats fire one aimed pellet when they cross x 120; pattern 2
/// at x 136 and again at x 84.
const gnat_fire_x: f32 = 120;
const gnat_fire_x2: f32 = 136;
const gnat_fire_x3: f32 = 84;
const gnat_shot_speed: f32 = 1.2;

const wasp_speed: f32 = 2.5;
const wasp_stop_x: f32 = 120;
/// Wasps from the top / bottom edge stop at these cell y.
const wasp_stop_top: f32 = 22;
const wasp_stop_bottom: f32 = 90;
const wasp_pause: u32 = 20;
const wasp_shot_speed: f32 = 1.3;
const wasp_fan_step = 14;

const beetle_speed: f32 = 0.5;
const beetle_stop_x: f32 = 112;
/// Pattern 2 (the wall beetle) stops further right.
const beetle_wall_stop_x: f32 = 136;
const beetle_sit: u32 = 240;
const beetle_first: u32 = 0;
const beetle_fire_every: u32 = 24;
const beetle_fan_n = 5;
const beetle_fan_step = 12;
const beetle_shot_speed: f32 = 0.9;
const beetle_ring_n = 10;
const beetle_wall_every: u32 = 60;
const beetle_wall_n = 13;
const beetle_wall_gap: f32 = 13;
const beetle_wall_speed: f32 = 0.8;
/// The wall's gap opens this far from the ship's y.
const beetle_wall_far: f32 = 48;
const beetle_orb_speed: f32 = 0.7;
const beetle_orb_split_at: u16 = 50;
const beetle_orb_children = 6;
const beetle_orb_child_speed: u8 = 16;

const spider_speed: f32 = 1.5;
const spider_start_y: f32 = -16;
const spider_hang_min = 24;
const spider_hang_max = 72;
const spider_hang: u32 = 180;
const spider_first: u32 = 10;
const spider_fire_every: u32 = 18;
const spider_arc_n = 5;
const spider_arc_step = 8;
/// The arc's middle sweeps 128 +- 40 (left, swinging down and up).
const spider_sweep: f32 = 40;
const spider_sweep_step: u8 = 12;
const spider_shot_speed: f32 = 0.8;
/// The thread hangs from just under the HUD.
const thread_top: i32 = 8;

const moth_speed: f32 = 1.2;
const moth_retarget_every: u32 = 30;
const moth_min_x = 80;
const moth_max_x = 144;
const moth_min_y = 16;
const moth_max_y = 104;
const moth_stay: u32 = 600;
const moth_exit_x: f32 = -40;
const moth_first: u32 = 0;
const moth_fire_every: u32 = 20;
const moth_pair_step = 8;
const moth_needle_speed: f32 = 1.4;
/// Pattern 1: a ring of stop-and-go pellets (brake, then re-aim).
const moth_sg_every: u32 = 45;
const moth_sg_n = 6;
const moth_sg_speed: f32 = 1.5;
const moth_sg_drag: f32 = 0.93;
const moth_sg_aim_at: u16 = 40;
const moth_sg_aim_speed: u8 = 26;

/// Centipede: a head and 5 segments on one weaving path, each `delay`
/// ticks behind the one in front (about 8.4 px at 0.6 px per tick).
const centipede_segments = 5;
const centipede_delay = 14;
const centipede_speed: f32 = 0.6;
const centipede_amplitude: f32 = 16;
const centipede_amplitude_wide: f32 = 28;
const centipede_period: u32 = 160;
/// The ripple: the head fires first, each segment `ripple_gap` ticks after
/// the one in front of it.
const centipede_first: u32 = 40;
const centipede_ripple_gap: u32 = 6;
const centipede_fire_every: u32 = 50;
const centipede_shot_speed: f32 = 1.1;
const centipede_ring_n = 10;

/// Flea: 30 ticks of warning chevron at the left edge, then gravity jumps
/// to the right, firing at each apex.
const flea_warn: u32 = 30;
const flea_start_x: f32 = -16;
const flea_vx: f32 = 1.1;
const flea_gravity: f32 = 0.09;
/// Vertical speed of the jump in from behind, and of each later jump
/// (pattern 1 jumps higher).
const flea_entry_vy: f32 = -1.6;
const flea_jump_vy: f32 = -2.5;
const flea_jump_vy_high: f32 = -3.0;
/// Cell top when standing on the ground.
const flea_ground: f32 = 97;
const flea_land: u32 = 12;
const flea_shot_speed: f32 = 1.2;
const flea_fan_step = 14;
const flea_ring_n = 8;

/// Ladybug: straight in from the top or bottom, one (pattern 1: two)
/// loops of radius 18, out the far edge; a ring at the top of each loop.
const ladybug_speed: f32 = 1.6;
const ladybug_drift: f32 = 0.4;
const ladybug_radius: f32 = 18;
/// Loop angle step per tick, 1/256 turns (a loop takes 64 ticks).
const ladybug_turn: u32 = 4;
/// The loop starts when the cell center reaches this y.
const ladybug_loop_top: f32 = 44;
const ladybug_loop_bottom: f32 = 84;
const ladybug_ring_n = 10;
const ladybug_shot_speed: f32 = 0.9;

/// Mite: rides the near layer (exactly its scroll), feet on its top edge.
const mite_first: u32 = 0;
const mite_burst_every: u32 = 60;
const mite_burst_gap: u8 = 6;
const mite_needle_speed: f32 = 1.5;
const mite_fan_first: u32 = 30;
const mite_fan_every: u32 = 70;
const mite_fan_angle: i32 = 176;
const mite_fan_step = 14;
const mite_fan_speed: f32 = 0.9;
/// Muzzle in the cell (ASSETS.md "Mite").
const mite_muzzle = [2]f32{ 3, 4 };

/// Zombie: lumbers left, dies into a husk that revives once.
const zombie_speed: f32 = 0.55;
const zombie_amplitude: f32 = 10;
const zombie_period: u32 = 120;
const zombie_first: u32 = 0;
const zombie_fire_every: u32 = 35;
const zombie_fan_step = 14;
const zombie_shot_speed: f32 = 1.0;
const zombie_husk: u32 = 90;
const zombie_husk_drift: f32 = 0.5;
const zombie_ring_n = 12;
const zombie_ring_speed: f32 = 0.9;

/// Thundering Herd (midboss): holds at x 112, gnat strings from her egg
/// row, flowers (two rings half a step apart, one fast, one slow); leaves
/// after 25 s.
const herd_speed: f32 = 0.8;
const herd_hold_x: f32 = 112;
const herd_y: f32 = 36;
const herd_bob: f32 = 16;
const herd_bob_period: u32 = 240;
const herd_stay: u32 = 25 * 60;
const herd_leave_speed: f32 = 1.0;
const herd_string_every: u32 = 120;
const herd_flower_first: u32 = 40;
const herd_flower_every = [3]u32{ 50, 42, 36 };
const herd_flower_n = [3]u32{ 10, 10, 12 };
const herd_fast_speed: f32 = 1.2;
const herd_slow_speed: f32 = 0.7;
const herd_flower_turn: u8 = 9;
const herd_line_every: u8 = 70;
const herd_line_n = 3;
/// Gnat strings leave from the egg row (ASSETS.md "Thundering Herd").
const herd_eggs = [2]f32{ 14, 18 };

/// Off-screen cull bounds for the cell top-left (after having entered).
const cull_min: f32 = -16;
const cull_max_x: f32 = 176;
const cull_max_y: f32 = 144;

/// Animation: 16x16 bug cells change frame every 5 ticks.
const bug_frame_ticks = 5;

fn alloc() ?*Enemy {
    for (&world.w.enemies) |*e| {
        if (!e.active) return e;
    }
    return null;
}

/// Base (rank 0) HP of a regular kind; `spawn` scales it by rank.
/// Centipede: head 10, segment 4. Herd by version (pattern 0..2).
fn base_hp(kind: Kind, variant: u8, pattern: u8) u16 {
    return switch (kind) {
        .gnat => 1,
        .wasp => 2,
        .beetle => 24,
        .spider => 12,
        .moth => 8,
        .centipede => if (variant == 0) 24 else 8,
        .flea => 12,
        .ladybug => 6,
        .mite => 36,
        .zombie => 16,
        .herd => switch (pattern) {
            0 => 400,
            1 => 520,
            else => 640,
        },
        .boss => 1,
    };
}

/// HP of the active boss `b` at full health (its id, this loop); the spawn
/// and the HUD bar share it.
pub fn boss_max_hp_of(b: Enemy) u32 {
    return boss_hp.max_hp(@fromBackingInt(@intCast(b.variant)), world.w.waves.loop);
}

/// Spawns one enemy of `kind` with its cell top-left at (x, y), appearing
/// after `delay` ticks, running program 0 from the right edge (`spawn_ex`).
pub fn spawn(kind: Kind, x: f32, y: f32, delay: u32) ?*Enemy {
    return spawn_ex(kind, x, y, delay, 0, .right, 0);
}

/// Spawns one enemy: cell top-left (x, y), `delay` ticks before it
/// appears, movement / fire program `pattern`, entering from `edge`;
/// `variant` is the centipede part (0 head, 1 segment) or the boss id
/// (set here from the stage). Spider: `x` is its column, it starts at
/// y -16 and draws its hang y from the world rng here. Mite: `y` is
/// ignored (it stands on the near layer). Returns null when the pool is
/// full.
pub fn spawn_ex(kind: Kind, x: f32, y: f32, delay: u32, pattern: u8, edge: Edge, variant: u8) ?*Enemy {
    const e = alloc() orelse return null;
    e.* = .{
        .active = true,
        .kind = kind,
        .delay = delay,
        .x = x,
        .y = y,
        .base_y = y,
        .pattern = pattern,
        .edge = edge,
        .variant = variant,
    };
    if (kind == .boss) {
        // The current stage's boss, HP by id and loop (not ranked).
        e.variant = @backingInt(boss_hp.for_stage(world.w.waves.stage));
        e.hp = @intCast(boss_max_hp_of(e.*));
    } else {
        e.hp = rank.hp(base_hp(kind, variant, pattern));
    }
    switch (kind) {
        .wasp => e.target_y = switch (edge) {
            .top => wasp_stop_top,
            .bottom => wasp_stop_bottom,
            else => 0,
        },
        .beetle => e.aux = beetle_first,
        .spider => {
            e.y = spider_start_y;
            e.base_y = spider_start_y;
            e.phase = .drop;
            e.target_y = @floatFromInt(rng.range(spider_hang_min, spider_hang_max));
            e.aux = spider_first;
        },
        .moth => {
            e.phase = .wander;
            e.aux = moth_first;
        },
        .centipede => {
            // The path origin; `ring_phase` is the place in the chain.
            e.target_x = x;
        },
        .flea => {
            e.phase = .warn;
            e.x = flea_start_x;
        },
        .mite => {
            e.target_x = x;
            e.timer = ground_steps();
            e.y = ground_cell_y(x);
            e.aux = mite_first;
            e.fire_tick = mite_fan_first;
        },
        .zombie => e.aux = zombie_first,
        .herd => {
            e.fire_tick = herd_string_every;
            e.aux = herd_flower_first;
        },
        else => {},
    }
    return e;
}

/// Spawns a string of 5 gnats at spawn x, wobbling around `y`, 12 ticks
/// apart, as one formation (`drop`: shooting all five drops a crate,
/// PLAN.md M7). Gnats that do not fit in the pool count as lost, so the
/// formation still frees its slot.
pub fn spawn_gnat_string(y: f32, drop: bool) void {
    spawn_gnat_string_ex(gnat_spawn_x, y, if (drop) formations.open(string_len, true) else 0, 0);
}

/// A string of 5 gnats from (x, y) running program `pattern`, members of
/// formation `id` (0 = none).
pub fn spawn_gnat_string_ex(x: f32, y: f32, id: u8, pattern: u8) void {
    for (0..string_len) |i| {
        const e = spawn_ex(.gnat, x, y, @intCast(i * string_spacing), pattern, .right, 0) orelse {
            formations.lost(id);
            continue;
        };
        e.formation = id;
    }
}

/// A centipede (head and 5 segments) entering at the right edge on the
/// weave around `y`, members of formation `id`. The tail is spawned
/// first so the head usually draws on top.
pub fn spawn_centipede(y: f32, id: u8, pattern: u8) void {
    var k: u32 = centipede_segments + 1;
    while (k > 0) {
        k -= 1;
        const e = spawn_ex(.centipede, spawn_x, y, k * centipede_delay, pattern, .right, @intFromBool(k > 0)) orelse {
            formations.lost(id);
            continue;
        };
        e.formation = id;
        e.ring_phase = @intCast(k);
        // The ripple: segment k fires `k * ripple_gap` after the head,
        // counted from its own appearance, `k * delay` after the head's.
        e.aux = centipede_first + k * centipede_ripple_gap - k * centipede_delay;
    }
}

/// The midboss (Thundering Herd) is on the field: the stage table waits.
pub fn herd_alive() bool {
    // By pointer: iterating the array by value copies all of it.
    for (&world.w.enemies) |*e| {
        if (e.active and e.kind == .herd) return true;
    }
    return false;
}

fn on_screen(e: *const Enemy) bool {
    const s = e.size();
    return e.x < @as(f32, cart.screen_width) and e.x + s[0] > 0 and
        e.y < @as(f32, cart.screen_height) and e.y + s[1] > 0;
}

fn off_field(e: *const Enemy) bool {
    return e.x < cull_min or e.x > cull_max_x or e.y < cull_min or e.y > cull_max_y;
}

/// (x, y) is inside the play field (below the HUD row).
fn in_field(p: [2]f32) bool {
    return p[0] >= 0 and p[0] < @as(f32, cart.screen_width) and
        p[1] >= @as(f32, draw.hud_height) and p[1] < @as(f32, cart.screen_height);
}

/// (x, y) is within `safe_radius` of the ship's hitbox center.
fn near_ship(p: [2]f32) bool {
    const hb = player.hitbox();
    const dx = p[0] - (hb[0] + hb[2] / 2);
    const dy = p[1] - (hb[1] + hb[3] / 2);
    return dx * dx + dy * dy < safe_radius * safe_radius;
}

/// A fire countdown: counts `c` down; at 0, when the emitter `at` is in
/// the field, reloads it with `rank.interval(every)` and returns whether
/// to fire (not when the emitter is on top of the ship: that volley is
/// skipped). Held at 0 while the emitter is off the field.
fn countdown(c: *u32, at: [2]f32, every: u32) bool {
    if (c.* > 0) {
        c.* -= 1;
        return false;
    }
    if (!in_field(at)) return false;
    c.* = reload(every) -| 1;
    return !near_ship(at);
}

/// Sixteenths of a fire interval by stage, on top of the rank: the
/// content's own difficulty curve. From the second loop on every stage
/// fires at `loop_pace` sixths of that again (the rank's mercy can hold a
/// struggling player's rank at 0 for minutes, so the loop's own +400
/// alone would not make loop 2 harder).
const stage_pace = [4]u32{ 16, 9, 9, 7 };
const loop_pace: u32 = 2;
const loop_pace_of: u32 = 6;

/// A fire interval at this stage, loop and rank (at least 1 tick).
fn reload(every: u32) u32 {
    const st = &world.w.waves;
    var k = stage_pace[@min(st.stage, stage_pace.len - 1)];
    if (st.loop > 0) k = @max(k * loop_pace / loop_pace_of, 1);
    return @max(rank.interval(every) * k / 16, 1);
}

/// The main fire countdown (`aux`) from the cell center.
fn fire_due(e: *Enemy, every: u32) bool {
    return countdown(&e.aux, e.center(), every);
}

/// sin of a 1/256-turn angle.
fn sin256(a: u32) f32 {
    return sin_table[a % 256];
}

/// x crossed `line` going left this tick.
fn crossed(before: f32, after: f32, line: f32) bool {
    return before > line and after <= line;
}

pub fn update() void {
    for (&world.w.enemies) |*e| {
        if (!e.active) continue;
        if (e.delay > 0) {
            e.delay -= 1;
            continue;
        }
        if (e.flash > 0) e.flash -= 1;
        switch (e.kind) {
            .gnat => update_gnat(e),
            .wasp => update_wasp(e),
            .beetle => update_beetle(e),
            .spider => update_spider(e),
            .moth => update_moth(e),
            .boss => bosses.update(e),
            .centipede => update_centipede(e),
            .flea => update_flea(e),
            .ladybug => update_ladybug(e),
            .mite => update_mite(e),
            .zombie => update_zombie(e),
            .herd => update_herd(e),
        }
        e.age += 1;
        if (!e.active) {
            // Left the field by itself (a gnat past the left edge), or a
            // boss that finished dying (no formation).
            formations.lost(e.formation);
            continue;
        }
        if (!e.entered) {
            e.entered = on_screen(e);
        } else if (e.kind != .boss and off_field(e)) {
            e.active = false;
            formations.lost(e.formation);
        }
    }
}

/// Straight left with a sine wobble, gone at x < -8. Pattern 1 fires one
/// aimed pellet crossing x 120 (stage 1 from 20 s on); pattern 2 wobbles
/// wider and fires crossing x 136 and x 84.
fn update_gnat(e: *Enemy) void {
    const before = e.x;
    e.x -= gnat_speed;
    const amp = if (e.pattern == 2) gnat_amplitude_wide else gnat_amplitude;
    e.y = e.base_y + amp * sin256((e.age % gnat_period) * 256 / gnat_period);
    const fire = switch (e.pattern) {
        1 => crossed(before, e.x, gnat_fire_x),
        2 => crossed(before, e.x, gnat_fire_x2) or crossed(before, e.x, gnat_fire_x3),
        else => false,
    };
    if (fire) {
        const c = e.center();
        if (!near_ship(c)) patterns.aimed(c[0], c[1], .{ .speed = gnat_shot_speed, .shape = .pellet, .source = .gnat });
    }
    if (e.x < -8.0) e.active = false;
}

/// Enter fast (from the right to x 120, or from the top / bottom edge to
/// its stop line), fire on stopping (pattern 0 one aimed pellet, else an
/// aimed 3-fan), pause 20 ticks, then charge at where the ship was on the
/// last pause tick.
fn update_wasp(e: *Enemy) void {
    switch (e.phase) {
        .enter => {
            const stop = switch (e.edge) {
                .top => blk: {
                    e.y += wasp_speed;
                    break :blk e.y >= e.target_y;
                },
                .bottom => blk: {
                    e.y -= wasp_speed;
                    break :blk e.y <= e.target_y;
                },
                else => blk: {
                    e.x -= wasp_speed;
                    break :blk e.x <= wasp_stop_x;
                },
            };
            if (stop) {
                e.phase = .pause;
                e.timer = 0;
                const c = e.center();
                if (!near_ship(c)) {
                    const shot: bullets.Shot = .{ .speed = wasp_shot_speed, .shape = .pellet, .source = .wasp };
                    patterns.fan(c[0], c[1], if (e.pattern == 0) 3 else 5, wasp_fan_step, shot);
                }
            }
        },
        .pause => {
            e.timer += 1;
            if (e.timer >= wasp_pause) {
                const c = e.center();
                const dir = patterns.aim(c[0], c[1]);
                e.vx = dir[0] * wasp_speed;
                e.vy = dir[1] * wasp_speed;
                e.phase = .charge;
                e.timer = 0;
            }
        },
        else => {
            e.x += e.vx;
            e.y += e.vy;
        },
    }
}

/// Crawl in to x 112, sit 240 ticks, leave; fires from 24 ticks after it
/// shows. Pattern 0: an aimed 5-fan; 1: the fan alternating with a
/// rotating 10-ring; 2 (the wall beetle, stops at x 136): walls with a gap
/// that sweeps up and down; 3: the fan alternating with an aimed orb that
/// splits into 6 pellets.
fn update_beetle(e: *Enemy) void {
    const stop_x = if (e.pattern == 2) beetle_wall_stop_x else beetle_stop_x;
    switch (e.phase) {
        .enter => {
            e.x -= beetle_speed;
            if (e.x <= stop_x) {
                e.x = stop_x;
                e.phase = .sit;
                e.timer = 0;
            }
        },
        .sit => {
            e.timer += 1;
            if (e.timer >= beetle_sit) {
                e.phase = .leave;
                e.timer = 0;
            }
        },
        else => e.x -= beetle_speed,
    }
    const every = if (e.pattern == 2) beetle_wall_every else beetle_fire_every;
    if (!fire_due(e, every)) return;
    const c = e.center();
    const round: bullets.Shot = .{ .speed = beetle_shot_speed, .source = .beetle };
    const alt = e.fire_tick % 2 == 1;
    e.fire_tick += 1;
    switch (e.pattern) {
        1 => if (alt) {
            patterns.ring(c[0], c[1], beetle_ring_n + rank.extra(2), e.ring_phase, round);
            e.ring_phase +%= 13;
        } else patterns.fan(c[0], c[1], beetle_fan_n, beetle_fan_step, round),
        2 => {
            // The gap opens on the far side of the ship (a wall is seen
            // coming for two seconds: move early).
            const sy = player.hitbox()[1] + player.hitbox_size / 2;
            const gap = @min(@max(if (sy < 66) sy + beetle_wall_far else sy - beetle_wall_far, 24), 112);
            patterns.wall(c[0], 14, 122, beetle_wall_n, gap, beetle_wall_gap, .{ .speed = beetle_wall_speed, .source = .beetle });
        },
        3 => if (alt) {
            patterns.aimed(c[0], c[1], .{
                .speed = beetle_orb_speed,
                .shape = .orb,
                .source = .beetle,
                .event = .split,
                .event_at = beetle_orb_split_at,
                .ev_n = beetle_orb_children,
                .ev_speed = beetle_orb_child_speed,
            });
        } else patterns.fan(c[0], c[1], beetle_fan_n, beetle_fan_step, round),
        else => patterns.fan(c[0], c[1], beetle_fan_n + rank.extra(2), beetle_fan_step, round),
    }
}

/// Drop to the hang y, hang 180 ticks, climb; from 24 ticks after it
/// appears it fires a 7-bullet arc whose middle sweeps around "left"
/// (pattern 1: pellets, 2 more bullets, a little faster).
fn update_spider(e: *Enemy) void {
    switch (e.phase) {
        .drop => {
            e.y += spider_speed;
            if (e.y >= e.target_y) {
                e.y = e.target_y;
                e.phase = .hang;
                e.timer = 0;
            }
        },
        .hang => {
            e.timer += 1;
            if (e.timer >= spider_hang) {
                e.phase = .climb;
                e.timer = 0;
            }
        },
        else => e.y -= spider_speed,
    }
    if (e.phase == .climb or !fire_due(e, spider_fire_every)) return;
    const c = e.center();
    const mid: i32 = 128 + @as(i32, @intFromFloat(spider_sweep * sin256(e.ring_phase)));
    e.ring_phase +%= spider_sweep_step;
    const n: i32 = spider_arc_n + if (e.pattern == 1) @as(i32, 2) else 0;
    const shot: bullets.Shot = if (e.pattern == 1)
        .{ .speed = spider_shot_speed + 0.2, .shape = .pellet, .source = .spider }
    else
        .{ .speed = spider_shot_speed, .source = .spider };
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        patterns.at_angle(c[0], c[1], mid + @divTrunc((2 * i - (n - 1)) * spider_arc_step, 2), shot);
    }
}

/// New random target every 30 ticks, fly at it; after 600 ticks on screen
/// the targets move to x = -40 so it leaves. Pattern 0: aimed needle
/// pairs every 40 ticks from 16 ticks after it appears; pattern 1: a ring
/// of 6 stop-and-go pellets that brake, then re-aim at the ship.
fn update_moth(e: *Enemy) void {
    if (e.age % moth_retarget_every == 0) {
        const tx = rng.range(moth_min_x, moth_max_x);
        const ty = rng.range(moth_min_y, moth_max_y);
        e.target_x = @floatFromInt(tx);
        e.target_y = @floatFromInt(ty);
    }
    // Leaving: the x draw is still made (so the rng order does not depend
    // on it) but overridden.
    if (e.timer >= moth_stay) e.target_x = moth_exit_x;
    const dx = e.target_x - e.x;
    const dy = e.target_y - e.y;
    const d = @sqrt(dx * dx + dy * dy);
    if (d > moth_speed) {
        e.x += dx / d * moth_speed;
        e.y += dy / d * moth_speed;
    }
    if (e.entered) e.timer += 1;
    if (e.timer >= moth_stay) return;
    if (!fire_due(e, if (e.pattern == 1) moth_sg_every else moth_fire_every)) return;
    const c = e.center();
    if (e.pattern == 1) {
        patterns.ring_aimed(c[0], c[1], moth_sg_n, .{
            .speed = moth_sg_speed,
            .shape = .pellet,
            .source = .moth,
            .drag = moth_sg_drag,
            .event = .aim,
            .event_at = moth_sg_aim_at,
            .ev_n = 1,
            .ev_speed = moth_sg_aim_speed,
        });
    } else {
        patterns.fan(c[0], c[1], 2, moth_pair_step, .{ .speed = moth_needle_speed, .shape = .needle, .source = .moth });
    }
}

/// One weaving path for the whole chain: each part runs it from its own
/// appearance, `k * delay` ticks behind the head. The ripple: every part
/// fires on its own countdown, staggered so the volley runs down the body.
/// Pattern 0: aimed pellets; 1: a wider weave and aimed 3-fans; 2: aimed
/// pellets and the head fires a 10-ring instead.
fn update_centipede(e: *Enemy) void {
    const amp = if (e.pattern == 1) centipede_amplitude_wide else centipede_amplitude;
    e.x = e.target_x - centipede_speed * @as(f32, @floatFromInt(e.age));
    e.y = e.base_y + amp * sin256((e.age % centipede_period) * 256 / centipede_period);
    if (!fire_due(e, centipede_fire_every)) return;
    const c = e.center();
    const shot: bullets.Shot = .{ .speed = centipede_shot_speed, .shape = .pellet, .source = .centipede };
    switch (e.pattern) {
        1 => patterns.fan(c[0], c[1], 3, 12, shot),
        2 => if (e.variant == 0)
            patterns.ring_aimed(c[0], c[1], centipede_ring_n, .{ .speed = 0.8, .source = .centipede })
        else
            patterns.aimed(c[0], c[1], shot),
        else => patterns.aimed(c[0], c[1], shot),
    }
}

/// Behind its 30-tick warning chevron at the left edge, then jumps in
/// from behind the ship and keeps jumping right under gravity; at each
/// apex it fires (pattern 0: an aimed 3-fan; 1: higher jumps and an
/// 8-ring; 2: an aimed sniper line of 3 needles).
fn update_flea(e: *Enemy) void {
    switch (e.phase) {
        .warn => {
            e.timer += 1;
            if (e.timer >= flea_warn) {
                e.phase = .jump;
                e.vx = flea_vx;
                e.vy = flea_entry_vy;
            }
        },
        .jump => {
            const before = e.vy;
            e.vy += flea_gravity;
            e.x += e.vx;
            e.y += e.vy;
            if (before < 0 and e.vy >= 0) flea_fire(e);
            if (e.vy > 0 and e.y >= flea_ground) {
                e.y = flea_ground;
                e.phase = .land;
                e.timer = 0;
            }
        },
        else => {
            e.timer += 1;
            if (e.timer >= flea_land) {
                e.phase = .jump;
                e.vy = if (e.pattern == 1) flea_jump_vy_high else flea_jump_vy;
            }
        },
    }
}

fn flea_fire(e: *Enemy) void {
    const c = e.center();
    if (!in_field(c) or near_ship(c)) return;
    const shot: bullets.Shot = .{ .speed = flea_shot_speed, .shape = .pellet, .source = .flea };
    switch (e.pattern) {
        1 => patterns.ring(c[0], c[1], flea_ring_n, @intCast(e.age % 256), shot),
        2 => patterns.line(c[0], c[1], 3, 0.25, .{ .speed = flea_shot_speed, .shape = .needle, .source = .flea }),
        else => patterns.fan(c[0], c[1], 3, flea_fan_step, shot),
    }
}

/// Straight in from the top (or bottom) edge drifting left with the
/// scroll, a loop of radius 18 (pattern 1: two), straight out the far
/// edge. A ring of 8 at the top of each loop (pattern 2: 10, plus an
/// aimed pellet as the loop starts).
fn update_ladybug(e: *Enemy) void {
    const s: f32 = if (e.edge == .bottom) -1 else 1;
    switch (e.phase) {
        .loop => {
            e.target_x -= ladybug_drift;
            e.timer += 1;
            const a = e.timer * ladybug_turn;
            const cx = e.target_x + ladybug_radius * sin256(a + 64);
            const cy = e.target_y + s * ladybug_radius * sin256(a);
            e.x = cx - 8;
            e.y = cy - 8;
            // The top of the loop: angle 192 going down, 64 going up.
            const top: u32 = if (s > 0) 192 else 64;
            if (a % 256 == top) {
                const c = e.center();
                if (in_field(c) and !near_ship(c)) {
                    const n: u32 = if (e.pattern == 2) ladybug_ring_n + 2 else ladybug_ring_n;
                    patterns.ring(c[0], c[1], n + rank.extra(2), @intCast(e.age % 32), .{ .speed = ladybug_shot_speed, .shape = .pellet, .source = .ladybug });
                }
            }
            const loops: u32 = if (e.pattern == 1) 2 else 1;
            if (a >= 256 * loops) e.phase = .leave;
        },
        else => {
            e.x -= ladybug_drift;
            e.y += s * ladybug_speed;
            const cy = e.y + 8;
            const loop_y = if (s > 0) ladybug_loop_top else ladybug_loop_bottom;
            if (e.phase == .enter and ((s > 0 and cy >= loop_y) or (s < 0 and cy <= loop_y))) {
                e.phase = .loop;
                e.timer = 0;
                e.target_x = e.x + 8 - ladybug_radius;
                e.target_y = cy;
                if (e.pattern == 2) {
                    const c = e.center();
                    if (in_field(c) and !near_ship(c)) patterns.aimed(c[0], c[1], .{ .speed = 1.2, .shape = .pellet, .source = .ladybug });
                }
            }
        },
    }
}

/// The near layer's scroll position as `draw.draw_near` will use it on
/// the frame after this tick (`draw.tick_bg` runs after the enemies).
fn ground_steps() u32 {
    return (world.w.bg.tick +% 1) / 2;
}

/// Screen y of the near layer's top edge at screen column `sx`.
fn ground_top(sx: i32) f32 {
    const sheet = gfx.bg_near;
    const col: u32 = @intCast(@mod(sx + @as(i32, @intCast(ground_steps() % sheet.width)), sheet.width));
    var row: u32 = 0;
    while (row < sheet.height) : (row += 1) {
        if (sheet.indices.get(row * sheet.width + col) != 0) break;
    }
    return @floatFromInt(draw.near_y + @as(i32, @intCast(row)));
}

/// The mite's cell y standing at cell x `x`: feet (cell row 14) on the
/// lower of the layer's tops under its two feet, so a narrow mast does
/// not lift it.
fn ground_cell_y(x: f32) f32 {
    const ix: i32 = @intFromFloat(@floor(x));
    return @max(ground_top(ix + 4), ground_top(ix + 12)) - 15;
}

/// Rides the near layer at exactly its scroll speed, stepping up and down
/// with its top edge (1 px per tick). Aimed needle bursts (pattern 0: 3,
/// 1: 4, 6 ticks apart) from the muzzle, and a fan of 5 (7) pellets up
/// and to the left.
fn update_mite(e: *Enemy) void {
    e.x = e.target_x - @as(f32, @floatFromInt(ground_steps() -% e.timer));
    const gy = ground_cell_y(e.x);
    if (e.y < gy) e.y = @min(e.y + 1, gy) else if (e.y > gy) e.y = @max(e.y - 1, gy);
    const m: [2]f32 = .{ e.x + mite_muzzle[0], e.y + mite_muzzle[1] };
    if (countdown(&e.aux, m, mite_burst_every)) e.ring_phase = if (e.pattern == 1) 4 else 3;
    if (e.ring_phase > 0) {
        if (e.spiral_angle > 0) {
            e.spiral_angle -= 1;
        } else {
            e.ring_phase -= 1;
            e.spiral_angle = mite_burst_gap - 1;
            if (in_field(m) and !near_ship(m)) patterns.aimed(m[0], m[1], .{ .speed = mite_needle_speed, .shape = .needle, .source = .mite });
        }
    }
    if (countdown(&e.fire_tick, m, mite_fan_every)) {
        const n: i32 = if (e.pattern == 1) 7 else 5;
        var i: i32 = 0;
        while (i < n) : (i += 1) {
            patterns.at_angle(m[0], m[1], mite_fan_angle + @divTrunc((2 * i - (n - 1)) * mite_fan_step, 2), .{ .speed = mite_fan_speed, .shape = .pellet, .source = .mite });
        }
    }
}

/// Lumbers left on a slow sine firing aimed fans (pattern 0: 3 rounds,
/// 1: 5 pellets). Its first death leaves a husk (`damage`): not
/// collidable, drifting with the scroll; 90 ticks later it revives with
/// half its HP and a 12-ring (`variant` 1 = revived, the next death is
/// final).
fn update_zombie(e: *Enemy) void {
    if (e.phase == .husk) {
        e.x -= zombie_husk_drift;
        e.timer += 1;
        if (e.timer < zombie_husk) return;
        e.phase = .enter;
        e.variant = 1;
        e.hp = @max(1, rank.hp(base_hp(.zombie, 0, e.pattern)) / 2);
        e.flash = 4;
        e.aux = zombie_first;
        const c = e.center();
        if (in_field(c) and !near_ship(c)) patterns.ring(c[0], c[1], zombie_ring_n, @intCast(e.age % 21), .{ .speed = zombie_ring_speed, .shape = .pellet, .source = .zombie });
        return;
    }
    e.x -= zombie_speed;
    e.timer += 1;
    e.y = e.base_y + zombie_amplitude * sin256((e.timer % zombie_period) * 256 / zombie_period);
    if (!fire_due(e, zombie_fire_every)) return;
    const c = e.center();
    if (e.pattern == 1) {
        patterns.fan(c[0], c[1], 5, 10, .{ .speed = zombie_shot_speed + 0.1, .shape = .pellet, .source = .zombie });
    } else {
        patterns.fan(c[0], c[1], 3, zombie_fan_step, .{ .speed = zombie_shot_speed, .source = .zombie });
    }
}

/// The midboss: in to x 112, then holds and bobs for 25 s, releasing a
/// gnat string from her egg row every 120 ticks and firing flowers; then
/// leaves to the right (no crates). Version `pattern` 0..2 (stages 2..4):
/// 0 flowers of 10 + 10; 1 every third flower's slow ring is stop-and-go
/// and the strings fire; 2 flowers of 12 + 12, aimed needle lines, wide
/// strings.
fn update_herd(e: *Enemy) void {
    const v: u8 = @min(e.pattern, 2);
    switch (e.phase) {
        .enter => {
            e.x -= herd_speed;
            if (e.x <= herd_hold_x) {
                e.x = herd_hold_x;
                e.phase = .hold;
                e.timer = 0;
            }
            return;
        },
        .hold => {
            e.timer += 1;
            e.y = e.base_y + herd_bob * sin256((e.timer % herd_bob_period) * 256 / herd_bob_period);
            if (e.timer >= herd_stay) e.phase = .leave;
        },
        else => {
            e.x += herd_leave_speed;
            return;
        },
    }
    const c = e.center();
    if (countdown(&e.fire_tick, c, herd_string_every)) {
        spawn_gnat_string_ex(e.x + herd_eggs[0], e.y + herd_eggs[1] - 4, 0, v + 1);
    }
    if (fire_due(e, herd_flower_every[v])) {
        const n = herd_flower_n[v] + rank.extra(2);
        const ph: i32 = e.ring_phase;
        patterns.ring(c[0], c[1], n, ph, .{ .speed = herd_fast_speed, .shape = .pellet, .source = .herd });
        const half: i32 = @intCast(128 / n);
        const stop_go = v >= 1 and e.ring_phase % 3 == 0;
        patterns.ring(c[0], c[1], n, ph + half, .{
            .speed = herd_slow_speed,
            .source = .herd,
            .drag = if (stop_go) 0.95 else 1,
            .event = if (stop_go) .aim else .none,
            .event_at = if (stop_go) 45 else 0,
            .ev_n = 1,
            .ev_speed = 20,
        });
        e.ring_phase +%= herd_flower_turn;
    }
    if (v == 2) {
        if (e.spiral_angle > 0) {
            e.spiral_angle -= 1;
        } else if (!near_ship(c)) {
            e.spiral_angle = @intCast(reload(herd_line_every) - 1);
            patterns.line(c[0], c[1], herd_line_n, 0.3, .{ .speed = 1.2, .shape = .needle, .source = .herd });
        }
    }
}

pub fn draw_enemies() void {
    for (&world.w.enemies) |*e| {
        if (e.live()) draw_enemy(e.*, .{});
    }
}

/// One enemy with its thread (also redrawn in flash-white by the bug
/// report). `opts` is merged with the enemy's own hit flash and the boss
/// flicker ghost.
pub fn draw_enemy(e: Enemy, opts: draw.SpriteOpts) void {
    const x: i32 = @intFromFloat(@floor(e.x));
    const y: i32 = @intFromFloat(@floor(e.y));
    // Big bugs under constant fire would stay white: they flash on the
    // first tick of a hit only.
    const flash = if (e.kind == .herd) e.flash == 2 else e.flash > 0;
    const own: draw.SpriteOpts = .{ .flash_white = opts.flash_white or flash, .skip_odd = opts.skip_odd };
    const frame = (e.age / bug_frame_ticks) % 2;
    switch (e.kind) {
        .gnat => draw.draw_sprite(gfx.bugs_small, 8, 8, (e.age / 4) % 2, x, y, own),
        .wasp => draw.draw_sprite(gfx.bugs, 16, 16, 0 + frame, x, y, own),
        .beetle => draw.draw_sprite(gfx.bugs, 16, 16, 2 + frame, x, y, own),
        .spider => {
            if (y > thread_top) {
                cart.vline(.{ .x = x + 8, .y = thread_top, .len = @intCast(y - thread_top), .color = draw.star_dim });
            }
            draw.draw_sprite(gfx.bugs, 16, 16, 4 + frame, x, y, own);
        },
        .moth => draw.draw_sprite(gfx.bugs, 16, 16, 6 + frame, x, y, own),
        // Head cells 0-1; segments alternate cells 2 and 3 along the chain
        // so the legs ripple.
        .centipede => {
            const cell: u32 = if (e.variant == 0) frame else 2 + (e.ring_phase + (e.age / 8)) % 2;
            draw.draw_sprite(gfx.bugs2, 16, 16, cell, x, y, own);
        },
        .flea => switch (e.phase) {
            // The warning: a blinking chevron at the left edge, on the
            // flea's line.
            .warn => if ((e.timer / 4) % 2 == 0) draw.text(">", 0, y + 4, if (own.flash_white) draw.anti_white else draw.coral),
            .jump => draw.draw_sprite(gfx.bugs2, 16, 16, 5, x, y, own),
            else => draw.draw_sprite(gfx.bugs2, 16, 16, 4, x, y, own),
        },
        .ladybug => draw.draw_sprite(gfx.bugs2, 16, 16, 6 + (e.age / 4) % 2, x, y, own),
        .mite => draw.draw_sprite(gfx.bugs2, 16, 16, 8 + (e.age / 8) % 2, x, y, own),
        .zombie => if (e.phase == .husk)
            draw.draw_sprite(gfx.bugs2, 16, 16, 10, x, y, .{ .flash_white = opts.flash_white, .skip_odd = true })
        else
            draw.draw_sprite(gfx.bugs2, 16, 16, 10 + frame, x, y, own),
        .herd => draw.draw_sprite(gfx.herd, 32, 32, (e.age / 8) % 2, x, y, own),
        .boss => bosses.draw_boss(e, x, y, opts, own),
    }
}

/// The kill hook for regular kinds (`damage` at 0 HP). A zombie's first
/// death is not one: it becomes a husk (an explosion and half its points)
/// and `damage` reports it alive. The midboss's death cancels every enemy
/// bullet and drops two crates; `collide.kill` then scores its 1,000.
fn regular_death(e: *Enemy) DamageResult {
    const c = e.center();
    switch (e.kind) {
        .zombie => if (e.variant == 0) {
            e.phase = .husk;
            e.timer = 0;
            e.hp = 1;
            fx.spawn(.explosion, @intFromFloat(@floor(c[0])), @intFromFloat(@floor(c[1])));
            player.add_score(e.points() / 2);
            return .alive;
        },
        .herd => {
            _ = bullets.cancel_all();
            pickups.spawn_drop(c[0], c[1] - 10);
            pickups.spawn_drop(c[0], c[1] + 10);
            fx.spawn(.big_explosion, @intFromFloat(@floor(c[0])), @intFromFloat(@floor(c[1])));
        },
        else => {},
    }
    return .killed;
}

pub const DamageResult = enum(u8) { alive, killed, boss_dying };

/// Applies `amount` HP of damage. `.killed`: the caller runs collide.kill
/// (explosion, score, deactivate). `.boss_dying`: the boss has started (or
/// is already in) its death sequence, which does its own explosions, score
/// and stage clear; the caller does nothing more. Damage is applied whatever
/// the boss phase (bolts are gated by `hittable`).
pub fn damage(e: *Enemy, amount: u16) DamageResult {
    if (e.kind == .boss) return bosses.damage(e, amount);
    e.hp -|= amount;
    if (e.hp > 0) return .alive;
    if (e.kind != .boss) return regular_death(e);
    e.phase = .dying;
    e.timer = 0;
    e.flash = 0;
    return .boss_dying;
}

/// The boss while active (entering, fighting, teleporting, dying or
/// escaping): the real body, never the Schrodinbug's phantom.
pub fn boss() ?*Enemy {
    for (&world.w.enemies) |*e| {
        if (e.active and e.kind == .boss and !bosses.is_phantom(e.*)) return e;
    }
    return null;
}

pub fn live_count() u32 {
    var n: u32 = 0;
    for (&world.w.enemies) |*e| n += @intFromBool(e.live());
    return n;
}
