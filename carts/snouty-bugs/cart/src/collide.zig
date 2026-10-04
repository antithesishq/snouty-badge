//! AABB collision passes: bolts vs enemies, enemy bullets vs the ship
//! hitbox (with graze), enemies vs the ship hitbox.
const bullets = @import("bullets.zig");
const enemies = @import("enemies.zig");
const player = @import("player.zig");
const fx = @import("fx.zig");
const world = @import("world.zig");
const pickups = @import("pickups.zig");
const formations = @import("formations.zig");
const rank = @import("rank.zig");

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
/// (bullets before enemies), or `.none` if unhurt or invulnerable. The
/// offender is left alive: `main` decides (a rewind restores the world
/// anyway; god mode and death remove it with `remove_offender`).
pub fn run() Hit {
    bolts_vs_enemies();
    if (player.invulnerable()) return .{};
    const hb = player.hitbox();

    for (&world.w.enemy_bullets, 0..) |*b, i| {
        if (!b.active) continue;
        const bb = bullets.hitbox(b.*);
        if (overlap(hb[0], hb[1], hb[2], hb[3], bb[0], bb[1], bb[2], bb[3])) {
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
        return .{ .by = .enemy, .kind = e.kind, .index = @intCast(i) };
    }
    return .{};
}

/// The M3 aftermath of a hit: the bullet vanishes, a rammer dies (the
/// boss survives a ram). A rammer is lost to its formation (no drop).
pub fn remove_offender(hit: Hit) void {
    switch (hit.by) {
        .none => {},
        .bullet => world.w.enemy_bullets[hit.index].active = false,
        .enemy => {
            const e = &world.w.enemies[hit.index];
            if (e.kind != .boss) {
                kill(e);
                formations.lost(e.formation);
            }
        },
    }
}

/// Zaps and seekers die on their first hit; a beam pierces, damaging each
/// enemy slot at most once (`hit_mask`). A spark at each hit. A kill by a
/// bolt counts for its formation (a complete one drops a crate), a beetle
/// drops one (every `beetle_drop_every`-th), and the rank may answer with
/// revenge bullets (PLAN.md M7); a ram kill does none of that.
fn bolts_vs_enemies() void {
    for (&world.w.bolts) |*b| {
        if (!b.active) continue;
        const bb = bullets.bolt_hitbox(b.*);
        for (&world.w.enemies, 0..) |*e, i| {
            if (!e.live() or !e.hittable()) continue;
            const bit = @as(u32, 1) << @intCast(i);
            if (b.kind == .beam and b.hit_mask & bit != 0) continue;
            const s = e.size();
            if (!overlap(bb[0], bb[1], bb[2], bb[3], e.x, e.y, s[0], s[1])) continue;
            fx.spawn(.spark, @intFromFloat(@floor(bb[0] + bb[2])), @intFromFloat(@floor(bb[1] + bb[3] / 2)));
            switch (enemies.damage(e, b.damage)) {
                .alive => e.flash = if (e.kind == .boss) 1 else 2,
                .killed => {
                    const c = e.center();
                    kill(e);
                    formations.killed(e.formation, c[0], c[1]);
                    drop_for_kill(e.kind, c);
                    rank.revenge(e.kind, c[0], c[1]);
                },
                .boss_dying => {},
            }
            if (b.kind == .beam) {
                b.hit_mask |= bit;
                continue;
            }
            b.active = false;
            break;
        }
    }
}

/// Every `beetle_drop_every`-th Memory Leak beetle killed by a bolt drops
/// a crate (PLAN.md M7; the M6 every-fifth-gnat rule is gone, gnat
/// strings drop as formations).
const beetle_drop_every: u32 = 1;

fn drop_for_kill(kind: enemies.Kind, c: [2]f32) void {
    if (kind != .beetle) return;
    const p = &world.w.player;
    p.beetle_kills += 1;
    if (p.beetle_kills % beetle_drop_every == 0) pickups.spawn_drop(c[0], c[1]);
}
