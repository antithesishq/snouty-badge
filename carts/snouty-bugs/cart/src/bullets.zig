//! Player bolts (`world.w.bolts`, 64: the fuzzer's zaps, the assert's
//! beams and the bisect's seekers, PLAN.md M6) and the enemy bullet pool
//! (`world.w.enemy_bullets`, 128) with the M7 pattern engine: bullets
//! that accelerate, brake, curve, split and re-aim. Enemy bullets are
//! spawned through `spawn_shot` (by the emitters in `patterns.zig`), scaled
//! by rank at spawn, and remember who fired them (`source`).
const cart = @import("cart-api");
const gfx = @import("gfx");
const draw = @import("draw.zig");
const world = @import("world.zig");
const enemies = @import("enemies.zig");
const fx = @import("fx.zig");
const patterns = @import("patterns.zig");
const player = @import("player.zig");
const rank = @import("rank.zig");

/// The zap (and seeker) cell in `bolt.png`.
pub const bolt_w = 16;
pub const bolt_h = 8;
/// The beam: 24 px long, its hitbox 24x4 (the drawn line is centered in it).
pub const beam_len = 24;
pub const beam_h = 4;
/// The seeker's 8x8 hitbox, centered in its 16x8 cell.
const seeker_box = 8;

pub const BoltKind = enum(u8) { zap, beam, seeker };

/// A player shot. (x, y) is the top-left of the zap or seeker's 16x8 cell
/// and of the beam's 24x4 box; (vx, vy) is its velocity in px per tick.
pub const Bolt = struct {
    active: bool = false,
    kind: BoltKind = .zap,
    damage: u8 = 1,
    x: f32 = 0,
    y: f32 = 0,
    vx: f32 = 0,
    vy: f32 = 0,
    /// Beam: the enemy slots it has already damaged (pierce, once each).
    hit_mask: u32 = 0,
    age: u32 = 0,
    /// Seeker: steering gain (0.08 + 0.04 per level above 1).
    gain: f32 = 0,
};

/// Enemy bullet shapes (PLAN.md M7 "Shapes and hitboxes"): round
/// (`bugs_small` cells 2-3), needle (`bugs` cell 8), pellet (`shots.png`
/// cells 0-1), orb (`orb.png` cells 0-1). The backing value indexes
/// `rank_math.speed_caps`.
pub const Shape = enum(u8) { round, needle, pellet, orb };

/// What a bullet does when its age reaches `event_at` (PLAN.md M7).
pub const Event = enum(u8) { none, split, aim };

pub const EnemyBullet = struct {
    active: bool = false,
    /// CENTER of the bullet.
    x: f32 = 0,
    y: f32 = 0,
    vx: f32 = 0,
    vy: f32 = 0,
    shape: Shape = .round,
    /// Who fired it (SPEC.md 5.1 messages, M4).
    source: enemies.Kind = .gnat,
    /// Set once the bullet has scored its graze point.
    grazed: bool = false,
    age: u32 = 0,
    // M7 pattern engine; the defaults fly straight as before.
    /// v *= drag every tick (< 1 slows, > 1 speeds up).
    drag: f32 = 1,
    /// If > 0, |v| is clamped to it after drag and accel.
    vmax: f32 = 0,
    /// Added to v every tick.
    ax: f32 = 0,
    ay: f32 = 0,
    /// The heading turns by turn / 256 of a turn every tick ...
    turn: i8 = 0,
    /// ... for this many ticks.
    turn_left: u8 = 0,
    event: Event = .none,
    /// The bullet's age at which the event fires.
    event_at: u16 = 0,
    /// split: children; aim: bullets in the aimed fan (1 = just re-aim).
    ev_n: u8 = 0,
    /// Child / re-aim base speed in 1/16 px per tick (rank-scaled when the
    /// event fires).
    ev_speed: u8 = 0,
    /// split: the children split again (same event_at, ev_n, ev_speed)
    /// while gen > 0.
    gen: u8 = 0,
};

/// One enemy shot as content describes it: base (rank 0) speed, and the
/// pattern-engine program. `bullets.spawn_shot` scales the speed by rank.
pub const Shot = struct {
    /// Base speed in px per tick, at rank 0.
    speed: f32,
    shape: Shape = .round,
    source: enemies.Kind,
    drag: f32 = 1,
    vmax: f32 = 0,
    /// Along the initial heading: ax, ay = dir * accel.
    accel: f32 = 0,
    turn: i8 = 0,
    turn_left: u8 = 0,
    event: Event = .none,
    event_at: u16 = 0,
    ev_n: u8 = 0,
    ev_speed: u8 = 0,
    gen: u8 = 0,
};

