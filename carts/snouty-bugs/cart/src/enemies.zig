//! Enemy pool (`world.w.enemies`) and the per-kind movement and fire
//! programs (SPEC.md sections 6 and 7, PLAN.md "Gameplay numbers for M2"
//! and "for M3"). Every program is plain data in `Enemy`; the only
//! randomness is the world rng, drawn in `spawn` (spider hang y) and in
//! `update` (moth targets, boss teleport and death explosions, in pool
//! order), so the rng call order per tick is deterministic. Fire programs
//! scale their intervals by rank at fire time (`rank.interval`); bullet
//! speeds are base speeds that `bullets.spawn_shot` scales; regular enemy
//! HP is scaled by rank at spawn (PLAN.md M7).
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
const rank = @import("rank.zig");
const formations = @import("formations.zig");

/// The bugs (PLAN.md M7 "Kinds"). centipede .. herd are defined by track
/// A with placeholder behaviour (fly left) and art; track B1 fills them.
pub const Kind = enum(u8) { gnat, wasp, beetle, spider, moth, boss, centipede, flea, ladybug, mite, zombie, herd };

/// `Enemy.variant` of a `.boss` (defined in the pure `boss_hp.zig`).
pub const BossId = boss_hp.BossId;

/// Where an enemy is in its movement program. Which values a kind uses:
/// wasp enter/pause/charge, beetle enter/sit/leave, spider drop/hang/climb,
/// moth wander, boss enter/fight/flicker/vanished/dying, gnat none.
pub const Phase = enum(u8) { enter, pause, charge, sit, leave, drop, hang, climb, wander, fight, flicker, vanished, dying };

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
    /// Free per-kind state for track B.
    aux: u32 = 0,
    aux2: f32 = 0,

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
            .boss => .{ 48, 48 },
        };
    }

    pub fn points(e: Enemy) u32 {
        return switch (e.kind) {
            .gnat => 10,
            .wasp => 30,
            .beetle => 50,
            .spider, .moth => 40,
            .boss => 500,
            // Placeholders until track B1 (PLAN.md M7).
            .centipede, .flea => 30,
            .ladybug => 40,
            .zombie => 50,
            .mite => 60,
            .herd => 1000,
        };
    }

    /// Whether player shots can hit it: false while the boss flickers, is
    /// vanished or is dying.
    pub fn hittable(e: Enemy) bool {
        if (e.kind != .boss) return true;
        return switch (e.phase) {
            .flicker, .vanished, .dying => false,
            else => true,
        };
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

const gnat_speed: f32 = 1.0;
const gnat_amplitude: f32 = 8.0;
const gnat_period: u32 = 40;
const string_len = 5;
const string_spacing = 12;

const wasp_speed: f32 = 2.5;
const wasp_stop_x: f32 = 120;
const wasp_pause: u32 = 20;

const beetle_hp = 4;
const beetle_speed: f32 = 0.5;
const beetle_stop_x: f32 = 112;
const beetle_sit: u32 = 240;
const beetle_fire_every: u32 = 45;
const beetle_spread_n = 3;
const beetle_spread_step = 12;
const beetle_bullet_speed: f32 = 1.0;

const spider_hp = 2;
const spider_speed: f32 = 1.5;
const spider_start_y: f32 = -16;
const spider_hang_min = 24;
const spider_hang_max = 72;
const spider_hang: u32 = 180;
const spider_fire_every: u32 = 30;
const spider_arc_n = 5;
const spider_arc_span = 96;
const spider_bullet_speed: f32 = 0.8;
/// The thread hangs from just under the HUD.
const thread_top: i32 = 8;

const moth_hp = 2;
const moth_speed: f32 = 1.2;
const moth_retarget_every: u32 = 30;
const moth_min_x = 80;
const moth_max_x = 144;
const moth_min_y = 16;
const moth_max_y = 104;
const moth_stay: u32 = 600;
const moth_exit_x: f32 = -40;
const moth_fire_every: u32 = 20;
const moth_bullet_speed: f32 = 1.5;

// Boss (SPEC.md section 7, PLAN.md "Gameplay numbers for M3"); its HP is in boss_hp.zig.
const boss_speed: f32 = 1.0;
const boss_stop_x: f32 = 104;
const boss_bob_amplitude: f32 = 32;
const boss_bob_period: u32 = 240;
const boss_min_y: f32 = 8;
const boss_max_y: f32 = 80;
const boss_teleport_every: u32 = 300;
const boss_flicker: u32 = 20;
const boss_vanish: u32 = 20;
const boss_min_x = 96;
const boss_max_x = 112;
const boss_min_base_y = 24;
const boss_max_base_y = 56;
const boss_fire_phase_len: u32 = 240;
const boss_fire_phases = 3;
const boss_ring_n = 12;
const boss_ring_every: u32 = 40;
const boss_ring_step: u8 = 11;
const boss_ring_speed: f32 = 0.8;
const boss_stream_every: u32 = 60;
const boss_stream_n = 3;
const boss_stream_gap: u32 = 8;
const boss_stream_speed: f32 = 1.5;
const boss_spread_every: u32 = 90;
const boss_spread_n = 5;
const boss_spread_step = 12;
const boss_spread_speed: f32 = 0.6;
const boss_spiral_every: u32 = 4;
const boss_spiral_step: u8 = 8;
const boss_spiral_speed: f32 = 1.0;
const boss_dying: u32 = 60;
const boss_blast_every: u32 = 10;
/// Small death explosions are centered this far inside the 48x48 cell.
const boss_blast_margin = 8;
const boss_frame_ticks = 6;
const boss_idle_frames = 4;
const boss_flicker_cell = 4;

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
fn base_hp(kind: Kind) u16 {
    return switch (kind) {
        .gnat, .wasp => 1,
        .beetle => beetle_hp,
        .spider => spider_hp,
        .moth => moth_hp,
        // Placeholders until track B1.
        .centipede, .flea, .ladybug, .mite, .zombie => 2,
        .herd => 30,
        .boss => 1,
    };
}

/// HP of the active boss `b` at full health (its id, this loop); the spawn
/// and the HUD bar share it.
pub fn boss_max_hp_of(b: Enemy) u32 {
    return boss_hp.max_hp(@enumFromInt(b.variant), world.w.waves.loop);
}

/// Spawns one enemy of `kind` with its cell top-left at (x, y), appearing
/// after `delay` ticks. Spider: `y` is ignored, `x` is its column; it
/// starts at y -16 and draws its hang y from the world rng here. Returns
/// null when the pool is full.
pub fn spawn(kind: Kind, x: f32, y: f32, delay: u32) ?*Enemy {
    const e = alloc() orelse return null;
    e.* = .{
        .active = true,
        .kind = kind,
        .delay = delay,
        .x = x,
        .y = y,
        .base_y = y,
    };
    if (kind == .boss) {
        // The current stage's boss, HP by id and loop (not ranked).
        e.variant = @backingInt(boss_hp.for_stage(world.w.waves.stage));
        e.hp = @intCast(boss_max_hp_of(e.*));
    } else {
        e.hp = rank.hp(base_hp(kind));
    }
    switch (kind) {
        .spider => {
            e.y = spider_start_y;
            e.base_y = spider_start_y;
            e.phase = .drop;
            e.target_y = @floatFromInt(rng.range(spider_hang_min, spider_hang_max));
        },
        .moth => e.phase = .wander,
        else => {},
    }
    return e;
}

/// Spawns a string of 5 gnats at spawn x, wobbling around `y`, 12 ticks
/// apart, as one formation (`drop`: shooting all five drops a crate,
/// PLAN.md M7). Gnats that do not fit in the pool count as lost, so the
/// formation still frees its slot.
pub fn spawn_gnat_string(y: f32, drop: bool) void {
    const id = formations.open(string_len, drop);
    for (0..string_len) |i| {
        const e = spawn(.gnat, gnat_spawn_x, y, @intCast(i * string_spacing)) orelse {
            formations.lost(id);
            continue;
        };
        e.formation = id;
    }
}

fn on_screen(e: *const Enemy) bool {
    const s = e.size();
    return e.x < @as(f32, cart.screen_width) and e.x + s[0] > 0 and
        e.y < @as(f32, cart.screen_height) and e.y + s[1] > 0;
}

fn off_field(e: *const Enemy) bool {
    return e.x < cull_min or e.x > cull_max_x or e.y < cull_min or e.y > cull_max_y;
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
            .boss => update_boss(e),
            .centipede, .flea, .ladybug, .mite, .zombie, .herd => update_placeholder(e),
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

/// Track A's placeholder for the M7 kinds until track B1 writes them:
/// straight left at 1 px per tick, no fire.
fn update_placeholder(e: *Enemy) void {
    e.x -= placeholder_speed;
}
const placeholder_speed: f32 = 1.0;

/// M1 behaviour: straight left with a sine wobble, gone at x < -8.
fn update_gnat(e: *Enemy) void {
    e.x -= gnat_speed;
    const phase = (e.age % gnat_period) * 256 / gnat_period;
    e.y = e.base_y + gnat_amplitude * sin_table[phase];
    if (e.x < -8.0) e.active = false;
}

/// Enter fast, pause 20 ticks at x <= 120, then charge at where the ship
/// was on the last pause tick.
fn update_wasp(e: *Enemy) void {
    switch (e.phase) {
        .enter => {
            e.x -= wasp_speed;
            if (e.x <= wasp_stop_x) {
                e.phase = .pause;
                e.timer = 0;
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

/// Crawl in to x = 112, sit 240 ticks firing a 3-way spread every 45, leave.
fn update_beetle(e: *Enemy) void {
    switch (e.phase) {
        .enter => {
            e.x -= beetle_speed;
            if (e.x <= beetle_stop_x) {
                e.x = beetle_stop_x;
                e.phase = .sit;
                e.timer = 0;
            }
        },
        .sit => {
            e.timer += 1;
            if (e.timer % rank.interval(beetle_fire_every) == 0) {
                const c = e.center();
                patterns.fan(c[0], c[1], beetle_spread_n, beetle_spread_step, .{ .speed = beetle_bullet_speed, .source = .beetle });
            }
            if (e.timer >= beetle_sit) {
                e.phase = .leave;
                e.timer = 0;
            }
        },
        else => e.x -= beetle_speed,
    }
}

/// Drop to the hang y, hang 180 ticks firing a 5-way arc every 30, climb.
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
            if (e.timer % rank.interval(spider_fire_every) == 0) {
                const c = e.center();
                patterns.arc(c[0], c[1], spider_arc_n, spider_arc_span, .{ .speed = spider_bullet_speed, .source = .spider });
            }
            if (e.timer >= spider_hang) {
                e.phase = .climb;
                e.timer = 0;
            }
        },
        else => e.y -= spider_speed,
    }
}

/// New random target every 30 ticks, fly at it, aimed needle every 20
/// ticks once on screen; after 600 ticks on screen the targets move to
/// x = -40 so it leaves.
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
    if (e.entered) {
        e.timer += 1;
        if (e.age % rank.interval(moth_fire_every) == 0 and e.age > 0) {
            const c = e.center();
            patterns.aimed(c[0], c[1], .{ .speed = moth_bullet_speed, .shape = .needle, .source = .moth });
        }
    }
}

/// Enter to x 104, then fight: bob on the sine table, fire, and every 300
/// fighting ticks teleport (flicker 20, vanished 20, reappear at a random
/// x and bob line). Dying: 60 ticks of small explosions, then the big one.
fn update_boss(e: *Enemy) void {
    switch (e.phase) {
        .enter => {
            e.x -= boss_speed;
            if (e.x <= boss_stop_x) {
                e.x = boss_stop_x;
                e.phase = .fight;
                e.timer = 0;
            }
        },
        .fight => {
            const i = (e.timer % boss_bob_period) * 256 / boss_bob_period;
            const y = e.base_y + boss_bob_amplitude * sin_table[i];
            e.y = @min(@max(y, boss_min_y), boss_max_y);
            // Each change of fire phase drops a crate (PLAN.md M6).
            if (e.fire_tick > 0 and e.fire_tick % boss_fire_phase_len == 0) {
                const c = e.center();
                pickups.spawn_drop(c[0], c[1]);
            }
            boss_fire(e);
            e.fire_tick += 1;
            e.timer += 1;
            if (e.timer >= boss_teleport_every) {
                e.phase = .flicker;
                e.timer = 0;
            }
        },
        .flicker => {
            e.timer += 1;
            if (e.timer >= boss_flicker) {
                e.phase = .vanished;
                e.timer = 0;
            }
        },
        .vanished => {
            e.timer += 1;
            if (e.timer >= boss_vanish) {
                e.x = @floatFromInt(rng.range(boss_min_x, boss_max_x));
                e.base_y = @floatFromInt(rng.range(boss_min_base_y, boss_max_base_y));
                e.y = e.base_y;
                e.phase = .fight;
                e.timer = 0;
            }
        },
        .dying => {
            if (e.timer >= boss_dying) {
                const c = e.center();
                fx.spawn(.big_explosion, @intFromFloat(@floor(c[0])), @intFromFloat(@floor(c[1])));
                player.add_score(e.points());
                e.active = false;
                waves.boss_cleared();
                return;
            }
            if (e.timer % boss_blast_every == 0) {
                const ox = rng.range(boss_blast_margin, 48 - boss_blast_margin);
                const oy = rng.range(boss_blast_margin, 48 - boss_blast_margin);
                const bx: i32 = @intFromFloat(@floor(e.x));
                const by: i32 = @intFromFloat(@floor(e.y));
                fx.spawn(.explosion, bx + ox, by + oy);
                e.flash = 2;
            }
            e.timer += 1;
        },
        else => {},
    }
}

/// The three fire phases, 240 fighting ticks each, cycling.
fn boss_fire(e: *Enemy) void {
    const c = e.center();
    const local = e.fire_tick % boss_fire_phase_len;
    switch ((e.fire_tick / boss_fire_phase_len) % boss_fire_phases) {
        0 => if (local % rank.interval(boss_ring_every) == 0) {
            patterns.ring(c[0], c[1], boss_ring_n, e.ring_phase, .{ .speed = boss_ring_speed, .source = .boss });
            e.ring_phase +%= boss_ring_step;
        },
        1 => {
            const k = local % rank.interval(boss_stream_every);
            if (k % boss_stream_gap == 0 and k / boss_stream_gap < boss_stream_n) {
                patterns.aimed(c[0], c[1], .{ .speed = boss_stream_speed, .shape = .needle, .source = .boss });
            }
            if (local % rank.interval(boss_spread_every) == 0) {
                patterns.fan(c[0], c[1], boss_spread_n, boss_spread_step, .{ .speed = boss_spread_speed, .source = .boss });
            }
        },
        else => if (local % rank.interval(boss_spiral_every) == 0) {
            patterns.at_angle(c[0], c[1], e.spiral_angle, .{ .speed = boss_spiral_speed, .source = .boss });
            e.spiral_angle +%= boss_spiral_step;
        },
    }
}

pub fn draw_enemies() void {
    for (world.w.enemies) |e| {
        if (e.live()) draw_enemy(e, .{});
    }
}

/// One enemy with its thread (also redrawn in flash-white by the bug
/// report). `opts` is merged with the enemy's own hit flash and the boss
/// flicker ghost.
pub fn draw_enemy(e: Enemy, opts: draw.SpriteOpts) void {
    const x: i32 = @intFromFloat(@floor(e.x));
    const y: i32 = @intFromFloat(@floor(e.y));
    const own: draw.SpriteOpts = .{ .flash_white = opts.flash_white or e.flash > 0, .skip_odd = opts.skip_odd };
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
        // Placeholders until track C's bugs2.png / herd.png and track B1.
        .centipede, .flea, .ladybug, .mite, .zombie => draw.draw_sprite(gfx.bugs, 16, 16, 0 + frame, x, y, own),
        .herd => for (0..2) |row| for (0..2) |col| {
            draw.draw_sprite(gfx.bugs, 16, 16, 2 + frame, x + 16 * @as(i32, @intCast(col)), y + 16 * @as(i32, @intCast(row)), own);
        },
        .boss => switch (e.phase) {
            // The flicker ghost ignores the hit flash.
            .flicker => draw.draw_sprite(gfx.boss, 48, 48, boss_flicker_cell, x, y, .{ .flash_white = opts.flash_white, .skip_odd = true }),
            else => draw.draw_sprite(gfx.boss, 48, 48, (e.age / boss_frame_ticks) % boss_idle_frames, x, y, own),
        },
    }
}

pub const DamageResult = enum(u8) { alive, killed, boss_dying };

/// Applies `amount` HP of damage. `.killed`: the caller runs collide.kill
/// (explosion, score, deactivate). `.boss_dying`: the boss has started (or
/// is already in) its death sequence, which does its own explosions, score
/// and stage clear; the caller does nothing more. Damage is applied whatever
/// the boss phase (bolts are gated by `hittable`).
pub fn damage(e: *Enemy, amount: u16) DamageResult {
    if (e.kind == .boss and e.phase == .dying) return .boss_dying;
    e.hp -|= amount;
    if (e.hp > 0) return .alive;
    if (e.kind != .boss) return .killed;
    e.phase = .dying;
    e.timer = 0;
    e.flash = 0;
    return .boss_dying;
}

/// The boss while active (entering, fighting, teleporting or dying).
pub fn boss() ?*Enemy {
    for (&world.w.enemies) |*e| {
        if (e.active and e.kind == .boss) return e;
    }
    return null;
}

pub fn live_count() u32 {
    var n: u32 = 0;
    for (world.w.enemies) |e| n += @intFromBool(e.live());
    return n;
}
