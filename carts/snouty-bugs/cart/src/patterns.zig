//! Bullet emitters used by the enemy fire programs (PLAN.md M7 "Bullet
//! engine"). (x, y) is the emitter center; angles are in 1/256 turns, 0 =
//! right, 64 = down, so `enemies.sin_table` is indexed directly
//! (cos(a) = sin(a + 64)). Aimed patterns rotate the unit vector towards
//! the ship's hitbox center with a rotation matrix from the table; no
//! atan2, no libm (`@sqrt` is an FPU instruction). Screen y points down, so
//! a positive angle turns clockwise on screen. Every emitter takes a
//! `bullets.Shot` with a base (rank 0) speed: `bullets.spawn_shot` scales
//! it by rank. Shots that do not fit in the pool are dropped.
const bullets = @import("bullets.zig");
const enemies = @import("enemies.zig");
const player = @import("player.zig");

const Shot = bullets.Shot;

fn sin256(a: i32) f32 {
    return enemies.sin_table[@as(u8, @truncate(@as(u32, @bitCast(a))))];
}

fn cos256(a: i32) f32 {
    return sin256(a + 64);
}

/// The unit vector at `angle_256` (0 = right, 64 = down).
pub fn dir256(angle_256: i32) [2]f32 {
    return .{ cos256(angle_256), sin256(angle_256) };
}

/// `v` rotated by `angle_256` (positive = clockwise on screen).
pub fn rotate(v: [2]f32, angle_256: i32) [2]f32 {
    const c = cos256(angle_256);
    const s = sin256(angle_256);
    return .{ v[0] * c - v[1] * s, v[0] * s + v[1] * c };
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

/// One bullet straight at the ship.
pub fn aimed(x: f32, y: f32, shot: Shot) void {
    _ = bullets.spawn_shot(x, y, aim(x, y), shot);
}

/// `n` bullets centered on the aim direction, `step_256` apart (the old
/// `spread`). For even `n` the half-step offsets are rounded toward zero.
pub fn fan(x: f32, y: f32, n: u32, step_256: u32, shot: Shot) void {
    const dir = aim(x, y);
    const ni: i32 = @intCast(n);
    const step: i32 = @intCast(step_256);
    var i: i32 = 0;
    while (i < ni) : (i += 1) {
        const off = @divTrunc((2 * i - (ni - 1)) * step, 2);
        _ = bullets.spawn_shot(x, y, rotate(dir, off), shot);
    }
}

/// `n` bullets spread evenly over `span_256`, centered on the aim
/// direction, both ends included. One bullet is simply aimed.
pub fn arc(x: f32, y: f32, n: u32, span_256: u32, shot: Shot) void {
    if (n == 0) return;
    if (n == 1) return aimed(x, y, shot);
    const dir = aim(x, y);
    const ni: i32 = @intCast(n);
    const span: i32 = @intCast(span_256);
    var i: i32 = 0;
    while (i < ni) : (i += 1) {
        const off = @divTrunc(i * span, ni - 1) - @divTrunc(span, 2);
        _ = bullets.spawn_shot(x, y, rotate(dir, off), shot);
    }
}

/// `n` bullets evenly around a full turn, the first at `phase_256`. Not
/// aimed.
pub fn ring(x: f32, y: f32, n: u32, phase_256: i32, shot: Shot) void {
    if (n == 0) return;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const a = phase_256 + @as(i32, @intCast(i * 256 / n));
        _ = bullets.spawn_shot(x, y, dir256(a), shot);
    }
}

/// A ring of `n` whose first bullet points at the ship.
pub fn ring_aimed(x: f32, y: f32, n: u32, shot: Shot) void {
    if (n == 0) return;
    const dir = aim(x, y);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const a: i32 = @intCast(i * 256 / n);
        _ = bullets.spawn_shot(x, y, if (a == 0) dir else rotate(dir, a), shot);
    }
}

/// One bullet at the absolute angle `angle_256` (the old `shot`). Not
/// aimed.
pub fn at_angle(x: f32, y: f32, angle_256: i32, shot: Shot) void {
    _ = bullets.spawn_shot(x, y, dir256(angle_256), shot);
}

/// `n` aimed bullets on one line, speeds `shot.speed + i * speed_step`
/// (a sniper line: they arrive one after another).
pub fn line(x: f32, y: f32, n: u32, speed_step: f32, shot: Shot) void {
    const dir = aim(x, y);
    var s = shot;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        s.speed = shot.speed + @as(f32, @floatFromInt(i)) * speed_step;
        _ = bullets.spawn_shot(x, y, dir, s);
    }
}

/// `n` bullets evenly on the vertical line x from `y_top` to `y_bottom`
/// (both ends included; one bullet sits in the middle), all moving
/// straight left (angle 128, exactly (-1, 0)), skipping those with
/// |y - gap_y| < gap_half: a wall with a gap.
pub fn wall(x: f32, y_top: f32, y_bottom: f32, n: u32, gap_y: f32, gap_half: f32, shot: Shot) void {
    if (n == 0) return;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const y = if (n == 1)
            (y_top + y_bottom) / 2
        else
            y_top + (y_bottom - y_top) * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1));
        if (@abs(y - gap_y) < gap_half) continue;
        _ = bullets.spawn_shot(x, y, .{ -1, 0 }, shot);
    }
}