/// The enemy bullet pool size (PLAN.md M7: 96 -> 128).
pub const enemy_pool_len = 128;
/// Fan spacing of an `aim` event with `ev_n > 1`, in 1/256 turns.
const aim_fan_step: i32 = 8;
/// Bullets cancelled by `cancel_all` score this each.
const cancel_points: u32 = 10;
/// `cancel_all` sparks on the first this many bullets only.
const cancel_sparks: u32 = 8;

/// Returns false when the pool is full (the shot is dropped).
pub fn spawn_bolt(b: Bolt) bool {
    for (&world.w.bolts) |*slot| {
        if (slot.active) continue;
        slot.* = b;
        slot.active = true;
        return true;
    }
    return false;
}

/// Hitbox of a player bolt as (x, y, w, h): zap 16x8 (the whole cell),
/// beam 24x4, seeker 8x8 centered in its cell.
pub fn bolt_hitbox(b: Bolt) [4]f32 {
    return switch (b.kind) {
        .zap => .{ b.x, b.y, bolt_w, bolt_h },
        .beam => .{ b.x, b.y, beam_len, beam_h },
        .seeker => .{ b.x + (bolt_w - seeker_box) / 2, b.y, seeker_box, seeker_box },
    };
}

/// Drawn thickness of a beam: 1, 2 or 3 px for damage 1, 2, 3.
fn beam_thickness(b: Bolt) u32 {
    return @min(@max(b.damage, 1), beam_h - 1);
}

fn alloc_enemy_bullet() ?*EnemyBullet {
    for (&world.w.enemy_bullets) |*b| {
        if (!b.active) return b;
    }
    return null;
}

/// Spawns one enemy bullet centered at (x, y) moving along the unit vector
/// `dir` at `shot.speed` scaled by rank (`rank.bullet_speed`, capped per
/// shape). Returns the bullet, or null when the pool is full (the shot is
/// dropped). The pointer is only good until the next spawn or tick.
pub fn spawn_shot(x: f32, y: f32, dir: [2]f32, shot: Shot) ?*EnemyBullet {
    const b = alloc_enemy_bullet() orelse return null;
    const v = rank.bullet_speed(shot.speed, shot.shape);
    b.* = .{
        .active = true,
        .x = x,
        .y = y,
        .vx = dir[0] * v,
        .vy = dir[1] * v,
        .shape = shot.shape,
        .source = shot.source,
        .drag = shot.drag,
        .vmax = shot.vmax,
        .ax = dir[0] * shot.accel,
        .ay = dir[1] * shot.accel,
        .turn = shot.turn,
        .turn_left = shot.turn_left,
        .event = shot.event,
        .event_at = shot.event_at,
        .ev_n = shot.ev_n,
        .ev_speed = shot.ev_speed,
        .gen = shot.gen,
    };
    return b;
}

/// Removes every enemy bullet (a boss phase break, the midboss's death):
/// +10 points each, a spark on the first 8. Returns how many there were.
pub fn cancel_all() u32 {
    var n: u32 = 0;
    for (&world.w.enemy_bullets) |*b| {
        if (!b.active) continue;
        if (n < cancel_sparks) fx.spawn(.spark, @intFromFloat(@floor(b.x)), @intFromFloat(@floor(b.y)));
        b.active = false;
        n += 1;
    }
    player.add_score(cancel_points * n);
    return n;
}

pub fn live_enemy_bullets() u32 {
    var n: u32 = 0;
    for (world.w.enemy_bullets) |b| n += @intFromBool(b.active);
    return n;
}

/// Hitbox of an enemy bullet as (x, y, w, h), centered (PLAN.md M7, the
/// bullet-hell bargain): round 4x4, needle 6x2, pellet 2x2, orb 8x8.
pub fn hitbox(b: EnemyBullet) [4]f32 {
    return switch (b.shape) {
        .round => .{ b.x - 2, b.y - 2, 4, 4 },
        .needle => .{ b.x - 3, b.y - 1, 6, 2 },
        .pellet => .{ b.x - 1, b.y - 1, 2, 2 },
        .orb => .{ b.x - 4, b.y - 4, 8, 8 },
    };
}

/// Half the drawn size: how far past the field edge the center may go
/// before the bullet is culled.
fn cull_margin(shape: Shape) f32 {
    return if (shape == .orb) 8 else 4;
}

/// The center has left the field: x outside [-m, 160 + m), y outside
/// [8 - m, 128 + m) (m = 4, 8 for the orb; the M2 bounds for m = 4).
fn off_field(b: EnemyBullet) bool {
    const m = cull_margin(b.shape);
    return b.x < -m or b.x >= @as(f32, cart.screen_width) + m or
        b.y < @as(f32, draw.hud_height) - m or b.y >= @as(f32, cart.screen_height) + m;
}

