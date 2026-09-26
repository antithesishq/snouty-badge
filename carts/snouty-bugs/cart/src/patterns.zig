//! Bullet emitters used by the enemy fire programs. Angles are in 1/256
//! turns so `enemies.sin_table` is indexed directly (cos(a) = sin(a + 64)).
//! Aimed patterns rotate the unit vector towards the ship's hitbox center
//! with a rotation matrix from the table; no atan2, no libm (`@sqrt` is an
//! FPU instruction). Screen y points down, so a positive angle turns
//! clockwise on screen; every pattern here is symmetric, so it does not
//! matter. Shots that do not fit in the pool are dropped by `bullets`.
const bullets = @import("bullets.zig");
const enemies = @import("enemies.zig");
const player = @import("player.zig");

const Kind = enemies.Kind;
const Shape = bullets.Shape;

fn sin256(a: i32) f32 {
    return enemies.sin_table[@as(u8, @truncate(@as(u32, @bitCast(a))))];
}

fn cos256(a: i32) f32 {
    return sin256(a + 64);
}

/// Unit vector from (x, y) to the ship's hitbox center; straight left when
/// the two coincide.
pub fn aim(x: f32, y: f32) [2]f32 {
    const hb = player.hitbox();
    const dx = hb[0] + hb[2] / 2 - x;
    const dy = hb[1] + hb[3] / 2 - y;
    const d = @sqrt(dx * dx + dy * dy);
    if (d == 0) return .{ -1, 0 };
    return .{ dx / d, dy / d };
}

/// Fires one bullet along `dir` rotated by `angle_256`.
fn fire_rotated(x: f32, y: f32, dir: [2]f32, angle_256: i32, speed: f32, shape: Shape, source: Kind) void {
    const c = cos256(angle_256);
    const s = sin256(angle_256);
    const vx = (dir[0] * c - dir[1] * s) * speed;
    const vy = (dir[0] * s + dir[1] * c) * speed;
    _ = bullets.spawn_enemy_bullet(x, y, vx, vy, shape, source);
}

/// One bullet from (x, y) straight at the ship hitbox center.
pub fn aimed(x: f32, y: f32, speed: f32, shape: Shape, source: Kind) void {
    const dir = aim(x, y);
    _ = bullets.spawn_enemy_bullet(x, y, dir[0] * speed, dir[1] * speed, shape, source);
}

/// `n` bullets centered on the aim direction, `step_256` apart. For even
/// `n` the half-step offsets are rounded toward zero.
pub fn spread(x: f32, y: f32, n: u32, step_256: u32, speed: f32, shape: Shape, source: Kind) void {
    const dir = aim(x, y);
    const ni: i32 = @intCast(n);
    const step: i32 = @intCast(step_256);
    var i: i32 = 0;
    while (i < ni) : (i += 1) {
        const off = @divTrunc((2 * i - (ni - 1)) * step, 2);
        fire_rotated(x, y, dir, off, speed, shape, source);
    }
}

/// `n` bullets evenly around a full turn, the first at `phase_256`
/// (0 = right, 64 = down). Not aimed.
pub fn ring(x: f32, y: f32, n: u32, phase_256: u32, speed: f32, shape: Shape, source: Kind) void {
    if (n == 0) return;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const a: i32 = @intCast((phase_256 + i * 256 / n) % 256);
        _ = bullets.spawn_enemy_bullet(x, y, cos256(a) * speed, sin256(a) * speed, shape, source);
    }
}

/// `n` bullets spread evenly over `span_256`, centered on the aim direction
/// (both ends included). One bullet is simply aimed.
pub fn arc(x: f32, y: f32, n: u32, span_256: u32, speed: f32, shape: Shape, source: Kind) void {
    if (n == 0) return;
    if (n == 1) return aimed(x, y, speed, shape, source);
    const dir = aim(x, y);
    const ni: i32 = @intCast(n);
    const span: i32 = @intCast(span_256);
    var i: i32 = 0;
    while (i < ni) : (i += 1) {
        const off = @divTrunc(i * span, ni - 1) - @divTrunc(span, 2);
        fire_rotated(x, y, dir, off, speed, shape, source);
    }
}
