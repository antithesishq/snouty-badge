//! Player zapper bolts (`world.w.bolts`) and the enemy bullet pool
//! (`world.w.enemy_bullets`, 96). Enemy bullets are spawned by the fire
//! programs in `patterns.zig` and remember who fired them (`source`).
const cart = @import("cart-api");
const gfx = @import("gfx");
const draw = @import("draw.zig");
const world = @import("world.zig");
const enemies = @import("enemies.zig");

pub const bolt_w = 16;
pub const bolt_h = 8;
const bolt_speed: f32 = 4.0;

pub const Bolt = struct {
    active: bool = false,
    x: f32 = 0,
    y: f32 = 0,
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
pub fn spawn_bolt(x: f32, y: f32) bool {
    for (&world.w.bolts) |*b| {
        if (b.active) continue;
        b.* = .{ .active = true, .x = x, .y = y };
        return true;
    }
    return false;
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

/// Removes every enemy bullet (bomb).
pub fn clear_enemy_bullets() void {
    for (&world.w.enemy_bullets) |*b| b.* = .{};
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

/// Moves the player's bolts.
pub fn update() void {
    for (&world.w.bolts) |*b| {
        if (!b.active) continue;
        b.x += bolt_speed;
        if (b.x >= @as(f32, cart.screen_width)) b.active = false;
    }
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

pub fn draw_bolts(tick: u32) void {
    const frame = (tick / 2) % 2;
    for (world.w.bolts) |b| {
        if (!b.active) continue;
        draw.draw_sprite(gfx.bolt, bolt_w, bolt_h, frame, @intFromFloat(@floor(b.x)), @intFromFloat(@floor(b.y)), .{});
    }
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