/// Moves the player's bolts (seekers steer first) and culls those that
/// left the field: x >= 160, x < -24, y < -8 or y >= 136.
pub fn update() void {
    for (&world.w.bolts) |*b| {
        if (!b.active) continue;
        if (b.kind == .seeker) steer(b);
        b.x += b.vx;
        b.y += b.vy;
        b.age += 1;
        if (b.x >= @as(f32, cart.screen_width) or b.x < -24.0 or b.y < -8.0 or b.y >= 136.0) b.active = false;
    }
}

/// Seeker steering (PLAN.md M6): toward the nearest live, hittable enemy
/// center by squared distance (pool order breaks ties),
/// v_hat = normalize(v_hat + gain * t), v = v_hat * speed. No target:
/// straight on.
fn steer(b: *Bolt) void {
    const hb = bolt_hitbox(b.*);
    const sx = hb[0] + hb[2] / 2;
    const sy = hb[1] + hb[3] / 2;
    var best: f32 = 0;
    var tx: f32 = 0;
    var ty: f32 = 0;
    var found = false;
    for (world.w.enemies) |e| {
        if (!e.live() or !e.hittable()) continue;
        const c = e.center();
        const dx = c[0] - sx;
        const dy = c[1] - sy;
        const d2 = dx * dx + dy * dy;
        if (!found or d2 < best) {
            best = d2;
            tx = dx;
            ty = dy;
            found = true;
        }
    }
    if (!found or best == 0) return;
    const speed = @sqrt(b.vx * b.vx + b.vy * b.vy);
    if (speed == 0) return;
    const d = @sqrt(best);
    const nx = b.vx / speed + b.gain * tx / d;
    const ny = b.vy / speed + b.gain * ty / d;
    const n = @sqrt(nx * nx + ny * ny);
    if (n == 0) return;
    b.vx = nx / n * speed;
    b.vy = ny / n * speed;
}

/// One tick of every enemy bullet (PLAN.md M7), in order: turn, drag,
/// accel, vmax clamp, move, age, event (when age == event_at), cull. The
/// events run after the whole pool has moved, in pool order, so the
/// children and fan bullets they spawn do not move until the next tick
/// wherever their slot is. No rng: every event is a pure function of the
/// bullet and the ship position.
pub fn update_enemy_bullets() void {
    var pending: [enemy_pool_len]u8 = undefined;
    var n_pending: usize = 0;
    for (&world.w.enemy_bullets, 0..) |*b, i| {
        if (!b.active) continue;
        if (b.turn_left > 0) {
            if (b.turn != 0) {
                const v = patterns.rotate(.{ b.vx, b.vy }, b.turn);
                b.vx = v[0];
                b.vy = v[1];
            }
            b.turn_left -= 1;
        }
        if (b.drag != 1) {
            b.vx *= b.drag;
            b.vy *= b.drag;
        }
        if (b.ax != 0 or b.ay != 0) {
            b.vx += b.ax;
            b.vy += b.ay;
        }
        if (b.vmax > 0) {
            const s2 = b.vx * b.vx + b.vy * b.vy;
            if (s2 > b.vmax * b.vmax) {
                const k = b.vmax / @sqrt(s2);
                b.vx *= k;
                b.vy *= k;
            }
        }
        b.x += b.vx;
        b.y += b.vy;
        b.age += 1;
        if (b.event != .none and b.age == b.event_at) {
            pending[n_pending] = @intCast(i);
            n_pending += 1;
            continue;
        }
        if (off_field(b.*)) b.active = false;
    }
    for (pending[0..n_pending]) |i| {
        const b = &world.w.enemy_bullets[i];
        switch (b.event) {
            .none => {},
            .split => split(b),
            .aim => aim_event(b),
        }
        if (b.active and off_field(b.*)) b.active = false;
    }
}

/// The unit heading of a bullet's velocity; straight left when it stands
/// still.
fn heading(b: EnemyBullet) [2]f32 {
    const s = @sqrt(b.vx * b.vx + b.vy * b.vy);
    if (s == 0) return .{ -1, 0 };
    return .{ b.vx / s, b.vy / s };
}

/// `split`: the bullet dies and leaves a ring of `ev_n` pellets at its
/// position, the first along its heading, at `ev_speed / 16` rank-scaled.
/// Children split again (gen - 1) while gen > 0. A bullet that splits
/// outside the field leaves nothing; children that do not fit are dropped.
fn split(b: *EnemyBullet) void {
    const parent = b.*;
    b.active = false;
    if (parent.ev_n == 0 or off_field(parent)) return;
    const dir = heading(parent);
    const child: Shot = .{
        .speed = @as(f32, @floatFromInt(parent.ev_speed)) / 16,
        .shape = .pellet,
        .source = parent.source,
        .event = if (parent.gen > 0) .split else .none,
        .event_at = if (parent.gen > 0) parent.event_at else 0,
        .ev_n = if (parent.gen > 0) parent.ev_n else 0,
        .ev_speed = if (parent.gen > 0) parent.ev_speed else 0,
        .gen = parent.gen -| 1,
    };
    const n: u32 = parent.ev_n;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const a: i32 = @intCast(i * 256 / n);
        _ = spawn_shot(parent.x, parent.y, patterns.rotate(dir, a), child) orelse return;
    }
}

