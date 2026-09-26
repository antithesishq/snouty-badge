//! Player zapper bolts. The enemy bullet pool is declared for M2.
const cart = @import("cart-api");
const gfx = @import("gfx");
const draw = @import("draw.zig");

pub const bolt_w = 16;
pub const bolt_h = 8;
const bolt_speed: f32 = 4.0;

pub const Bolt = struct {
    active: bool = false,
    x: f32 = 0,
    y: f32 = 0,
};

pub const EnemyBullet = struct {
    active: bool = false,
    x: f32 = 0,
    y: f32 = 0,
    vx: f32 = 0,
    vy: f32 = 0,
};

pub var bolts: [24]Bolt = @splat(.{});
/// Unused in M1 (SPEC.md section 6: pool of 96).
pub var enemy_bullets: [96]EnemyBullet = @splat(.{});

pub fn reset() void {
    bolts = @splat(.{});
    enemy_bullets = @splat(.{});
}

/// Returns false when the pool is full (the shot is dropped).
pub fn spawn_bolt(x: f32, y: f32) bool {
    for (&bolts) |*b| {
        if (b.active) continue;
        b.* = .{ .active = true, .x = x, .y = y };
        return true;
    }
    return false;
}

pub fn update() void {
    for (&bolts) |*b| {
        if (!b.active) continue;
        b.x += bolt_speed;
        if (b.x >= @as(f32, cart.screen_width)) b.active = false;
    }
}

pub fn draw_bolts(tick: u32) void {
    const frame = (tick / 2) % 2;
    for (bolts) |b| {
        if (!b.active) continue;
        draw.draw_sprite(gfx.bolt, bolt_w, bolt_h, frame, @intFromFloat(@floor(b.x)), @intFromFloat(@floor(b.y)), .{});
    }
}

pub fn live_bolts() u32 {
    var n: u32 = 0;
    for (bolts) |b| n += @intFromBool(b.active);
    return n;
}
