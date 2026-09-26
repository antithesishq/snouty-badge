//! Ship state: movement, banking, zapper, invulnerability, lives, score.
const cart = @import("cart-api");
const gfx = @import("gfx");
const draw = @import("draw.zig");
const input = @import("input.zig");
const bullets = @import("bullets.zig");

pub const cell_w = 32;
pub const cell_h = 24;

// Hard-coded until the real ship sheet reports its own (PLAN.md M1).
const hitbox_off = [2]f32{ 14, 9 };
const thruster_off = [2]i32{ -6, 8 };
pub const hitbox_size: f32 = 6;

const speed: f32 = 1.5;
const min_x: f32 = 0;
const max_x: f32 = 104;
const min_y: f32 = 10;
const max_y: f32 = 125 - cell_h;
const spawn_x: f32 = 16;
const spawn_y: f32 = 64 - cell_h / 2;

const fire_interval: u32 = 6;
const bank_hold: u32 = 6;
const invuln_ticks: u32 = 120;
pub const start_lives: u32 = 3;
const score_cap: u32 = 999_999;

pub const Pose = enum(u32) { level = 0, up = 1, down = 2 };

pub var x: f32 = spawn_x;
pub var y: f32 = spawn_y;
pub var pose: Pose = .level;
var pose_age: u32 = 0;
var fire_cooldown: u32 = 0;
pub var invuln: u32 = 0;
pub var lives: u32 = start_lives;
pub var score: u32 = 0;

pub fn reset() void {
    x = spawn_x;
    y = spawn_y;
    pose = .level;
    pose_age = 0;
    fire_cooldown = 0;
    invuln = 0;
    lives = start_lives;
    score = 0;
}

pub fn update() void {
    if (input.held(.left)) x -= speed;
    if (input.held(.right)) x += speed;
    if (input.held(.up)) y -= speed;
    if (input.held(.down)) y += speed;
    x = @min(@max(x, min_x), max_x);
    y = @min(@max(y, min_y), max_y);

    // Banking: a pose must be held for bank_hold ticks before it can change,
    // so tapping the stick does not flicker the sprite.
    const want: Pose = if (input.held(.up) and !input.held(.down))
        .up
    else if (input.held(.down) and !input.held(.up))
        .down
    else
        .level;
    pose_age +|= 1;
    if (want != pose and pose_age >= bank_hold) {
        pose = want;
        pose_age = 0;
    }

    if (fire_cooldown > 0) fire_cooldown -= 1;
    if (input.held(.a) and fire_cooldown == 0) {
        _ = bullets.spawn_bolt(x + 28, y + 8);
        fire_cooldown = fire_interval;
    }

    if (invuln > 0) invuln -= 1;
}

pub fn invulnerable() bool {
    return invuln > 0;
}

/// Hitbox as [x, y, w, h].
pub fn hitbox() [4]f32 {
    return .{ x + hitbox_off[0], y + hitbox_off[1], hitbox_size, hitbox_size };
}

/// Takes a hit. Returns true when that was the last life.
pub fn hit() bool {
    if (invuln > 0) return false;
    lives -|= 1;
    invuln = invuln_ticks;
    return lives == 0;
}

pub fn add_score(points: u32) void {
    score = @min(score + points, score_cap);
}

pub fn draw_ship(tick: u32) void {
    const ix: i32 = @intFromFloat(@floor(x));
    const iy: i32 = @intFromFloat(@floor(y));
    // Blink while invulnerable: drawn every other tick.
    if (invuln == 0 or tick % 2 == 0) {
        draw.draw_sprite(gfx.thruster, 8, 8, (tick / 3) % 4, ix + thruster_off[0], iy + thruster_off[1], .{});
        draw.draw_sprite(gfx.ship, cell_w, cell_h, @backingInt(pose), ix, iy, .{});
    }
    if (invuln > 0) {
        const hb = hitbox();
        // 1 px dot at the hitbox center.
        cart.hline(.{
            .x = @as(i32, @intFromFloat(hb[0])) + 3,
            .y = @as(i32, @intFromFloat(hb[1])) + 3,
            .len = 1,
            .color = draw.cream,
        });
    }
}
