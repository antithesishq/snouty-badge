//! Ship: movement, banking, zapper, invulnerability, lives, score. The
//! ship state is `world.w.player`; `lives` is meta-state kept here.
const cart = @import("cart-api");
const gfx = @import("gfx");
const draw = @import("draw.zig");
const input = @import("input.zig");
const bullets = @import("bullets.zig");
const world = @import("world.zig");

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

/// Ship state, stored in `world.w.player`. Defaults are the spawn values.
pub const State = struct {
    x: f32 = spawn_x,
    y: f32 = spawn_y,
    pose: Pose = .level,
    pose_age: u32 = 0,
    fire_cooldown: u32 = 0,
    invuln: u32 = 0,
    score: u32 = 0,
};

/// Meta-state outside the World (becomes the rewind stock in M2); reset by
/// `new_game` in `main.zig`.
pub var lives: u32 = start_lives;

pub fn update() void {
    const p = &world.w.player;
    if (input.held(.left)) p.x -= speed;
    if (input.held(.right)) p.x += speed;
    if (input.held(.up)) p.y -= speed;
    if (input.held(.down)) p.y += speed;
    p.x = @min(@max(p.x, min_x), max_x);
    p.y = @min(@max(p.y, min_y), max_y);

    // Banking: a pose must be held for bank_hold ticks before it can change,
    // so tapping the stick does not flicker the sprite.
    const want: Pose = if (input.held(.up) and !input.held(.down))
        .up
    else if (input.held(.down) and !input.held(.up))
        .down
    else
        .level;
    p.pose_age +|= 1;
    if (want != p.pose and p.pose_age >= bank_hold) {
        p.pose = want;
        p.pose_age = 0;
    }

    if (p.fire_cooldown > 0) p.fire_cooldown -= 1;
    if (input.held(.a) and p.fire_cooldown == 0) {
        _ = bullets.spawn_bolt(p.x + 28, p.y + 8);
        p.fire_cooldown = fire_interval;
    }

    if (p.invuln > 0) p.invuln -= 1;
}

pub fn invulnerable() bool {
    return world.w.player.invuln > 0;
}

/// Hitbox as [x, y, w, h].
pub fn hitbox() [4]f32 {
    const p = &world.w.player;
    return .{ p.x + hitbox_off[0], p.y + hitbox_off[1], hitbox_size, hitbox_size };
}

/// Takes a hit. Returns true when that was the last life.
pub fn hit() bool {
    const p = &world.w.player;
    if (p.invuln > 0) return false;
    lives -|= 1;
    p.invuln = invuln_ticks;
    return lives == 0;
}

pub fn add_score(points: u32) void {
    const p = &world.w.player;
    p.score = @min(p.score + points, score_cap);
}

pub fn draw_ship(tick: u32) void {
    const p = &world.w.player;
    const ix: i32 = @intFromFloat(@floor(p.x));
    const iy: i32 = @intFromFloat(@floor(p.y));
    // Blink while invulnerable: drawn every other tick.
    if (p.invuln == 0 or tick % 2 == 0) {
        draw.draw_sprite(gfx.thruster, 8, 8, (tick / 3) % 4, ix + thruster_off[0], iy + thruster_off[1], .{});
        draw.draw_sprite(gfx.ship, cell_w, cell_h, @backingInt(p.pose), ix, iy, .{});
    }
    if (p.invuln > 0) {
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
