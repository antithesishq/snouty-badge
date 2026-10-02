//! Powerup crates (PLAN.md M6, SPEC.md 5.4): a pool of 4 in
//! `world.w.pickups`, dropped by kills (`collide.zig`) and by the boss's
//! fire phase changing (`enemies.zig`), kind from a fixed 8-step sequence
//! (`world.w.drops`), never from the rng. Collection is any overlap of the
//! 16x16 crate with the 32x24 ship cell; what it grants lives in
//! `world.w.player`, so a rewind across a collection takes it back.
const gfx = @import("gfx");
const draw = @import("draw.zig");
const enemies = @import("enemies.zig");
const fx = @import("fx.zig");
const player = @import("player.zig");
const world = @import("world.zig");

/// `pickups.png` cell index = kind.
pub const Kind = enum(u8) { fuzzer, assert, bisect, fork, retry, cores };

pub const size = 16;
const drift: f32 = 0.5;
const bob_amplitude: f32 = 6;
const bob_period: u32 = 90;
/// Clamp for the cell top: the play area.
const min_y: f32 = 16;
const max_y: f32 = 104;
const gone_x: f32 = -16;
const collect_points: u32 = 100;
/// A crate that can grant nothing more (max level, fourth fork, second
/// shield) scores this instead.
const spare_points: u32 = 500;

pub const Pickup = struct {
    active: bool = false,
    kind: Kind = .fuzzer,
    /// Cell top-left.
    x: f32 = 0,
    y: f32 = 0,
    /// The bob's center line (cell top).
    base_y: f32 = 0,
    age: u32 = 0,
};

/// The drop sequence cursor and the crates spawned this game, in
/// `world.w.drops`.
pub const Drops = struct {
    /// Index into `sequence`, wraps at 8; advanced only when a crate
    /// actually spawns, so a drop lost to a full pool skips no kind.
    seq: u8 = 0,
    /// Crates spawned this game (`debug_drops`).
    count: u32 = 0,
};

const Slot = enum { w, x, cores, fork, retry };
/// W = the ship's weapon at drop time, X = the next kind after it.
const sequence = [8]Slot{ .w, .cores, .w, .fork, .x, .retry, .w, .fork };

fn weapon_kind(wp: player.Weapon) Kind {
    return @fromBackingInt(@intCast(@backingInt(wp)));
}

fn next_weapon(wp: player.Weapon) player.Weapon {
    return switch (wp) {
        .fuzzer => .assert,
        .assert => .bisect,
        .bisect => .fuzzer,
    };
}

/// Drops the next crate of the sequence centered on (cx, cy). A full pool
/// loses the drop.
pub fn spawn_drop(cx: f32, cy: f32) void {
    const d = &world.w.drops;
    for (&world.w.pickups) |*c| {
        if (c.active) continue;
        const wp = world.w.player.weapon;
        const kind: Kind = switch (sequence[d.seq % sequence.len]) {
            .w => weapon_kind(wp),
            .x => weapon_kind(next_weapon(wp)),
            .cores => .cores,
            .fork => .fork,
            .retry => .retry,
        };
        const y = clamp_y(cy - size / 2);
        c.* = .{ .active = true, .kind = kind, .x = cx - size / 2, .y = y, .base_y = cy - size / 2 };
        d.seq = @intCast((d.seq + 1) % sequence.len);
        d.count += 1;
        return;
    }
}

fn clamp_y(y: f32) f32 {
    return @min(@max(y, min_y), max_y);
}

/// Drift, bob, leave at the left edge, and collection by the ship cell.
pub fn update() void {
    const p = &world.w.player;
    for (&world.w.pickups) |*c| {
        if (!c.active) continue;
        c.age += 1;
        c.x -= drift;
        const phase = (c.age % bob_period) * 256 / bob_period;
        c.y = clamp_y(c.base_y + bob_amplitude * enemies.sin_table[phase]);
        if (c.x < gone_x) {
            c.active = false;
            continue;
        }
        if (c.x < p.x + player.cell_w and p.x < c.x + size and
            c.y < p.y + player.cell_h and p.y < c.y + size)
        {
            collect(c.kind);
            fx.spawn(.spark, @intFromFloat(@floor(c.x + size / 2)), @intFromFloat(@floor(c.y + size / 2)));
            c.active = false;
        }
    }
}

/// The crate's effect (PLAN.md M6 "Numbers"), plus +100 for any crate.
fn collect(kind: Kind) void {
    const p = &world.w.player;
    player.add_score(collect_points);
    switch (kind) {
        .fuzzer, .assert, .bisect => {
            const wp: player.Weapon = @fromBackingInt(@intCast(@backingInt(kind)));
            if (wp != p.weapon) {
                p.weapon = wp;
            } else if (p.level < player.max_level) {
                p.level += 1;
            } else {
                player.add_score(spare_points);
            }
        },
        .fork => if (p.forks < player.max_forks) {
            p.forks += 1;
        } else {
            player.add_score(spare_points);
        },
        .retry => if (p.shield == 0) {
            p.shield = 1;
        } else {
            player.add_score(spare_points);
        },
        .cores => p.cores += 1,
    }
}

pub fn live_count() u32 {
    var n: u32 = 0;
    for (world.w.pickups) |c| n += @intFromBool(c.active);
    return n;
}

/// After the enemies, before the ghosts and the ship.
pub fn draw_pickups() void {
    for (world.w.pickups) |c| {
        if (!c.active) continue;
        draw.draw_sprite(gfx.pickups, size, size, @backingInt(c.kind), @intFromFloat(@floor(c.x)), @intFromFloat(@floor(c.y)), .{});
    }
}