/// `aim`: the velocity becomes the aim at the ship times `ev_speed / 16`
/// (rank-scaled), drag 1, no accel, no vmax, no more turning. With
/// `ev_n > 1` the bullet is the middle of a fan of `ev_n`, 8/256 apart
/// (for even n, the one just below the middle), and the others are
/// spawned with no program.
fn aim_event(b: *EnemyBullet) void {
    const dir = patterns.aim(b.x, b.y);
    const base = @as(f32, @floatFromInt(b.ev_speed)) / 16;
    const n: i32 = @max(b.ev_n, 1);
    const mid = @divTrunc(n - 1, 2);
    const extra: Shot = .{ .speed = base, .shape = b.shape, .source = b.source };
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        const off = @divTrunc((2 * i - (n - 1)) * aim_fan_step, 2);
        const d = if (off == 0) dir else patterns.rotate(dir, off);
        if (i != mid) {
            _ = spawn_shot(b.x, b.y, d, extra);
            continue;
        }
        const v = rank.bullet_speed(base, b.shape);
        b.vx = d[0] * v;
        b.vy = d[1] * v;
    }
    b.drag = 1;
    b.ax = 0;
    b.ay = 0;
    b.vmax = 0;
    b.turn_left = 0;
    b.event = .none;
}

/// Zap: `bolt.png` cells 0-1 flickering every 2 ticks. Seeker: cells
/// 4-5. Beam: drawn with `cart.rect`, 24 px long, 1-3 px thick (by
/// damage) in Anti-White, its tail flickering Coral.
pub fn draw_bolts(tick: u32) void {
    const frame = (tick / 2) % 2;
    for (world.w.bolts) |b| {
        if (!b.active) continue;
        const x: i32 = @intFromFloat(@floor(b.x));
        const y: i32 = @intFromFloat(@floor(b.y));
        switch (b.kind) {
            .zap => draw.draw_sprite(gfx.bolt, bolt_w, bolt_h, frame, x, y, .{}),
            .seeker => draw.draw_sprite(gfx.bolt, bolt_w, bolt_h, 4 + frame, x, y, .{}),
            .beam => draw_beam(b, x, y, frame),
        }
    }
}

fn draw_beam(b: Bolt, x: i32, y: i32, frame: u32) void {
    const t = beam_thickness(b);
    const ty = y + @as(i32, @intCast((beam_h - t) / 2));
    // cart.rect clips to the screen itself.
    cart.rect(.{ .x = x, .y = ty, .width = beam_len, .height = t, .fill_color = draw.anti_white });
    if (frame == 1) cart.rect(.{ .x = x, .y = ty, .width = beam_len / 3, .height = t, .fill_color = draw.coral });
}

pub fn draw_enemy_bullets() void {
    for (world.w.enemy_bullets) |b| {
        if (b.active) draw_enemy_bullet(b, .{});
    }
}

/// One enemy bullet (also redrawn in flash-white by the bug report).
pub fn draw_enemy_bullet(b: EnemyBullet, opts: draw.SpriteOpts) void {
    const x: i32 = @intFromFloat(@floor(b.x));
    const y: i32 = @intFromFloat(@floor(b.y));
    switch (b.shape) {
        // 8x8 cell: top-left = center - (4, 4).
        .round => draw.draw_sprite(gfx.bugs_small, 8, 8, 2 + (b.age / 4) % 2, x - 4, y - 4, opts),
        // The 8x4 needle sits centered in a 16x16 cell: top-left = center - (8, 8).
        .needle => draw.draw_sprite(gfx.bugs, 16, 16, 8, x - 8, y - 8, opts),
        // 4x4 dot centered in an 8x8 cell.
        .pellet => draw.draw_sprite(gfx.shots, 8, 8, (b.age / 4) % 2, x - 4, y - 4, opts),
        // 12x12 orb centered in a 16x16 cell, pulsing.
        .orb => draw.draw_sprite(gfx.orb, 16, 16, (b.age / 6) % 2, x - 8, y - 8, opts),
    }
}

pub fn live_bolts() u32 {
    var n: u32 = 0;
    for (world.w.bolts) |b| n += @intFromBool(b.active);
    return n;
}
