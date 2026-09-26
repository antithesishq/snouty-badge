//! AABB collision passes: bolts vs enemies, enemies vs the ship hitbox.
const bullets = @import("bullets.zig");
const enemies = @import("enemies.zig");
const player = @import("player.zig");
const fx = @import("fx.zig");
const world = @import("world.zig");

pub fn overlap(ax: f32, ay: f32, aw: f32, ah: f32, bx: f32, by: f32, bw: f32, bh: f32) bool {
    return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah;
}

fn center(v: f32, size: f32) i32 {
    return @intFromFloat(@floor(v + size / 2));
}

fn kill(e: *enemies.Enemy) void {
    const s = e.size();
    fx.spawn(.explosion, center(e.x, s[0]), center(e.y, s[1]));
    e.active = false;
}

/// Runs both passes. Returns true when the player lost their last life.
pub fn run() bool {
    for (&world.w.bolts) |*b| {
        if (!b.active) continue;
        for (&world.w.enemies) |*e| {
            if (!e.live()) continue;
            const s = e.size();
            if (!overlap(b.x, b.y, bullets.bolt_w, bullets.bolt_h, e.x, e.y, s[0], s[1])) continue;
            b.active = false;
            fx.spawn(.spark, @intFromFloat(@floor(b.x + bullets.bolt_w)), @intFromFloat(@floor(b.y + bullets.bolt_h / 2)));
            e.hp -|= 1;
            if (e.hp == 0) {
                player.add_score(e.points());
                kill(e);
            } else {
                e.flash = 2;
            }
            break;
        }
    }

    var dead = false;
    if (!player.invulnerable()) {
        const hb = player.hitbox();
        for (&world.w.enemies) |*e| {
            if (!e.live()) continue;
            const s = e.size();
            if (!overlap(hb[0], hb[1], hb[2], hb[3], e.x, e.y, s[0], s[1])) continue;
            kill(e);
            if (player.hit()) dead = true;
            // One hit per tick: invulnerability starts now.
            break;
        }
    }
    return dead;
}
