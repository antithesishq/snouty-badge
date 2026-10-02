//! Player bolts (`world.w.bolts`, 64: the fuzzer's zaps, the assert's
//! beams and the bisect's seekers, PLAN.md M6) and the enemy bullet pool
//! (`world.w.enemy_bullets`, 96). Enemy bullets are spawned by the fire
//! programs in `patterns.zig` and remember who fired them (`source`).
const cart = @import("cart-api");
const gfx = @import("gfx");
const draw = @import("draw.zig");
const world = @import("world.zig");
const enemies = @import("enemies.zig");

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

/// round: `bugs_small` cells 2-3 (pulse, 4 ticks/frame); needle: `bugs` cell 8.
pub const Shape = enum(u8) { round, needle };

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
};

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

/// Returns false when the pool (96) is full; the shot is dropped.
pub fn spawn_enemy_bullet(x: f32, y: f32, vx: f32, vy: f32, shape: Shape, source: enemies.Kind) bool {
    for (&world.w.enemy_bullets) |*b| {
        if (b.active) continue;
        b.* = .{ .active = true, .x = x, .y = y, .vx = vx, .vy = vy, .shape = shape, .source = source };
        return true;
    }
    return false;
}

pub fn live_enemy_bullets() u32 {
    var n: u32 = 0;
    for (world.w.enemy_bullets) |b| n += @intFromBool(b.active);
    return n;
}

/// Hitbox of an enemy bullet as (x, y, w, h): round 6x6, needle 8x4, centered.
pub fn hitbox(b: EnemyBullet) [4]f32 {
    return switch (b.shape) {
        .round => .{ b.x - 3, b.y - 3, 6, 6 },
        .needle => .{ b.x - 4, b.y - 2, 8, 4 },
    };
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

/// Moves enemy bullets and culls those whose center left the field.
pub fn update_enemy_bullets() void {
    for (&world.w.enemy_bullets) |*b| {
        if (!b.active) continue;
        b.x += b.vx;
        b.y += b.vy;
        b.age += 1;
        if (b.x < -4.0 or b.x >= 164.0 or b.y < 4.0 or b.y >= 132.0) b.active = false;
    }
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
    }
}

pub fn live_bolts() u32 {
    var n: u32 = 0;
    for (world.w.bolts) |b| n += @intFromBool(b.active);
    return n;
}
