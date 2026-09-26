//! Enemy pool (`world.w.enemies`) and the per-kind movement and fire
//! programs (SPEC.md section 6, PLAN.md "Gameplay numbers for M2"). Every
//! program is plain data in `Enemy`; the only randomness is the world rng,
//! drawn in `spawn` (spider hang y) and in `update` (moth targets, pool
//! order), so the rng call order per tick is deterministic.
const cart = @import("cart-api");
const gfx = @import("gfx");
const draw = @import("draw.zig");
const patterns = @import("patterns.zig");
const player = @import("player.zig");
const rng = @import("rng.zig");
const world = @import("world.zig");

/// `boss` is reserved for M3.
pub const Kind = enum(u8) { gnat, wasp, beetle, spider, moth, boss };

/// Where an enemy is in its movement program. Which values a kind uses:
/// wasp enter/pause/charge, beetle enter/sit/leave, spider drop/hang/climb,
/// moth wander, gnat none.
pub const Phase = enum(u8) { enter, pause, charge, sit, leave, drop, hang, climb, wander };

pub const Enemy = struct {
    active: bool = false,
    kind: Kind = .gnat,
    /// Ticks before the enemy appears (used to space out strings).
    delay: u32 = 0,
    /// Cell top-left.
    x: f32 = 0,
    y: f32 = 0,
    /// Gnat: wobble center line.
    base_y: f32 = 0,
    /// Ticks since it appeared (animation, gnat wobble, moth fire clock).
    age: u32 = 0,
    hp: u8 = 1,
    /// Ticks of white hit flash left.
    flash: u8 = 0,
    phase: Phase = .enter,
    /// Ticks spent in the current phase (moth: ticks since first on screen).
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

    /// Spawned and on the field (collidable, drawn).
    pub fn live(e: Enemy) bool {
        return e.active and e.delay == 0;
    }

    pub fn size(e: Enemy) [2]f32 {
        return switch (e.kind) {
            .gnat => .{ 8, 8 },
            .wasp, .beetle, .spider, .moth => .{ 16, 16 },
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
        };
    }

    /// Whether player shots can hit it (false while the boss flickers, M3).
    pub fn hittable(e: Enemy) bool {
        _ = e;
        return true;
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

fn start_hp(kind: Kind) u8 {
    return switch (kind) {
        .gnat, .wasp => 1,
        .beetle => beetle_hp,
        .spider => spider_hp,
        .moth => moth_hp,
        .boss => 60,
    };
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
        .hp = start_hp(kind),
    };
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

/// Spawns a string of 5 gnats at spawn x, wobbling around `y`, 12 ticks apart.
pub fn spawn_gnat_string(y: f32) void {
    for (0..string_len) |i| {
        _ = spawn(.gnat, gnat_spawn_x, y, @intCast(i * string_spacing)) orelse return;
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
            .boss => {},
        }
        e.age += 1;
        if (!e.active) continue;
        if (!e.entered) {
            e.entered = on_screen(e);
        } else if (off_field(e)) {
            e.active = false;
        }
    }
}

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
            if (e.timer % beetle_fire_every == 0) {
                const c = e.center();
                patterns.spread(c[0], c[1], beetle_spread_n, beetle_spread_step, beetle_bullet_speed, .round, .beetle);
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
            if (e.timer % spider_fire_every == 0) {
                const c = e.center();
                patterns.arc(c[0], c[1], spider_arc_n, spider_arc_span, spider_bullet_speed, .round, .spider);
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
        if (e.age % moth_fire_every == 0 and e.age > 0) {
            const c = e.center();
            patterns.aimed(c[0], c[1], moth_bullet_speed, .needle, .moth);
        }
    }
}

pub fn draw_enemies() void {
    for (world.w.enemies) |e| {
        if (!e.live()) continue;
        const x: i32 = @intFromFloat(@floor(e.x));
        const y: i32 = @intFromFloat(@floor(e.y));
        const opts: draw.SpriteOpts = .{ .flash_white = e.flash > 0 };
        const frame = (e.age / bug_frame_ticks) % 2;
        switch (e.kind) {
            .gnat => draw.draw_sprite(gfx.bugs_small, 8, 8, (e.age / 4) % 2, x, y, opts),
            .wasp => draw.draw_sprite(gfx.bugs, 16, 16, 0 + frame, x, y, opts),
            .beetle => draw.draw_sprite(gfx.bugs, 16, 16, 2 + frame, x, y, opts),
            .spider => {
                if (y > thread_top) {
                    cart.vline(.{ .x = x + 8, .y = thread_top, .len = @intCast(y - thread_top), .color = draw.star_dim });
                }
                draw.draw_sprite(gfx.bugs, 16, 16, 4 + frame, x, y, opts);
            },
            .moth => draw.draw_sprite(gfx.bugs, 16, 16, 6 + frame, x, y, opts),
            .boss => {},
        }
    }
}

pub fn live_count() u32 {
    var n: u32 = 0;
    for (world.w.enemies) |e| n += @intFromBool(e.live());
    return n;
}
