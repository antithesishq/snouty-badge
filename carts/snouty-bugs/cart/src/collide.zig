//! AABB collision passes: bolts vs enemies, enemy bullets vs the ship
//! hitbox (with graze), enemies vs the ship hitbox.
const bullets = @import("bullets.zig");
const enemies = @import("enemies.zig");
const player = @import("player.zig");
const fx = @import("fx.zig");
const world = @import("world.zig");

/// What touched the ship this tick.
pub const HitBy = enum(u8) { none, enemy, bullet };

/// The hit result of one tick. `kind` is the enemy that rammed or the
/// `source` of the bullet (the bug message in M4); `index` is its slot in
/// `world.w.enemies` or `world.w.enemy_bullets`.
pub const Hit = struct {
    by: HitBy = .none,
    kind: enemies.Kind = .gnat,
    index: u8 = 0,
};

/// Graze margin: a bullet within this many pixels of the hitbox grazes it.
const graze_margin: f32 = 4;

pub fn overlap(ax: f32, ay: f32, aw: f32, ah: f32, bx: f32, by: f32, bw: f32, bh: f32) bool {
    return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah;
}

fn center(v: f32, size: f32) i32 {
    return @intFromFloat(@floor(v + size / 2));
}

/// Explosion at the enemy center, its points to the score, and it is gone.
pub fn kill(e: *enemies.Enemy) void {
    const s = e.size();
    fx.spawn(.explosion, center(e.x, s[0]), center(e.y, s[1]));
    player.add_score(e.points());
    e.active = false;
}

/// Runs all passes. Returns the first contact with the ship this tick
/// (bullets before enemies), or `.none` if unhurt or invulnerable.
pub fn run() Hit {
    bolts_vs_enemies();
    if (player.invulnerable()) return .{};
    const hb = player.hitbox();

    for (&world.w.enemy_bullets, 0..) |*b, i| {
        if (!b.active) continue;
        const bb = bullets.hitbox(b.*);
        if (overlap(hb[0], hb[1], hb[2], hb[3], bb[0], bb[1], bb[2], bb[3])) {
            b.active = false;
            return .{ .by = .bullet, .kind = b.source, .index = @intCast(i) };
        }
        if (b.grazed) continue;
        const m = graze_margin;
        if (overlap(hb[0], hb[1], hb[2], hb[3], bb[0] - m, bb[1] - m, bb[2] + 2 * m, bb[3] + 2 * m)) {
            b.grazed = true;
            player.add_score(1);
            world.w.player.grazes += 1;
        }
    }

    for (&world.w.enemies, 0..) |*e, i| {
        // A flickering, vanished or dying boss is a ghost: it neither takes
        // nor gives hits.
        if (!e.live() or !e.hittable()) continue;
        const s = e.size();
        if (!overlap(hb[0], hb[1], hb[2], hb[3], e.x, e.y, s[0], s[1])) continue;
        const kind = e.kind;
        // The boss survives a ram (M3); everything else dies.
        if (kind != .boss) kill(e);
        return .{ .by = .enemy, .kind = kind, .index = @intCast(i) };
    }
    return .{};
}

fn bolts_vs_enemies() void {
    for (&world.w.bolts) |*b| {
        if (!b.active) continue;
        for (&world.w.enemies) |*e| {
            if (!e.live() or !e.hittable()) continue;
            const s = e.size();
            if (!overlap(b.x, b.y, bullets.bolt_w, bullets.bolt_h, e.x, e.y, s[0], s[1])) continue;
            b.active = false;
            fx.spawn(.spark, @intFromFloat(@floor(b.x + bullets.bolt_w)), @intFromFloat(@floor(b.y + bullets.bolt_h / 2)));
            switch (enemies.damage(e, 1)) {
                .alive => e.flash = if (e.kind == .boss) 1 else 2,
                .killed => kill(e),
                .boss_dying => {},
            }
            break;
        }
    }
}
